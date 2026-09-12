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
build_runtime="webster/deepseek-v41/scripts/build-runtime.sh"
registry_probe="webster/deepseek-v41/scripts/verify-runtime-registry.py"
lifecycle_scripts=(
  webster/deepseek-v41/scripts/stop-glm52-tp2.sh
  webster/deepseek-v41/scripts/start-glm52-tp2.sh
  webster/deepseek-v41/scripts/stop-deepseek-v41-tp2.sh
  webster/deepseek-v41/scripts/start-deepseek-v41-tp2.sh
  webster/deepseek-v41/scripts/deepseek-v41-watchdog.sh
)
for required_script in \
  "$install_guard" "$restore_config" "$build_runtime" "$registry_probe" \
  "${lifecycle_scripts[@]}"; do
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
    'if [[ "$(basename "$0")" == "ssh" && "$*" == *"df -B1 --output=avail"* && -n "${TEST_SSH_DF_FREE:-}" ]]; then' \
    '  printf "Avail\\n%s\\n" "$TEST_SSH_DF_FREE"' \
    'fi' \
    'if [[ "$(basename "$0")" == "ssh" && "$*" == *"stat -c %a:%U:%s"* && -n "${TEST_SSH_CREDENTIAL_METADATA:-}" ]]; then' \
    '  printf "%s\\n" "$TEST_SSH_CREDENTIAL_METADATA"' \
    'fi' \
    'if [[ "$(basename "$0")" == "ssh" && "${TEST_SSH_HANG:-0}" == "1" ]]; then' \
    '  sleep 30' \
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

: >"$TEST_LOG"
(
  export TEST_RUNS_ROOT="$scratch/runs"
  source webster/deepseek-v41/scripts/common.sh
  check_glm_health
)
grep -Fxq \
  'curl -fsS --connect-timeout 3 --max-time 5 http://100.73.140.127:8000/health' \
  "$TEST_LOG"
if grep -q '^ssh ' "$TEST_LOG"; then
  echo "FAIL: direct GLM health check unexpectedly used SSH" >&2
  exit 1
fi

available_bytes="$(
  export TEST_RUNS_ROOT="$scratch/runs"
  source webster/deepseek-v41/scripts/common.sh
  TEST_SSH_DF_FREE=123456789 remote_available_bytes \
    shamu /home/alecfong/test
)"
[[ "$available_bytes" == "123456789" ]]
grep -Fxq \
  'ssh shamu df -B1 --output=avail /home/alecfong/test' \
  "$TEST_LOG"

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

stage_timeout_started="$(date +%s)"
expect_failure stage_ssh_probe_timeout \
  timeout 5 env TEST_SSH_HANG=1 STAGE_SSH_TIMEOUT_SECONDS=1 \
    "$stage_artifacts" --node shamu --run-root "$valid_root"
stage_timeout_elapsed=$(( $(date +%s) - stage_timeout_started ))
(( stage_timeout_elapsed < 5 )) || {
  echo "FAIL: staging quick SSH probe was not bounded" >&2
  exit 1
}

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

runtime_runs_root="$scratch/runtime-runs"
runtime_run_root="$runtime_runs_root/20990101T000002Z"
registry_fixture="$scratch/registry-fixture/vllm/model_executor/models"
mkdir -p "$registry_fixture"
printf '%s\n' \
  'MODEL_REGISTRY = {' \
  '    "DeepseekV41ForCausalLM": ("deepseek_v4_1", "DeepseekV41ForCausalLM"),' \
  '}' >"$registry_fixture/registry.py"
"$registry_probe" --package-root "$scratch/registry-fixture/vllm" \
  --require-model DeepseekV41ForCausalLM \
  >"$scratch/registry-probe.stdout"
grep -Fq 'DeepseekV41ForCausalLM' "$scratch/registry-probe.stdout"
expect_failure runtime_registry_missing_model \
  "$registry_probe" --package-root "$scratch/registry-fixture/vllm" \
    --require-model MissingForCausalLM
