#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../.."

preflight="webster/deepseek-v41/scripts/preflight.sh"
if [[ ! -x "$preflight" ]]; then
  echo "FAIL: missing executable $preflight" >&2
  exit 1
fi
stage_artifacts="webster/deepseek-v41/scripts/stage-artifacts.sh"
if [[ ! -x "$stage_artifacts" ]]; then
  echo "FAIL: missing executable $stage_artifacts" >&2
  exit 1
fi
install_guard="webster/deepseek-v41/scripts/install-glm52-guard.sh"
restore_config="webster/deepseek-v41/scripts/restore-litellm-config.sh"
for required_script in "$install_guard" "$restore_config"; do
  if [[ ! -x "$required_script" ]]; then
    echo "FAIL: missing executable $required_script" >&2
    exit 1
  fi
done

scratch="$(mktemp -d)"
trap 'chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf "$scratch"' EXIT
fake_bin="$scratch/bin"
mkdir -p "$fake_bin"
export TEST_LOG="$scratch/invocations.log"
: >"$TEST_LOG"

for command in ssh docker curl systemctl sha256sum nvidia-smi; do
  command_path="$fake_bin/$command"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s %s\\n" "$(basename "$0")" "$*" >>"$TEST_LOG"' \
    'if [[ "$(basename "$0")" == "ssh" && "$*" == *"df -PB1 /home/alecfong"* && -n "${TEST_SSH_DF_FREE:-}" ]]; then' \
    '  printf "Filesystem 1-blocks Used Available Capacity Mounted\\n/dev/test 1000 1 %s 1%% /home/alecfong\\n" "$TEST_SSH_DF_FREE"' \
    'fi' \
    'if [[ "$(basename "$0")" == "ssh" && "$*" == *"stat -c %a:%U:%s"* && -n "${TEST_SSH_CREDENTIAL_METADATA:-}" ]]; then' \
    '  printf "%s\\n" "$TEST_SSH_CREDENTIAL_METADATA"' \
    'fi' \
    'exit 0' >"$command_path"
  chmod +x "$command_path"
done
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s %s\n" "$(basename "$0")" "$*" >>"$TEST_LOG"' \
  '[[ "${TEST_SCP_FAIL:-0}" != "1" ]] || exit 9' \
  'exit 0' >"$fake_bin/scp"
chmod +x "$fake_bin/scp"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s %s\\n" "$(basename "$0")" "$*" >>"$TEST_LOG"' \
  'exec /usr/bin/sha256sum "$@"' >"$fake_bin/sha256sum"
chmod +x "$fake_bin/sha256sum"

export PATH="$fake_bin:$PATH"
export WEBSTER_PREFLIGHT_TEST_MODE=1
export WEBSTER_STAGE_TEST_MODE=1

expect_failure() {
  local name="$1"
  shift
  if "$@" >"$scratch/$name.stdout" 2>"$scratch/$name.stderr"; then
    echo "FAIL: $name unexpectedly succeeded" >&2
    exit 1
  fi
}

valid_root="/home/ubuntu/deepseek-v41-runs/20990101T000000Z"
valid_inspect="$scratch/litellm-inspect-valid.json"
bad_inspect="$scratch/litellm-inspect-bad.json"
printf '%s\n' \
  '[{"Image":"sha256:0000000000000000000000000000000000000000000000000000000000000000","Config":{"Entrypoint":["docker/prod_entrypoint.sh"],"Cmd":["--config","/app/config.yaml","--host","127.0.0.1","--port","4446"]}}]' \
  >"$valid_inspect"
printf '%s\n' \
  '[{"Image":"sha256:0000000000000000000000000000000000000000000000000000000000000000","Config":{"Entrypoint":["docker/prod_entrypoint.sh"],"Cmd":["--config","/app/config.yaml","--host","0.0.0.0","--port","4446"]}}]' \
  >"$bad_inspect"
export TEST_LITELLM_INSPECT="$valid_inspect"

(
  export TEST_RUNS_ROOT="$scratch/runs"
  source webster/deepseek-v41/scripts/common.sh
  local_root="$TEST_RUNS_ROOT/20990101T000000Z"
  init_run_root "$local_root"
  printf 'sentinel\n' >>"$local_root/events.tsv"
  init_run_root "$local_root"
  grep -qx sentinel "$local_root/events.tsv"
  [[ "$(stat -c %a "$local_root")" == "700" ]]
  [[ "$(stat -c %a "$local_root/manifest.env")" == "600" ]]
)

credential_root="$scratch/credential-evidence"
mkdir -p "$credential_root/logs"
chmod 0700 "$credential_root" "$credential_root/logs"
env WEBSTER_PREFLIGHT_TEST_MODE=0 WEBSTER_STAGE_TEST_MODE=0 \
  TEST_SSH_CREDENTIAL_METADATA=600:nvidia:32 \
  RUN_ROOT="$credential_root" bash -c '
    source webster/deepseek-v41/scripts/common.sh
    require_file_mode_600 shamu /home/alecfong/.config/glm52/vllm-api-key
  '

TEST_FREE_BYTES=805306367999 expect_failure low_free \
  "$preflight" --phase stage --run-root "$valid_root"

