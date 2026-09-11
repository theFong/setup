#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

node=""
run_root=""
while (($#)); do
  case "$1" in
    --node)
      [[ $# -ge 2 ]] || die "--node requires a value"
      node="$2"
      shift 2
      ;;
    --run-root)
      [[ $# -ge 2 ]] || die "--run-root requires a value"
      run_root="$2"
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$node" in
  shamu|tilikum) ;;
  *) die "node must be shamu or tilikum" ;;
esac
validated_root="$(validate_run_root "$run_root")"

if [[ "${WEBSTER_STAGE_TEST_MODE:-0}" == "1" ]]; then
  require_ge "free bytes before staging" "$MIN_FREE_BEFORE_STAGE_BYTES" \
    "${TEST_FREE_BYTES:-$MIN_FREE_BEFORE_STAGE_BYTES}"
  [[ "${TEST_STAGE_FINAL_STATE:-absent}" != "divergent" ]] ||
    die "divergent final checkpoint must not be overwritten"
  if [[ -n "${TEST_STAGE_HEALTH_WINDOWS:-}" ]]; then
    baseline_p90="${TEST_STAGE_BASELINE_P90:?test baseline p90 is required}"
    consecutive_failures=0
    while read -r request_count success_rate p90; do
      [[ -n "${request_count:-}" ]] || continue
      decision="$(stage_window_decision \
        "$baseline_p90" "$request_count" "$success_rate" "$p90")"
      if [[ "$decision" == BREACH\ * ]]; then
        consecutive_failures=$((consecutive_failures + 1))
      else
        consecutive_failures=0
      fi
      (( consecutive_failures < 2 )) ||
        die "GLM success/latency breached for two consecutive staging windows"
    done <<<"$TEST_STAGE_HEALTH_WINDOWS"
  fi
  ssh "$node" stage-artifacts-test >/dev/null
  exit 0
fi

[[ -d "$validated_root" ]] || die "run root does not exist; run baseline preflight first"
RUN_ROOT="$validated_root"
export RUN_ROOT
checkpoint_name="DeepSeek-V4.1-Flash-${CHECKPOINT_REVISION:0:10}"
model_parent="/home/alecfong/deepseek-v41/models"
final_path="$model_parent/$checkpoint_name"
incomplete_path="$model_parent/.$checkpoint_name.incomplete"
verifier="$script_dir/verify-checkpoint.py"
[[ -f "$verifier" ]] || die "missing checkpoint verifier"

event "stage-$node" START "immutable checkpoint staging"
ssh "$node" "curl -fsS --max-time 5 'http://$SHAMU_NETBIRD:$CANARY_PORT/health' >/dev/null" ||
  die "GLM health failed before staging on $node"

baseline_p90=""
baseline_window=""
for candidate_window in 15m 1h 6h 24h 7d; do
  baseline_candidate="$RUN_ROOT/metrics/stage-$node-baseline-$candidate_window.json"
  write_glm_window_snapshot "$baseline_candidate" "$candidate_window" ||
    die "cannot capture GLM staging baseline from Prometheus"
  read -r baseline_requests candidate_p90 < <(
    python3 - "$baseline_candidate" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
requests = data.get("request_count")
p90 = data.get("p90_seconds")
print("null" if requests is None else requests, "null" if p90 is None else p90)
PY
  )
  if python3 - "$baseline_requests" "$candidate_p90" \
    "$STAGE_BASELINE_MIN_REQUESTS" <<'PY'
import math
import sys

try:
    requests, p90, minimum = map(float, sys.argv[1:])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if requests >= minimum and math.isfinite(p90) and p90 > 0 else 1)
PY
  then
    baseline_p90="$candidate_p90"
    baseline_window="$candidate_window"
    break
  fi
done
[[ -n "$baseline_p90" ]] ||
  die "no GLM latency baseline with at least $STAGE_BASELINE_MIN_REQUESTS requests"
event "stage-$node" GO \
  "monitor baseline window=$baseline_window p90_seconds=$baseline_p90"

layout_file="$RUN_ROOT/baseline/$node-lfs-layout.json"
ssh "$node" python3 - "$CHECKPOINT_REPO" "$CHECKPOINT_REVISION" \
  "$incomplete_path" >"$layout_file" <<'PY'
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

repo, revision, incomplete = sys.argv[1:]
url = (
    "https://huggingface.co/api/models/"
    + urllib.parse.quote(repo, safe="/")
    + "/revision/"
    + urllib.parse.quote(revision, safe="")
    + "?blobs=true"
)
with urllib.request.urlopen(url, timeout=60) as response:
    metadata = json.load(response)
if metadata.get("sha") != revision:
    raise SystemExit("resolved Hugging Face revision does not match requested revision")
root = Path(incomplete)
files = []
missing = []
for sibling in metadata.get("siblings", []):
    name = sibling.get("rfilename")
    if not isinstance(name, str) or not name:
        continue
    size = sibling.get("lfs", {}).get("size", sibling.get("size"))
    if not isinstance(size, int) or size < 0:
        raise SystemExit(f"missing size metadata for {name}")
    files.append({"path": name, "bytes": size})
    candidate = root / name
    if not candidate.is_file() or candidate.stat().st_size != size:
        missing.append({"path": name, "bytes": size})
print(json.dumps({
    "repository": repo,
    "revision": revision,
    "files": files,
    "missing_files": missing,
    "missing_file_bytes": sum(item["bytes"] for item in missing),
    "largest_missing_file_bytes": max((item["bytes"] for item in missing), default=0),
}, sort_keys=True, indent=2))
PY
chmod 0600 "$layout_file"

read -r missing_bytes largest_missing < <(
  python3 - "$layout_file" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data["missing_file_bytes"], data["largest_missing_file_bytes"])
PY
)
required_bytes=$((missing_bytes + largest_missing + MIN_FREE_AFTER_STAGE_BYTES))
(( required_bytes < MIN_FREE_BEFORE_STAGE_BYTES )) &&
  required_bytes="$MIN_FREE_BEFORE_STAGE_BYTES"
