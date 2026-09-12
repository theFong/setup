#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/common.sh"
registry_probe="$script_dir/verify-runtime-registry.py"
[[ -x "$registry_probe" ]] || die "runtime registry probe is not executable"

run_root=""
source_dir=""
while (($#)); do
  case "$1" in
    --run-root)
      [[ $# -ge 2 ]] || die "--run-root requires a value"
      run_root="$2"
      shift 2
      ;;
    --source-dir)
      [[ $# -ge 2 ]] || die "--source-dir requires a value"
      source_dir="$2"
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

validated_root="$(validate_run_root "$run_root")"
[[ -d "$validated_root" ]] || die "run root does not exist"
RUN_ROOT="$validated_root"
export RUN_ROOT
manifest="$RUN_ROOT/manifest.env"
[[ -f "$manifest" ]] || die "manifest.env does not exist"
require_eq "manifest mode" "600" "$(stat -c %a "$manifest")"

manifest_value() {
  local key="$1" count value
  count="$(grep -c "^${key}=" "$manifest" || true)"
  require_eq "manifest field count for $key" "1" "$count"
  value="$(sed -n "s/^${key}=//p" "$manifest")"
  printf '%s\n' "$value"
}

set_manifest_value() {
  local key="$1" value="$2"
  python3 - "$manifest" "$key" "$value" <<'PY'
import os
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
    raise SystemExit("invalid manifest field")
lines = path.read_text(encoding="utf-8").splitlines()
matches = [index for index, line in enumerate(lines) if line.startswith(key + "=")]
if len(matches) > 1:
    raise SystemExit(f"manifest contains duplicate {key}")
if matches:
    index = matches[0]
    existing = lines[index].split("=", 1)[1]
    if existing and existing != value:
        raise SystemExit(f"manifest already pins a different {key}")
    lines[index] = f"{key}={value}"
else:
    lines.append(f"{key}={value}")
temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write("\n".join(lines) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    os.chmod(path, 0o600)
finally:
    if temporary.exists():
        temporary.unlink()
PY
}

require_sha256() {
  [[ "$2" =~ ^sha256:[0-9a-f]{64}$ ]] || die "$1 is not a sha256 digest"
}

validate_cgroup_parent() {
  local parent="$1"
  [[ "$parent" == /* ]] || {
    printf 'ERROR: BuildKit cgroup parent must be an absolute ControlGroup\n' >&2
    return 1
  }
  [[ "$parent" != *".."* ]] || {
    printf 'ERROR: BuildKit cgroup parent contains traversal\n' >&2
    return 1
  }
}

validate_wheel_ceiling() {
  local ceiling="$1"
  [[ "$ceiling" =~ ^[1-9][0-9]*$ ]] ||
    die "runtime wheel ceiling must be a positive integer MiB value"
  (( ceiling <= 800 )) ||
    die "runtime wheel ceiling exceeds the upstream 800 MiB quota"
}

validate_help_probe() {
  local visible_devices="$1" target_device="$2" selector="$3"
  require_eq "runtime help probe GPU visibility" "void" "$visible_devices"
  require_eq "runtime help probe target device" "cpu" "$target_device"
  require_eq "runtime help probe selector" "engram-config" "$selector"
}

vllm_commit="$(manifest_value VLLM_COMMIT)"
[[ "$vllm_commit" =~ ^[0-9a-f]{40}$ ]] || die "VLLM_COMMIT is not pinned"
source_dir="${source_dir:-$RUN_ROOT/runtime-source/vllm}"
[[ -d "$source_dir/.git" ]] || die "vLLM source is not a Git checkout"
require_eq "vLLM source HEAD" "$vllm_commit" \
  "$(git -C "$source_dir" rev-parse HEAD)"
[[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=all)" ]] ||
  die "vLLM source checkout is dirty"
if git -C "$source_dir" symbolic-ref -q HEAD >/dev/null; then
  die "vLLM source checkout must be detached"
fi

validate_runtime_gate() {
  local arch="$1" build_platform="$2" final_platform="$3"
  local transfer_match="$4" image_ids="$5" internal_commits="$6"
  local help_text="$7" registry_text="$8" engram_layers="$9"
  local -a ids commits
  require_eq "runtime builder architecture" "arm64" "$arch"
  require_eq "build base platform" "linux/arm64" "$build_platform"
  require_eq "final base platform" "linux/arm64" "$final_platform"
  require_eq "saved-image transfer checksum" "1" "$transfer_match"
  mapfile -t ids <<<"$image_ids"
  mapfile -t commits <<<"$internal_commits"
  require_eq "station image count" "2" "${#ids[@]}"
  require_eq "station commit count" "2" "${#commits[@]}"
  require_sha256 "Shamu image ID" "${ids[0]}"
  require_sha256 "Tilikum image ID" "${ids[1]}"
  require_eq "station image ID" "${ids[0]}" "${ids[1]}"
  require_eq "Shamu internal vLLM commit" "$vllm_commit" "${commits[0]}"
  require_eq "Tilikum internal vLLM commit" "$vllm_commit" "${commits[1]}"
  [[ "$help_text" == *"--engram-config"* ]] || die "runtime lacks --engram-config"
  [[ "$registry_text" == *"DeepseekV41ForCausalLM"* ]] ||
    die "runtime lacks DeepseekV41ForCausalLM registry support"
  [[ -n "$engram_layers" ]] || die "checkpoint has no engram_layer_ids"
}

if [[ "${WEBSTER_RUNTIME_TEST_MODE:-0}" == "1" ]]; then
  runtime_wheel_ceiling="${TEST_RUNTIME_MAX_WHEEL_SIZE_MB:-$VLLM_MAX_WHEEL_SIZE_MB}"
  validate_wheel_ceiling "$runtime_wheel_ceiling"
  validate_help_probe \
    "${TEST_RUNTIME_HELP_VISIBLE_DEVICES:-void}" \
    "${TEST_RUNTIME_HELP_TARGET_DEVICE:-cpu}" \
    "${TEST_RUNTIME_HELP_SELECTOR:-engram-config}"
  validate_runtime_gate \
    "${TEST_RUNTIME_REMOTE_ARCH:-}" \
    "${TEST_RUNTIME_BUILD_BASE_PLATFORM:-}" \
    "${TEST_RUNTIME_FINAL_BASE_PLATFORM:-}" \
    "${TEST_RUNTIME_TRANSFER_SHA_MATCH:-}" \
    "${TEST_RUNTIME_IMAGE_IDS:-}" \
    "${TEST_RUNTIME_INTERNAL_COMMITS:-}" \
    "${TEST_RUNTIME_HELP_TEXT:-}" \
    "${TEST_RUNTIME_REGISTRY_TEXT:-}" \
    "${TEST_RUNTIME_ENGRAM_LAYER_IDS:-}"
  validate_cgroup_parent "${TEST_RUNTIME_CGROUP_PARENT:-}"
  test_image_id="${TEST_RUNTIME_IMAGE_IDS%%$'\n'*}"
  set_manifest_value VLLM_BASE_IMAGE_DIGEST "$VLLM_BUILD_BASE_IMAGE_DIGEST"
  set_manifest_value VLLM_BUILD_BASE_IMAGE_DIGEST "$VLLM_BUILD_BASE_IMAGE_DIGEST"
  set_manifest_value VLLM_FINAL_BASE_IMAGE_DIGEST "$VLLM_FINAL_BASE_IMAGE_DIGEST"
  set_manifest_value VLLM_SOURCE_ARCHIVE_SHA256 \
    "${TEST_RUNTIME_SOURCE_ARCHIVE_SHA256:-$(printf test-source | sha256sum | awk '{print $1}')}"
  set_manifest_value VLLM_MAX_WHEEL_SIZE_MB "$runtime_wheel_ceiling"
  set_manifest_value VLLM_IMAGE_ID "$test_image_id"
  set_manifest_value VLLM_IMAGE_TAR_SHA256 \
    "${TEST_RUNTIME_IMAGE_TAR_SHA256:-$(printf test-image | sha256sum | awk '{print $1}')}"
  printf 'GO runtime-package test-mode\n'
  exit 0
fi

validate_wheel_ceiling "$VLLM_MAX_WHEEL_SIZE_MB"

[[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "aarch64" ]] ||
  die "unsupported orchestrator architecture"
arm_lane="$source_dir/.buildkite/image_build/image_build_arm64.sh"
release_lane="$source_dir/.buildkite/release-pipeline.yaml"
[[ -f "$arm_lane" && -f "$release_lane" ]] || die "upstream arm64 build lanes missing"
grep -Fq "$VLLM_BUILD_BASE_IMAGE_TAG" "$arm_lane" ||
  die "selected source no longer names the reviewed arm64 builder"
grep -Fq -- '--platform linux/arm64' "$arm_lane" ||
  die "selected source no longer builds the arm64 platform"
grep -Fq 'torch_cuda_arch_list="9.0 10.0 11.0 12.0"' "$arm_lane" ||
  die "selected source arm64 architecture list changed"
grep -Fq -- '--target vllm-openai' "$release_lane" ||
  die "selected source lacks an arm64 vllm-openai release lane"
check_glm_health ||
  die "GLM health failed before runtime packaging"

evidence_dir="$RUN_ROOT/runtime-source/evidence"
mkdir -p "$evidence_dir"
chmod 0700 "$RUN_ROOT/runtime-source" "$evidence_dir"

resolve_platform_manifest() {
  local label="$1" tag="$2" expected="$3" output="$4" selected
  docker manifest inspect --verbose "$tag" >"$output"
  chmod 0600 "$output"
  selected="$(python3 - "$output" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
if isinstance(payload, dict):
    payload = [payload]
matches = []
for item in payload:
    descriptor = item.get("Descriptor", {})
    platform = descriptor.get("platform", {})
    if platform.get("os") == "linux" and platform.get("architecture") == "arm64":
        matches.append(descriptor.get("digest"))
if len(matches) != 1 or not isinstance(matches[0], str):
    raise SystemExit("expected exactly one linux/arm64 manifest")
print(matches[0])
PY
)"
  require_eq "$label platform digest" "$expected" "$selected"
}

resolve_platform_manifest "build base" "$VLLM_BUILD_BASE_IMAGE_TAG" \
  "$VLLM_BUILD_BASE_IMAGE_DIGEST" "$evidence_dir/build-base-manifest.json"
resolve_platform_manifest "final base" "$VLLM_FINAL_BASE_IMAGE_TAG" \
  "$VLLM_FINAL_BASE_IMAGE_DIGEST" "$evidence_dir/final-base-manifest.json"
docker buildx imagetools inspect "$VLLM_BUILD_BASE_IMAGE_TAG" \
  >"$evidence_dir/build-base-index.txt"
docker buildx imagetools inspect "$VLLM_FINAL_BASE_IMAGE_TAG" \
  >"$evidence_dir/final-base-index.txt"
chmod 0600 "$evidence_dir"/*

for excluded_pr in 56220 56227 56344; do
  excluded_file="$evidence_dir/excluded-pr-$excluded_pr.json"
  python3 - "$excluded_pr" "$excluded_file" <<'PY'
import json
import os
import sys
import urllib.request

number, output = sys.argv[1:]
request = urllib.request.Request(
    f"https://api.github.com/repos/vllm-project/vllm/pulls/{number}",
    headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "webster-runtime-gate",
        "X-GitHub-Api-Version": "2022-11-28",
    },
)
with urllib.request.urlopen(request, timeout=30) as response:
    payload = json.load(response)
temporary = output + f".tmp.{os.getpid()}"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, indent=2, sort_keys=True)
    stream.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, output)
PY
  excluded_head="$(python3 - "$excluded_file" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
head = payload.get("head", {}).get("sha")
if not isinstance(head, str) or len(head) != 40:
    raise SystemExit("excluded PR has no immutable head")
print(head)
PY
)"
  if git -C "$source_dir" cat-file -e "$excluded_head^{commit}" 2>/dev/null &&
    git -C "$source_dir" merge-base --is-ancestor "$excluded_head" "$vllm_commit"; then
    die "excluded PR #$excluded_pr is present in the baseline commit"
  fi
done

bundle="$evidence_dir/vllm-$vllm_commit.bundle"
create_tagged_git_bundle "$source_dir" "$bundle" "$vllm_commit"
git -C "$source_dir" bundle verify "$bundle" >"$evidence_dir/bundle-verify.txt" 2>&1
git -C "$source_dir" diff --binary --no-ext-diff HEAD \
  >"$evidence_dir/local.diff"
git -C "$source_dir" submodule status --recursive \
  >"$evidence_dir/submodules.txt"
archive="$evidence_dir/vllm-$vllm_commit.tar.gz"
if [[ ! -f "$archive" ]]; then
  temporary="$archive.tmp.$$"
  git -C "$source_dir" archive --format=tar \
    --prefix="vllm-$vllm_commit/" "$vllm_commit" | gzip -n >"$temporary"
  mv "$temporary" "$archive"
fi
archive_sha="$(sha256sum "$archive" | awk '{print $1}')"
printf '%s  %s\n' "$archive_sha" "$(basename "$archive")" \
  >"$archive.sha256"
chmod 0600 "$evidence_dir"/*

set_manifest_value VLLM_BASE_IMAGE_DIGEST "$VLLM_BUILD_BASE_IMAGE_DIGEST"
set_manifest_value VLLM_BUILD_BASE_IMAGE_DIGEST "$VLLM_BUILD_BASE_IMAGE_DIGEST"
set_manifest_value VLLM_FINAL_BASE_IMAGE_DIGEST "$VLLM_FINAL_BASE_IMAGE_DIGEST"
set_manifest_value VLLM_SOURCE_ARCHIVE_SHA256 "$archive_sha"
set_manifest_value VLLM_MAX_WHEEL_SIZE_MB "$VLLM_MAX_WHEEL_SIZE_MB"

change_id="$(basename "$RUN_ROOT")"
short_commit="${vllm_commit:0:12}"
source_description="$(git -C "$source_dir" describe --tags "$vllm_commit")"
remote_root="/home/alecfong/deepseek-v41/runtime/$change_id"
remote_source="/home/alecfong/deepseek-v41/runtime-source/vllm-$short_commit"
remote_bundle="$remote_root/$(basename "$bundle")"
remote_registry_probe="$remote_root/verify-runtime-registry.py"
runtime_tag="webster/deepseek-v41-vllm:$short_commit"
upstream_tag="webster/deepseek-v41-vllm-upstream:$short_commit"
slice="deepseek-v41-build-${change_id,,}.slice"
service="deepseek-v41-build-${change_id,,}.service"
keeper="deepseek-v41-build-${change_id,,}-keeper.service"

event runtime-package START "freeze and arm64 image build"
ssh shamu "umask 077; mkdir -p '$remote_root' /home/alecfong/deepseek-v41/runtime-source"
rsync --archive --checksum "$bundle" "shamu:$remote_bundle"
rsync --archive --checksum "$package_root/runtime/Dockerfile" \
  "shamu:$remote_root/Dockerfile"
rsync --archive --checksum "$registry_probe" "shamu:$remote_registry_probe"
ssh shamu bash -s -- "$remote_bundle" "$remote_source" "$vllm_commit" \
  "$source_description" <<'REMOTE'
set -euo pipefail
bundle="$1"
source_dir="$2"
commit="$3"
expected_description="$4"
incomplete="${source_dir}.incomplete"
if [[ -d "$source_dir/.git" ]]; then
  [[ "$(git -C "$source_dir" rev-parse HEAD)" == "$commit" ]]
  [[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=all)" ]]
  ! git -C "$source_dir" symbolic-ref -q HEAD >/dev/null
  git -C "$source_dir" fetch --quiet "$bundle" \
    '+refs/tags/*:refs/tags/*'
  [[ "$(git -C "$source_dir" describe --tags "$commit")" == \
    "$expected_description" ]]
  exit 0
fi
[[ ! -e "$source_dir" ]] || { printf 'divergent final source path\n' >&2; exit 1; }
[[ ! -e "$incomplete" ]] || { printf 'existing incomplete source path\n' >&2; exit 1; }
git clone --quiet "$bundle" "$incomplete"
git -C "$incomplete" checkout --quiet --detach "$commit"
[[ -z "$(git -C "$incomplete" status --porcelain --untracked-files=all)" ]]
[[ "$(git -C "$incomplete" describe --tags "$commit")" == \
  "$expected_description" ]]
mv "$incomplete" "$source_dir"
REMOTE

baseline_p90=""
for candidate_window in 15m 1h 6h 24h 7d; do
  baseline_file="$RUN_ROOT/metrics/runtime-baseline-$candidate_window.json"
  write_glm_window_snapshot "$baseline_file" "$candidate_window"
  read -r requests candidate_p90 < <(python3 - "$baseline_file" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data.get("request_count"), data.get("p90_seconds"))
PY
)
  if python3 - "$requests" "$candidate_p90" "$STAGE_BASELINE_MIN_REQUESTS" <<'PY'
import math
import sys

try:
    requests, p90, minimum = map(float, sys.argv[1:])
except (TypeError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if requests >= minimum and math.isfinite(p90) and p90 > 0 else 1)
PY
  then
    baseline_p90="$candidate_p90"
    break
  fi
done
[[ -n "$baseline_p90" ]] || die "no GLM latency baseline for runtime build"

runner="$remote_root/build.runner.sh"
status_file="$remote_root/build.status"
log_file="$remote_root/build.log"
pid_file="$remote_root/build.pid"
ssh shamu "sudo -n systemctl set-property --runtime '$slice' \
  CPUQuota=400% MemoryMax=96G IOWeight=10"
ssh shamu "sudo -n systemctl stop '$keeper' >/dev/null 2>&1 || true; \
  sudo -n systemd-run --unit='$keeper' --slice='$slice' \
  --property=RuntimeMaxSec=10min /usr/bin/sleep infinity >/dev/null"
cgroup_parent="$(ssh shamu "systemctl show '$slice' --property ControlGroup --value")"
if ! validate_cgroup_parent "$cgroup_parent"; then
  ssh shamu "sudo -n systemctl stop '$keeper' >/dev/null 2>&1 || true"
  exit 1
fi
ssh shamu "systemctl show '$slice' -p ControlGroup -p CPUQuotaPerSecUSec \
  -p MemoryMax -p IOWeight" >"$evidence_dir/build-cgroup.txt"
chmod 0600 "$evidence_dir/build-cgroup.txt"
ssh shamu bash -s -- "$runner" <<'REMOTE'
set -euo pipefail
runner="$1"
cat >"$runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
source_dir="$1"
wrapper="$2"
commit="$3"
upstream_tag="$4"
runtime_tag="$5"
build_ref="$6"
final_ref="$7"
build_digest="$8"
final_digest="$9"
cuda_version="${10}"
nccl_version="${11}"
arch_list="${12}"
slice="${13}"
cgroup_parent="${14}"
status_file="${15}"
constraints="${16}"
log_file="${17}"
wheel_ceiling="${18}"
exec >"$log_file" 2>&1

finish() {
  local status=$?
  printf 'EXIT=%s\n' "$status" >"$status_file"
}
trap finish EXIT
trap 'exit 143' TERM INT

sudo -n systemctl show "$slice" -p CPUQuotaPerSecUSec -p MemoryMax -p IOWeight
printf 'VLLM_MAX_SIZE_MB=%s\n' "$wheel_ceiling"

if docker image inspect "$runtime_tag" >/dev/null 2>&1; then
  image_commit="$(docker image inspect "$runtime_tag" \
    --format '{{index .Config.Labels "ai.webster.vllm.commit"}}')"
  image_build_digest="$(docker image inspect "$runtime_tag" \
    --format '{{index .Config.Labels "ai.webster.vllm.build-base-digest"}}')"
  image_final_digest="$(docker image inspect "$runtime_tag" \
    --format '{{index .Config.Labels "ai.webster.vllm.final-base-digest"}}')"
  [[ "$image_commit" == "$commit" ]]
  [[ "$image_build_digest" == "$build_digest" ]]
  [[ "$image_final_digest" == "$final_digest" ]]
else
  buildx_state="$(docker buildx inspect --bootstrap)"
  [[ "$buildx_state" != *"Automatically allowed: true"* ]]
  # The upstream graph builds the manylinux wheel branch and Ubuntu runtime
  # branch concurrently. Both branches mount the same uv distribution cache.
  # Under this four-CPU production-safe quota, a native dependency build can
  # hold that cache lock longer than uv's 300-second timeout. Complete the
  # independent runtime branch first so the full build consumes cached layers
  # instead of racing the wheel branch for the same lock.
  ionice -c3 nice -n 19 docker buildx build --load --pull \
    --platform linux/arm64 \
    --cgroup-parent "$cgroup_parent" \
    --build-arg CUDA_VERSION="$cuda_version" \
    --build-arg NCCL_VERSION="$nccl_version" \
    --build-arg FINAL_BASE_IMAGE="$final_ref" \
    --target vllm-runtime-base \
    --tag "$upstream_tag-runtime-base" \
    --progress plain \
    --file "$source_dir/docker/Dockerfile" "$source_dir"
  ionice -c3 nice -n 19 docker buildx build --load --pull \
    --platform linux/arm64 \
    --cgroup-parent "$cgroup_parent" \
    --build-arg max_jobs=4 \
    --build-arg nvcc_threads=1 \
    --build-arg GIT_REPO_CHECK=1 \
    --build-arg CUDA_VERSION="$cuda_version" \
    --build-arg NCCL_VERSION="$nccl_version" \
    --build-arg BUILD_BASE_IMAGE="$build_ref" \
    --build-arg FINAL_BASE_IMAGE="$final_ref" \
    --build-arg torch_cuda_arch_list="$arch_list" \
    --build-arg VLLM_MAX_SIZE_MB="$wheel_ceiling" \
    --build-arg VLLM_BUILD_COMMIT="$commit" \
    --build-arg VLLM_BUILD_PIPELINE=webster-deepseek-v41 \
    --build-arg VLLM_IMAGE_TAG="$runtime_tag" \
    --target vllm-openai \
    --tag "$upstream_tag" \
    --progress plain \
    --file "$source_dir/docker/Dockerfile" "$source_dir"
  ionice -c3 nice -n 19 docker buildx build --load \
    --platform linux/arm64 \
    --cgroup-parent "$cgroup_parent" \
    --build-arg UPSTREAM_VLLM_IMAGE="$upstream_tag" \
    --build-arg VLLM_COMMIT="$commit" \
    --build-arg VLLM_BUILD_BASE_IMAGE_DIGEST="$build_digest" \
    --build-arg VLLM_FINAL_BASE_IMAGE_DIGEST="$final_digest" \
    --tag "$runtime_tag" \
    --progress plain \
    --file "$wrapper" "$(dirname "$wrapper")"
fi

image_id="$(docker image inspect "$runtime_tag" --format '{{.Id}}')"
architecture="$(docker image inspect "$runtime_tag" --format '{{.Architecture}}')"
image_commit="$(docker image inspect "$runtime_tag" \
  --format '{{index .Config.Labels "ai.webster.vllm.commit"}}')"
[[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]]
[[ "$architecture" == arm64 ]]
[[ "$image_commit" == "$commit" ]]
temporary="${constraints}.tmp.$$"
docker run --rm --runtime runc --network none \
  --env NVIDIA_VISIBLE_DEVICES=void --entrypoint python3 "$image_id" \
  -m pip freeze >"$temporary"
[[ -s "$temporary" ]]
grep -Eqi '^vllm(==| @ )' "$temporary"
mv "$temporary" "$constraints"
printf 'IMAGE_ID=%s\n' "$image_id"
RUNNER
chmod 0700 "$runner"
REMOTE

if ! ssh shamu "rm -f -- '$status_file' '$pid_file'; : >'$log_file'; \
  sudo -n systemctl stop '$service' >/dev/null 2>&1 || true; \
  sudo -n systemctl reset-failed '$service' >/dev/null 2>&1 || true; \
  sudo -n systemd-run --unit='$service' --slice='$slice' --uid=alecfong \
  --property=Nice=19 --property=IOSchedulingClass=idle --collect '$runner' \
  '$remote_source' '$remote_root/Dockerfile' '$vllm_commit' '$upstream_tag' \
  '$runtime_tag' '${VLLM_BUILD_BASE_IMAGE_TAG}@${VLLM_BUILD_BASE_IMAGE_DIGEST}' \
  '${VLLM_FINAL_BASE_IMAGE_TAG}@${VLLM_FINAL_BASE_IMAGE_DIGEST}' \
  '$VLLM_BUILD_BASE_IMAGE_DIGEST' '$VLLM_FINAL_BASE_IMAGE_DIGEST' \
  '$VLLM_CUDA_VERSION' '$VLLM_NCCL_VERSION' '$VLLM_ARM64_ARCH_LIST' '$slice' \
  '$cgroup_parent' '$status_file' '$remote_root/constraints.txt' '$log_file' \
  '$VLLM_MAX_WHEEL_SIZE_MB' \
  >/dev/null; systemctl show '$service' --property MainPID --value >'$pid_file'"; then
  ssh shamu "sudo -n systemctl stop '$keeper' >/dev/null 2>&1 || true"
  die "failed to start the constrained runtime build service"
fi
ssh shamu "sudo -n systemctl stop '$keeper' >/dev/null 2>&1 || true"

sleep 3
if ! ssh shamu "test \"\$(systemctl show '$slice' --property ActiveState --value)\" = active && \
  test \"\$(systemctl show '$slice' --property MemoryCurrent --value)\" -gt 0"; then
  ssh shamu "sudo -n systemctl stop '$service' >/dev/null 2>&1 || true"
  die "runtime build service did not enter the limited systemd slice"
fi

monitor_window=0
consecutive_failures=0
while ! ssh shamu test -s "$status_file"; do
  sleep 60
  monitor_window=$((monitor_window + 1))
  snapshot="$RUN_ROOT/metrics/runtime-build-$(printf '%05d' "$monitor_window").json"
  write_glm_window_snapshot "$snapshot" 1m
  read -r requests success p90 < <(python3 - "$snapshot" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
values = [data.get("request_count"), data.get("success_rate"), data.get("p90_seconds")]
print(*(value if value is not None else "null" for value in values))
PY
)
  decision="$(stage_window_decision "$baseline_p90" "$requests" "$success" "$p90")"
  if ! check_glm_health; then
    decision="BREACH direct-health;$decision"
  fi
  if [[ "$decision" == BREACH\ * ]]; then
    consecutive_failures=$((consecutive_failures + 1))
  else
    consecutive_failures=0
  fi
  event "runtime-build-window-$monitor_window" MONITOR "$decision"
  if (( consecutive_failures >= 2 )); then
    ssh shamu "sudo -n systemctl stop '$service' >/dev/null 2>&1 || true"
    die "GLM success/latency breached for two runtime-build windows"
  fi
done
status="$(ssh shamu "cat '$status_file'")"
ssh shamu "cat '$log_file'" >"$RUN_ROOT/logs/runtime-build.log"
chmod 0600 "$RUN_ROOT/logs/runtime-build.log"
ssh shamu "sudo -n systemctl stop '$service' >/dev/null 2>&1 || true; \
  sudo -n systemctl stop '$slice' >/dev/null 2>&1 || true"
require_eq "runtime build" "EXIT=0" "$status"

ssh shamu "cat '$remote_root/constraints.txt'" >"$package_root/runtime/constraints.txt"
[[ -s "$package_root/runtime/constraints.txt" ]] || die "empty runtime dependency freeze"

image_id="$(ssh shamu "docker image inspect '$runtime_tag' --format '{{.Id}}'")"
require_sha256 "runtime image ID" "$image_id"
internal_commit_shamu="$(ssh shamu "docker image inspect '$runtime_tag' --format '{{index .Config.Labels \"ai.webster.vllm.commit\"}}'")"

image_tar="$remote_root/deepseek-v41-vllm-$short_commit.tar"
tar_status="$remote_root/save.status"
tar_log="$remote_root/save.log"
tar_pid="$remote_root/save.pid"

monitor_runtime_job() {
  local host="$1" status_path="$2" pid_path="$3" label="$4"
  local tick=0 consecutive_health_bad=0 consecutive_metric_bad=0
  local job_pid snapshot requests success p90 decision
  while ! ssh "$host" test -s "$status_path"; do
    sleep 30
    tick=$((tick + 1))
    if ! check_glm_health; then
      consecutive_health_bad=$((consecutive_health_bad + 1))
    elif ((tick % 2 == 0)); then
      consecutive_health_bad=0
      snapshot="$RUN_ROOT/metrics/$label-$(printf '%05d' "$((tick / 2))").json"
      write_glm_window_snapshot "$snapshot" 1m
      read -r requests success p90 < <(python3 - "$snapshot" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
values = [data.get("request_count"), data.get("success_rate"), data.get("p90_seconds")]
print(*(value if value is not None else "null" for value in values))
PY
)
      decision="$(stage_window_decision "$baseline_p90" "$requests" "$success" "$p90")"
      if [[ "$decision" == BREACH\ * ]]; then
        consecutive_metric_bad=$((consecutive_metric_bad + 1))
      else
        consecutive_metric_bad=0
      fi
      event "$label-window-$((tick / 2))" MONITOR "$decision"
    else
      consecutive_health_bad=0
    fi
    if ((consecutive_health_bad >= 2 || consecutive_metric_bad >= 2)); then
      job_pid="$(ssh "$host" "cat '$pid_path'")"
      ssh "$host" "/bin/kill -TERM -- '-$job_pid' 2>/dev/null || true"
      die "GLM health/latency breached while $label was active"
    fi
  done
  check_glm_health ||
    die "GLM health failed after $label"
}

if ! ssh shamu test -f "$image_tar"; then
  if ssh shamu test -e "$image_tar.tmp"; then
    die "incomplete saved-image archive exists; preserving it for diagnosis"
  fi
  ssh shamu "rm -f '$tar_status'; nohup setsid bash -c 'set -o pipefail; \
    ionice -c3 nice -n 19 docker image save \"$runtime_tag\" --output \"$image_tar.tmp\" && \
    mv \"$image_tar.tmp\" \"$image_tar\"; s=\$?; printf \"EXIT=%s\\n\" \"\$s\" >\"$tar_status\"; exit \"\$s\"' \
    >'$tar_log' 2>&1 </dev/null & printf '%s\\n' \$! >'$tar_pid'"
  monitor_runtime_job shamu "$tar_status" "$tar_pid" runtime-save
  require_eq "runtime image save" "EXIT=0" "$(ssh shamu "cat '$tar_status'")"
fi
tar_sha="$(ssh shamu "sha256sum '$image_tar' | awk '{print \$1}'")"
[[ "$tar_sha" =~ ^[0-9a-f]{64}$ ]] || die "invalid saved-image checksum"
printf '%s  %s\n' "$tar_sha" "$(basename "$image_tar")" \
  >"$evidence_dir/image-tar.sha256"
chmod 0600 "$evidence_dir/image-tar.sha256"

tilikum_dir="/home/alecfong/deepseek-v41/runtime/$change_id"
ssh tilikum "umask 077; mkdir -p '$tilikum_dir'"
tilikum_tar="$tilikum_dir/$(basename "$image_tar")"
if ssh tilikum test -f "$tilikum_tar"; then
  existing_tilikum_sha="$(ssh tilikum "sha256sum '$tilikum_tar' | awk '{print \$1}'")"
  require_eq "existing Tilikum image archive" "$tar_sha" "$existing_tilikum_sha"
else
  copy_status="$remote_root/copy.status"
  copy_log="$remote_root/copy.log"
  copy_pid="$remote_root/copy.pid"
  ssh shamu "rm -f '$copy_status'; nohup setsid bash -c 'set -o pipefail; \
    rsync --archive --checksum --bwlimit=250000 \"$image_tar\" \"10.10.1.2:$tilikum_dir/\"; \
    s=\$?; printf \"EXIT=%s\\n\" \"\$s\" >\"$copy_status\"; exit \"\$s\"' \
    >'$copy_log' 2>&1 </dev/null & printf '%s\\n' \$! >'$copy_pid'"
  monitor_runtime_job shamu "$copy_status" "$copy_pid" runtime-copy
  require_eq "runtime image copy" "EXIT=0" "$(ssh shamu "cat '$copy_status'")"
fi
tilikum_sha="$(ssh tilikum "sha256sum '$tilikum_dir/$(basename "$image_tar")' | awk '{print \$1}'")"
require_eq "saved-image transfer checksum" "$tar_sha" "$tilikum_sha"
load_status="$tilikum_dir/load.status"
load_log="$tilikum_dir/load.log"
load_pid="$tilikum_dir/load.pid"
ssh tilikum "rm -f '$load_status'; nohup setsid bash -c 'set -o pipefail; \
  sudo -n docker image load --input \"$tilikum_tar\" >/dev/null; \
  s=\$?; printf \"EXIT=%s\\n\" \"\$s\" >\"$load_status\"; exit \"\$s\"' \
  >'$load_log' 2>&1 </dev/null & printf '%s\\n' \$! >'$load_pid'"
monitor_runtime_job tilikum "$load_status" "$load_pid" runtime-load
require_eq "runtime image load" "EXIT=0" "$(ssh tilikum "cat '$load_status'")"
tilikum_image_id="$(ssh tilikum "sudo -n docker image inspect '$runtime_tag' --format '{{.Id}}'")"
internal_commit_tilikum="$(ssh tilikum "sudo -n docker image inspect '$runtime_tag' --format '{{index .Config.Labels \"ai.webster.vllm.commit\"}}'")"

help_visible_devices="void"
help_target_device="cpu"
help_selector="engram-config"
validate_help_probe "$help_visible_devices" "$help_target_device" "$help_selector"
help_text="$(ssh shamu "docker run --rm --runtime runc --network none \
  --env NVIDIA_VISIBLE_DEVICES='$help_visible_devices' \
  --env VLLM_TARGET_DEVICE='$help_target_device' \
  --entrypoint vllm '$image_id' serve --help='$help_selector' 2>&1")"
registry_text="$(ssh shamu "docker run --rm --runtime runc --network none \
  --env NVIDIA_VISIBLE_DEVICES=void \
  --volume '$remote_registry_probe:/opt/webster/verify-runtime-registry.py:ro' \
  --entrypoint python3 '$image_id' /opt/webster/verify-runtime-registry.py \
  --require-model DeepseekV41ForCausalLM")"
config_file="$evidence_dir/checkpoint-config.json"
python3 - "$CHECKPOINT_REPO" "$CHECKPOINT_REVISION" "$config_file" <<'PY'
import json
import os
import sys
import urllib.parse
import urllib.request

repository, revision, output = sys.argv[1:]
url = (
    "https://huggingface.co/"
    + repository
    + "/resolve/"
    + urllib.parse.quote(revision, safe="")
    + "/config.json"
)
request = urllib.request.Request(url, headers={"User-Agent": "webster-runtime-gate"})
with urllib.request.urlopen(request, timeout=60) as response:
    payload = json.load(response)
temporary = output + f".tmp.{os.getpid()}"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, indent=2, sort_keys=True)
    stream.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, output)
PY
engram_layers="$(python3 - "$config_file" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
layers = payload.get("text_config", payload).get("engram_layer_ids")
if not isinstance(layers, list) or not layers:
    raise SystemExit("checkpoint has no engram_layer_ids")
print(",".join(str(layer) for layer in layers))
PY
)"

validate_runtime_gate arm64 linux/arm64 linux/arm64 1 \
  "$image_id"$'\n'"$tilikum_image_id" \
  "$internal_commit_shamu"$'\n'"$internal_commit_tilikum" \
  "$help_text" "$registry_text" "$engram_layers"

set_manifest_value VLLM_IMAGE_ID "$image_id"
set_manifest_value VLLM_IMAGE_TAR_SHA256 "$tar_sha"
event runtime-package GO \
  "arm64 image=$image_id source=$vllm_commit engram baseline verified"
printf 'GO runtime-package image=%s\n' "$image_id"
