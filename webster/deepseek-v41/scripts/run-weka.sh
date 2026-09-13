#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

AIPERF_COMMIT="ea28b2e81c7367f8403c6f6ebe0837a508795a8d"
AIPERF_WEKA_PATCH_SHA256="9557a46afac031b64f66ea64ebac4e8ed4d1a0e142354388c19c086a9377a36e"
AIPERF_DATASET_CONFIGURATION_TIMEOUT_SECONDS="1200"
AIPERF_PROFILE_CONFIGURE_TIMEOUT_SECONDS="1200"
MIN_CONTROLLER_MEMORY_BYTES="34359738368"
WEKA_REPOSITORY="semianalysisai/cc-traces-weka-062126"
WEKA_REVISION="23f152f6f0f9399a85901b89a6458def0ef16729"
WEKA_TRACE_COUNT="393"
WEKA_SOURCE_SHA256="29b6a19e751ff5230771519aab755f80a0f43a4ba9cf96b72d3a6a437ec99276"
WEKA_SOURCE_SIZE="1847151435"

if [[ -n "${WEBSTER_WEKA_RUNS_ROOT:-}" ]]; then
  [[ -d "$WEBSTER_WEKA_RUNS_ROOT" && ! -L "$WEBSTER_WEKA_RUNS_ROOT" ]] ||
    die "Weka runs root override must be an existing non-symlink directory"
  RUNS_ROOT="$(canonical_existing_path "$WEBSTER_WEKA_RUNS_ROOT")"
fi
export WEBSTER_RUNS_ROOT="$RUNS_ROOT"

run_root=""
profile_name=""
concurrency=""
repetition=""
key_file=""
schedule=""
internal=0
while (($#)); do
  case "$1" in
    --run-root) run_root="${2:?}"; shift 2 ;;
    --profile-name) profile_name="${2:?}"; shift 2 ;;
    --concurrency) concurrency="${2:?}"; shift 2 ;;
    --repetition) repetition="${2:?}"; shift 2 ;;
    --key-file) key_file="${2:?}"; shift 2 ;;
    --no-fixed-schedule) schedule="open"; shift ;;
    --fixed-schedule) schedule="fixed"; shift ;;
    --internal) internal=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

