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

manifest="$RUN_ROOT/manifest.env"
[[ -f "$manifest" && ! -L "$manifest" ]] || die "manifest.env is missing"
require_eq "manifest mode" 600 "$(stat -c %a "$manifest")"
manifest_value() {
  local key="$1" value
  value="$(awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$manifest")"
  [[ -n "$value" ]] || die "manifest field $key is empty"
  printf '%s\n' "$value"
}
image_id="$(manifest_value VLLM_IMAGE_ID)"
[[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "manifest image ID is invalid"

if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
  existing_shamu="${TEST_LIFECYCLE_DEEPSEEK_SHAMU_RUNNING:-false}"
  existing_tilikum="${TEST_LIFECYCLE_DEEPSEEK_TILIKUM_RUNNING:-false}"
else
  existing_shamu="$(ssh shamu "docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false")"
  existing_tilikum="$(ssh tilikum "sudo -n docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false")"
fi
if [[ "$existing_shamu" == true && "$existing_tilikum" == true ]]; then
  if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
    require_eq "existing authenticated API" 1 "${TEST_LIFECYCLE_AUTH_OK:-1}"
    require_eq "existing listener isolation" 1 "${TEST_LIFECYCLE_LISTENERS_OK:-1}"
    require_eq "existing rank 1 keyless" 1 "${TEST_LIFECYCLE_RANK1_KEYLESS:-1}"
    require_eq "existing NCCL rail" 1 "${TEST_LIFECYCLE_NCCL_OK:-1}"
  else
    curl -fsS --connect-timeout 3 --max-time 5 \
      "http://$SHAMU_NETBIRD:$CANARY_PORT/health" >/dev/null ||
      die "both DeepSeek ranks run but direct health is unavailable"
    ssh tilikum "sudo -n docker inspect '$DEEPSEEK_CONTAINER' --format '{{json .Args}}' | grep -q -- --headless" ||
      die "both DeepSeek ranks run but rank 1 is not headless"
  fi
  event start-deepseek-v41 GO "existing healthy two-rank deployment retained"
  printf 'DeepSeek V4.1 TP2 already healthy; no relaunch performed\n'
  exit 0
fi
if [[ "$existing_shamu" == true || "$existing_tilikum" == true ]]; then
  "$script_dir/stop-deepseek-v41-tp2.sh" --run-root "$RUN_ROOT"
fi

test_lifecycle_gate() {
  require_eq "Shamu GLM stopped" false "${TEST_LIFECYCLE_GLM_SHAMU_RUNNING:-false}"
  require_eq "Tilikum GLM stopped" false "${TEST_LIFECYCLE_GLM_TILIKUM_RUNNING:-false}"
  require_eq "checkpoint manifests" 1 "${TEST_LIFECYCLE_CHECKPOINTS_MATCH:-1}"
  require_eq "runtime image IDs" 1 "${TEST_LIFECYCLE_IMAGES_MATCH:-1}"
  require_ge "station free bytes" "$MIN_FREE_AFTER_STAGE_BYTES" \
    "${TEST_LIFECYCLE_FREE_BYTES:-$MIN_FREE_AFTER_STAGE_BYTES}"
  require_eq "station rails" 1 "${TEST_LIFECYCLE_RAILS_OK:-1}"
  require_eq "Shamu-to-Tilikum SSH" 1 "${TEST_LIFECYCLE_SSH_OK:-1}"
}

live_lifecycle_gate() {
  local shamu_glm tilikum_glm shamu_manifest tilikum_manifest
  shamu_glm="$(ssh shamu "docker inspect '$GLM_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false")"
  tilikum_glm="$(ssh tilikum "sudo -n docker inspect '$GLM_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false")"
  require_eq "Shamu GLM stopped" false "$shamu_glm"
  require_eq "Tilikum GLM stopped" false "$tilikum_glm"
  for node in shamu tilikum; do
    ssh "$node" "test -d '$DEEPSEEK_CHECKPOINT_PATH' && test ! -L '$DEEPSEEK_CHECKPOINT_PATH' && test -r '$DEEPSEEK_CHECKPOINT_PATH/MANIFEST.sha256'" ||
      die "$node checkpoint is incomplete"
    require_ge "$node free bytes" "$MIN_FREE_AFTER_STAGE_BYTES" \
      "$(remote_available_bytes "$node" "$DEEPSEEK_CHECKPOINT_PATH")"
    ssh "$node" "ip addr show dev '$NCCL_IFACE' | grep -q '$([[ "$node" == shamu ]] && printf %s "$SHAMU_RAIL" || printf %s "$TILIKUM_RAIL")/' && grep -q ACTIVE /sys/class/infiniband/'$NCCL_HCA'/ports/1/state" ||
      die "$node rail/HCA validation failed"
  done
  shamu_manifest="$(ssh shamu "sha256sum '$DEEPSEEK_CHECKPOINT_PATH/MANIFEST.sha256' | awk '{print \$1}'")"
  tilikum_manifest="$(ssh tilikum "sha256sum '$DEEPSEEK_CHECKPOINT_PATH/MANIFEST.sha256' | awk '{print \$1}'")"
  require_eq "checkpoint manifest hash" "$shamu_manifest" "$tilikum_manifest"
  require_eq "Shamu runtime image" "$image_id" \
    "$(ssh shamu "docker image inspect '$image_id' --format '{{.Id}}'")"
  require_eq "Tilikum runtime image" "$image_id" \
    "$(ssh tilikum "sudo -n docker image inspect '$image_id' --format '{{.Id}}'")"
  ssh shamu "ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new alecfong@$TILIKUM_RAIL true" ||
    die "Shamu cannot reach Tilikum passwordlessly over the direct rail"
  ssh shamu "test -s '$DEEPSEEK_API_ENV_FILE' && test \"\$(stat -c %a '$DEEPSEEK_API_ENV_FILE')\" = 600 && grep -q '^VLLM_API_KEY=' '$DEEPSEEK_API_ENV_FILE'" ||
    die "DeepSeek rank-0 API env file is missing or unsafe"
  ssh shamu "test -z \"\$(ss -lntH '( sport = :$CANARY_PORT )')\"" ||
    die "Shamu port $CANARY_PORT is already in use"
  ssh tilikum "test -z \"\$(ss -lntH '( sport = :$CANARY_PORT )')\"" ||
    die "Tilikum port $CANARY_PORT is already in use"
  ssh shamu "mkdir -p '$DEEPSEEK_CACHE_PATH'"
  ssh tilikum "mkdir -p '$DEEPSEEK_CACHE_PATH'"
}

event start-deepseek-v41 START "minimal eager TP2/PP1 canary"
if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
  test_lifecycle_gate
else
  live_lifecycle_gate
fi

common_args="/model --served-model-name $DEEPSEEK_SERVED_MODEL --nnodes 2 --master-addr $SHAMU_RAIL --master-port 29511 --distributed-executor-backend mp --tensor-parallel-size 2 --pipeline-parallel-size 1 --engram-config '{\"cpu_offload\":true,\"embedding_across_dp\":false}' --enforce-eager --max-model-len 131072 --max-num-seqs 1 --gpu-memory-utilization 0.90 --disable-custom-all-reduce --enable-auto-tool-choice --tool-call-parser deepseek_v41 --reasoning-parser deepseek_v41"
docker_args="--network host --ipc host --shm-size 34359738368 --gpus all --device /dev/infiniband --restart no --ulimit memlock=-1:-1 --ulimit stack=67108864:67108864 --cap-add CAP_IPC_LOCK --security-opt label=disable -w /vllm-workspace -v $DEEPSEEK_CHECKPOINT_PATH:/model:ro -v $DEEPSEEK_CACHE_PATH:/root/.cache -e NCCL_IB_HCA=$NCCL_HCA -e NCCL_SOCKET_IFNAME=$NCCL_IFACE -e GLOO_SOCKET_IFNAME=$NCCL_IFACE -e NCCL_NET_GDR_LEVEL=5 -e NCCL_IB_GID_INDEX=3 -e NCCL_CUMEM_ENABLE=1 -e NCCL_DEBUG=INFO -e NCCL_DEBUG_SUBSYS=INIT,NET -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 -e VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=1800"
shamu_launch="docker rm -f $DEEPSEEK_CONTAINER >/dev/null 2>&1 || true; docker run -d --name $DEEPSEEK_CONTAINER $docker_args -e VLLM_HOST_IP=$SHAMU_RAIL --env-file $DEEPSEEK_API_ENV_FILE $image_id $common_args --node-rank 0 --host $SHAMU_NETBIRD --port $CANARY_PORT"
tilikum_launch="sudo -n docker rm -f $DEEPSEEK_CONTAINER >/dev/null 2>&1 || true; sudo -n env -u VLLM_API_KEY -u DSPARK_API_KEYS docker run -d --name $DEEPSEEK_CONTAINER $docker_args -e VLLM_HOST_IP=$TILIKUM_RAIL $image_id $common_args --node-rank 1 --headless"

if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
  {
    printf 'deepseek-profile --tensor-parallel-size 2 --pipeline-parallel-size 1 '
    printf '%s ' '--engram-config' '{"cpu_offload":true,"embedding_across_dp":false}'
    printf '%s\n' '--enforce-eager --max-model-len 131072 --max-num-seqs 1 --host 100.73.140.127 --port 8000'
  } >>"$TEST_LOG"
fi

if ! ssh shamu "$shamu_launch" >/dev/null; then
  event start-deepseek-v41 NO-GO "rank 0 launch failed"
  die "DeepSeek rank 0 launch failed"
fi
if ! ssh tilikum "$tilikum_launch" >/dev/null; then
  set +e
  "$script_dir/stop-deepseek-v41-tp2.sh" --run-root "$RUN_ROOT"
  set -e
  event start-deepseek-v41 NO-GO "rank 1 launch failed; both ranks stopped"
  die "DeepSeek rank 1 launch failed"
fi

if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
  require_eq "authenticated API" 1 "${TEST_LIFECYCLE_AUTH_OK:-1}"
  require_eq "listener isolation" 1 "${TEST_LIFECYCLE_LISTENERS_OK:-1}"
  require_eq "rank 1 keyless" 1 "${TEST_LIFECYCLE_RANK1_KEYLESS:-1}"
  require_eq "NCCL rail" 1 "${TEST_LIFECYCLE_NCCL_OK:-1}"
  event start-deepseek-v41 GO "test-mode canary checks passed"
  printf 'DeepSeek V4.1 eager TP2/PP1 canary validated\n'
  exit 0
fi

ready=0
memory_log="$RUN_ROOT/metrics/deepseek-v41-startup-memory.tsv"
printf 'captured_at\tshamu_mib\ttilikum_mib\n' >"$memory_log"
chmod 0600 "$memory_log"
for _ in $(seq 1 60); do
  shamu_memory="$(ssh shamu "nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits" 2>/dev/null || true)"
  tilikum_memory="$(ssh tilikum "nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits" 2>/dev/null || true)"
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${shamu_memory:-unknown}" "${tilikum_memory:-unknown}" >>"$memory_log"
  shamu_running="$(ssh shamu "docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.Running}}' 2>/dev/null" || true)"
  tilikum_running="$(ssh tilikum "sudo -n docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.Running}}' 2>/dev/null" || true)"
  if [[ "$shamu_running" == true && "$tilikum_running" == true ]] &&
    ssh shamu python3 - "$DEEPSEEK_API_ENV_FILE" "$SHAMU_NETBIRD" "$CANARY_PORT" <<'PY' >/dev/null 2>&1
