#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

run_root=""
while (($#)); do
  case "$1" in
    --run-root)
      [[ $# -ge 2 ]] || die "--run-root requires a value"
      run_root="$2"
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done
init_run_root "$(validate_run_root "$run_root")"

event start-glm52 START "coordinated cold rollback"

if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
  existing_shamu="${TEST_LIFECYCLE_GLM_SHAMU_RUNNING:-false}"
  existing_tilikum="${TEST_LIFECYCLE_GLM_TILIKUM_RUNNING:-false}"
else
  existing_shamu="$(ssh shamu "docker inspect '$GLM_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false")"
  existing_tilikum="$(ssh tilikum "sudo -n docker inspect '$GLM_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false")"
fi
if [[ "$existing_shamu" == true && "$existing_tilikum" == true ]]; then
  if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
    require_eq "existing GLM authenticated health" 1 "${TEST_LIFECYCLE_AUTH_OK:-1}"
    require_eq "existing GLM listener isolation" 1 "${TEST_LIFECYCLE_LISTENERS_OK:-1}"
    require_eq "existing GLM rank 1 keyless" 1 "${TEST_LIFECYCLE_RANK1_KEYLESS:-1}"
  else
    check_glm_health || die "both GLM ranks run but direct health is unavailable"
    ssh tilikum "sudo -n docker inspect '$GLM_CONTAINER' --format '{{json .Args}}' | grep -q -- --headless" ||
      die "both GLM ranks run but rank 1 is not headless"
  fi
  event start-glm52 GO "existing healthy two-rank deployment retained"
  printf 'GLM-5.2 TP2 already healthy; no relaunch performed\n'
  exit 0
fi
if [[ "$existing_shamu" == true || "$existing_tilikum" == true ]]; then
  "$script_dir/stop-glm52-tp2.sh" --run-root "$RUN_ROOT"
fi
"$script_dir/stop-deepseek-v41-tp2.sh" --run-root "$RUN_ROOT"

shamu_command="GLM_NODE_RANK=0 GLM_HOST_IP=$SHAMU_RAIL GLM_MAX_MODEL_LEN=320000 GLM_MAX_NUM_SEQS=8 /home/alecfong/serve_glm52.sh"
tilikum_command="GLM_NODE_RANK=1 GLM_HOST_IP=$TILIKUM_RAIL GLM_MAX_MODEL_LEN=320000 GLM_MAX_NUM_SEQS=8 GLM_DOCKER='sudo -n docker' /home/alecfong/serve_glm52.sh"

if ! ssh shamu "$shamu_command" >/dev/null; then
  event start-glm52 NO-GO "rank 0 launch failed"
  die "GLM rank 0 launch failed"
fi
if ! ssh tilikum "$tilikum_command" >/dev/null; then
  set +e
  "$script_dir/stop-glm52-tp2.sh" --run-root "$RUN_ROOT"
  set -e
  event start-glm52 NO-GO "rank 1 launch failed; both ranks stopped"
  die "GLM rank 1 launch failed"
fi

if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
  require_eq "GLM authenticated health" 1 "${TEST_LIFECYCLE_AUTH_OK:-1}"
  require_eq "GLM listener isolation" 1 "${TEST_LIFECYCLE_LISTENERS_OK:-1}"
  require_eq "GLM rank 1 keyless" 1 "${TEST_LIFECYCLE_RANK1_KEYLESS:-1}"
  event start-glm52 GO "test-mode rollback checks passed"
  printf 'GLM-5.2 TP2 rollback validated\n'
  exit 0
fi

ready=0
memory_log="$RUN_ROOT/metrics/glm52-rank1-startup-memory.tsv"
printf 'captured_at\tmemory_used_mib\n' >"$memory_log"
chmod 0600 "$memory_log"
for _ in $(seq 1 60); do
  memory="$(ssh tilikum "nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits" 2>/dev/null || true)"
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${memory:-unknown}" >>"$memory_log"
  shamu_running="$(ssh shamu "docker inspect '$GLM_CONTAINER' --format '{{.State.Running}}' 2>/dev/null" || true)"
  tilikum_running="$(ssh tilikum "sudo -n docker inspect '$GLM_CONTAINER' --format '{{.State.Running}}' 2>/dev/null" || true)"
  if [[ "$shamu_running" == true && "$tilikum_running" == true ]] &&
    ssh shamu python3 - <<'PY' >/dev/null 2>&1
from pathlib import Path
import urllib.request

line = Path("/home/alecfong/.config/glm52/vllm-api.env").read_text().strip()
key = line.split("=", 1)[1]
request = urllib.request.Request(
    "http://100.73.140.127:8000/v1/models",
    headers={"Authorization": "Bearer " + key},
)
with urllib.request.urlopen(request, timeout=5) as response:
    if response.status != 200:
        raise SystemExit(1)
PY
  then
    ready=1
    break
  fi
  sleep 20
done
if [[ "$ready" != 1 ]]; then
  capture glm52-shamu-failed-start ssh shamu "docker logs --tail 400 '$GLM_CONTAINER'"
  capture glm52-tilikum-failed-start ssh tilikum "sudo -n docker logs --tail 400 '$GLM_CONTAINER'"
  set +e
  "$script_dir/stop-glm52-tp2.sh" --run-root "$RUN_ROOT"
  set -e
  event start-glm52 NO-GO "direct authenticated health absent after 20 minutes"
  die "GLM rollback did not become healthy within 20 minutes"
fi

ssh tilikum "sudo -n docker inspect '$GLM_CONTAINER' --format '{{json .Args}}' | grep -q -- --headless" ||
  die "GLM rank 1 is not headless"
ssh tilikum python3 - "$GLM_CONTAINER" <<'PY'
import json
import subprocess
import sys

name = sys.argv[1]
data = json.loads(subprocess.check_output(["sudo", "-n", "docker", "inspect", name]))[0]
for item in data.get("Config", {}).get("Env", []):
    if item.startswith(("VLLM_API_KEY=", "DSPARK_API_KEYS=")) and item.split("=", 1)[1]:
        raise SystemExit("rank 1 received a serving key")
if data.get("RestartCount") != 0:
    raise SystemExit("rank 1 restart count is nonzero")
PY
shamu_listener="$(ssh shamu "ss -lntH '( sport = :$CANARY_PORT )' | awk '{print \$4}'")"
require_eq "GLM rank 0 listener" "$SHAMU_NETBIRD:$CANARY_PORT" "$shamu_listener"
[[ -z "$(ssh tilikum "ss -lntH '( sport = :$CANARY_PORT )'")" ]] ||
  die "GLM rank 1 exposes port $CANARY_PORT"
event start-glm52 GO "both ranks healthy; rank 1 headless/keyless; listener isolated"
printf 'GLM-5.2 TP2 rollback validated\n'