init_run_root "$(validate_run_root "$run_root")"
[[ "$profile_name" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "unsafe profile name"
[[ "$repetition" =~ ^[1-9][0-9]*$ ]] || die "repetition must be positive"
[[ "$repetition" == 1 || "$repetition" == 2 ]] ||
  die "repetition must be 1 (warmup) or 2 (scored)"
[[ "$schedule" == open || "$schedule" == fixed ]] ||
  die "exactly one schedule mode is required"
if [[ "$schedule" == open ]]; then
  [[ "$concurrency" =~ ^[1-9][0-9]*$ ]] || die "concurrency must be positive"
elif [[ -n "$concurrency" ]]; then
  [[ "$concurrency" =~ ^[1-9][0-9]*$ ]] || die "concurrency must be positive"
fi
[[ -f "$key_file" && ! -L "$key_file" ]] || die "benchmark key must be a regular file"
[[ "$(file_mode "$key_file")" == 600 ]] || die "benchmark key mode must be 0600"
[[ -s "$key_file" ]] || die "benchmark key is empty"

manifest="$RUN_ROOT/manifest.env"
[[ -f "$manifest" && ! -L "$manifest" ]] || die "manifest.env is missing"
[[ "$(file_mode "$manifest")" == 600 ]] || die "manifest.env mode must be 0600"
manifest_value() {
  local key="$1" value
  value="$(awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$manifest")"
  [[ -n "$value" ]] || die "manifest field $key is empty"
  printf '%s\n' "$value"
}
require_eq "manifest AIPERF_COMMIT" "$AIPERF_COMMIT" \
  "$(manifest_value AIPERF_COMMIT)"
require_eq "manifest WEKA_REPOSITORY" "$WEKA_REPOSITORY" \
  "$(manifest_value WEKA_REPOSITORY)"
require_eq "manifest WEKA_REVISION" "$WEKA_REVISION" \
  "$(manifest_value WEKA_REVISION)"

if [[ "$schedule" == open ]]; then
  run_name="$profile_name-c$concurrency-r$repetition-open"
else
  run_name="$profile_name-r$repetition-fixed"
fi
destination="$RUN_ROOT/aiperf/$run_name"

validate_weka_artifacts() {
  local artifacts="$1"
  local preserve_summary="${2:-0}"
  local results_ready="$artifacts/.aiperf_results_ready.json"
  local readiness_code=0 readiness_message=""
  local summary_code=0 summary_message=""
  local summary_output="$artifacts/summary.json"
  local rederived_summary=""

  if [[ ! -f "$results_ready" || -L "$results_ready" ]]; then
    printf 'AIPerf results readiness marker is missing or not a regular file\n' >&2
    return 1
  fi
  readiness_message="$(python3 - "$results_ready" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        result = json.load(handle)
except (OSError, json.JSONDecodeError) as error:
    print(f"AIPerf results readiness marker is malformed: {error}", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(result, dict):
    print("AIPerf results readiness marker must be an object", file=sys.stderr)
    raise SystemExit(1)
if result.get("was_cancelled") is True:
    print("AIPerf results readiness marker reports cancellation", file=sys.stderr)
    raise SystemExit(130)
if result.get("ready") is not True:
    print("AIPerf results readiness marker does not report ready=true", file=sys.stderr)
    raise SystemExit(1)
if result.get("was_cancelled") is not False:
    print("AIPerf results readiness marker lacks was_cancelled=false", file=sys.stderr)
    raise SystemExit(1)
if result.get("partial") is not False:
    print("AIPerf results readiness marker does not report partial=false", file=sys.stderr)
    raise SystemExit(1)
failed_exporters = result.get("failed_exporters", [])
if not isinstance(failed_exporters, list) or any(
    not isinstance(value, str) or not value for value in failed_exporters
):
    print("AIPerf results readiness failed_exporters must be a string list", file=sys.stderr)
    raise SystemExit(1)
if failed_exporters:
    print(
        "AIPerf results readiness marker reports failed exporters: "
        + ", ".join(failed_exporters),
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
)" || readiness_code=$?
  if (( readiness_code != 0 )); then
    [[ -z "$readiness_message" ]] || printf '%s\n' "$readiness_message" >&2
    return "$readiness_code"
  fi

  if [[ "$preserve_summary" == preserve ]]; then
    rederived_summary="$(mktemp "$artifacts/.summary-rederived.XXXXXXXX")"
    chmod 0600 "$rederived_summary"
    summary_output="$rederived_summary"
  fi
  summary_message="$(python3 "$script_dir/summarize-aiperf.py" \
    --profile "$artifacts/profile_export_aiperf.json" \
    --records "$artifacts/profile_export.jsonl" \
    --server-metrics "$artifacts/server_metrics_export.json" \
    --timing-log "$artifacts/aiperf.stdout.log" \
    --output-json "$summary_output" 2>&1)" || summary_code=$?
  if (( summary_code != 0 )); then
    if [[ -f "$summary_output" ]] && python3 - "$summary_output" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        summary = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(0 if summary.get("qualified") is False else 1)
PY
    then
      [[ -z "$rederived_summary" ]] || rm -f -- "$rederived_summary"
      printf 'AIPerf request results are not qualified\n' >&2
      return 1
    fi
    [[ -z "$rederived_summary" ]] || rm -f -- "$rederived_summary"
    printf 'AIPerf result summary failed: %s\n' "$summary_message" >&2
    return 1
  fi

  if ! python3 - "$summary_output" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    summary = json.load(handle)
if summary.get("qualified") is not True:
    print("AIPerf request results are not qualified", file=sys.stderr)
    raise SystemExit(1)
required = (
    "prefix_cache_hits",
    "prefix_cache_queries",
    "prefix_cache_hit_ratio",
    "kv_cache_usage_max",
    "preemptions_total",
    "running_requests_max",
    "waiting_requests_max",
    "wall_power_avg_watts",
    "facility_power_avg_watts",
    "facility_energy_kwh",
    "facility_cost_dollars",
    "completed_root_workflows",
    "cancelled_root_workflows",
    "root_workflow_elapsed_seconds",
    "completed_root_workflows_per_second",
)
for name in required:
    if summary.get(name) is None:
        print(f"required AIPerf summary metric is missing: {name}", file=sys.stderr)
        raise SystemExit(1)
if summary["completed_root_workflows"] <= 0:
    print("AIPerf completed no root workflows", file=sys.stderr)
    raise SystemExit(1)
if summary["cancelled_root_workflows"] != 0:
    print("AIPerf cancelled one or more root workflows", file=sys.stderr)
    raise SystemExit(1)
PY
  then
    [[ -z "$rederived_summary" ]] || rm -f -- "$rederived_summary"
    return 1
  fi
  if [[ -n "$rederived_summary" ]] &&
    ! cmp -s -- "$rederived_summary" "$artifacts/summary.json"; then
    rm -f -- "$rederived_summary"
    printf 'AIPerf rederived summary differs from recorded evidence\n' >&2
    return 1
  fi
  [[ -z "$rederived_summary" ]] || rm -f -- "$rederived_summary"
}

verify_controller_capacity() {
  local physical_memory_bytes
  if [[ "${WEBSTER_WEKA_TEST_MODE:-0}" == 1 ]]; then
    [[ -n "${TEST_WEKA_CONTROLLER_MEMORY_BYTES:-}" ]] || return 0
    physical_memory_bytes="$TEST_WEKA_CONTROLLER_MEMORY_BYTES"
  else
    physical_memory_bytes="$({
      awk '/^MemTotal:/ {printf "%.0f\n", $2 * 1024; exit}' /proc/meminfo
    })"
  fi
  [[ "$physical_memory_bytes" =~ ^[1-9][0-9]*$ ]] ||
    die "cannot determine Weka controller physical memory"
  (( physical_memory_bytes >= MIN_CONTROLLER_MEMORY_BYTES )) ||
    die "Weka controller physical memory is too small: need at least \
$MIN_CONTROLLER_MEMORY_BYTES bytes, found $physical_memory_bytes"
}

