#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

phase=""
run_root=""
while (($#)); do
  case "$1" in
    --phase)
      [[ $# -ge 2 ]] || die "--phase requires a value"
      phase="$2"
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

validate_phase "$phase"
validated_root="$(validate_run_root "$run_root")"

test_mode_checks() {
  if [[ "$phase" == "stage" ]]; then
    require_ge "free bytes before staging" "$MIN_FREE_BEFORE_STAGE_BYTES" \
      "${TEST_FREE_BYTES:-$MIN_FREE_BEFORE_STAGE_BYTES}"
  fi
  [[ -z "${TEST_MISSING_TOPOLOGY:-}" ]] ||
    die "missing required topology: $TEST_MISSING_TOPOLOGY"
  local mode="${TEST_CREDENTIAL_MODE:-0600}"
  mode="${mode#0}"
  require_eq "credential mode" "600" "$mode"
  local inspect_path="${TEST_LITELLM_INSPECT:?TEST_LITELLM_INSPECT is required}"
  "$script_dir/verify-litellm-container.py" "$inspect_path" >/dev/null
  require_eq "current model probe status" "ok" \
    "${TEST_CURRENT_MODEL_PROBE_STATUS:-ok}"
  ssh shamu preflight-test >/dev/null
  ssh tilikum preflight-test >/dev/null
}

if [[ "${WEBSTER_PREFLIGHT_TEST_MODE:-0}" == "1" ]]; then
  test_mode_checks
  exit 0
fi

init_run_root "$validated_root"
write_summary_header "$phase"
event "$phase" START "read-only preflight"

inspect_path="$RUN_ROOT/baseline/litellm.inspect.redacted.json"
inspect_temporary="$inspect_path.tmp.$$"
ssh spark-1 'docker inspect litellm' |
  python3 -c 'import json,sys; data=json.load(sys.stdin); data[0].get("Config", {})["Env"]=["REDACTED"]; json.dump(data,sys.stdout); print()' \
    >"$inspect_temporary"
chmod 0600 "$inspect_temporary"
mv -- "$inspect_temporary" "$inspect_path"
capture litellm-container-verify "$script_dir/verify-litellm-container.py" "$inspect_path"

capture git-state bash -c \
  'git rev-parse HEAD; git status --short --branch; sha256sum docs/superpowers/specs/2026-09-11-glm52-to-deepseek-v41-cutover-design.md'
capture brev-instances brev ls
capture brev-nodes brev ls nodes

capture shamu-host ssh shamu \
  'set -eu; hostname; date -u +%Y-%m-%dT%H:%M:%SZ; uptime; uname -a; nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used --format=csv,noheader; free -b; df -PB1 /home/alecfong; ip -o addr show; cat /sys/class/infiniband/mlx5_1/ports/1/state; docker inspect glm52-full-mtp --format "id={{.Id}} image={{.Image}} started={{.State.StartedAt}} restarts={{.RestartCount}} running={{.State.Running}} args={{json .Args}}"; ss -lntp'
capture tilikum-host ssh tilikum \
  'set -eu; hostname; date -u +%Y-%m-%dT%H:%M:%SZ; uptime; uname -a; nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used --format=csv,noheader; free -b; df -PB1 /home/alecfong; ip -o addr show; cat /sys/class/infiniband/mlx5_1/ports/1/state; sudo -n docker inspect glm52-full-mtp --format "id={{.Id}} image={{.Image}} started={{.State.StartedAt}} restarts={{.RestartCount}} running={{.State.Running}} args={{json .Args}}"; ss -lntp'

shamu_free="$(ssh shamu "df -PB1 /home/alecfong | awk 'NR==2 {print \\$4}'")"
tilikum_free="$(ssh tilikum "df -PB1 /home/alecfong | awk 'NR==2 {print \\$4}'")"
if [[ "$phase" == "stage" ]]; then
  require_ge "Shamu free bytes before staging" "$MIN_FREE_BEFORE_STAGE_BYTES" "$shamu_free"
  require_ge "Tilikum free bytes before staging" "$MIN_FREE_BEFORE_STAGE_BYTES" "$tilikum_free"
fi

for node in shamu tilikum; do
  rail="$SHAMU_RAIL"
  [[ "$node" == "tilikum" ]] && rail="$TILIKUM_RAIL"
  ssh "$node" "ip link show '$NCCL_IFACE' >/dev/null; ip addr show dev '$NCCL_IFACE' | grep -F '$rail/' >/dev/null; grep -q ACTIVE /sys/class/infiniband/'$NCCL_HCA'/ports/1/state" ||
    die "$node station rail/HCA validation failed"
done
capture rail-ping-shamu ssh shamu "ping -c 3 -W 2 -I '$NCCL_IFACE' '$TILIKUM_RAIL'"
capture rail-ping-tilikum ssh tilikum "ping -c 3 -W 2 -I '$NCCL_IFACE' '$SHAMU_RAIL'"

shamu_running="$(ssh shamu "docker inspect glm52-full-mtp --format '{{.State.Running}}'")"
tilikum_running="$(ssh tilikum "sudo -n docker inspect glm52-full-mtp --format '{{.State.Running}}'")"
if [[ "$phase" == "canary" ]]; then
  require_eq "Shamu GLM stopped" "false" "$shamu_running"
  require_eq "Tilikum GLM stopped" "false" "$tilikum_running"
else
  require_eq "Shamu GLM running" "true" "$shamu_running"
  require_eq "Tilikum GLM running" "true" "$tilikum_running"
  ssh shamu "curl -fsS --max-time 5 http://$SHAMU_NETBIRD:$CANARY_PORT/health >/dev/null" ||
    die "GLM rank 0 health check failed"
  ssh tilikum "sudo -n docker inspect glm52-full-mtp --format '{{json .Args}}' | grep -q -- --headless" ||
    die "GLM rank 1 is not headless"
fi

require_file_mode_600 shamu /home/alecfong/.config/glm52/vllm-api-key
require_file_mode_600 spark-1 /home/nvidia/litellm/config.yaml

capture litellm-shape ssh spark-1 \
  'docker inspect litellm --format "id={{.Id}} image={{.Image}} started={{.State.StartedAt}} restarts={{.RestartCount}} running={{.State.Running}} network={{.HostConfig.NetworkMode}} entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}} ports={{json .HostConfig.PortBindings}}"; ss -lntp | grep 4446'
capture litellm-config ssh spark-1 \
  'python3 - <<'"'"'PY'"'"'
import json
from pathlib import Path
import yaml
path = Path("/home/nvidia/litellm/config.yaml")
data = yaml.safe_load(path.read_text())
models = []
for item in data.get("model_list", []):
    info = item.get("model_info", {})
    params = item.get("litellm_params", {})
    models.append({
        "model_name": item.get("model_name"),
        "model": params.get("model"),
        "api_base": params.get("api_base"),
        "max_input_tokens": info.get("max_input_tokens"),
        "max_output_tokens": info.get("max_output_tokens"),
    })
print(json.dumps({
    "callbacks": data.get("litellm_settings", {}).get("callbacks", []),
    "plugins": data.get("router_settings", {}).get("plugins", []),
    "models": models,
}, sort_keys=True))
PY'

root_status="$(ssh spark-1 "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:4444/")"
models_status="$(ssh spark-1 "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:4444/v1/models")"
require_eq "Caddy root status" "403" "$root_status"
require_eq "unauthenticated model-list status" "401" "$models_status"

capture current-model-probes ssh spark-1 python3 - "$(basename "$RUN_ROOT")" <<'PY'
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import yaml

change_id = sys.argv[1]
environment = subprocess.check_output(
    [
        "docker",
        "inspect",
        "litellm",
        "--format",
        "{{range .Config.Env}}{{println .}}{{end}}",
    ],
    text=True,
).splitlines()
master = next(
    line.split("=", 1)[1]
    for line in environment
    if line.startswith("LITELLM_MASTER_KEY=")
)
config = yaml.safe_load(Path("/home/nvidia/litellm/config.yaml").read_text())
models = list(dict.fromkeys(item["model_name"] for item in config["model_list"]))


def post(url, body, key, timeout):
    request = urllib.request.Request(
        url,
        data=json.dumps(body, separators=(",", ":")).encode(),
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status, json.load(response)


virtual = None
results = []
try:
    _, created = post(
        "http://127.0.0.1:4446/key/generate",
        {
            "key_alias": f"baseline-{change_id}",
            "models": models,
            "max_budget": 0.5,
            "budget_duration": "1d",
        },
        master,
        30,
    )
    virtual = created["key"]
    for model in models:
        started = time.monotonic()
        status, payload = post(
            "http://127.0.0.1:4444/v1/chat/completions",
            {
                "model": model,
                "messages": [{"role": "user", "content": "Reply OK."}],
                "max_tokens": 8,
            },
            virtual,
            180,
        )
        choices = payload.get("choices")
        if status != 200 or not isinstance(choices, list) or not choices:
            raise RuntimeError(f"completion probe failed for {model}")
        results.append(
            {
                "model": model,
                "status": status,
                "response_model": payload.get("model"),
                "elapsed_seconds": round(time.monotonic() - started, 6),
            }
        )
finally:
    if virtual is not None:
        post(
            "http://127.0.0.1:4446/key/delete",
            {"keys": [virtual]},
            master,
            30,
        )
print(json.dumps({"models": results, "key_revoked": True}, sort_keys=True))
PY

capture prometheus-targets curl -fsS --max-time 10 \
  "http://$SHAMU_NETBIRD:9095/api/v1/targets?state=active"
capture langfuse-health curl -fsS --max-time 10 \
  "http://$SHAMU_NETBIRD:3000/api/public/health"

if [[ "$phase" == "publish" ]]; then
  [[ -f "$RUN_ROOT/private-acceptance.json" ]] ||
    die "publish phase requires private-acceptance.json"
fi

event "$phase" GO "all read-only preflight requirements passed"
printf 'GO phase=%s run_root=%s\n' "$phase" "$RUN_ROOT"
