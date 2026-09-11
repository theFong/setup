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

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fake_bin="$scratch/bin"
mkdir -p "$fake_bin"
export TEST_LOG="$scratch/invocations.log"
: >"$TEST_LOG"

for command in ssh docker curl systemctl sha256sum nvidia-smi; do
  command_path="$fake_bin/$command"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s %s\\n" "$(basename "$0")" "$*" >>"$TEST_LOG"' 'exit 0' >"$command_path"
  chmod +x "$command_path"
done

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

TEST_FREE_BYTES=805306367999 expect_failure low_free \
  "$preflight" --phase stage --run-root "$valid_root"

TEST_MISSING_TOPOLOGY=shamu-hca expect_failure missing_hca \
  "$preflight" --phase baseline --run-root "$valid_root"

expect_failure invalid_root \
  "$preflight" --phase baseline --run-root "$scratch/outside"

TEST_CREDENTIAL_MODE=0644 expect_failure bad_credential_mode \
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

echo "cutover failure-path tests passed"
