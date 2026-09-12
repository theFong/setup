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
[[ ! -e "$RUN_ROOT/watchdog.disabled" ]] || exit 0

healthy=1
reason=()
if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
  shamu_running="${TEST_LIFECYCLE_DEEPSEEK_SHAMU_RUNNING:-false}"
  tilikum_running="${TEST_LIFECYCLE_DEEPSEEK_TILIKUM_RUNNING:-false}"
  [[ "$shamu_running" == true && "$tilikum_running" == true ]] || {
    healthy=0
    reason+=("rank-state-skew")
  }
  for pair in \
    "${TEST_LIFECYCLE_AUTH_OK:-1}:direct-health" \
    "${TEST_LIFECYCLE_LISTENERS_OK:-1}:listeners" \
    "${TEST_LIFECYCLE_RANK1_KEYLESS:-1}:rank1-key" \
    "${TEST_LIFECYCLE_NCCL_OK:-1}:nccl"; do
    [[ "${pair%%:*}" == 1 ]] || {
      healthy=0
      reason+=("${pair#*:}")
    }
  done
else
  shamu_running="$(ssh shamu "docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false")"
  tilikum_running="$(ssh tilikum "sudo -n docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.Running}}' 2>/dev/null || printf false")"
  shamu_started="$(ssh shamu "docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.StartedAt}}' 2>/dev/null" || true)"
  tilikum_started="$(ssh tilikum "sudo -n docker inspect '$DEEPSEEK_CONTAINER' --format '{{.State.StartedAt}}' 2>/dev/null" || true)"
  [[ "$shamu_running" == true && "$tilikum_running" == true ]] || {
    healthy=0
    reason+=("rank-state-skew")
  }
  if [[ -n "$shamu_started" && -n "$tilikum_started" ]]; then
    shamu_started_epoch="$(date -d "$shamu_started" +%s)" || die "invalid Shamu container start time"
    tilikum_started_epoch="$(date -d "$tilikum_started" +%s)" || die "invalid Tilikum container start time"
    start_skew=$((shamu_started_epoch - tilikum_started_epoch))
    (( start_skew < 0 )) && start_skew=$((-start_skew))
    if (( start_skew > 300 )); then
      healthy=0
      reason+=("rank-start-time-skew")
    fi
  fi
  curl -fsS --connect-timeout 3 --max-time 5 "http://$SHAMU_NETBIRD:$CANARY_PORT/health" >/dev/null || {
    healthy=0
    reason+=("direct-health")
  }
  shamu_listener="$(ssh shamu "ss -lntH '( sport = :$CANARY_PORT )' | awk '{print \$4}'" || true)"
  tilikum_listener="$(ssh tilikum "ss -lntH '( sport = :$CANARY_PORT )'" || true)"
  [[ "$shamu_listener" == "$SHAMU_NETBIRD:$CANARY_PORT" && -z "$tilikum_listener" ]] || {
    healthy=0
    reason+=("listeners")
  }
  ssh tilikum "sudo -n docker inspect '$DEEPSEEK_CONTAINER' --format '{{json .Args}}' | grep -q -- --headless" || {
    healthy=0
    reason+=("rank1-not-headless")
  }
  ssh tilikum "sudo -n docker inspect '$DEEPSEEK_CONTAINER' --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -Eq '^(VLLM_API_KEY|DSPARK_API_KEYS)=.+'" && {
    healthy=0
    reason+=("rank1-key-present")
  }
  if ssh shamu "docker logs --since 10m '$DEEPSEEK_CONTAINER' 2>&1 | grep -Eq 'EngineDeadError|NCCL.*(timeout|error)|RPC call.*timed out'" ||
    ssh tilikum "sudo -n docker logs --since 10m '$DEEPSEEK_CONTAINER' 2>&1 | grep -Eq 'EngineDeadError|NCCL.*(timeout|error)|RPC call.*timed out'"; then
    healthy=0
    reason+=("engine-or-nccl-error")
  fi
fi

if (( healthy )); then
  event deepseek-v41-watchdog OK "two-rank canary healthy"
  exit 0
fi

reason_text="${reason[*]}"
event deepseek-v41-watchdog BREACH "$reason_text"

now="$(date +%s)"
startup_age=""
if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" == "1" ]]; then
  startup_age="${TEST_LIFECYCLE_START_AGE_SECONDS:-1200}"
else
  for started in "${shamu_started:-}" "${tilikum_started:-}"; do
    [[ -n "$started" ]] || continue
    started_epoch="$(date -d "$started" +%s)" || die "invalid container start time"
    candidate_age=$((now - started_epoch))
    if [[ -z "$startup_age" || candidate_age -lt startup_age ]]; then
      startup_age="$candidate_age"
    fi
  done
fi
if [[ -n "$startup_age" ]]; then
  [[ "$startup_age" =~ ^[0-9]+$ ]] || die "invalid startup age"
  if (( startup_age < 1200 )); then
    event deepseek-v41-watchdog DEFER "breach inside 20-minute startup grace"
    exit 0
  fi
fi
if [[ "${TEST_WATCHDOG_NO_RECOVERY:-0}" == 1 ]]; then
  die "watchdog breach: $reason_text"
fi

state_file="$RUN_ROOT/watchdog.last-recovery"
if [[ -f "$state_file" ]]; then
  last="$(<"$state_file")"
  [[ "$last" =~ ^[0-9]+$ ]] || die "invalid watchdog cooldown state"
  if (( now - last < 1800 )); then
    event deepseek-v41-watchdog DEFER "breach inside 30-minute recovery cooldown"
    exit 0
  fi
fi

if [[ "${WEBSTER_LIFECYCLE_TEST_MODE:-0}" != "1" ]]; then
  capture deepseek-v41-watchdog-shamu ssh shamu \
    "docker inspect '$DEEPSEEK_CONTAINER' 2>&1 || true; docker logs --tail 500 '$DEEPSEEK_CONTAINER' 2>&1 || true; nvidia-smi"
  capture deepseek-v41-watchdog-tilikum ssh tilikum \
    "sudo -n docker inspect '$DEEPSEEK_CONTAINER' 2>&1 || true; sudo -n docker logs --tail 500 '$DEEPSEEK_CONTAINER' 2>&1 || true; nvidia-smi"
fi
printf '%s\n' "$now" >"$state_file"
chmod 0600 "$state_file"
"$script_dir/stop-deepseek-v41-tp2.sh" --run-root "$RUN_ROOT"
"$script_dir/start-deepseek-v41-tp2.sh" --run-root "$RUN_ROOT"
event deepseek-v41-watchdog RECOVERED "coordinated stop/start completed"