TEST_MISSING_TOPOLOGY=shamu-hca expect_failure missing_hca \
  "$preflight" --phase baseline --run-root "$valid_root"

expect_failure invalid_root \
  "$preflight" --phase baseline --run-root "$scratch/outside"

TEST_CREDENTIAL_MODE=0644 expect_failure bad_credential_mode \
  "$preflight" --phase baseline --run-root "$valid_root"

expect_failure bad_litellm_shape \
  env TEST_LITELLM_INSPECT="$bad_inspect" \
    "$preflight" --phase baseline --run-root "$valid_root"

expect_failure model_probe_failure \
  env TEST_CURRENT_MODEL_PROBE_STATUS=failed \
    "$preflight" --phase baseline --run-root "$valid_root"

expect_failure malformed_station_free \
  env TEST_VALIDATE_STATION_FREE=1 TEST_SSH_DF_FREE=not-an-integer \
    "$preflight" --phase baseline --run-root "$valid_root"

: >"$TEST_LOG"
"$preflight" --phase baseline --run-root "$valid_root"
cp "$TEST_LOG" "$scratch/first-success.log"
: >"$TEST_LOG"
"$preflight" --phase baseline --run-root "$valid_root"
cmp "$scratch/first-success.log" "$TEST_LOG"

TEST_FREE_BYTES=805306367999 expect_failure stage_low_free \
  "$stage_artifacts" --node shamu --run-root "$valid_root"

expect_failure stage_invalid_node \
  "$stage_artifacts" --node baker-spark-1 --run-root "$valid_root"

TEST_STAGE_FINAL_STATE=divergent expect_failure stage_divergent_final \
  "$stage_artifacts" --node shamu --run-root "$valid_root"

TEST_STAGE_BASELINE_P90=10 \
TEST_STAGE_HEALTH_WINDOWS=$'12 0.98 5\n9 0.97 4' \
  expect_failure stage_two_bad_windows \
    "$stage_artifacts" --node shamu --run-root "$valid_root"

TEST_STAGE_BASELINE_P90=10 \
TEST_STAGE_HEALTH_WINDOWS=$'12 1.0 21\n9 1.0 25' \
  expect_failure stage_two_slow_windows \
    "$stage_artifacts" --node shamu --run-root "$valid_root"

: >"$TEST_LOG"
TEST_STAGE_BASELINE_P90=10 \
TEST_STAGE_HEALTH_WINDOWS=$'12 0.98 5\n12 1.0 6' \
  "$stage_artifacts" --node shamu --run-root "$valid_root"

: >"$TEST_LOG"
"$stage_artifacts" --node shamu --run-root "$valid_root"
cp "$TEST_LOG" "$scratch/first-stage.log"
: >"$TEST_LOG"
"$stage_artifacts" --node shamu --run-root "$valid_root"
cmp "$scratch/first-stage.log" "$TEST_LOG"

test_runs_root="$scratch/runs"
test_run_root="$test_runs_root/20990101T000001Z"
(
  export WEBSTER_PREFLIGHT_TEST_MODE=1
  export TEST_RUNS_ROOT="$test_runs_root"
  source webster/deepseek-v41/scripts/common.sh
  init_run_root "$test_run_root"
)

tokenizer_source="$scratch/tokenizer"
mkdir -p "$tokenizer_source"
for name in tokenizer.json tokenizer_config.json chat_template.jinja; do
  printf 'fixture-%s\n' "$name" >"$tokenizer_source/$name"
done
candidate_config="$scratch/candidate.yaml"
printf 'model_list: []\n' >"$candidate_config"
chmod 0600 "$candidate_config"
test_litellm_root="$scratch/litellm"

: >"$TEST_LOG"
expect_failure install_transfer_cleanup \
  env TEST_SCP_FAIL=1 TEST_RUNS_ROOT="$test_runs_root" \
    TEST_TOKENIZER_SOURCE="$tokenizer_source" \
    "$install_guard" --candidate --run-root "$test_run_root" \
      --candidate-config "$candidate_config"
if ! grep -F 'for path in '\''/home/nvidia/litellm/energy-pricing/.glm52-guard-stage-' \
    "$TEST_LOG" |
    grep -F "' '/home/nvidia/litellm/energy-pricing/.glm52-guard-offline-" >/dev/null ||
  ! grep -F 'rm -rf -- "$resolved"' "$TEST_LOG" >/dev/null; then
  echo "FAIL: transfer failure did not clean both remote candidate trees" >&2
  sed -n '1,20p' "$TEST_LOG" >&2
  exit 1
fi

install_test_env=(
  env
  WEBSTER_LITELLM_TEST_MODE=1
  TEST_RUNS_ROOT="$test_runs_root"
  TEST_LITELLM_ROOT="$test_litellm_root"
  TEST_TOKENIZER_SOURCE="$tokenizer_source"
)
"${install_test_env[@]}" "$install_guard" --candidate \
  --run-root "$test_run_root" --candidate-config "$candidate_config"
first_module_hash="$(sha256sum "$test_litellm_root/glm52_contract_guard.py")"
"${install_test_env[@]}" "$install_guard" --candidate \
  --run-root "$test_run_root" --candidate-config "$candidate_config"
