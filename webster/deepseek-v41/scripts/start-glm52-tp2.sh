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

validate_live_glm_rank() {
  local node="$1" docker_mode="$2" rank="$3" host_ip="$4" state
  state="$(ssh "$node" python3 - "$docker_mode" "$GLM_CONTAINER" "$rank" \
    "$host_ip" "$SHAMU_RAIL" "$CANARY_PORT" <<'PY'
import json
import shlex
import subprocess
import sys

docker_mode, container, rank, host_ip, master_addr, port = sys.argv[1:]
docker = ["docker"] if docker_mode == "direct" else ["sudo", "-n", "docker"]
try:
    data = json.loads(
        subprocess.check_output(docker + ["inspect", container], text=True)
    )[0]
except (subprocess.CalledProcessError, json.JSONDecodeError, IndexError) as error:
    raise SystemExit(f"cannot inspect existing GLM rank {rank}: {error}")

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"existing GLM rank {rank} {message}")

config = data.get("Config") or {}
host = data.get("HostConfig") or {}
runtime = data.get("State") or {}
require(runtime.get("Running") is True, "is not running")
require(data.get("RestartCount") == 0, "has a nonzero restart count")
require(config.get("Entrypoint") == ["bash"], "has the wrong entrypoint")
command = config.get("Cmd")
require(
    isinstance(command, list) and len(command) == 2 and command[0] == "-lc",
    "has the wrong container command",
)
serve_lines = [
    line.strip()
    for line in command[1].splitlines()
    if line.strip().startswith("exec vllm serve ")
]
require(len(serve_lines) == 1, "does not contain one vLLM serve command")
tokens = shlex.split(serve_lines[0])
require(tokens[:4] == ["exec", "vllm", "serve", "/model"], "has the wrong serve prefix")
value_flags = {
    "--served-model-name",
    "--host",
    "--port",
    "--nnodes",
    "--node-rank",
    "--master-addr",
    "--master-port",
    "--tensor-parallel-size",
    "--speculative-config",
    "--max-model-len",
    "--block-size",
    "--max-num-seqs",
    "--kv-cache-dtype",
    "--gpu-memory-utilization",
    "--cpu-offload-gb",
    "--kernel-config",
    "--compilation-config",
    "--tool-call-parser",
    "--reasoning-parser",
}
boolean_flags = {
    "--trust-remote-code",
    "--disable-custom-all-reduce",
    "--enable-prefix-caching",
    "--enable-auto-tool-choice",
    "--headless",
}
values = {}
flags = set()
index = 4
while index < len(tokens):
    token = tokens[index]
    require(token not in values and token not in flags, f"duplicates {token}")
    if token in value_flags:
        require(index + 1 < len(tokens), f"omits the value for {token}")
        values[token] = tokens[index + 1]
        index += 2
    elif token in boolean_flags:
        flags.add(token)
        index += 1
    else:
        require(False, f"uses unexpected serve argument {token}")
expected_values = {
    "--served-model-name": "nvidia/GLM-5.2-NVFP4",
    "--host": host_ip,
    "--port": port,
    "--nnodes": "2",
    "--node-rank": rank,
    "--master-addr": master_addr,
    "--master-port": "29501",
    "--tensor-parallel-size": "2",
    "--max-model-len": "320000",
    "--block-size": "128",
    "--max-num-seqs": "8",
    "--kv-cache-dtype": "fp8",
    "--gpu-memory-utilization": "0.97",
    "--cpu-offload-gb": "0",
    "--tool-call-parser": "glm47",
    "--reasoning-parser": "glm47",
}
for name, expected in expected_values.items():
    require(values.get(name) == expected, f"has the wrong {name}")
require(set(values) == value_flags, "does not match the complete requested profile")
required_flags = boolean_flags - {"--headless"}
require(required_flags.issubset(flags), "omits a required serve flag")
require(("--headless" in flags) == (rank == "1"), "has the wrong headless role")
try:
    speculative = json.loads(values["--speculative-config"])
    kernel = json.loads(values["--kernel-config"])
    compilation = json.loads(values["--compilation-config"])
except json.JSONDecodeError as error:
    raise SystemExit(f"existing GLM rank {rank} has malformed JSON config: {error}")