free_bytes="$(ssh "$node" "df -PB1 '$model_parent' 2>/dev/null | awk 'NR==2 {print \\$4}' || df -PB1 /home/alecfong | awk 'NR==2 {print \\$4}'")"
require_ge "$node free bytes for staging" "$required_bytes" "$free_bytes"

verify_remote() {
  local path="$1" output="$2"
  ssh "$node" python3 - "$path" <"$verifier" >"$output"
  chmod 0600 "$output"
}

download_log="$incomplete_path/download.log"
download_status="$incomplete_path/download.status"
download_pid="$incomplete_path/download.pid"
download_runner="$incomplete_path/download.runner.sh"
download_container="deepseek-v41-artifact-stage-${CHECKPOINT_REVISION:0:10}"
if [[ "$node" == "tilikum" ]]; then
  download_docker_mode="sudo"
  download_docker="sudo -n docker"
else
  download_docker_mode="plain"
  download_docker="docker"
fi
shamu_downloader_image="$(ssh shamu \
  'docker inspect glm52-full-mtp --format "{{.Image}}"')"
tilikum_downloader_image="$(ssh tilikum \
  'sudo -n docker inspect glm52-full-mtp --format "{{.Image}}"')"
[[ "$shamu_downloader_image" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  die "invalid Shamu GLM image ID for artifact downloader"
require_eq "station GLM image ID" "$shamu_downloader_image" \
  "$tilikum_downloader_image"
download_image="$shamu_downloader_image"
event "stage-$node" GO "downloader image=$download_image runtime=runc gpu=none"
download_active=0
stage_complete=0

remote_download_pid() {
  local pid
  pid="$(ssh "$node" "test -s '$download_pid' && cat '$download_pid'" 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$pid"
}

remote_download_is_running() {
  local pid
  pid="$(remote_download_pid)" || return 1
  ssh "$node" "/bin/kill -0 -- '-$pid' 2>/dev/null"
}

capture_download_evidence() {
  local suffix="$1" artifact
  artifact="$RUN_ROOT/logs/stage-$node-download-$suffix.log"
  if ssh "$node" test -f "$download_log"; then
    ssh "$node" "cat '$download_log'" >"$artifact"
    chmod 0600 "$artifact"
  fi
  artifact="$RUN_ROOT/logs/stage-$node-download-$suffix.status"
  if ssh "$node" test -f "$download_status"; then
    ssh "$node" "cat '$download_status'" >"$artifact"
    chmod 0600 "$artifact"
  fi
  artifact="$RUN_ROOT/logs/stage-$node-download-$suffix.runner.sh"
  if ssh "$node" test -f "$download_runner"; then
    ssh "$node" "cat '$download_runner'" >"$artifact"
    chmod 0600 "$artifact"
  fi
  artifact="$RUN_ROOT/logs/stage-$node-hf-cache-$suffix.tar"
  if ssh "$node" test -d "$incomplete_path/.cache"; then
    ssh "$node" "tar -C '$incomplete_path' -cf - .cache" >"$artifact"
    chmod 0600 "$artifact"
  fi
}

start_remote_download() {
  ssh "$node" bash -s -- \
    "$download_docker_mode" "$download_container" "$download_image" \
    "$CHECKPOINT_REPO" "$CHECKPOINT_REVISION" "$incomplete_path" \
    "$download_status" "$download_log" "$download_pid" "$download_runner" <<'REMOTE'
set -euo pipefail
docker_mode="$1"
container="$2"
image="$3"
repository="$4"
revision="$5"
incomplete="$6"
status_file="$7"
log_file="$8"
pid_file="$9"
runner="${10}"

case "$docker_mode" in
  plain) docker_command=(docker) ;;
  sudo) docker_command=(sudo -n docker) ;;
  *) printf 'invalid Docker mode\n' >&2; exit 2 ;;