aiperf_bin="${WEBSTER_WEKA_AIPERF_BIN:-${TEST_AIPERF_BIN:-$RUN_ROOT/aiperf-venv/bin/aiperf}}"
aiperf_source="${WEBSTER_WEKA_AIPERF_SOURCE:-$RUN_ROOT/aiperf-source}"
dataset="${WEBSTER_WEKA_DATASET:-${TEST_WEKA_DATASET:-$RUN_ROOT/weka-dataset/traces}}"
tokenizer="${WEBSTER_WEKA_TOKENIZER:-${TEST_DEEPSEEK_TOKENIZER:-$RUN_ROOT/deepseek-tokenizer}}"

verify_client_and_corpus() {
  local actual_aiperf actual_patch actual_revision trace_count full_subagents
  local expected_trace_count="$WEKA_TRACE_COUNT"
  if [[ "${WEBSTER_WEKA_TEST_MODE:-0}" == 1 ]]; then
    actual_aiperf="${TEST_WEKA_AIPERF_COMMIT:-$AIPERF_COMMIT}"
    actual_patch="${TEST_WEKA_AIPERF_PATCH_SHA256:-$AIPERF_WEKA_PATCH_SHA256}"
    actual_revision="${TEST_WEKA_REVISION:-$WEKA_REVISION}"
    trace_count="${TEST_WEKA_TRACE_COUNT:-$WEKA_TRACE_COUNT}"
    full_subagents="${TEST_WEKA_FULL_SUBAGENTS:-1}"
  fi
  if [[ "${WEBSTER_WEKA_TEST_MODE:-0}" != 1 ]]; then
    [[ -d "$aiperf_source/.git" && ! -L "$aiperf_source" ]] ||
      die "pinned AIPerf source checkout is missing"
    actual_aiperf="$(git -C "$aiperf_source" rev-parse HEAD)"
    [[ "$(git -C "$aiperf_source" status --porcelain --untracked-files=all -- src)" == \
      " M src/aiperf/config/dataset/resolver.py" ]] ||
      die "AIPerf runtime source differs from the pinned Weka timing patch"
    actual_patch="$(
      git -C "$aiperf_source" diff --binary --no-ext-diff HEAD -- src |
        sha256sum | awk '{print $1}'
    )"
  fi
  if [[ "${WEBSTER_WEKA_TEST_MODE:-0}" != 1 || "${TEST_WEKA_VERIFY_CORPUS:-0}" == 1 ]]; then
    local corpus_manifest source_sha256 source_size
    corpus_manifest="${WEBSTER_WEKA_CORPUS_MANIFEST:-$(dirname -- "$dataset")/corpus-manifest.json}"
    [[ -f "$corpus_manifest" && ! -L "$corpus_manifest" ]] ||
      die "pinned Weka corpus manifest is missing"
    source_sha256="$WEKA_SOURCE_SHA256"
    source_size="$WEKA_SOURCE_SIZE"
    if [[ "${WEBSTER_WEKA_TEST_MODE:-0}" == 1 ]]; then
      source_sha256="${TEST_WEKA_SOURCE_SHA256:?}"
      source_size="${TEST_WEKA_SOURCE_SIZE:?}"
      expected_trace_count="${TEST_WEKA_SOURCE_TRACE_COUNT:?}"
    fi
    python3 "$script_dir/verify-weka-corpus.py" \
      --dataset "$dataset" \
      --manifest "$corpus_manifest" \
      --repository "$WEKA_REPOSITORY" \
      --revision "$WEKA_REVISION" \
      --source-sha256 "$source_sha256" \
      --source-size "$source_size" \
      --trace-count "$expected_trace_count" >/dev/null ||
      die "Weka corpus identity validation failed"
    actual_revision="$WEKA_REVISION"
    trace_count="$expected_trace_count"
    full_subagents=1
  fi
  require_eq "checked-out AIPERF_COMMIT" "$AIPERF_COMMIT" "$actual_aiperf"
  require_eq "AIPerf Weka timing patch" "$AIPERF_WEKA_PATCH_SHA256" \
    "$actual_patch"
  require_eq "resolved WEKA_REVISION" "$WEKA_REVISION" "$actual_revision"
  require_eq "exact $expected_trace_count traces" "$expected_trace_count" "$trace_count"
  require_eq "full subagents" 1 "$full_subagents"
}
verify_client_and_corpus

validate_weka_provenance() {
  local directory="$1"
  python3 - "$directory/provenance.json" "$profile_name" \
    "${concurrency:-0}" "$repetition" "$AIPERF_COMMIT" \
    "$AIPERF_WEKA_PATCH_SHA256" "$WEKA_REPOSITORY" "$WEKA_REVISION" \
    "$WEKA_TRACE_COUNT" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

(
    provenance_raw,
    profile_name,
    concurrency,
    repetition,
    aiperf_commit,
    aiperf_patch,
    weka_repository,
    weka_revision,
    trace_count,
) = sys.argv[1:]
provenance_path = Path(provenance_raw)
if not provenance_path.is_file() or provenance_path.is_symlink():
    raise SystemExit("completed Weka run provenance is missing or unsafe")
try:
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"completed Weka run provenance is malformed: {error}")
if not isinstance(provenance, dict):
    raise SystemExit("completed Weka run provenance must be an object")