runtime_source="$scratch/vllm-source"
mkdir -p "$runtime_source"
git -C "$runtime_source" init -q
git -C "$runtime_source" config user.name test
git -C "$runtime_source" config user.email test@example.invalid
printf 'fixture\n' >"$runtime_source/source.txt"
git -C "$runtime_source" add source.txt
git -C "$runtime_source" commit -qm fixture
runtime_commit="$(git -C "$runtime_source" rev-parse HEAD)"
git -C "$runtime_source" tag v0.1.0
printf 'second fixture\n' >>"$runtime_source/source.txt"
git -C "$runtime_source" commit -qam second-fixture
runtime_commit="$(git -C "$runtime_source" rev-parse HEAD)"
git -C "$runtime_source" checkout -q --detach "$runtime_commit"
runtime_bundle="$scratch/runtime-source.bundle"
(
  export WEBSTER_RUNTIME_TEST_MODE=1
  export TEST_RUNS_ROOT="$runtime_runs_root"
  source webster/deepseek-v41/scripts/common.sh
  create_tagged_git_bundle "$runtime_source" "$runtime_bundle" "$runtime_commit"
  mkdir "$scratch/non-git-caller"
  cd "$scratch/non-git-caller"
  create_tagged_git_bundle "$runtime_source" "$runtime_bundle" "$runtime_commit"
)
runtime_bundle_clone="$scratch/runtime-bundle-clone"
git -c advice.detachedHead=false clone -q "$runtime_bundle" "$runtime_bundle_clone"
[[ "$(git -C "$runtime_bundle_clone" describe --tags)" == v0.1.0-1-g* ]]
(
  export WEBSTER_RUNTIME_TEST_MODE=1
  export TEST_RUNS_ROOT="$runtime_runs_root"
  source webster/deepseek-v41/scripts/common.sh
  init_run_root "$runtime_run_root"
)
sed -i "s/^VLLM_COMMIT=.*/VLLM_COMMIT=$runtime_commit/" \
  "$runtime_run_root/manifest.env"

runtime_test_env=(
  env
  WEBSTER_RUNTIME_TEST_MODE=1
  TEST_RUNS_ROOT="$runtime_runs_root"
  TEST_RUNTIME_REMOTE_ARCH=arm64
  TEST_RUNTIME_BUILD_BASE_PLATFORM=linux/arm64
  TEST_RUNTIME_FINAL_BASE_PLATFORM=linux/arm64
  TEST_RUNTIME_TRANSFER_SHA_MATCH=1
  TEST_RUNTIME_IMAGE_IDS=$'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  TEST_RUNTIME_INTERNAL_COMMITS=$'REPLACE_RUNTIME_COMMIT\nREPLACE_RUNTIME_COMMIT'
  TEST_RUNTIME_HELP_TEXT=--engram-config
  TEST_RUNTIME_REGISTRY_TEXT=DeepseekV41ForCausalLM
  TEST_RUNTIME_ENGRAM_LAYER_IDS=1,2
  TEST_RUNTIME_CGROUP_PARENT=/deepseek.slice/deepseek-v41.slice/build.slice
)
runtime_test_env=("${runtime_test_env[@]//REPLACE_RUNTIME_COMMIT/$runtime_commit}")

chmod 0644 "$runtime_run_root/manifest.env"
expect_failure runtime_manifest_mode \
  "${runtime_test_env[@]}" "$build_runtime" --run-root "$runtime_run_root" \
    --source-dir "$runtime_source"
chmod 0600 "$runtime_run_root/manifest.env"

expect_failure runtime_wrong_arch \
  env "${runtime_test_env[@]:1}" TEST_RUNTIME_REMOTE_ARCH=amd64 \
    "$build_runtime" --run-root "$runtime_run_root" --source-dir "$runtime_source"