esac

"${docker_command[@]}" rm -f "$container" >/dev/null 2>&1 || true
rm -f -- "$pid_file"
cat >"$runner" <<'RUNNER'
#!/usr/bin/env bash
set -uo pipefail
docker_mode="$1"
container="$2"
image="$3"
repository="$4"
revision="$5"
incomplete="$6"
status_file="$7"
case "$docker_mode" in
  plain) docker_command=(docker) ;;
  sudo) docker_command=(sudo -n docker) ;;
  *) printf 'invalid Docker mode\n' >&2; exit 2 ;;
esac
"${docker_command[@]}" run --rm --runtime runc --network bridge \
  --name "$container" \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --env HF_HUB_DISABLE_TELEMETRY=1 \
  --env HF_HUB_DISABLE_XET=1 \
  --env NVIDIA_VISIBLE_DEVICES=void \
  --volume "$incomplete:$incomplete" \
  --entrypoint ionice \
  "$image" -c3 nice -n 19 python3 -c \
  'from huggingface_hub import snapshot_download; import sys; snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], local_dir=sys.argv[3], max_workers=1)' \
  "$repository" "$revision" "$incomplete"
status=$?
printf 'EXIT=%s\n' "$status" >"$status_file"
exit "$status"
RUNNER
chmod 0700 "$runner"
nohup setsid "$runner" "$docker_mode" "$container" "$image" "$repository" \
  "$revision" "$incomplete" "$status_file" >"$log_file" 2>&1 </dev/null &
printf '%s\n' "$!" >"$pid_file"
REMOTE
}

cancel_remote_download() {
  local pid attempt
  pid="$(remote_download_pid)" || return 0
  ssh "$node" "$download_docker stop --time 15 '$download_container' >/dev/null 2>&1 || true; /bin/kill -TERM -- '-$pid' 2>/dev/null || true"
  for attempt in 1 2 3 4 5; do
    ssh "$node" "/bin/kill -0 -- '-$pid' 2>/dev/null" || return 0
    sleep 1
  done
  ssh "$node" "/bin/kill -KILL -- '-$pid' 2>/dev/null || true"
}

cleanup_on_exit() {
  local status=$?
  trap - EXIT
  if (( status != 0 && download_active == 1 && stage_complete == 0 )); then
    cancel_remote_download || true
    capture_download_evidence "abort-$(date -u +%Y%m%dT%H%M%SZ)" || true
    event "stage-$node" NO-GO "download cancelled after staging gate failure" || true
  fi
  exit "$status"
}
trap cleanup_on_exit EXIT

local_manifest="$RUN_ROOT/baseline/$node-checkpoint.manifest"
if ssh "$node" test -d "$final_path"; then
  ssh "$node" test -f "$final_path/MANIFEST.sha256" ||
    die "existing final checkpoint has no stored manifest at $node:$final_path"
  if ! verify_remote "$final_path" "$local_manifest"; then
    die "divergent final checkpoint at $node:$final_path; refusing overwrite"
  fi
  event "stage-$node" GO "existing immutable checkpoint verified"