[[ "$(sha256sum "$test_litellm_root/glm52_contract_guard.py")" == "$first_module_hash" ]]
if find "$test_litellm_root" -maxdepth 1 -name 'glm52_contract_guard.py.bak-*' | grep -q .; then
  echo "FAIL: identical guard reinstall created a backup" >&2
  exit 1
fi

chmod 0666 "$test_litellm_root/glm52_contract_guard.py"
chmod 0755 "$test_litellm_root/glm52-tokenizer"
chmod 0644 "$test_litellm_root/glm52-tokenizer/"*
"${install_test_env[@]}" "$install_guard" --candidate \
  --run-root "$test_run_root" --candidate-config "$candidate_config"
[[ "$(stat -c %a "$test_litellm_root/glm52_contract_guard.py")" == "644" ]]
[[ "$(stat -c %a "$test_litellm_root/glm52-tokenizer")" == "555" ]]
for tokenizer_file in "$test_litellm_root/glm52-tokenizer/"*; do
  [[ "$(stat -c %a "$tokenizer_file")" == "444" ]]
done

printf 'divergent\n' >"$test_litellm_root/glm52_contract_guard.py"
"${install_test_env[@]}" "$install_guard" --candidate \
  --run-root "$test_run_root" --candidate-config "$candidate_config"
find "$test_litellm_root" -maxdepth 1 -name 'glm52_contract_guard.py.bak-*' | grep -q .
[[ "$(sha256sum "$test_litellm_root/glm52_contract_guard.py")" == "$first_module_hash" ]]

mv "$tokenizer_source/chat_template.jinja" "$scratch/missing-chat-template"
expect_failure install_missing_tokenizer \
  "${install_test_env[@]}" "$install_guard" --candidate \
    --run-root "$test_run_root" --candidate-config "$candidate_config"
mv "$scratch/missing-chat-template" "$tokenizer_source/chat_template.jinja"

rollback_backup="$test_litellm_root/config.yaml.bak-alias"
printf 'restored: true\n' >"$rollback_backup"
chmod 0600 "$rollback_backup"
printf 'restored: false\n' >"$test_litellm_root/config.yaml"
chmod 0600 "$test_litellm_root/config.yaml"
rollback_hash="$(sha256sum "$rollback_backup" | awk '{print $1}')"
{
  printf 'ALIAS_CONFIG_BACKUP=/home/nvidia/litellm/config.yaml.bak-alias\n'
  printf 'ALIAS_CONFIG_SHA256=%s\n' "$rollback_hash"
} >"$test_run_root/rollback.env"
chmod 0600 "$test_run_root/rollback.env"
: >"$TEST_LOG"
restore_test_env=(
  env
  WEBSTER_LITELLM_TEST_MODE=1
  TEST_RUNS_ROOT="$test_runs_root"
  TEST_LITELLM_ROOT="$test_litellm_root"
)
"${restore_test_env[@]}" "$restore_config" --phase alias --run-root "$test_run_root"
grep -qx 'restored: true' "$test_litellm_root/config.yaml"
first_restart_count="$(grep -c '^docker restart litellm$' "$TEST_LOG" || true)"
"${restore_test_env[@]}" "$restore_config" --phase alias --run-root "$test_run_root"
second_restart_count="$(grep -c '^docker restart litellm$' "$TEST_LOG" || true)"
[[ "$first_restart_count" == "1" && "$second_restart_count" == "1" ]]

chmod 0644 "$test_litellm_root/config.yaml"
"${restore_test_env[@]}" "$restore_config" --phase alias --run-root "$test_run_root"
[[ "$(stat -c %a "$test_litellm_root/config.yaml")" == "600" ]]
third_restart_count="$(grep -c '^docker restart litellm$' "$TEST_LOG" || true)"
[[ "$third_restart_count" == "1" ]]

expect_failure restore_not_ready \
  env WEBSTER_LITELLM_TEST_MODE=1 TEST_RUNS_ROOT="$test_runs_root" \
    TEST_LITELLM_ROOT="$test_litellm_root" TEST_RESTORE_READINESS=failed \
    "$restore_config" --phase alias --run-root "$test_run_root"

sed -i 's#^ALIAS_CONFIG_BACKUP=.*#ALIAS_CONFIG_BACKUP=/tmp/outside.yaml#' \
  "$test_run_root/rollback.env"
expect_failure restore_outside_path \
  "${restore_test_env[@]}" "$restore_config" --phase alias --run-root "$test_run_root"
sed -i 's#^ALIAS_CONFIG_BACKUP=.*#ALIAS_CONFIG_BACKUP=/home/nvidia/litellm/config.yaml.bak-alias#' \
  "$test_run_root/rollback.env"
sed -i 's/^ALIAS_CONFIG_SHA256=.*/ALIAS_CONFIG_SHA256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
  "$test_run_root/rollback.env"
expect_failure restore_hash_mismatch \
  "${restore_test_env[@]}" "$restore_config" --phase alias --run-root "$test_run_root"

echo "cutover failure-path tests passed"
