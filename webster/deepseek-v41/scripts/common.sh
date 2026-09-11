#!/usr/bin/env bash
set -euo pipefail

SHAMU_NETBIRD="100.73.140.127"
SHAMU_LAN="192.168.1.75"
SHAMU_RAIL="10.10.1.1"
TILIKUM_NETBIRD="100.73.89.150"
TILIKUM_RAIL="10.10.1.2"
NCCL_IFACE="enP1p3s0f1np1"
NCCL_HCA="mlx5_1"
CANARY_PORT="8000"
MIN_FREE_BEFORE_STAGE_BYTES="805306368000"
MIN_FREE_AFTER_STAGE_BYTES="214748364800"
CHECKPOINT_REPO="deepseek-ai/DeepSeek-V4.1-Flash"
CHECKPOINT_REVISION="dba1be0a40aa45a94ad051997016db3960a90277"
CHECKPOINT_SHARDS="48"
CHECKPOINT_TENSOR_BYTES="510286023000"
CHECKPOINT_SHARD_FILE_BYTES="510296708312"
PROMETHEUS_URL="http://100.73.140.127:9095"
GLM_METRICS_INSTANCE="100.73.140.127:8000"
STAGE_MIN_SUCCESS_RATE="0.99"
STAGE_LATENCY_MULTIPLIER="2.0"
STAGE_BASELINE_MIN_REQUESTS="20"
if [[ "${WEBSTER_PREFLIGHT_TEST_MODE:-0}" == "1" || "${WEBSTER_STAGE_TEST_MODE:-0}" == "1" ]]; then
  RUNS_ROOT="${TEST_RUNS_ROOT:-/home/ubuntu/deepseek-v41-runs}"
else
  RUNS_ROOT="/home/ubuntu/deepseek-v41-runs"
fi

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

validate_phase() {
  case "${1:-}" in
    baseline|stage|alias|canary|publish) ;;
    *) die "invalid phase: ${1:-<empty>}" ;;
  esac
}

canonical_path() {
  realpath -m -- "$1"
}

validate_run_root() {
  local requested resolved relative
  requested="${1:-}"
  [[ -n "$requested" ]] || die "run root is required"
  resolved="$(canonical_path "$requested")"
  case "$resolved" in
    "$RUNS_ROOT"/*) ;;
    *) die "run root must resolve beneath $RUNS_ROOT" ;;
  esac
  relative="${resolved#"$RUNS_ROOT"/}"
  [[ "$relative" != */* && "$relative" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] ||
    die "run root must end in one UTC change id"
  printf '%s\n' "$resolved"
}

init_run_root() {
  RUN_ROOT="$(validate_run_root "$1")"
  export RUN_ROOT
  umask 077
  mkdir -p -- "$RUN_ROOT" "$RUN_ROOT/baseline" "$RUN_ROOT/logs" \
    "$RUN_ROOT/metrics" "$RUN_ROOT/aiperf"
  chmod 0700 "$RUN_ROOT" "$RUN_ROOT/baseline" "$RUN_ROOT/logs" \
    "$RUN_ROOT/metrics" "$RUN_ROOT/aiperf"
  touch "$RUN_ROOT/events.tsv" "$RUN_ROOT/summary.md"
  chmod 0600 "$RUN_ROOT/events.tsv" "$RUN_ROOT/summary.md"
  if [[ ! -f "$RUN_ROOT/manifest.env" ]]; then
    {
      printf 'CHECKPOINT_REPO=%s\n' "$CHECKPOINT_REPO"
      printf 'CHECKPOINT_REVISION=%s\n' "$CHECKPOINT_REVISION"
      printf 'CHECKPOINT_SHARDS=%s\n' "$CHECKPOINT_SHARDS"
      printf 'CHECKPOINT_TENSOR_BYTES=%s\n' "$CHECKPOINT_TENSOR_BYTES"
      printf 'CHECKPOINT_SHARD_FILE_BYTES=%s\n' "$CHECKPOINT_SHARD_FILE_BYTES"
      printf 'VLLM_COMMIT=\nVLLM_BASE_IMAGE_DIGEST=\nVLLM_IMAGE_ID=\n'
      printf 'VLLM_IMAGE_TAR_SHA256=\nAIPERF_COMMIT=\nWEKA_REPOSITORY=\nWEKA_REVISION=\n'
    } >"$RUN_ROOT/manifest.env"
    chmod 0600 "$RUN_ROOT/manifest.env"
  fi
}

event() {
  local milestone="$1" decision="$2" reason="$3" timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  reason="${reason//$'\t'/ }"
  reason="${reason//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\n' "$timestamp" "$milestone" "$decision" "$reason" \
    >>"$RUN_ROOT/events.tsv"
}

redact_stream() {
  sed -E \
    -e 's/(Authorization:[[:space:]]*Bearer)[[:space:]]+[^[:space:]]+/\1 [REDACTED]/Ig' \
    -e "s/((api[_-]?key|master[_-]?key|password|secret|token)[\"']?[[:space:]]*[:=][[:space:]]*)[^,[:space:]\"']+/\\1[REDACTED]/Ig" \
    -e 's/sk-[A-Za-z0-9._-]{8,}/[REDACTED-KEY]/g'
}

capture() {
  local name="$1" output temporary status
  shift
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe capture name: $name"
  output="$RUN_ROOT/logs/$name.log"
  temporary="$output.tmp.$$"
  set +e
  "$@" >"$temporary" 2>&1
  status=$?
  set -e
  redact_stream <"$temporary" >"$output"
  rm -f -- "$temporary"
  chmod 0600 "$output"
  printf 'capture %s status=%s artifact=%s\n' "$name" "$status" "$output"
  return "$status"
}

