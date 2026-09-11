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
CHECKPOINT_WEIGHT_BYTES="510286023000"
RUNS_ROOT="/home/ubuntu/deepseek-v41-runs"

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
  : >"$RUN_ROOT/events.tsv"
  : >"$RUN_ROOT/summary.md"
  chmod 0600 "$RUN_ROOT/events.tsv" "$RUN_ROOT/summary.md"
  if [[ ! -f "$RUN_ROOT/manifest.env" ]]; then
    {
      printf 'CHECKPOINT_REPO=%s\n' "$CHECKPOINT_REPO"
      printf 'CHECKPOINT_REVISION=%s\n' "$CHECKPOINT_REVISION"
      printf 'CHECKPOINT_SHARDS=%s\n' "$CHECKPOINT_SHARDS"
      printf 'CHECKPOINT_WEIGHT_BYTES=%s\n' "$CHECKPOINT_WEIGHT_BYTES"
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

require_file_mode_600() {
  local host="$1" path="$2" metadata mode
  if [[ "${WEBSTER_PREFLIGHT_TEST_MODE:-0}" == "1" ]]; then
    mode="${TEST_CREDENTIAL_MODE:-0600}"
  else
    metadata="$(ssh "$host" stat -c '%a %U %s' -- "$path")" ||
      die "cannot inspect credential metadata on $host"
    mode="${metadata%% *}"
    capture "credential-${host}" ssh "$host" sh -c \
      "'stat -c \"mode=%a owner=%U size=%s path=$path\" -- \"$path\"; sha256sum -- \"$path\"'"
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