expected_repetition = int(repetition)
expected_cache_state = "warmup" if expected_repetition == 1 else "warm"
expected = (
    ("schema_version", 1, "recorded provenance schema"),
    ("profile_name", profile_name, "recorded profile name"),
    ("concurrency", int(concurrency), "recorded concurrency"),
    ("repetition", expected_repetition, "recorded repetition"),
    ("cache_state", expected_cache_state, "recorded cache state"),
    ("aiperf_commit", aiperf_commit, "recorded AIPerf commit"),
    ("aiperf_weka_patch_sha256", aiperf_patch, "recorded AIPerf patch"),
    ("weka_repository", weka_repository, "recorded Weka repository"),
    ("weka_revision", weka_revision, "recorded Weka revision"),
    ("trace_count", int(trace_count), "recorded Weka trace count"),
    ("full_subagents", True, "recorded full-subagent mode"),
)
for field, wanted, label in expected:
    recorded = provenance.get(field)
    if type(recorded) is not type(wanted) or recorded != wanted:
        raise SystemExit(f"{label} differs from the current qualification contract")

if expected_repetition == 1:
    if (
        provenance.get("warmup_and_scored_comparable") is not False
        or provenance.get("warmup_provenance_sha256") is not None
    ):
        raise SystemExit("recorded warmup cache provenance is malformed")
else:
    warmup_hash = provenance.get("warmup_provenance_sha256")
    if (
        provenance.get("warmup_and_scored_comparable") is not True
        or not isinstance(warmup_hash, str)
        or re.fullmatch(r"[0-9a-f]{64}", warmup_hash) is None
    ):
        raise SystemExit("recorded scored cache provenance is malformed")

generation = provenance.get("serving_generation")
if not isinstance(generation, str) or not generation:
    raise SystemExit("recorded serving generation is missing")

required_artifacts = (
    "EXIT",
    ".aiperf_results_ready.json",
    "profile_export.jsonl",
    "profile_export_aiperf.json",
    "server_metrics_export.json",
    "aiperf.stdout.log",
    "aiperf.stderr.log",
    "rendered-command.txt",
    "summary.json",
    "benchmark-window.json",
    "rank0-before.json",
    "rank1-before.json",
    "rank0-after.json",
    "rank1-after.json",
    "rank0-container.log",
    "rank1-container.log",
)
artifacts = provenance.get("artifacts")
if not isinstance(artifacts, dict) or set(artifacts) != set(required_artifacts):
    raise SystemExit("recorded required artifact hash map is incomplete")
directory = provenance_path.parent
for name in required_artifacts:
    expected_hash = artifacts.get(name)
    if not isinstance(expected_hash, str) or re.fullmatch(r"[0-9a-f]{64}", expected_hash) is None:
        raise SystemExit(f"recorded artifact hash is malformed: {name}")
    path = directory / name
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"recorded artifact is missing or unsafe: {name}")
    actual_hash = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual_hash != expected_hash:
        raise SystemExit(f"recorded artifact hash differs: {name}")
PY
}

if [[ -f "$destination/EXIT" ]]; then
  [[ "$(<"$destination/EXIT")" == "EXIT=0" ]] ||
    die "existing Weka run is not successful: $destination"
  validate_weka_provenance "$destination" ||
    die "existing Weka run failed provenance validation: $destination"
  validate_weka_artifacts "$destination" preserve ||
    die "existing Weka run failed artifact validation: $destination"
  printf 'GO Weka run already complete: %s\n' "$destination"
  exit 0
fi

verify_controller_capacity

if [[ "$internal" == 0 && -z "${TMUX:-}" &&
  ( "${WEBSTER_WEKA_TEST_MODE:-0}" != 1 || "${TEST_WEKA_ENABLE_TMUX:-0}" == 1 ) ]]; then
  session="dsv41-${run_name//./-}"
  command=(env "WEBSTER_WEKA_RUNS_ROOT=$RUNS_ROOT"
    "WEBSTER_WEKA_AIPERF_BIN=$aiperf_bin"
    "WEBSTER_WEKA_AIPERF_SOURCE=$aiperf_source"
    "WEBSTER_WEKA_DATASET=$dataset"
    "WEBSTER_WEKA_TOKENIZER=$tokenizer"
    "WEBSTER_LOCAL_SHAMU=${WEBSTER_LOCAL_SHAMU:-0}"
    bash "$0" --run-root "$RUN_ROOT" --profile-name "$profile_name"
    --repetition "$repetition" --key-file "$key_file" --internal)
  if [[ "$schedule" == open ]]; then
    command+=(--concurrency "$concurrency" --no-fixed-schedule)
  else
    command+=(--fixed-schedule)
  fi
  log="$RUN_ROOT/logs/$run_name.tmux.log"
  : >"$log"
  chmod 0600 "$log"
  shell_command="$(printf '%q ' "${command[@]}")"
  tmux new-session -d -s "$session" "$shell_command >$(printf '%q' "$log") 2>&1"
  while tmux has-session -t "$session" 2>/dev/null; do sleep 15; done
  [[ -f "$destination/EXIT" ]] || die "tmux Weka run ended without EXIT record"
  [[ "$(<"$destination/EXIT")" == "EXIT=0" ]] || die "tmux Weka run failed"
  printf 'GO Weka run complete: %s\n' "$destination"
  exit 0
