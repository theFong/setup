#!/usr/bin/env bash
set -euo pipefail

# Cluster commands must never inherit or forward an operator's SSH agent.  The
# wrappers cover direct calls from every package script; composed remote paths
# additionally scrub the remote shell before starting their nested transport.
unset SSH_AUTH_SOCK
ssh() {
  if [[ "${WEBSTER_LOCAL_SHAMU:-0}" == 1 && "${1:-}" == shamu ]]; then
    if [[ "${WEBSTER_WEKA_TEST_MODE:-0}" != 1 && "$(hostname -s)" != shamu ]]; then
      printf 'ERROR: local Shamu command mode may run only on shamu\n' >&2
      return 1
    fi
    shift
    if (( $# == 1 )); then
      env -u SSH_AUTH_SOCK bash -c "$1"
    else
      env -u SSH_AUTH_SOCK "$@"
    fi
    return
  fi
  env -u SSH_AUTH_SOCK "$(type -P ssh)" -o ForwardAgent=no "$@"
}
scp() {
  env -u SSH_AUTH_SOCK "$(type -P scp)" -o ForwardAgent=no "$@"
}
rsync() {
  env -u SSH_AUTH_SOCK "$(type -P rsync)" "$@"
}
brev() {
  env -u SSH_AUTH_SOCK "$(type -P brev)" "$@"
}

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
VLLM_BUILD_BASE_IMAGE_TAG="pytorch/manylinuxaarch64-builder:cuda13.0-b8b5f17a7d9ccfc25bbc5cf17b3fcea12964a042"
VLLM_BUILD_BASE_IMAGE_DIGEST="sha256:994bed2b225a9ff0f6fbe85c85fe84fbeac9031bb909442e18178484798529df"
VLLM_FINAL_BASE_IMAGE_TAG="nvidia/cuda:13.0.3-base-ubuntu24.04"
VLLM_FINAL_BASE_IMAGE_DIGEST="sha256:56d9d8183e2181a20be6b0d3801d1f056a0e75c17706df939ba207b126e1cb9c"
VLLM_CUDA_VERSION="13.0.3"
VLLM_NCCL_VERSION="2.30.7"
VLLM_ARM64_ARCH_LIST="9.0 10.0 11.0 12.0"
VLLM_MAX_WHEEL_SIZE_MB="700"
PROMETHEUS_URL="http://100.73.140.127:9095"
GLM_METRICS_INSTANCE="100.73.140.127:8000"
BAKER_RANK0_HOST="baker-spark-1"
BAKER_RANK1_HOST="baker-spark-2"
BAKER_RANK0_NETBIRD="100.73.127.129"
BAKER_API_PORT="8888"
BAKER_CONTAINER="deepseek-v4-flash-vllm-dspark-1"
STAGE_MIN_SUCCESS_RATE="0.99"
STAGE_LATENCY_MULTIPLIER="2.0"
STAGE_BASELINE_MIN_REQUESTS="20"
if [[ "${WEBSTER_PREFLIGHT_TEST_MODE:-0}" == "1" ||
  "${WEBSTER_STAGE_TEST_MODE:-0}" == "1" ||
  "${WEBSTER_RUNTIME_TEST_MODE:-0}" == "1" ||
  "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ||
  "${WEBSTER_WEKA_TEST_MODE:-0}" == "1" ||
  "${WEBSTER_ACCEPTANCE_TEST_MODE:-0}" == "1" ]]; then
  RUNS_ROOT="${TEST_RUNS_ROOT:-/home/ubuntu/deepseek-v41-runs}"
elif [[ -n "${WEBSTER_RUNS_ROOT:-}" ]]; then
  [[ -d "$WEBSTER_RUNS_ROOT" && ! -L "$WEBSTER_RUNS_ROOT" ]] || {
    printf 'ERROR: Webster runs root override must be an existing non-symlink directory\n' >&2
    return 1 2>/dev/null || exit 1
  }
  RUNS_ROOT="$(realpath -e -- "$WEBSTER_RUNS_ROOT")"
else
  RUNS_ROOT="/home/ubuntu/deepseek-v41-runs"
fi

GLM_CONTAINER="glm52-full-mtp"
DEEPSEEK_CONTAINER="deepseek-v41-flash-tp2"
DEEPSEEK_CHECKPOINT_DIR="DeepSeek-V4.1-Flash-${CHECKPOINT_REVISION:0:10}"
DEEPSEEK_REMOTE_ROOT="/home/alecfong/deepseek-v41"
DEEPSEEK_CHECKPOINT_PATH="$DEEPSEEK_REMOTE_ROOT/models/$DEEPSEEK_CHECKPOINT_DIR"
DEEPSEEK_CACHE_PATH="$DEEPSEEK_REMOTE_ROOT/cache"
DEEPSEEK_API_ENV_FILE="$DEEPSEEK_REMOTE_ROOT/credentials/vllm-api.env"
DEEPSEEK_SERVED_MODEL="deepseek-ai/DeepSeek-V4.1-Flash"

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
      printf 'VLLM_COMMIT=\nVLLM_BASE_IMAGE_DIGEST=\n'
      printf 'VLLM_BUILD_BASE_IMAGE_DIGEST=\nVLLM_FINAL_BASE_IMAGE_DIGEST=\n'
      printf 'VLLM_SOURCE_ARCHIVE_SHA256=\nVLLM_IMAGE_ID=\n'
      printf 'VLLM_MAX_WHEEL_SIZE_MB=%s\n' "$VLLM_MAX_WHEEL_SIZE_MB"
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
    -e "s/((api[_-]?keys?|master[_-]?key|password|secret|token)[\"']?[[:space:]]*[:=][[:space:]]*)[^,[:space:]\"']+/\\1[REDACTED]/Ig" \
    -e 's/sk-[A-Za-z0-9._-]{8,}/[REDACTED-KEY]/g'
}

capture() {
  local name="$1" output temporary status suffix=2
  shift
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe capture name: $name"
  output="$RUN_ROOT/logs/$name.log"
  while [[ -e "$output" || -L "$output" ]]; do
    output="$RUN_ROOT/logs/$name-$suffix.log"
    ((suffix += 1))
  done
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

check_glm_health() {
  curl -fsS --connect-timeout 3 --max-time 5 \
    "http://$SHAMU_NETBIRD:$CANARY_PORT/health" >/dev/null
}

remote_available_bytes() {
  local node="$1" requested_path="$2" output available
  if ! output="$(
    ssh "$node" df -B1 --output=avail "$requested_path" 2>/dev/null
  )"; then
    output="$(ssh "$node" df -B1 --output=avail /home/alecfong)"
  fi
  available="$(awk 'NR == 2 {print $1}' <<<"$output")"
  [[ "$available" =~ ^[0-9]+$ ]] ||
    die "remote free-space query returned a non-integer for $node"
  printf '%s\n' "$available"
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

create_tagged_git_bundle() {
  local source_dir="$1" output="$2" expected_commit="$3"
  local temporary bundle_head tag_count
  require_eq "source bundle HEAD" "$expected_commit" \
    "$(git -C "$source_dir" rev-parse HEAD)"
  git -C "$source_dir" describe --tags "$expected_commit" >/dev/null
  if [[ -f "$output" ]]; then
    git -C "$source_dir" bundle verify "$output" >/dev/null 2>&1
    bundle_head="$(git bundle list-heads "$output" | awk '$2 == "HEAD" {print $1}')"
    require_eq "existing source bundle HEAD" "$expected_commit" "$bundle_head"
    tag_count="$(git bundle list-heads "$output" | awk '$2 ~ /^refs\/tags\// {count++} END {print count+0}')"
    (( tag_count > 0 )) || die "existing source bundle contains no tags"
    return 0
  fi
  temporary="$output.tmp.$$"
  git -C "$source_dir" bundle create "$temporary" HEAD --tags
  bundle_head="$(git bundle list-heads "$temporary" | awk '$2 == "HEAD" {print $1}')"
  require_eq "new source bundle HEAD" "$expected_commit" "$bundle_head"
  tag_count="$(git bundle list-heads "$temporary" | awk '$2 ~ /^refs\/tags\// {count++} END {print count+0}')"
  (( tag_count > 0 )) || die "new source bundle contains no tags"
  mv "$temporary" "$output"
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
