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

station_free_bytes() {
  local node="$1" value
  value="$(ssh "$node" df -PB1 /home/alecfong | awk 'NR == 2 {print $4}')"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$node free-space query returned a non-integer"
  printf '%s\n' "$value"
}

validate_station_owner_state() {
  local checked_phase="$1" glm_shamu="$2" glm_tilikum="$3"
  local deepseek_shamu="$4" deepseek_tilikum="$5"
  case "$checked_phase" in
    baseline|stage|alias)
      require_eq "Shamu GLM running" "true" "$glm_shamu"
      require_eq "Tilikum GLM running" "true" "$glm_tilikum"
      require_eq "Shamu DeepSeek stopped" "false" "$deepseek_shamu"
      require_eq "Tilikum DeepSeek stopped" "false" "$deepseek_tilikum"
      ;;
    canary)
      require_eq "Shamu GLM stopped" "false" "$glm_shamu"
      require_eq "Tilikum GLM stopped" "false" "$glm_tilikum"
      require_eq "Shamu DeepSeek stopped" "false" "$deepseek_shamu"
      require_eq "Tilikum DeepSeek stopped" "false" "$deepseek_tilikum"
      ;;
    publish)
      require_eq "Shamu GLM stopped" "false" "$glm_shamu"
      require_eq "Tilikum GLM stopped" "false" "$glm_tilikum"
      require_eq "Shamu DeepSeek running" "true" "$deepseek_shamu"
      require_eq "Tilikum DeepSeek running" "true" "$deepseek_tilikum"
      ;;
  esac
}

validate_publish_acceptance() {
  [[ "$phase" == "publish" ]] || return 0
  local verifier="$script_dir/verify-private-acceptance.py"
  if [[ "${WEBSTER_PREFLIGHT_TEST_MODE:-0}" == "1" &&
    -n "${TEST_PRIVATE_ACCEPTANCE_VERIFIER:-}" ]]; then
    verifier="$TEST_PRIVATE_ACCEPTANCE_VERIFIER"
  fi
  [[ -f "$validated_root/private-acceptance.json" ]] ||
    die "publish phase requires private-acceptance.json"
  "$verifier" \
    --run-root "$validated_root" \
    --acceptance "$validated_root/private-acceptance.json" \
    --max-age-seconds 21600
}

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
  local glm_default=true deepseek_default=false
  if [[ "$phase" == "canary" || "$phase" == "publish" ]]; then
    glm_default=false
  fi
  if [[ "$phase" == "publish" ]]; then
    deepseek_default=true
  fi
  validate_station_owner_state "$phase" \
    "${TEST_PREFLIGHT_GLM_SHAMU_RUNNING:-$glm_default}" \
    "${TEST_PREFLIGHT_GLM_TILIKUM_RUNNING:-$glm_default}" \
    "${TEST_PREFLIGHT_DEEPSEEK_SHAMU_RUNNING:-$deepseek_default}" \
    "${TEST_PREFLIGHT_DEEPSEEK_TILIKUM_RUNNING:-$deepseek_default}"
  validate_publish_acceptance
  if [[ "${TEST_VALIDATE_STATION_FREE:-0}" == "1" ]]; then
    station_free_bytes shamu >/dev/null
    station_free_bytes tilikum >/dev/null
  fi
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

station_inspect_format='--format "id={{.Id}} image={{.Image}} started={{.State.StartedAt}} restarts={{.RestartCount}} running={{.State.Running}} args={{json .Args}}"'
station_inspect_shamu="docker inspect '$GLM_CONTAINER'"
station_inspect_tilikum="sudo -n docker inspect '$GLM_CONTAINER'"
if [[ "$phase" == "publish" ]]; then
  station_inspect_shamu="docker inspect '$DEEPSEEK_CONTAINER'"
  station_inspect_tilikum="sudo -n docker inspect '$DEEPSEEK_CONTAINER'"
elif [[ "$phase" == "canary" ]]; then
  station_inspect_format=""
  station_inspect_shamu="docker ps -a --filter name='$GLM_CONTAINER' --filter name='$DEEPSEEK_CONTAINER' --format 'id={{.ID}} image={{.Image}} status={{.Status}} names={{.Names}}'"
  station_inspect_tilikum="sudo -n docker ps -a --filter name='$GLM_CONTAINER' --filter name='$DEEPSEEK_CONTAINER' --format 'id={{.ID}} image={{.Image}} status={{.Status}} names={{.Names}}'"
fi

capture shamu-host ssh shamu \
  "set -eu; hostname; date -u +%Y-%m-%dT%H:%M:%SZ; uptime; uname -a; nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used --format=csv,noheader; free -b; df -PB1 /home/alecfong; ip -o addr show; cat /sys/class/infiniband/mlx5_1/ports/1/state; $station_inspect_shamu $station_inspect_format; ss -lntp"
capture tilikum-host ssh tilikum \
  "set -eu; hostname; date -u +%Y-%m-%dT%H:%M:%SZ; uptime; uname -a; nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used --format=csv,noheader; free -b; df -PB1 /home/alecfong; ip -o addr show; cat /sys/class/infiniband/mlx5_1/ports/1/state; $station_inspect_tilikum $station_inspect_format; ss -lntp"

shamu_free="$(station_free_bytes shamu)"
tilikum_free="$(station_free_bytes tilikum)"
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

glm_shamu_running="$(ssh shamu "docker inspect glm52-full-mtp --format '{{.State.Running}}' 2>/dev/null || printf false")"
glm_tilikum_running="$(ssh tilikum "sudo -n docker inspect glm52-full-mtp --format '{{.State.Running}}' 2>/dev/null || printf false")"
deepseek_shamu_running="$(ssh shamu "docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false")"
deepseek_tilikum_running="$(ssh tilikum "sudo -n docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false")"
validate_station_owner_state "$phase" \
  "$glm_shamu_running" "$glm_tilikum_running" \
  "$deepseek_shamu_running" "$deepseek_tilikum_running"
if [[ "$phase" == "baseline" || "$phase" == "stage" || "$phase" == "alias" ]]; then
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

capture current-model-probes ssh spark-1 python3 - "$(basename "$RUN_ROOT")" \
  <"$script_dir/current-model-probes.py"

capture prometheus-targets curl -fsS --max-time 10 \
  "http://$SHAMU_NETBIRD:9095/api/v1/targets?state=active"
capture langfuse-health curl -fsS --max-time 10 \
  "http://$SHAMU_NETBIRD:3000/api/public/health"

validate_publish_acceptance

event "$phase" GO "all read-only preflight requirements passed"
printf 'GO phase=%s run_root=%s\n' "$phase" "$RUN_ROOT"
