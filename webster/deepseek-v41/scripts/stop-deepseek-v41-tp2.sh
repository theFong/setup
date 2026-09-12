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

stop_rank() {
  local node="$1" status=0 exists
  if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" != "1" ]]; then
    if [[ "$node" == "shamu" ]]; then
      exists="$(ssh shamu "docker inspect '$DEEPSEEK_CONTAINER' --format '{{.Id}}' 2>/dev/null" || true)"
    else
      exists="$(ssh tilikum "sudo -n docker inspect '$DEEPSEEK_CONTAINER' --format '{{.Id}}' 2>/dev/null" || true)"
    fi
    [[ -n "$exists" ]] || return 0
  fi
  if [[ "$node" == "shamu" ]]; then
    ssh shamu docker stop --time 120 "$DEEPSEEK_CONTAINER" >/dev/null || status=$?
  else
    ssh tilikum sudo -n docker stop --time 120 "$DEEPSEEK_CONTAINER" >/dev/null || status=$?
  fi
  if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" &&
    "${TEST_LIFECYCLE_STOP_FAIL_NODE:-}" == "$node" ]]; then
    return 9
  fi
  return "$status"
}

container_running() {
  local node="$1"
  if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
    if [[ "$node" == "shamu" ]]; then
      printf '%s\n' "${TEST_LIFECYCLE_DEEPSEEK_SHAMU_RUNNING:-false}"
    else
      printf '%s\n' "${TEST_LIFECYCLE_DEEPSEEK_TILIKUM_RUNNING:-false}"
    fi
    return
  fi
  if [[ "$node" == "shamu" ]]; then
    ssh shamu "docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false"
  else
    ssh tilikum "sudo -n docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false"
  fi
}

event stop-deepseek-v41 START "coordinated two-rank stop"
if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" != "1" ]]; then
  capture deepseek-v41-shamu-prestop ssh shamu \
    "if docker inspect '$DEEPSEEK_CONTAINER' >/dev/null 2>&1; then docker inspect '$DEEPSEEK_CONTAINER'; docker logs --tail 400 '$DEEPSEEK_CONTAINER'; fi"
  capture deepseek-v41-tilikum-prestop ssh tilikum \
    "if sudo -n docker inspect '$DEEPSEEK_CONTAINER' >/dev/null 2>&1; then sudo -n docker inspect '$DEEPSEEK_CONTAINER'; sudo -n docker logs --tail 400 '$DEEPSEEK_CONTAINER'; fi"
fi

set +e
stop_rank shamu & shamu_pid=$!
stop_rank tilikum & tilikum_pid=$!
wait "$shamu_pid"; shamu_status=$?
wait "$tilikum_pid"; tilikum_status=$?
set -e
if (( shamu_status != 0 || tilikum_status != 0 )); then
  set +e
  stop_rank shamu
  stop_rank tilikum
  set -e
  event stop-deepseek-v41 NO-GO "at least one rank stop failed; both stops retried"
  die "coordinated DeepSeek stop failed; both ranks received a retry"
fi

require_eq "Shamu DeepSeek stopped" false "$(container_running shamu)"
require_eq "Tilikum DeepSeek stopped" false "$(container_running tilikum)"
if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
  require_eq "station listeners released" 1 "${TEST_LIFECYCLE_LISTENERS_OK:-1}"
else
  for node in shamu tilikum; do
    ssh "$node" "test -z \"\$(ss -lntH '( sport = :$CANARY_PORT )')\"" ||
      die "$node still has a port-$CANARY_PORT listener"
    ssh "$node" "test -z \"\$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)\"" ||
      die "$node GPU still has a compute process"
  done
fi
event stop-deepseek-v41 GO "both ranks stopped; GPUs and port released"
printf 'DeepSeek V4.1 TP2 ranks stopped\n'