fi

collect_rank_state() {
  local node="$1" docker_mode="$2" expected_image="$3"
  ssh "$node" python3 - "$docker_mode" "$DEEPSEEK_CONTAINER" \
    "$expected_image" <<'PY'
import json
import subprocess
import sys

docker_mode, container, expected_image = sys.argv[1:]
docker = ["docker"] if docker_mode == "direct" else ["sudo", "-n", "docker"]
try:
    value = json.loads(
        subprocess.check_output(docker + ["inspect", container], text=True)
    )[0]
except (subprocess.CalledProcessError, json.JSONDecodeError, IndexError) as error:
    raise SystemExit(f"cannot inspect serving rank: {error}")
state = value.get("State") or {}
if state.get("Running") is not True:
    raise SystemExit("serving rank is not running")
if value.get("RestartCount") != 0:
    raise SystemExit("serving rank has a nonzero restart count")
if value.get("Image") != expected_image:
    raise SystemExit("serving rank uses the wrong image")
labels = (value.get("Config") or {}).get("Labels") or {}
print(
    json.dumps(
        {
            "container_id": value.get("Id"),
            "generation": labels.get("ai.webster.generation"),
            "image": value.get("Image"),
            "restart_count": value.get("RestartCount"),
            "started_at": state.get("StartedAt"),
        },
        separators=(",", ":"),
    )
)
PY
}

resolve_generation_from_states() {
  local rank0_state="$1" rank1_state="$2"
  python3 "$script_dir/verify-serving-pair.py" \
    --rank0-state-json "$rank0_state" \
    --rank1-state-json "$rank1_state" \
    --max-start-skew-seconds 120 \
    --require-matching-image \
    "--print-generation"
}

pre_run_generation=""
pre_rank0_state=""
pre_rank1_state=""
if [[ "${WEBSTER_WEKA_TEST_MODE:-0}" != 1 ]]; then
  live_profile="$RUN_ROOT/profiles/$profile_name.env"
  [[ -f "$live_profile" && ! -L "$live_profile" ]] ||
    die "selected Weka profile is missing"
  "$script_dir/start-deepseek-v41-tp2.sh" --run-root "$RUN_ROOT" \
    --profile-file "$live_profile" --verify-only >/dev/null
  expected_image="$(manifest_value VLLM_IMAGE_ID)"
  pre_rank0_state="$(collect_rank_state shamu direct "$expected_image")"
  pre_rank1_state="$(collect_rank_state tilikum sudo "$expected_image")"
  pre_run_generation="$(resolve_generation_from_states \
    "$pre_rank0_state" "$pre_rank1_state")"
else
  pre_run_generation="${TEST_WEKA_SERVING_GENERATION:-test-serving-generation}"
  pre_rank0_state="{\"container_id\":\"$(printf '0%.0s' {1..64})\",\"generation\":\"$pre_run_generation\",\"image\":\"sha256:$(printf 'a%.0s' {1..64})\",\"restart_count\":0,\"started_at\":\"2099-01-01T00:00:00Z\"}"
  pre_rank1_state="{\"container_id\":\"$(printf '1%.0s' {1..64})\",\"generation\":\"$pre_run_generation\",\"image\":\"sha256:$(printf 'a%.0s' {1..64})\",\"restart_count\":0,\"started_at\":\"2099-01-01T00:00:01Z\"}"
fi

temp_parent="${TEST_WEKA_TMP_ROOT:-$RUN_ROOT/tmp}"
[[ -x "$aiperf_bin" ]] || die "pinned AIPerf executable is missing"
[[ ( -f "$dataset" || -d "$dataset" ) && ! -L "$dataset" ]] ||
  die "pinned Weka dataset is missing"
if [[ "${WEBSTER_WEKA_TEST_MODE:-0}" != 1 ]]; then
  [[ -d "$tokenizer" && ! -L "$tokenizer" ]] || die "pinned tokenizer is missing"
fi
mkdir -p "$temp_parent"
chmod 0700 "$temp_parent"
temporary="$(mktemp -d "$temp_parent/weka-$run_name.XXXXXXXX")"

cleanup() {
  local status=$?
  trap - EXIT
  unset OPENAI_API_KEY || true
  if [[ -n "${temporary:-}" && -d "$temporary" ]]; then
    resolved="$(canonical_existing_path "$temporary")"
    parent="$(canonical_existing_path "$temp_parent")"
    case "$resolved" in "$parent"/weka-*) ;; *) exit 1 ;; esac
    [[ "$(file_uid "$resolved")" == "$(id -u)" ]] || exit 1
    rm -rf -- "$resolved"
  fi
  exit "$status"
}
trap cleanup EXIT