from pathlib import Path
import sys
import urllib.request

path, host, port = sys.argv[1:]
line = Path(path).read_text().strip()
key = line.split("=", 1)[1]
request = urllib.request.Request(
    f"http://{host}:{port}/v1/models",
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
  capture deepseek-v41-shamu-failed-start ssh shamu "docker logs --tail 500 '$DEEPSEEK_CONTAINER'"
  capture deepseek-v41-tilikum-failed-start ssh tilikum "sudo -n docker logs --tail 500 '$DEEPSEEK_CONTAINER'"
  set +e
  "$script_dir/stop-deepseek-v41-tp2.sh" --run-root "$RUN_ROOT"
  set -e
  event start-deepseek-v41 NO-GO "authenticated readiness absent after 20 minutes"
  die "DeepSeek did not become ready within 20 minutes"
fi

require_eq "unauthenticated OpenAI status" 401 \
  "$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://$SHAMU_NETBIRD:$CANARY_PORT/v1/models")"
require_eq "wrong-key OpenAI status" 401 \
  "$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer invalid-canary-key' "http://$SHAMU_NETBIRD:$CANARY_PORT/v1/models")"
require_eq "health status" 200 \
  "$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://$SHAMU_NETBIRD:$CANARY_PORT/health")"
require_eq "metrics status" 200 \
  "$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://$SHAMU_NETBIRD:$CANARY_PORT/metrics")"