printf 'dirty\n' >>"$runtime_source/source.txt"
expect_failure runtime_dirty_source \
  "${runtime_test_env[@]}" "$build_runtime" --run-root "$runtime_run_root" \
    --source-dir "$runtime_source"
git -C "$runtime_source" checkout -q -- source.txt

expect_failure runtime_wrong_base_platform \
  env "${runtime_test_env[@]:1}" TEST_RUNTIME_BUILD_BASE_PLATFORM=linux/amd64 \
    "$build_runtime" --run-root "$runtime_run_root" --source-dir "$runtime_source"

expect_failure runtime_transfer_mismatch \
  env "${runtime_test_env[@]:1}" TEST_RUNTIME_TRANSFER_SHA_MATCH=0 \
    "$build_runtime" --run-root "$runtime_run_root" --source-dir "$runtime_source"

expect_failure runtime_image_mismatch \
  env "${runtime_test_env[@]:1}" \
    TEST_RUNTIME_IMAGE_IDS=$'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nsha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    "$build_runtime" --run-root "$runtime_run_root" --source-dir "$runtime_source"

expect_failure runtime_missing_engram_flag \
  env "${runtime_test_env[@]:1}" TEST_RUNTIME_HELP_TEXT='usage: vllm serve' \
    "$build_runtime" --run-root "$runtime_run_root" --source-dir "$runtime_source"

expect_failure runtime_help_probe_gpu_visible \
  env "${runtime_test_env[@]:1}" TEST_RUNTIME_HELP_VISIBLE_DEVICES=all \
    "$build_runtime" --run-root "$runtime_run_root" --source-dir "$runtime_source"

expect_failure runtime_help_probe_cuda_target \
  env "${runtime_test_env[@]:1}" TEST_RUNTIME_HELP_TARGET_DEVICE=cuda \
    "$build_runtime" --run-root "$runtime_run_root" --source-dir "$runtime_source"

expect_failure runtime_help_probe_default_selector \
  env "${runtime_test_env[@]:1}" TEST_RUNTIME_HELP_SELECTOR=default \
    "$build_runtime" --run-root "$runtime_run_root" --source-dir "$runtime_source"

expect_failure runtime_relative_cgroup \
  env "${runtime_test_env[@]:1}" TEST_RUNTIME_CGROUP_PARENT=deepseek-v41-build.slice \
    "$build_runtime" --run-root "$runtime_run_root" --source-dir "$runtime_source"

expect_failure runtime_wheel_ceiling_above_upstream_quota \
  env "${runtime_test_env[@]:1}" TEST_RUNTIME_MAX_WHEEL_SIZE_MB=801 \
    "$build_runtime" --run-root "$runtime_run_root" --source-dir "$runtime_source"

: >"$TEST_LOG"
"${runtime_test_env[@]}" "$build_runtime" --run-root "$runtime_run_root" \
  --source-dir "$runtime_source"
wheel_manifest_entry="$(grep '^VLLM_MAX_WHEEL_SIZE_MB=' "$runtime_run_root/manifest.env")"
[[ "$wheel_manifest_entry" == "VLLM_MAX_WHEEL_SIZE_MB=700" ]]
first_runtime_manifest="$(sha256sum "$runtime_run_root/manifest.env")"
"${runtime_test_env[@]}" "$build_runtime" --run-root "$runtime_run_root" \
  --source-dir "$runtime_source"
[[ "$(sha256sum "$runtime_run_root/manifest.env")" == "$first_runtime_manifest" ]]

lifecycle_runs_root="$scratch/lifecycle-runs"
lifecycle_run_root="$lifecycle_runs_root/20990101T000003Z"
(
  export WEBSTER_PREFLIGHT_TEST_MODE=1
  export TEST_RUNS_ROOT="$lifecycle_runs_root"
  source webster/deepseek-v41/scripts/common.sh
  init_run_root "$lifecycle_run_root"
)
sed -i \
  's#^VLLM_IMAGE_ID=.*#VLLM_IMAGE_ID=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#' \
  "$lifecycle_run_root/manifest.env"