artifacts="$temporary/artifacts"
mkdir -m 0700 "$artifacts"
printf '%s\n' "$pre_rank0_state" >"$artifacts/rank0-before.json"
printf '%s\n' "$pre_rank1_state" >"$artifacts/rank1-before.json"
chmod 0600 "$artifacts/rank0-before.json" "$artifacts/rank1-before.json"
cache_state="warmup"
warmup_and_scored_comparable=false
warmup_provenance_sha256=""
if [[ "$repetition" == 2 ]]; then
  if [[ "$schedule" == open ]]; then
    warmup_name="$profile_name-c$concurrency-r1-open"
  else
    warmup_name="$profile_name-r1-fixed"
  fi
  warmup_dir="$RUN_ROOT/aiperf/$warmup_name"
  warmup_provenance="$warmup_dir/provenance.json"
  [[ -f "$warmup_provenance" && ! -L "$warmup_provenance" ]] ||
    die "successful warmup repetition provenance is missing"
  [[ -f "$warmup_dir/EXIT" && "$(<"$warmup_dir/EXIT")" == "EXIT=0" ]] ||
    die "warmup repetition is not successful"
  warmup_provenance_sha256="$(python3 - "$warmup_provenance" "$profile_name" \
    "${concurrency:-0}" "$pre_run_generation" "$AIPERF_COMMIT" \
    "$AIPERF_WEKA_PATCH_SHA256" "$WEKA_REPOSITORY" "$WEKA_REVISION" \
    "$artifacts/rank0-before.json" "$artifacts/rank1-before.json" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

provenance_path = Path(sys.argv[1])
profile_name, concurrency, generation = sys.argv[2:5]
aiperf_commit, aiperf_patch, weka_repository, weka_revision = sys.argv[5:9]
current_states = [Path(path) for path in sys.argv[9:11]]
provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
if (
    provenance.get("schema_version") != 1
    or provenance.get("profile_name") != profile_name
    or provenance.get("concurrency") != int(concurrency)
    or provenance.get("repetition") != 1
    or provenance.get("cache_state") != "warmup"
    or provenance.get("serving_generation") != generation
):
    raise SystemExit("warmup repetition provenance is not comparable")
if (
    provenance.get("aiperf_commit") != aiperf_commit
    or provenance.get("weka_repository") != weka_repository
    or provenance.get("weka_revision") != weka_revision
):
    raise SystemExit("warmup repetition client or dataset pin is not comparable")
if provenance.get("aiperf_weka_patch_sha256") != aiperf_patch:
    raise SystemExit("warmup repetition runtime patch is not comparable")
artifacts = provenance.get("artifacts")
if not isinstance(artifacts, dict):
    raise SystemExit("warmup repetition artifact manifest is missing")
for rank, current in enumerate(current_states):
    previous = provenance_path.parent / f"rank{rank}-after.json"
    if not previous.is_file() or previous.is_symlink():
        raise SystemExit("warmup repetition rank state is missing")
    digest = hashlib.sha256(previous.read_bytes()).hexdigest()
    if artifacts.get(previous.name) != digest:
        raise SystemExit("warmup repetition rank state hash differs")
    if json.loads(previous.read_text(encoding="utf-8")) != json.loads(
        current.read_text(encoding="utf-8")
    ):
        raise SystemExit("warmup repetition used a different serving rank")
print(hashlib.sha256(provenance_path.read_bytes()).hexdigest())
PY
)" || die "warmup repetition is not generation-comparable"
  cache_state="warm"
  warmup_and_scored_comparable=true
fi
config="$artifacts/aiperf-config.yaml"
python3 - "$config" "$dataset" "$tokenizer" "$artifacts" "$schedule" \
  "$concurrency" "$SHAMU_NETBIRD" "$TILIKUM_NETBIRD" "$CANARY_PORT" \
  "$DEEPSEEK_SERVED_MODEL" <<'PY'
import json
import os
import sys
from pathlib import Path

(
    config_path,
    dataset,
    tokenizer,
    artifacts,
    schedule,
    concurrency,
    shamu,
    tilikum,
    port,
    model,
) = sys.argv[1:]

phase = {
    "name": "profiling",
    "kind": "profiling",
    "duration": 900.0,
    "grace_period": 300.0,
}
dataset_config = {
    "name": "main",
    "type": "file",
    "path": dataset,
    "format": "weka_trace",
    "random_seed": 20260911,
}
if schedule == "fixed":
    phase.update({"type": "fixed_schedule", "auto_offset": True})
else:
    phase.update({"type": "concurrency", "concurrency": int(concurrency)})
    dataset_config["ignore_trace_delays"] = True