require_eq() {
  local label="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] ||
    die "$label mismatch (expected $expected, got $actual)"
}

require_ge() {
  local label="$1" minimum="$2" actual="$3"
  [[ "$actual" =~ ^[0-9]+$ ]] || die "$label is not an integer"
  (( actual >= minimum )) || die "$label is below required floor"
}

write_glm_window_snapshot() {
  local output="$1" window="$2"
  [[ "$window" =~ ^[1-9][0-9]*[mhd]$ ]] || die "invalid Prometheus window: $window"
  python3 - "$PROMETHEUS_URL" "$GLM_METRICS_INSTANCE" "$window" "$output" <<'PY'
import datetime
import json
import math
import os
import sys
import urllib.parse
import urllib.request

prometheus_url, instance, window, output = sys.argv[1:]
selector = f'instance="{instance}"'
queries = {
    "request_count": (
        f'sum(increase(vllm:request_success_total{{{selector}}}[{window}]))'
    ),
    "successful_requests": (
        'sum(increase(vllm:request_success_total{'
        f'{selector},finished_reason!~"abort|error"}}[{window}]))'
    ),
    "p90_seconds": (
        'histogram_quantile(0.90, sum by (le) '
        f'(rate(vllm:e2e_request_latency_seconds_bucket{{{selector}}}[{window}])))'
    ),
}


def query(expression):
    url = prometheus_url.rstrip("/") + "/api/v1/query?query=" + urllib.parse.quote(expression)
    with urllib.request.urlopen(url, timeout=15) as response:
        payload = json.load(response)
    if payload.get("status") != "success":
        raise RuntimeError(f"Prometheus query failed: {payload.get('error', 'unknown error')}")
    rows = payload.get("data", {}).get("result", [])
    if len(rows) != 1:
        return None
    raw = rows[0].get("value", [None, None])[1]
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


values = {name: query(expression) for name, expression in queries.items()}
request_count = values["request_count"]
successful = values["successful_requests"]
success_rate = None
if request_count is not None and request_count > 0 and successful is not None:
    success_rate = min(1.0, max(0.0, successful / request_count))
result = {
    "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "instance": instance,
    "window": window,
    "request_count": request_count,
    "successful_requests": successful,
    "success_rate": success_rate,
    "p90_seconds": values["p90_seconds"],
    "queries": queries,
}
temporary = output + f".tmp.{os.getpid()}"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(result, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, output)
PY
}

stage_window_decision() {
  local baseline_p90="$1" request_count="$2" success_rate="$3" p90="$4"
  python3 - "$baseline_p90" "$request_count" "$success_rate" "$p90" \
    "$STAGE_MIN_SUCCESS_RATE" "$STAGE_LATENCY_MULTIPLIER" <<'PY'
import math
import sys

baseline_raw, requests_raw, success_raw, p90_raw, minimum_raw, multiplier_raw = sys.argv[1:]


def finite_number(raw, label):
    try:
        value = float(raw)
    except ValueError as error:
        raise SystemExit(f"invalid {label}: {raw}") from error
    if not math.isfinite(value):
        raise SystemExit(f"invalid {label}: {raw}")
    return value


baseline = finite_number(baseline_raw, "baseline p90")
requests = finite_number(requests_raw, "request count")
minimum = finite_number(minimum_raw, "minimum success rate")
multiplier = finite_number(multiplier_raw, "latency multiplier")
if baseline <= 0 or requests < 0 or not 0 < minimum <= 1 or multiplier <= 0:
    raise SystemExit("invalid staging health threshold")
if requests == 0:
    print("OK no-completed-requests")
    raise SystemExit(0)
if success_raw == "null" or p90_raw == "null":
    print("BREACH incomplete-window-metrics")
    raise SystemExit(0)
success = finite_number(success_raw, "success rate")
p90 = finite_number(p90_raw, "p90")
reasons = []
if success < minimum:
    reasons.append(f"success-rate={success:.6f}<{minimum:.6f}")
if p90 > baseline * multiplier:
    reasons.append(f"p90={p90:.6f}>{baseline * multiplier:.6f}")
if reasons:
    print("BREACH " + ",".join(reasons))
else:
    print(f"OK success-rate={success:.6f},p90={p90:.6f}")
PY
}

capture_credential_metadata() {
  local host="$1" path="$2"
  ssh "$host" stat -c 'mode=%a,owner=%U,size=%s,path=%n' -- "$path"
  ssh "$host" sha256sum -- "$path"
}

require_file_mode_600() {
  local host="$1" path="$2" metadata mode
  if [[ "${WEBSTER_PREFLIGHT_TEST_MODE:-0}" == "1" ]]; then
    mode="${TEST_CREDENTIAL_MODE:-0600}"
  else
    metadata="$(ssh "$host" stat -c '%a:%U:%s' -- "$path")" ||
      die "cannot inspect credential metadata on $host"
    mode="${metadata%%:*}"
    capture "credential-${host}" capture_credential_metadata "$host" "$path"
  fi
  mode="${mode#0}"
  require_eq "$host credential mode" "600" "$mode"
}

write_summary_header() {
  {
    printf '# Cutover evidence %s\n\n' "$(basename "$RUN_ROOT")"
    printf -- '- Phase: `%s`\n' "$1"
    printf -- '- Created: `%s`\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '- Full evidence is mode-restricted under this run root.\n'
  } >"$RUN_ROOT/summary.md"
  chmod 0600 "$RUN_ROOT/summary.md"
}