require(
    speculative == {"method": "mtp", "num_speculative_tokens": 4},
    "has the wrong speculative profile",
)
require(
    kernel
    == {"enable_flashinfer_autotune": False, "moe_backend": "flashinfer_cutlass"},
    "has the wrong kernel profile",
)
require(
    compilation
    == {
        "cudagraph_mode": "FULL_DECODE_ONLY",
        "cudagraph_capture_sizes": [5, 10, 20, 40],
        "pass_config": {"fuse_allreduce_rms": False},
    },
    "has the wrong compilation profile",
)
require(host.get("NetworkMode") == "host", "is not on host networking")
require(host.get("IpcMode") == "host", "does not use host IPC")
require(config.get("WorkingDir") == "/vllm-workspace", "has the wrong working directory")
require(host.get("ShmSize") == 34359738368, "has the wrong shared-memory size")
require((host.get("RestartPolicy") or {}).get("Name") == "unless-stopped", "has the wrong restart policy")
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
require(
    any(
        item.get("PathOnHost") == "/dev/infiniband"
        for item in (host.get("Devices") or [])
    ),
    "lacks the InfiniBand device",
)
require(bool(host.get("DeviceRequests")), "lacks a GPU device request")
mounts = {item.get("Destination"): item for item in (data.get("Mounts") or [])}
require(
    (mounts.get("/model") or {}).get("Source")
    == "/home/alecfong/glm52/models/GLM-5.2-NVFP4-full"
    and (mounts.get("/model") or {}).get("RW") is False,
    "does not use the exact read-only checkpoint",
)
require(
    (mounts.get("/root/.cache") or {}).get("Source")
    == "/home/alecfong/glm52/exo-repro/cache"
    and (mounts.get("/root/.cache") or {}).get("RW") is True,
    "does not use the exact cache mount",
)
environment = {}
for item in config.get("Env") or []:
    if "=" in item:
        key, value = item.split("=", 1)
        environment[key] = value
require(environment.get("VLLM_HOST_IP") == host_ip, "has the wrong VLLM_HOST_IP")
if rank == "0":
    require(bool(environment.get("VLLM_API_KEY")), "lacks the rank-0 API key")
else:
    require(not environment.get("VLLM_API_KEY"), "received VLLM_API_KEY")
    require(not environment.get("DSPARK_API_KEYS"), "received DSPARK_API_KEYS")
print(
    json.dumps(
        {"image": data.get("Image"), "started_at": runtime.get("StartedAt")},
        separators=(",", ":"),
    )
)
PY
)" || die "$node existing GLM generation validation failed"
  printf '%s\n' "$state"
}

validate_glm_pair_generation() {
  "$script_dir/verify-serving-pair.py" \
    --rank0-state-json "$1" \
    --rank1-state-json "$2" \
    --max-start-skew-seconds 120 \
    --require-matching-image >/dev/null
}

if [[ "$existing_shamu" == true && "$existing_tilikum" == true ]]; then
  if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
    require_eq "existing GLM authenticated health" 1 "${TEST_LIFECYCLE_AUTH_OK:-1}"
    require_eq "existing GLM listener isolation" 1 "${TEST_LIFECYCLE_LISTENERS_OK:-1}"
    require_eq "existing GLM rank 1 keyless" 1 "${TEST_LIFECYCLE_RANK1_KEYLESS:-1}"
    require_eq "existing GLM image" 1 "${TEST_LIFECYCLE_GLM_IMAGE_MATCH:-1}"
    require_eq "existing GLM profile" 1 "${TEST_LIFECYCLE_GLM_PROFILE_MATCH:-1}"
    require_eq "existing GLM runtime shape" 1 \
      "${TEST_LIFECYCLE_GLM_RUNTIME_MATCH:-1}"
    require_eq "existing GLM restart state" 1 \
      "${TEST_LIFECYCLE_GLM_RESTARTS_OK:-1}"
    require_eq "existing GLM pair generation" 1 \
      "${TEST_LIFECYCLE_GLM_GENERATION_MATCH:-1}"
  else
    shamu_generation="$(validate_live_glm_rank \
      shamu direct 0 "$SHAMU_NETBIRD")"
    tilikum_generation="$(validate_live_glm_rank \
      tilikum sudo 1 "$TILIKUM_NETBIRD")"
    validate_glm_pair_generation "$shamu_generation" "$tilikum_generation"
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