config = {
    "schemaVersion": "2.0",
    "benchmark": {
        "models": {"items": [{"name": model}]},
        "endpoint": {
            "urls": [f"http://{shamu}:{port}"],
            "type": "chat",
            "api_key": "${OPENAI_API_KEY}",
            "timeout": 900.0,
            "streaming": True,
            "use_server_token_count": True,
        },
        "datasets": [dataset_config],
        "phases": [phase],
        "artifacts": {
            "dir": artifacts,
            "records": ["jsonl"],
            "export_outputs_json": True,
        },
        "tokenizer": {"name": tokenizer},
        "gpu_telemetry": {
            "enabled": True,
            "urls": [
                f"http://{shamu}:9400/metrics",
                f"http://{tilikum}:9400/metrics",
            ],
            "collector": "dcgm",
            "mode": "summary",
        },
        "server_metrics": {
            "enabled": True,
            "urls": [
                f"http://{shamu}:{port}/metrics",
                f"http://{shamu}:9877/metrics",
                f"http://{tilikum}:9877/metrics",
            ],
            "formats": ["json", "csv"],
        },
    },
    "random_seed": 20260911,
}

path = Path(config_path)
path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
os.chmod(path, 0o600)
PY

command=(env
  "AIPERF_DATASET_CONFIGURATION_TIMEOUT=$AIPERF_DATASET_CONFIGURATION_TIMEOUT_SECONDS"
  "AIPERF_SERVICE_PROFILE_CONFIGURE_TIMEOUT=$AIPERF_PROFILE_CONFIGURE_TIMEOUT_SECONDS"
  "$aiperf_bin" profile --config "$config")

printf '%q ' "${command[@]}" >"$artifacts/rendered-command.txt"
printf '\n' >>"$artifacts/rendered-command.txt"
chmod 0600 "$artifacts/rendered-command.txt"
OPENAI_API_KEY="$(<"$key_file")"
OPENAI_API_KEY="${OPENAI_API_KEY%$'\n'}"
export OPENAI_API_KEY
benchmark_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
validation_message=""
set +e
"${command[@]}" >"$artifacts/aiperf.stdout.log" 2>"$artifacts/aiperf.stderr.log"
status=$?
set -e
unset OPENAI_API_KEY
benchmark_ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

capture_rank_log() {
  local node="$1" docker_mode="$2" output="$3" result=0
  if [[ "${WEBSTER_WEKA_TEST_MODE:-0}" == 1 ]]; then
    if [[ "$node" == shamu ]]; then
      printf '%s\n' "${TEST_WEKA_RANK0_LOG:-healthy rank 0}" >"$output"
    else
      printf '%s\n' "${TEST_WEKA_RANK1_LOG:-healthy rank 1}" >"$output"
    fi
  elif [[ "$docker_mode" == direct ]]; then
    ssh "$node" docker logs --since "$benchmark_started_at" --timestamps \
      "$DEEPSEEK_CONTAINER" >"$output" 2>&1 || result=$?
  else
    ssh "$node" sudo -n docker logs --since "$benchmark_started_at" --timestamps \
      "$DEEPSEEK_CONTAINER" >"$output" 2>&1 || result=$?
  fi
  chmod 0600 "$output"
  return "$result"
}

rank_capture_failed=0
capture_rank_log shamu direct "$artifacts/rank0-container.log" || rank_capture_failed=1
capture_rank_log tilikum sudo "$artifacts/rank1-container.log" || rank_capture_failed=1
if (( rank_capture_failed != 0 )); then
  status=1
  validation_message="failed to capture one or more serving-rank logs"
fi

post_rank0_state="$pre_rank0_state"
post_rank1_state="$pre_rank1_state"
if [[ "${WEBSTER_WEKA_TEST_MODE:-0}" != 1 ]]; then
  post_rank0_state="$(collect_rank_state shamu direct "$expected_image")" || status=1
  post_rank1_state="$(collect_rank_state tilikum sudo "$expected_image")" || status=1
fi
printf '%s\n' "$post_rank0_state" >"$artifacts/rank0-after.json"
printf '%s\n' "$post_rank1_state" >"$artifacts/rank1-after.json"
python3 - "$artifacts/benchmark-window.json" "$benchmark_started_at" \
  "$benchmark_ended_at" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(
    json.dumps({"started_at": sys.argv[2], "ended_at": sys.argv[3]}, sort_keys=True)
    + "\n",
    encoding="utf-8",
)
os.chmod(path, 0o600)
PY
chmod 0600 "$artifacts/rank0-after.json" "$artifacts/rank1-after.json"

rank_fatal_matches="$(python3 - \
  "$artifacts/rank0-container.log" "$artifacts/rank1-container.log" <<'PY'
import re
import sys
from pathlib import Path

pattern = re.compile(
    r"EngineDeadError|NCCL.*(?:timeout|error)|RPC call.*timed out",
    re.IGNORECASE,
)
print(
    sum(
        len(pattern.findall(Path(path).read_text(encoding="utf-8", errors="replace")))
        for path in sys.argv[1:]
    )
)
PY
)"
if (( rank_fatal_matches != 0 )); then
  status=1
  validation_message="fatal serving-rank log markers detected: $rank_fatal_matches"