else
  ssh "$node" "umask 077; mkdir -p '$incomplete_path'"
  if ssh "$node" test -s "$download_status"; then
    status_line="$(ssh "$node" "cat '$download_status'")"
    if [[ "$status_line" != "EXIT=0" ]]; then
      capture_download_evidence "retry-$(date -u +%Y%m%dT%H%M%SZ)"
      ssh "$node" "rm -f -- '$download_log' '$download_status' '$download_pid' '$download_runner'"
    fi
  fi
  if ! ssh "$node" test -s "$download_status" && ! remote_download_is_running; then
    start_remote_download
  fi
  if ! ssh "$node" test -s "$download_status"; then
    remote_download_is_running || die "checkpoint downloader failed to start on $node"
    download_active=1
  fi

  window=0
  consecutive_failures=0
  while ! ssh "$node" test -s "$download_status"; do
    sleep 60
    window=$((window + 1))
    if ! remote_download_is_running && ! ssh "$node" test -s "$download_status"; then
      die "checkpoint downloader exited without a completion record on $node"
    fi
    window_snapshot="$RUN_ROOT/metrics/stage-$node-window-$(printf '%05d' "$window").json"
    write_glm_window_snapshot "$window_snapshot" 1m ||
      die "cannot capture GLM staging window from Prometheus"
    read -r request_count success_rate p90 < <(
      python3 - "$window_snapshot" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
values = [data.get("request_count"), data.get("success_rate"), data.get("p90_seconds")]
print(*(value if value is not None else "null" for value in values))
PY
    )
    decision="$(stage_window_decision \
      "$baseline_p90" "$request_count" "$success_rate" "$p90")" ||
      die "invalid GLM staging-window metrics"
    window_bad=0
    [[ "$decision" != BREACH\ * ]] || window_bad=1
    if ! ssh "$node" "curl -fsS --max-time 5 'http://$SHAMU_NETBIRD:$CANARY_PORT/health' >/dev/null"; then
      decision="BREACH direct-health-check-failed;$decision"
      window_bad=1
    fi
    if (( window_bad == 1 )); then
      consecutive_failures=$((consecutive_failures + 1))
    else
      consecutive_failures=0
    fi
    event "stage-$node-window-$window" MONITOR "$decision"
    if (( window % 5 == 0 )); then
      capture "stage-$node-window-$window" bash -c \
        "ssh '$node' 'df -PB1 /home/alecfong; cat /proc/pressure/io'"
    fi
    (( consecutive_failures < 2 )) ||
      die "GLM success/latency failed for two consecutive staging windows"
  done
  download_active=0
  status_line="$(ssh "$node" "cat '$download_status'")"
  capture_download_evidence "complete-$(date -u +%Y%m%dT%H%M%SZ)"
  require_eq "$node checkpoint download" "EXIT=0" "$status_line"
  ssh "$node" "rm -f -- '$download_log' '$download_status' '$download_pid' '$download_runner'; if test -d '$incomplete_path/.cache'; then rm -rf -- '$incomplete_path/.cache'; fi"

  verify_remote "$incomplete_path" "$local_manifest"
  ssh "$node" "tee '$incomplete_path/MANIFEST.sha256' >/dev/null" <"$local_manifest"
  ssh "$node" "mv '$incomplete_path' '$final_path'; chmod -R a-w '$final_path'"
  verify_remote "$final_path" "$local_manifest.after"
  cmp "$local_manifest" "$local_manifest.after" ||
    die "checkpoint manifest changed during atomic promotion"
  mv "$local_manifest.after" "$local_manifest"
  event "stage-$node" GO "checkpoint downloaded, verified, and made immutable"
fi

free_bytes="$(ssh "$node" "df -PB1 '$final_path' | awk 'NR==2 {print \\$4}'")"
require_ge "$node post-stage free bytes" "$MIN_FREE_AFTER_STAGE_BYTES" "$free_bytes"

other_node="shamu"
[[ "$node" == "shamu" ]] && other_node="tilikum"
other_manifest="$RUN_ROOT/baseline/$other_node-checkpoint.manifest"
if [[ -f "$other_manifest" ]]; then
  cmp "$other_manifest" "$local_manifest" ||
    die "cross-node checkpoint manifest mismatch"