lifecycle_test_env=(
  env
  WEBSTER_LIFECYCLE_TEST_MODE=1
  TEST_RUNS_ROOT="$lifecycle_runs_root"
  TEST_LIFECYCLE_GLM_SHAMU_RUNNING=false
  TEST_LIFECYCLE_GLM_TILIKUM_RUNNING=false
  TEST_LIFECYCLE_DEEPSEEK_SHAMU_RUNNING=false
  TEST_LIFECYCLE_DEEPSEEK_TILIKUM_RUNNING=false
  TEST_LIFECYCLE_CHECKPOINTS_MATCH=1
  TEST_LIFECYCLE_IMAGES_MATCH=1
  TEST_LIFECYCLE_FREE_BYTES=214748364800
  TEST_LIFECYCLE_RAILS_OK=1
  TEST_LIFECYCLE_SSH_OK=1
  TEST_LIFECYCLE_AUTH_OK=1
  TEST_LIFECYCLE_LISTENERS_OK=1
  TEST_LIFECYCLE_RANK1_KEYLESS=1
  TEST_LIFECYCLE_NCCL_OK=1
)

stop_glm="${lifecycle_scripts[0]}"
start_glm="${lifecycle_scripts[1]}"
stop_deepseek="${lifecycle_scripts[2]}"
start_deepseek="${lifecycle_scripts[3]}"
watchdog="${lifecycle_scripts[4]}"

: >"$TEST_LOG"
"${lifecycle_test_env[@]}" "$stop_glm" --run-root "$lifecycle_run_root"
grep -Fq 'ssh shamu docker stop --time 120 glm52-full-mtp' "$TEST_LOG"
grep -Fq 'ssh tilikum sudo -n docker stop --time 120 glm52-full-mtp' "$TEST_LOG"

redacted_inspect="$(
  export TEST_RUNS_ROOT="$scratch/runs"
  source webster/deepseek-v41/scripts/common.sh
  printf '%s\n' \
    '{"Config":{"Env":["VLLM_API_KEY=singular-secret","DSPARK_API_KEYS=plural-secret"]}}' |
    redact_stream
)"
[[ "$redacted_inspect" != *singular-secret* ]]
if [[ "$redacted_inspect" == *plural-secret* ]]; then
  echo "FAIL: Docker inspect evidence leaked a plural API key field" >&2
  exit 1
fi

: >"$TEST_LOG"
expect_failure glm_partial_stop \
  env "${lifecycle_test_env[@]:1}" TEST_LIFECYCLE_STOP_FAIL_NODE=tilikum \
    "$stop_glm" --run-root "$lifecycle_run_root"
[[ "$(grep -Fc 'ssh shamu docker stop --time 120 glm52-full-mtp' "$TEST_LOG")" -ge 2 ]]
[[ "$(grep -Fc 'ssh tilikum sudo -n docker stop --time 120 glm52-full-mtp' "$TEST_LOG")" -ge 2 ]]

: >"$TEST_LOG"
"${lifecycle_test_env[@]}" "$start_glm" --run-root "$lifecycle_run_root"
grep -Fq 'GLM_NODE_RANK=0 GLM_HOST_IP=10.10.1.1 GLM_MAX_MODEL_LEN=320000 GLM_MAX_NUM_SEQS=8' "$TEST_LOG"
grep -Fq 'GLM_NODE_RANK=1 GLM_HOST_IP=10.10.1.2 GLM_MAX_MODEL_LEN=320000 GLM_MAX_NUM_SEQS=8' "$TEST_LOG"
grep -Fq "GLM_DOCKER='sudo -n docker'" "$TEST_LOG"

: >"$TEST_LOG"
env "${lifecycle_test_env[@]:1}" \
  TEST_LIFECYCLE_GLM_SHAMU_RUNNING=true \
  TEST_LIFECYCLE_GLM_TILIKUM_RUNNING=true \
  "$start_glm" --run-root "$lifecycle_run_root"