fi
cancelled=0
if (( status == 0 )); then
  validation_code=0
  validation_message="$(validate_weka_artifacts "$artifacts" 2>&1)" ||
    validation_code=$?
  if (( validation_code != 0 )); then
    status="$validation_code"
    (( validation_code == 130 )) && cancelled=1
  fi
fi
printf 'EXIT=%s\n' "$status" >"$artifacts/EXIT"
chmod -R go-rwx "$artifacts"

serving_generation="$pre_run_generation"
if (( status == 0 )); then
  serving_generation="$(resolve_generation_from_states \
    "$post_rank0_state" "$post_rank1_state")"
  require_eq "serving generation remained stable" "$pre_run_generation" \
    "$serving_generation"
fi
if (( status == 0 )); then
  python3 - "$artifacts" "$profile_name" "${concurrency:-0}" "$repetition" \
    "$AIPERF_COMMIT" "$WEKA_REPOSITORY" "$WEKA_REVISION" \
    "$WEKA_TRACE_COUNT" "$serving_generation" "$cache_state" \
    "$AIPERF_WEKA_PATCH_SHA256" \
    "$warmup_and_scored_comparable" "$warmup_provenance_sha256" <<'PY'
import hashlib
import json
import os
import re
import sys
from pathlib import Path

(
    artifacts_raw,
    profile_name,
    concurrency,
    repetition,
    aiperf_commit,
    repository,
    revision,
    trace_count,
    serving_generation,
    cache_state,
    aiperf_weka_patch_sha256,
    warmup_and_scored_comparable,
    warmup_provenance_sha256,
) = sys.argv[1:]
artifacts = Path(artifacts_raw)
names = (
    "EXIT",
    ".aiperf_results_ready.json",
    "profile_export.jsonl",
    "profile_export_aiperf.json",
    "server_metrics_export.json",
    "aiperf.stdout.log",
    "aiperf.stderr.log",
    "rendered-command.txt",
    "summary.json",
    "benchmark-window.json",
    "rank0-before.json",
    "rank1-before.json",
    "rank0-after.json",
    "rank1-after.json",
    "rank0-container.log",
    "rank1-container.log",
)
missing = [name for name in names if not (artifacts / name).is_file()]
if missing:
    raise SystemExit("missing raw AIPerf artifacts: " + ", ".join(missing))
combined_logs = "\n".join(
    (artifacts / name).read_text(encoding="utf-8", errors="replace")
    for name in (
        "aiperf.stdout.log",
        "aiperf.stderr.log",
        "rank0-container.log",
        "rank1-container.log",
    )
    if (artifacts / name).is_file()
)
records_text = (artifacts / "profile_export.jsonl").read_text(
    encoding="utf-8", errors="replace"
)
value = {
    "schema_version": 1,
    "profile_name": profile_name,
    "concurrency": int(concurrency),
    "repetition": int(repetition),
    "cache_state": cache_state,
    "warmup_and_scored_comparable": warmup_and_scored_comparable == "true",
    "warmup_provenance_sha256": warmup_provenance_sha256 or None,
    "aiperf_commit": aiperf_commit,
    "aiperf_weka_patch_sha256": aiperf_weka_patch_sha256,
    "weka_repository": repository,
    "weka_revision": revision,
    "trace_count": int(trace_count),
    "full_subagents": True,
    "serving_generation": serving_generation,
    "engine_deaths": combined_logs.count("EngineDeadError"),
    "nccl_timeouts": sum(
        combined_logs.lower().count(marker)
        for marker in ("nccl timeout", "nccl operation timed out")
    ),
    "rank_fatal_error_matches": sum(
        len(
            re.findall(
                r"EngineDeadError|NCCL.*(?:timeout|error)|RPC call.*timed out",
                (artifacts / name).read_text(encoding="utf-8", errors="replace"),
                re.IGNORECASE,
            )
        )
        for name in ("rank0-container.log", "rank1-container.log")
    ),
    "corruption_flags": records_text.lower().count('"corruption":true'),
    "artifacts": {
        name: hashlib.sha256((artifacts / name).read_bytes()).hexdigest()
        for name in names
    },
}
temporary = artifacts / f"provenance.json.tmp.{os.getpid()}"
temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.chmod(temporary, 0o600)
os.replace(temporary, artifacts / "provenance.json")
PY
fi

partial="$destination.partial.$$"
[[ ! -e "$destination" && ! -e "$partial" ]] || die "Weka destination already exists"
mkdir -m 0700 "$partial"
cp -a "$artifacts/." "$partial/"
mv "$partial" "$destination"
event weka-run "$([[ "$status" == 0 ]] && printf GO || printf NO-GO)" \
  "profile=$profile_name concurrency=${concurrency:-trace-driven} repetition=$repetition schedule=$schedule"
[[ -z "$validation_message" ]] || printf '%s\n' "$validation_message" >&2
(( cancelled == 0 )) || die "AIPerf run was cancelled"
(( status == 0 )) || die "AIPerf exited with status $status"
printf 'GO Weka run complete: %s\n' "$destination"