shamu_listener="$(ssh shamu "ss -lntH '( sport = :$CANARY_PORT )' | awk '{print \$4}'")"
require_eq "DeepSeek rank 0 listener" "$SHAMU_NETBIRD:$CANARY_PORT" "$shamu_listener"
[[ -z "$(ssh tilikum "ss -lntH '( sport = :$CANARY_PORT )'")" ]] ||
  die "DeepSeek rank 1 exposes port $CANARY_PORT"
ssh tilikum python3 - "$DEEPSEEK_CONTAINER" <<'PY'
import json
import subprocess
import sys

name = sys.argv[1]
data = json.loads(subprocess.check_output(["sudo", "-n", "docker", "inspect", name]))[0]
args = data.get("Args", [])
if "--headless" not in args and "--headless" not in " ".join(args):
    raise SystemExit("rank 1 is not headless")
for item in data.get("Config", {}).get("Env", []):
    if item.startswith(("VLLM_API_KEY=", "DSPARK_API_KEYS=")) and item.split("=", 1)[1]:
        raise SystemExit("rank 1 received a serving key")
if data.get("RestartCount") != 0:
    raise SystemExit("rank 1 restart count is nonzero")
PY
ssh shamu "docker logs '$DEEPSEEK_CONTAINER' 2>&1 | grep -Eq '($NCCL_HCA|NCCL_IB_HCA)'" ||
  die "rank 0 logs do not prove the pinned NCCL HCA"
ssh tilikum "sudo -n docker logs '$DEEPSEEK_CONTAINER' 2>&1 | grep -Eq '($NCCL_HCA|NCCL_IB_HCA)'" ||
  die "rank 1 logs do not prove the pinned NCCL HCA"
capture deepseek-v41-shamu-started ssh shamu \
  "docker inspect '$DEEPSEEK_CONTAINER'; docker logs --tail 500 '$DEEPSEEK_CONTAINER'; free -b; nvidia-smi"
capture deepseek-v41-tilikum-started ssh tilikum \
  "sudo -n docker inspect '$DEEPSEEK_CONTAINER'; sudo -n docker logs --tail 500 '$DEEPSEEK_CONTAINER'; free -b; nvidia-smi"
event start-deepseek-v41 GO "authenticated eager TP2/PP1 canary; rank 1 headless/keyless; NCCL HCA pinned"
printf 'DeepSeek V4.1 eager TP2/PP1 canary validated\n'