if grep -Fq '/home/alecfong/serve_glm52.sh' "$TEST_LOG"; then
  echo "FAIL: healthy GLM re-run relaunched ranks" >&2
  exit 1
fi

: >"$TEST_LOG"
"${lifecycle_test_env[@]}" "$start_deepseek" --run-root "$lifecycle_run_root"
grep -Fq -- '--tensor-parallel-size 2 --pipeline-parallel-size 1' "$TEST_LOG"
grep -Fq -- '--engram-config {"cpu_offload":true,"embedding_across_dp":false}' "$TEST_LOG"
grep -Fq -- '--enforce-eager --max-model-len 131072 --max-num-seqs 1' "$TEST_LOG"
grep -Fq -- '--host 100.73.140.127 --port 8000' "$TEST_LOG"
grep -Fq -- '--headless' "$TEST_LOG"
rank1_launch="$(grep 'ssh tilikum .*deepseek-v41-flash-tp2' "$TEST_LOG")"
[[ "$rank1_launch" != *'--env-file'* ]]
[[ "$rank1_launch" != *'VLLM_API_KEY='* ]]

: >"$TEST_LOG"
env "${lifecycle_test_env[@]:1}" \
  TEST_LIFECYCLE_DEEPSEEK_SHAMU_RUNNING=true \
  TEST_LIFECYCLE_DEEPSEEK_TILIKUM_RUNNING=true \
  "$start_deepseek" --run-root "$lifecycle_run_root"
if grep -Fq 'docker run -d --name deepseek-v41-flash-tp2' "$TEST_LOG"; then
  echo "FAIL: healthy DeepSeek re-run relaunched ranks" >&2
  exit 1
fi

expect_failure deepseek_glm_collision \
  env "${lifecycle_test_env[@]:1}" TEST_LIFECYCLE_GLM_SHAMU_RUNNING=true \
    "$start_deepseek" --run-root "$lifecycle_run_root"
expect_failure deepseek_checkpoint_mismatch \
  env "${lifecycle_test_env[@]:1}" TEST_LIFECYCLE_CHECKPOINTS_MATCH=0 \
    "$start_deepseek" --run-root "$lifecycle_run_root"
expect_failure deepseek_image_mismatch \
  env "${lifecycle_test_env[@]:1}" TEST_LIFECYCLE_IMAGES_MATCH=0 \
    "$start_deepseek" --run-root "$lifecycle_run_root"

: >"$TEST_LOG"
"${lifecycle_test_env[@]}" "$stop_deepseek" --run-root "$lifecycle_run_root"
grep -Fq 'ssh shamu docker stop --time 120 deepseek-v41-flash-tp2' "$TEST_LOG"
grep -Fq 'ssh tilikum sudo -n docker stop --time 120 deepseek-v41-flash-tp2' "$TEST_LOG"

expect_failure watchdog_rank_skew \
  env "${lifecycle_test_env[@]:1}" \
    TEST_LIFECYCLE_DEEPSEEK_SHAMU_RUNNING=true \
    TEST_LIFECYCLE_DEEPSEEK_TILIKUM_RUNNING=false \
    TEST_WATCHDOG_NO_RECOVERY=1 \
    "$watchdog" --run-root "$lifecycle_run_root"

: >"$TEST_LOG"
env "${lifecycle_test_env[@]:1}" \
  TEST_LIFECYCLE_DEEPSEEK_SHAMU_RUNNING=true \
  TEST_LIFECYCLE_DEEPSEEK_TILIKUM_RUNNING=false \
  TEST_LIFECYCLE_START_AGE_SECONDS=300 \
  "$watchdog" --run-root "$lifecycle_run_root"
if grep -Eq 'docker (stop|run).*deepseek-v41-flash-tp2' "$TEST_LOG"; then
  echo "FAIL: watchdog restarted inside the 20-minute startup grace" >&2
  exit 1
fi

echo "cutover failure-path tests passed"
