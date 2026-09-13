#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

run_root=""
profile_file=""
verify_only=0
while (($#)); do
  case "$1" in
    --run-root)
      [[ $# -ge 2 ]] || die "--run-root requires a value"
      run_root="$2"
      shift 2
      ;;
    --profile-file)
      [[ $# -ge 2 ]] || die "--profile-file requires a value"
      profile_file="$2"
      shift 2
      ;;
    --verify-only)
      verify_only=1
      shift
      ;;
    *) die "unknown argument: $1" ;;
  esac
done
init_run_root "$(validate_run_root "$run_root")"

profile_name="eager-128k"
max_model_len="131072"
max_num_seqs="1"
gpu_memory_utilization="0.90"
enforce_eager="1"
enable_prefix_caching="0"
max_num_batched_tokens=""
enable_expert_parallel="0"
speculative_method="none"
num_speculative_tokens="0"
draft_sample_method="greedy"
rejection_sample_method="standard"
enable_flashinfer_autotune="1"

if [[ -n "$profile_file" ]]; then
  profile_file="$(canonical_path "$profile_file")"
  case "$profile_file" in
    "$RUN_ROOT"/*) ;;
    *) die "profile file must resolve beneath the run root" ;;
  esac
  [[ -f "$profile_file" && ! -L "$profile_file" ]] ||
    die "profile file must be a regular non-symlink"
  require_eq "profile file mode" 600 "$(stat -c %a "$profile_file")"
  require_eq "profile file owner" "$(id -un)" "$(stat -c %U "$profile_file")"

  declare -A profile_values=()
  declare -A profile_seen=()
  while IFS='=' read -r key value; do
    value="${value%$'\r'}"
    [[ -n "$key" ]] || continue
    [[ "$key" != \#* ]] || continue
    case "$key" in
      PROFILE_NAME|MAX_MODEL_LEN|MAX_NUM_SEQS|GPU_MEMORY_UTILIZATION|\
        ENFORCE_EAGER|ENABLE_PREFIX_CACHING|MAX_NUM_BATCHED_TOKENS|\
        ENABLE_EXPERT_PARALLEL|SPECULATIVE_METHOD|NUM_SPECULATIVE_TOKENS|\
        DRAFT_SAMPLE_METHOD|REJECTION_SAMPLE_METHOD|ENABLE_FLASHINFER_AUTOTUNE) ;;
      *) die "unknown profile field: $key" ;;
    esac
    [[ -z "${profile_seen[$key]:-}" ]] || die "duplicate profile field: $key"
    [[ -n "$value" ]] || die "profile field $key is empty"
    profile_seen[$key]=1
    profile_values[$key]="$value"
  done <"$profile_file"

  for key in PROFILE_NAME MAX_MODEL_LEN MAX_NUM_SEQS GPU_MEMORY_UTILIZATION \
    ENFORCE_EAGER ENABLE_PREFIX_CACHING MAX_NUM_BATCHED_TOKENS \
    ENABLE_EXPERT_PARALLEL; do
    [[ -n "${profile_seen[$key]:-}" ]] || die "profile field $key is missing"
  done
  profile_name="${profile_values[PROFILE_NAME]}"
  max_model_len="${profile_values[MAX_MODEL_LEN]}"
  max_num_seqs="${profile_values[MAX_NUM_SEQS]}"
  gpu_memory_utilization="${profile_values[GPU_MEMORY_UTILIZATION]}"
  enforce_eager="${profile_values[ENFORCE_EAGER]}"
  enable_prefix_caching="${profile_values[ENABLE_PREFIX_CACHING]}"
  max_num_batched_tokens="${profile_values[MAX_NUM_BATCHED_TOKENS]}"
  enable_expert_parallel="${profile_values[ENABLE_EXPERT_PARALLEL]}"
  speculative_method="${profile_values[SPECULATIVE_METHOD]:-$speculative_method}"
  num_speculative_tokens="${profile_values[NUM_SPECULATIVE_TOKENS]:-$num_speculative_tokens}"
  draft_sample_method="${profile_values[DRAFT_SAMPLE_METHOD]:-$draft_sample_method}"
  rejection_sample_method="${profile_values[REJECTION_SAMPLE_METHOD]:-$rejection_sample_method}"
  enable_flashinfer_autotune="${profile_values[ENABLE_FLASHINFER_AUTOTUNE]:-$enable_flashinfer_autotune}"

  [[ "$profile_name" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] ||
    die "PROFILE_NAME is invalid"
  [[ "$max_model_len" =~ ^[1-9][0-9]*$ ]] || die "MAX_MODEL_LEN is invalid"
  [[ "$max_num_seqs" =~ ^[1-9][0-9]*$ ]] || die "MAX_NUM_SEQS is invalid"
  [[ "$max_num_batched_tokens" =~ ^[1-9][0-9]*$ ]] ||
    die "MAX_NUM_BATCHED_TOKENS is invalid"
  [[ "$gpu_memory_utilization" =~ ^0\.[0-9]+$ ]] ||
    die "GPU_MEMORY_UTILIZATION is invalid"
  for toggle in "$enforce_eager" "$enable_prefix_caching" \
    "$enable_expert_parallel" "$enable_flashinfer_autotune"; do
    [[ "$toggle" == 0 || "$toggle" == 1 ]] || die "profile toggle must be 0 or 1"
  done
  case "$speculative_method" in
    none)
      require_eq "NUM_SPECULATIVE_TOKENS for method none" 0 \
        "$num_speculative_tokens"
      ;;
    dspark)
      require_eq "DeepSeek V4.1 DSpark block size" 5 \
        "$num_speculative_tokens"
      [[ "$enforce_eager" == 0 ]] ||
        die "DSpark profile must enable CUDA graphs"
      ;;
    *) die "SPECULATIVE_METHOD is invalid" ;;
  esac
  case "$draft_sample_method" in
    greedy|probabilistic) ;;
    *) die "DRAFT_SAMPLE_METHOD is invalid" ;;
  esac
  case "$rejection_sample_method" in
    standard|block) ;;
    *) die "REJECTION_SAMPLE_METHOD is invalid" ;;
  esac
fi

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

common_args="/model --served-model-name $DEEPSEEK_SERVED_MODEL --nnodes 2 --master-addr $SHAMU_RAIL --master-port 29511 --distributed-executor-backend mp --tensor-parallel-size 2 --pipeline-parallel-size 1 --engram-config '{\"cpu_offload\":true,\"embedding_across_dp\":false}'"
[[ "$enforce_eager" == 0 ]] || common_args+=" --enforce-eager"
common_args+=" --max-model-len $max_model_len --max-num-seqs $max_num_seqs --gpu-memory-utilization $gpu_memory_utilization --disable-custom-all-reduce --enable-auto-tool-choice --tool-call-parser deepseek_v41 --reasoning-parser deepseek_v41"
[[ "$enable_prefix_caching" == 0 ]] || common_args+=" --enable-prefix-caching"
[[ -z "$max_num_batched_tokens" ]] ||
  common_args+=" --max-num-batched-tokens $max_num_batched_tokens"
[[ "$enable_expert_parallel" == 0 ]] || common_args+=" --enable-expert-parallel"
[[ "$enable_flashinfer_autotune" == 0 ]] &&
  common_args+=" --no-enable-flashinfer-autotune"
if [[ "$speculative_method" == dspark ]]; then
  common_args+=" --speculative-config '{\"method\":\"dspark\",\"num_speculative_tokens\":$num_speculative_tokens,\"draft_sample_method\":\"$draft_sample_method\",\"rejection_sample_method\":\"$rejection_sample_method\"}'"
fi
docker_args="--network host --ipc host --shm-size 34359738368 --gpus all --device /dev/infiniband --restart no --ulimit memlock=-1:-1 --ulimit stack=67108864:67108864 --cap-add CAP_IPC_LOCK --security-opt label=disable -w /vllm-workspace -v $DEEPSEEK_CHECKPOINT_PATH:/model:ro -v $DEEPSEEK_CACHE_PATH:/root/.cache -e NCCL_IB_HCA=$NCCL_HCA -e NCCL_SOCKET_IFNAME=$NCCL_IFACE -e GLOO_SOCKET_IFNAME=$NCCL_IFACE -e NCCL_NET_GDR_LEVEL=5 -e NCCL_IB_GID_INDEX=3 -e NCCL_CUMEM_ENABLE=1 -e NCCL_DEBUG=INFO -e NCCL_DEBUG_SUBSYS=INIT,NET -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 -e VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=1800"
profile_fingerprint="$(python3 - "$image_id" "$common_args" "$docker_args" \
  "$SHAMU_RAIL" "$TILIKUM_RAIL" "$SHAMU_NETBIRD" "$CANARY_PORT" <<'PY'
import hashlib
import json
import sys

payload = json.dumps(sys.argv[1:], ensure_ascii=True, separators=(",", ":"))
print(hashlib.sha256(payload.encode("utf-8")).hexdigest())
PY
)"
expected_rank0_cmd="$(python3 - "$common_args --node-rank 0 --host $SHAMU_NETBIRD --port $CANARY_PORT" <<'PY'
import base64
import json
import shlex
import sys

print(base64.b64encode(json.dumps(shlex.split(sys.argv[1])).encode()).decode())
PY
)"
expected_rank1_cmd="$(python3 - "$common_args --node-rank 1 --headless" <<'PY'
import base64
import json
import shlex
import sys

print(base64.b64encode(json.dumps(shlex.split(sys.argv[1])).encode()).decode())
PY
)"

if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
  existing_shamu="${TEST_LIFECYCLE_DEEPSEEK_SHAMU_RUNNING:-false}"
  existing_tilikum="${TEST_LIFECYCLE_DEEPSEEK_TILIKUM_RUNNING:-false}"
else
  existing_shamu="$(ssh shamu "docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false")"
  existing_tilikum="$(ssh tilikum "sudo -n docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false")"
fi

validate_live_deepseek_rank() {
  local node="$1" docker_mode="$2" rank="$3" expected_cmd="$4"
  local host_ip="$5" state
  state="$(ssh "$node" python3 - "$docker_mode" "$DEEPSEEK_CONTAINER" \
    "$image_id" "$expected_cmd" "$profile_fingerprint" "$rank" "$host_ip" \
    "$DEEPSEEK_CHECKPOINT_PATH" "$DEEPSEEK_CACHE_PATH" "$NCCL_HCA" \
    "$NCCL_IFACE" <<'PY'
import base64
import json
import subprocess
import sys

(
    docker_mode,
    container,
    image_id,
    expected_cmd_b64,
    profile_fingerprint,
    rank,
    host_ip,
    checkpoint_path,
    cache_path,
    nccl_hca,
    nccl_iface,
) = sys.argv[1:]
docker = ["docker"] if docker_mode == "direct" else ["sudo", "-n", "docker"]
try:
    data = json.loads(
        subprocess.check_output(docker + ["inspect", container], text=True)
    )[0]
except (subprocess.CalledProcessError, json.JSONDecodeError, IndexError) as error:
    raise SystemExit(f"cannot inspect existing DeepSeek rank {rank}: {error}")

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"existing DeepSeek rank {rank} {message}")

expected_cmd = json.loads(base64.b64decode(expected_cmd_b64))
config = data.get("Config") or {}
host = data.get("HostConfig") or {}
state = data.get("State") or {}
require(state.get("Running") is True, "is not running")
require(data.get("Image") == image_id, "uses the wrong image ID")
require(data.get("RestartCount") == 0, "has a nonzero restart count")
require(config.get("Entrypoint") == ["vllm", "serve"], "has the wrong entrypoint")
require(config.get("Cmd") == expected_cmd, "does not match the requested profile")
require(config.get("WorkingDir") == "/vllm-workspace", "has the wrong working directory")
require(host.get("NetworkMode") == "host", "is not on host networking")
require(host.get("IpcMode") == "host", "does not use host IPC")
require(host.get("ShmSize") == 34359738368, "has the wrong shared-memory size")
require((host.get("RestartPolicy") or {}).get("Name") == "no", "has the wrong restart policy")
require("label=disable" in (host.get("SecurityOpt") or []), "lacks SELinux label isolation")
require(
    any(value in {"IPC_LOCK", "CAP_IPC_LOCK"} for value in (host.get("CapAdd") or [])),
    "lacks IPC_LOCK",
)
ulimits = {item.get("Name"): item for item in (host.get("Ulimits") or [])}
require(
    (ulimits.get("memlock") or {}).get("Soft") == -1
    and (ulimits.get("memlock") or {}).get("Hard") == -1,
    "has the wrong memlock ulimit",
)
require(
    (ulimits.get("stack") or {}).get("Soft") == 67108864
    and (ulimits.get("stack") or {}).get("Hard") == 67108864,
    "has the wrong stack ulimit",
)
mounts = {item.get("Destination"): item for item in (data.get("Mounts") or [])}
require(
    (mounts.get("/model") or {}).get("Source") == checkpoint_path
    and (mounts.get("/model") or {}).get("RW") is False,
    "does not use the requested read-only checkpoint",
)
require(
    (mounts.get("/root/.cache") or {}).get("Source") == cache_path,
    "does not use the requested cache path",
)
require(
    any(
        item.get("PathOnHost") == "/dev/infiniband"
        for item in (host.get("Devices") or [])
    ),
    "lacks the InfiniBand device",
)
require(bool(host.get("DeviceRequests")), "lacks a GPU device request")
environment = {}
for item in config.get("Env") or []:
    if "=" in item:
        key, value = item.split("=", 1)
        environment[key] = value
required_environment = {
    "VLLM_HOST_IP": host_ip,
    "NCCL_IB_HCA": nccl_hca,
    "NCCL_SOCKET_IFNAME": nccl_iface,
    "GLOO_SOCKET_IFNAME": nccl_iface,
    "NCCL_NET_GDR_LEVEL": "5",
    "NCCL_IB_GID_INDEX": "3",
    "NCCL_CUMEM_ENABLE": "1",
    "NCCL_DEBUG": "INFO",
    "NCCL_DEBUG_SUBSYS": "INIT,NET",
    "HF_HUB_OFFLINE": "1",
    "TRANSFORMERS_OFFLINE": "1",
    "VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS": "1800",
}
for key, expected in required_environment.items():
    require(environment.get(key) == expected, f"has the wrong {key}")
if rank == "0":
    require(bool(environment.get("VLLM_API_KEY")), "lacks the rank-0 API key")
else:
    require(not environment.get("VLLM_API_KEY"), "received VLLM_API_KEY")
    require(not environment.get("DSPARK_API_KEYS"), "received DSPARK_API_KEYS")
labels = config.get("Labels") or {}
profile_label = labels.get("ai.webster.profile-sha256")
rank_label = labels.get("ai.webster.rank")
generation = labels.get("ai.webster.generation")
labels_present = tuple(
    isinstance(label, str) and bool(label)
    for label in (profile_label, rank_label, generation)
)
if any(labels_present):
    require(all(labels_present), "has partial serving labels")
    require(profile_label == profile_fingerprint, "has a mismatched profile fingerprint")
    require(rank_label == rank, "has a mismatched rank label")
print(
    json.dumps(
        {
            "container_id": data.get("Id"),
            "generation": generation,
            "started_at": state.get("StartedAt"),
        },
        separators=(",", ":"),
    )
)
PY
)" || die "$node existing DeepSeek generation validation failed"
  printf '%s\n' "$state"
}

validate_deepseek_pair_generation() {
  "$script_dir/verify-serving-pair.py" \
    --rank0-state-json "$1" \
    --rank1-state-json "$2" \
    --max-start-skew-seconds 120 >/dev/null
}

if [[ "$existing_shamu" == true && "$existing_tilikum" == true ]]; then
  if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
    require_eq "existing authenticated API" 1 "${TEST_LIFECYCLE_AUTH_OK:-1}"
    require_eq "existing listener isolation" 1 "${TEST_LIFECYCLE_LISTENERS_OK:-1}"
    require_eq "existing rank 1 keyless" 1 "${TEST_LIFECYCLE_RANK1_KEYLESS:-1}"
    require_eq "existing NCCL rail" 1 "${TEST_LIFECYCLE_NCCL_OK:-1}"
    require_eq "existing DeepSeek image" 1 \
      "${TEST_LIFECYCLE_DEEPSEEK_IMAGE_MATCH:-1}"
    require_eq "existing DeepSeek profile" 1 \
      "${TEST_LIFECYCLE_DEEPSEEK_PROFILE_MATCH:-1}"
    require_eq "existing DeepSeek runtime shape" 1 \
      "${TEST_LIFECYCLE_DEEPSEEK_RUNTIME_MATCH:-1}"
    require_eq "existing DeepSeek restart state" 1 \
      "${TEST_LIFECYCLE_DEEPSEEK_RESTARTS_OK:-1}"
    require_eq "existing DeepSeek pair generation" 1 \
      "${TEST_LIFECYCLE_DEEPSEEK_GENERATION_MATCH:-1}"
  else
    shamu_generation="$(validate_live_deepseek_rank \
      shamu direct 0 "$expected_rank0_cmd" "$SHAMU_RAIL")"
    tilikum_generation="$(validate_live_deepseek_rank \
      tilikum sudo 1 "$expected_rank1_cmd" "$TILIKUM_RAIL")"
    validate_deepseek_pair_generation "$shamu_generation" "$tilikum_generation"
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
if [[ "$verify_only" == 1 ]]; then
  die "DeepSeek pair is not already healthy for the requested profile"
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
  ssh shamu "env -u SSH_AUTH_SOCK ssh -o ForwardAgent=no -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new alecfong@$TILIKUM_RAIL true" ||
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

event start-deepseek-v41 START "profile $profile_name TP2/PP1 canary"
if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
  test_lifecycle_gate
else
  live_lifecycle_gate
fi

generation_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
generation_labels="--label ai.webster.profile-sha256=$profile_fingerprint --label ai.webster.generation=$generation_id"
# Preserve any stopped or failed generation before docker rm can discard its
# inspect metadata or logs.  capture() redacts credential-shaped environment
# fields and assigns a unique mode-0600 evidence path on every attempt.
capture deepseek-v41-shamu-prior-generation ssh shamu \
  "docker inspect '$DEEPSEEK_CONTAINER' 2>&1 || true; docker logs --tail 1000 '$DEEPSEEK_CONTAINER' 2>&1 || true"
capture deepseek-v41-tilikum-prior-generation ssh tilikum \
  "sudo -n docker inspect '$DEEPSEEK_CONTAINER' 2>&1 || true; sudo -n docker logs --tail 1000 '$DEEPSEEK_CONTAINER' 2>&1 || true"
shamu_launch="docker rm -f $DEEPSEEK_CONTAINER >/dev/null 2>&1 || true; docker run -d --name $DEEPSEEK_CONTAINER $docker_args $generation_labels --label ai.webster.rank=0 -e VLLM_HOST_IP=$SHAMU_RAIL --env-file $DEEPSEEK_API_ENV_FILE $image_id $common_args --node-rank 0 --host $SHAMU_NETBIRD --port $CANARY_PORT"
tilikum_launch="sudo -n docker rm -f $DEEPSEEK_CONTAINER >/dev/null 2>&1 || true; sudo -n env -u VLLM_API_KEY -u DSPARK_API_KEYS docker run -d --name $DEEPSEEK_CONTAINER $docker_args $generation_labels --label ai.webster.rank=1 -e VLLM_HOST_IP=$TILIKUM_RAIL $image_id $common_args --node-rank 1 --headless"

if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
  {
    printf 'deepseek-profile %s --tensor-parallel-size 2 --pipeline-parallel-size 1 ' "$profile_name"
    printf '%s ' '--engram-config' '{"cpu_offload":true,"embedding_across_dp":false}'
    printf '%s --host %s --port %s\n' "$common_args" "$SHAMU_NETBIRD" "$CANARY_PORT"
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
  event start-deepseek-v41 GO \
    "profile $profile_name authenticated; rank 1 headless/keyless; NCCL HCA pinned"
  printf 'DeepSeek V4.1 profile %s TP2/PP1 canary validated\n' "$profile_name"
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
wrong_key_header="$(printf 'Authorization: %s %s' Bearer invalid-canary-key)"
require_eq "wrong-key OpenAI status" 401 \
  "$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' -H "$wrong_key_header" "http://$SHAMU_NETBIRD:$CANARY_PORT/v1/models")"
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
event start-deepseek-v41 GO \
  "profile $profile_name authenticated; rank 1 headless/keyless; NCCL HCA pinned"
printf 'DeepSeek V4.1 profile %s TP2/PP1 canary validated\n' "$profile_name"