fi

if [[ "$node" == "shamu" ]]; then
  source_dir="$(ssh shamu 'python3 - <<'"'"'PY'"'"'
import json
import subprocess
from pathlib import Path
inspect = json.loads(subprocess.check_output(["docker", "inspect", "glm52-full-mtp"]))[0]
for mount in inspect.get("Mounts", []):
    source = Path(mount.get("Source", ""))
    if source.is_dir() and all((source / name).is_file() for name in ("tokenizer.json", "tokenizer_config.json", "chat_template.jinja")):
        print(source)
        break
else:
    raise SystemExit("GLM tokenizer mount not found")
PY')"
  tokenizer_local="$RUN_ROOT/baseline/glm52-tokenizer"
  mkdir -p "$tokenizer_local"
  ssh shamu "cd '$source_dir' && sha256sum tokenizer.json tokenizer_config.json chat_template.jinja | sort" \
    >"$RUN_ROOT/baseline/glm52-tokenizer.source.manifest"
  ssh shamu "tar -C '$source_dir' -cf - tokenizer.json tokenizer_config.json chat_template.jinja" |
    tar -C "$tokenizer_local" -xf -
  (cd "$tokenizer_local" && sha256sum tokenizer.json tokenizer_config.json chat_template.jinja | sort) \
    >"$RUN_ROOT/baseline/glm52-tokenizer.manifest"
  cmp "$RUN_ROOT/baseline/glm52-tokenizer.source.manifest" \
    "$RUN_ROOT/baseline/glm52-tokenizer.manifest" ||
    die "GLM tokenizer hash mismatch after copying from Shamu"
  chmod 0600 "$RUN_ROOT/baseline/glm52-tokenizer.source.manifest"
  chmod 0600 "$RUN_ROOT/baseline/glm52-tokenizer.manifest"

  tokenizer_parent="/home/nvidia/litellm/energy-pricing"
  tokenizer_final="$tokenizer_parent/glm52-tokenizer"
  tokenizer_temp="$tokenizer_parent/.glm52-tokenizer-${CHECKPOINT_REVISION:0:10}.tmp"
  if ssh spark-1 test -d "$tokenizer_final"; then
    ssh spark-1 "cd '$tokenizer_final' && sha256sum tokenizer.json tokenizer_config.json chat_template.jinja | sort" \
      >"$RUN_ROOT/baseline/glm52-tokenizer.remote.manifest"
    cmp "$RUN_ROOT/baseline/glm52-tokenizer.manifest" \
      "$RUN_ROOT/baseline/glm52-tokenizer.remote.manifest" ||
      die "divergent staged GLM tokenizer; refusing overwrite"
  else
    if ssh spark-1 test -d "$tokenizer_temp"; then
      ssh spark-1 "cd '$tokenizer_temp' && sha256sum tokenizer.json tokenizer_config.json chat_template.jinja | sort" \
        >"$RUN_ROOT/baseline/glm52-tokenizer.temp.manifest" ||
        die "incomplete staged GLM tokenizer cannot be verified"
      cmp "$RUN_ROOT/baseline/glm52-tokenizer.manifest" \
        "$RUN_ROOT/baseline/glm52-tokenizer.temp.manifest" ||
        die "divergent incomplete GLM tokenizer; refusing overwrite"
    else
      ssh spark-1 "umask 077; mkdir '$tokenizer_temp'"
      tar -C "$tokenizer_local" -cf - . |
        ssh spark-1 "tar -C '$tokenizer_temp' -xf -"
    fi
    ssh spark-1 "cd '$tokenizer_temp' && sha256sum tokenizer.json tokenizer_config.json chat_template.jinja | sort" \
      >"$RUN_ROOT/baseline/glm52-tokenizer.remote.manifest"
    cmp "$RUN_ROOT/baseline/glm52-tokenizer.manifest" \
      "$RUN_ROOT/baseline/glm52-tokenizer.remote.manifest" ||
      die "GLM tokenizer hash mismatch after transfer"
    ssh spark-1 "mv '$tokenizer_temp' '$tokenizer_final'; chmod -R a-w '$tokenizer_final'"
  fi
fi

stage_complete=1
printf 'GO node=%s checkpoint=%s\n' "$node" "$final_path"
