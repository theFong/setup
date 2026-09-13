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

case "$phase" in alias|publish) ;; *) die "phase must be alias or publish" ;; esac
validated_root="$(validate_run_root "$run_root")"
init_run_root "$validated_root"
rollback_file="$validated_root/rollback.env"
[[ -f "$rollback_file" && ! -L "$rollback_file" ]] || die "rollback.env is missing"
[[ "$(stat -c %a "$rollback_file")" == "600" ]] || die "rollback.env mode must be 0600"

declare -A rollback
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  case "$key" in
    ALIAS_CONFIG_BACKUP|ALIAS_CONFIG_SHA256|PUBLISH_CONFIG_BACKUP|PUBLISH_CONFIG_SHA256)
      rollback["$key"]="$value"
      ;;
    *) die "unknown rollback.env field: $key" ;;
  esac
done <"$rollback_file"

prefix="${phase^^}"
backup_path="${rollback[${prefix}_CONFIG_BACKUP]:-}"
expected_hash="${rollback[${prefix}_CONFIG_SHA256]:-}"
[[ "$backup_path" == /home/nvidia/litellm/* && "$backup_path" != *'/../'* ]] ||
  die "rollback backup path must remain under /home/nvidia/litellm"
[[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || die "rollback SHA-256 is invalid"

if [[ "${WEBSTER_LITELLM_TEST_MODE:-0}" == "1" ]]; then
  test_root="${TEST_LITELLM_ROOT:?TEST_LITELLM_ROOT is required in test mode}"
  mapped_backup="$test_root/${backup_path#/home/nvidia/litellm/}"
  live_config="$test_root/config.yaml"
  [[ -f "$mapped_backup" && ! -L "$mapped_backup" ]] || die "rollback backup is missing"
  [[ "$(stat -c %a "$mapped_backup")" == "600" ]] || die "rollback backup mode must be 0600"
  actual_hash="$(sha256sum "$mapped_backup" | awk '{print $1}')"
  require_eq "rollback backup SHA-256" "$expected_hash" "$actual_hash"
  if [[ ! -f "$live_config" ]] || ! cmp -s "$mapped_backup" "$live_config"; then
    install -m 0600 "$mapped_backup" "$live_config.tmp-$$"
    mv -- "$live_config.tmp-$$" "$live_config"
    docker restart litellm >/dev/null
  fi
  chmod 0600 "$live_config"
  [[ "$(stat -c %a "$live_config")" == "600" ]] ||
    die "restored config mode must be 0600"
  [[ "${TEST_RESTORE_HEALTH:-ok}" == "ok" ]] || die "test restore health failed"
  [[ "${TEST_RESTORE_READINESS:-ok}" == "ok" ]] ||
    die "test restore readiness failed"
  event "$phase-rollback" GO "hash-verified config restored and ingress checks passed"
  printf 'LiteLLM %s rollback validated in test mode\n' "$phase"
  exit 0
fi

remote_backup="$(ssh spark-1 "realpath -e -- '$backup_path'")" || die "rollback backup is missing"
[[ "$remote_backup" == /home/nvidia/litellm/* ]] || die "resolved rollback path escaped"
remote_mode="$(ssh spark-1 "stat -c %a -- '$remote_backup'")"
require_eq "rollback backup mode" "600" "$remote_mode"
actual_hash="$(ssh spark-1 "sha256sum -- '$remote_backup' | awk '{print \$1}'")"
require_eq "rollback backup SHA-256" "$expected_hash" "$actual_hash"
live_hash="$(ssh spark-1 "sha256sum /home/nvidia/litellm/config.yaml | awk '{print \$1}'")"
if [[ "$live_hash" != "$expected_hash" ]]; then
  ssh spark-1 "set -eu; install -m 0600 '$remote_backup' /home/nvidia/litellm/config.yaml.restore-$$; mv /home/nvidia/litellm/config.yaml.restore-$$ /home/nvidia/litellm/config.yaml; docker restart litellm >/dev/null"
  ready=0
  for _ in $(seq 1 60); do
    if ssh spark-1 "curl -fsS --max-time 2 http://127.0.0.1:4446/health/liveliness >/dev/null && curl -fsS --max-time 2 http://127.0.0.1:4446/health/readiness >/dev/null"; then
      ready=1
      break
    fi
    sleep 1
  done
  [[ "$ready" == "1" ]] || die "LiteLLM did not recover within 60 seconds"
fi
ssh spark-1 "chmod 0600 /home/nvidia/litellm/config.yaml"
live_mode_owner="$(ssh spark-1 "stat -c %a:%U /home/nvidia/litellm/config.yaml")"
require_eq "restored config mode and owner" "600:nvidia" "$live_mode_owner"
for endpoint in liveliness readiness; do
  status="$(ssh spark-1 "curl -sS --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:4446/health/$endpoint")"
  require_eq "LiteLLM $endpoint status" "200" "$status"
done

root_status="$(ssh spark-1 "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:4444/")"
models_status="$(ssh spark-1 "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:4444/v1/models")"
require_eq "Caddy root status" "403" "$root_status"
require_eq "unauthenticated model-list status" "401" "$models_status"
binds="$(ssh spark-1 "ss -lntH '( sport = :4446 )' | awk '{print \$4}'")"
[[ -n "$binds" ]] || die "LiteLLM is not listening on port 4446"
if grep -vE '^(127\.0\.0\.1|\[::1\]):4446$' <<<"$binds" | grep -q .; then
  die "LiteLLM port 4446 is not loopback-only"
fi
ssh spark-1 python3 - "$phase" "$(basename "$validated_root")" <<'PY'
import json
import subprocess
import sys
import urllib.request

phase, change_id = sys.argv[1:]
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


def post(url, body, key):
    request = urllib.request.Request(
        url,
        data=json.dumps(body, separators=(",", ":")).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.status, json.load(response)


virtual = None
try:
    _, created = post(
        "http://127.0.0.1:4446/key/generate",
        {
            "key_alias": f"rollback-{phase}-{change_id}",
            "models": ["glm-5.2", "glm-5.3-flash", "inkling-small-nvfp4"],
            "max_budget": 0.1,
            "budget_duration": "1d",
        },
        master,
    )
    virtual = created["key"]
    for model in ("glm-5.2", "glm-5.3-flash", "inkling-small-nvfp4"):
        status, payload = post(
            "http://127.0.0.1:4444/v1/chat/completions",
            {
                "model": model,
                "messages": [{"role": "user", "content": "Reply OK."}],
                "max_tokens": 8,
                "temperature": 0,
            },
            virtual,
        )
        if status != 200 or payload.get("model") != model:
            raise RuntimeError(f"cross-model rollback probe failed for {model}")
finally:
    if virtual is not None:
        post("http://127.0.0.1:4446/key/delete", {"keys": [virtual]}, master)
print("cross-model rollback probes passed")
PY
event "$phase-rollback" GO "hash-verified config restored and ingress checks passed"
printf 'LiteLLM %s rollback complete\n' "$phase"
