#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "$script_dir/.." && pwd)"
source "$script_dir/common.sh"

candidate=0
run_root=""
candidate_config=""
while (($#)); do
  case "$1" in
    --candidate)
      candidate=1
      shift
      ;;
    --run-root)
      [[ $# -ge 2 ]] || die "--run-root requires a value"
      run_root="$2"
      shift 2
      ;;
    --candidate-config)
      [[ $# -ge 2 ]] || die "--candidate-config requires a value"
      candidate_config="$2"
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$candidate" == "1" ]] || die "--candidate is required"
validated_root="$(validate_run_root "$run_root")"
init_run_root "$validated_root"
[[ -f "$candidate_config" && ! -L "$candidate_config" ]] ||
  die "candidate config must be a regular file"
[[ "$(stat -c %a "$candidate_config")" == "600" ]] ||
  die "candidate config mode must be 0600"

module_source="${TEST_GUARD_SOURCE:-$package_dir/litellm/glm52_contract_guard.py}"
test_source="$package_dir/litellm/test_glm52_contract_guard.py"
fixture_source="$package_dir/tests/fixtures"
tokenizer_source="${TEST_TOKENIZER_SOURCE:-$RUN_ROOT/baseline/glm52-tokenizer}"
[[ -f "$module_source" && ! -L "$module_source" ]] || die "guard module is missing"
for name in tokenizer.json tokenizer_config.json chat_template.jinja; do
  [[ -f "$tokenizer_source/$name" && ! -L "$tokenizer_source/$name" ]] ||
    die "legacy tokenizer asset is missing: $name"
done

backup_suffix="$(date -u +%Y%m%dT%H%M%SZ)-$$"

promote_local_file() {
  local source_path="$1" final_path="$2" temporary_path
  mkdir -p "$(dirname "$final_path")"
  if [[ -f "$final_path" ]] && cmp -s "$source_path" "$final_path"; then
    chmod 0644 "$final_path"
    return
  fi
  if [[ -e "$final_path" ]]; then
    mv -- "$final_path" "$final_path.bak-$backup_suffix"
  fi
  temporary_path="$final_path.tmp-$backup_suffix"
  install -m 0644 "$source_path" "$temporary_path"
  mv -- "$temporary_path" "$final_path"
}

promote_local_tokenizer() {
  local source_path="$1" final_path="$2" temporary_path source_manifest live_manifest
  source_manifest="$(mktemp)"
  live_manifest="$(mktemp)"
  (
    cd "$source_path"
    sha256sum tokenizer.json tokenizer_config.json chat_template.jinja | sort
  ) >"$source_manifest"
  if [[ -d "$final_path" ]]; then
    (
      cd "$final_path"
      sha256sum tokenizer.json tokenizer_config.json chat_template.jinja | sort
    ) >"$live_manifest" 2>/dev/null || true
    if cmp -s "$source_manifest" "$live_manifest"; then
      chmod 0444 "$final_path/tokenizer.json" \
        "$final_path/tokenizer_config.json" "$final_path/chat_template.jinja"
      chmod 0555 "$final_path"
      rm -f -- "$source_manifest" "$live_manifest"
      return
    fi
    mv -- "$final_path" "$final_path.bak-$backup_suffix"
  elif [[ -e "$final_path" ]]; then
    mv -- "$final_path" "$final_path.bak-$backup_suffix"
  fi
  temporary_path="$final_path.tmp-$backup_suffix"
  mkdir -m 0755 "$temporary_path"
  for name in tokenizer.json tokenizer_config.json chat_template.jinja; do
    install -m 0444 "$source_path/$name" "$temporary_path/$name"
  done
  chmod 0555 "$temporary_path"
  mv -- "$temporary_path" "$final_path"
  rm -f -- "$source_manifest" "$live_manifest"
}

if [[ "${WEBSTER_LITELLM_TEST_MODE:-0}" == "1" ]]; then
  test_root="${TEST_LITELLM_ROOT:?TEST_LITELLM_ROOT is required in test mode}"
  promote_local_file "$module_source" "$test_root/glm52_contract_guard.py"
  promote_local_tokenizer "$tokenizer_source" "$test_root/glm52-tokenizer"
  printf 'guard candidate installed in test root\n'
  exit 0
fi

change_id="$(basename "$RUN_ROOT")"
remote_parent="/home/nvidia/litellm/energy-pricing"
remote_module="$remote_parent/glm52_contract_guard.py"
remote_tokenizer="$remote_parent/glm52-tokenizer"
remote_stage="$remote_parent/.glm52-guard-stage-$change_id-$backup_suffix"
remote_offline="$remote_parent/.glm52-guard-offline-$change_id-$backup_suffix"

cleanup_remote_candidates() {
  local original_status=$?
  trap - EXIT
  if ! ssh spark-1 "set -eu
parent='$remote_parent'
for path in '$remote_stage' '$remote_offline'; do
  case \"\$path\" in
    \"\$parent\"/.glm52-guard-stage-*|\"\$parent\"/.glm52-guard-offline-*) ;;
    *) exit 1 ;;
  esac
  if test -e \"\$path\"; then
    resolved=\$(realpath -e -- \"\$path\")
    case \"\$resolved\" in
      \"\$parent\"/.glm52-guard-stage-*|\"\$parent\"/.glm52-guard-offline-*) ;;
      *) exit 1 ;;
    esac
    chmod -R u+w -- \"\$resolved\"
    rm -rf -- \"\$resolved\"
  fi
done"; then
    printf 'ERROR: failed to remove remote guard candidate paths\n' >&2
    [[ "$original_status" != "0" ]] || original_status=1
  fi
  exit "$original_status"
}
trap cleanup_remote_candidates EXIT

local_module_hash="$(sha256sum "$module_source" | awk '{print $1}')"
local_tokenizer_manifest="$RUN_ROOT/baseline/glm52-tokenizer.install.manifest"
(
  cd "$tokenizer_source"
  sha256sum tokenizer.json tokenizer_config.json chat_template.jinja | sort
) >"$local_tokenizer_manifest"
chmod 0600 "$local_tokenizer_manifest"

ssh spark-1 "set -eu; umask 077; test ! -e '$remote_stage'; mkdir -p '$remote_stage/tokenizer'"
scp "$module_source" "spark-1:$remote_stage/glm52_contract_guard.py"
tar -C "$tokenizer_source" -cf - tokenizer.json tokenizer_config.json chat_template.jinja |
  ssh spark-1 "tar -C '$remote_stage/tokenizer' -xf -"
remote_module_hash="$(ssh spark-1 "sha256sum '$remote_stage/glm52_contract_guard.py' | awk '{print \$1}'")"
require_eq "guard module transfer hash" "$local_module_hash" "$remote_module_hash"
ssh spark-1 "cd '$remote_stage/tokenizer' && sha256sum tokenizer.json tokenizer_config.json chat_template.jinja | sort" \
  >"$RUN_ROOT/baseline/glm52-tokenizer.install.remote.manifest"
cmp "$local_tokenizer_manifest" "$RUN_ROOT/baseline/glm52-tokenizer.install.remote.manifest" ||
  die "legacy tokenizer transfer hash mismatch"

ssh spark-1 "set -eu
backup_suffix='$backup_suffix'
if test -f '$remote_module'; then
  live_hash=\$(sha256sum '$remote_module' | awk '{print \$1}')
  if test \"\$live_hash\" != '$local_module_hash'; then
    mv '$remote_module' '$remote_module.bak-$backup_suffix'
  fi
fi
if ! test -f '$remote_module' || test \"\$(sha256sum '$remote_module' | awk '{print \$1}')\" != '$local_module_hash'; then
  install -m 0644 '$remote_stage/glm52_contract_guard.py' '$remote_module.tmp-$backup_suffix'
  mv '$remote_module.tmp-$backup_suffix' '$remote_module'
fi
if test -d '$remote_tokenizer'; then
  cd '$remote_tokenizer'
  sha256sum tokenizer.json tokenizer_config.json chat_template.jinja | sort >'/tmp/glm52-live-$backup_suffix.manifest'
  cd '$remote_stage/tokenizer'
  sha256sum tokenizer.json tokenizer_config.json chat_template.jinja | sort >'/tmp/glm52-new-$backup_suffix.manifest'
  if ! cmp -s '/tmp/glm52-live-$backup_suffix.manifest' '/tmp/glm52-new-$backup_suffix.manifest'; then
    mv '$remote_tokenizer' '$remote_tokenizer.bak-$backup_suffix'
  fi
elif test -e '$remote_tokenizer'; then
  mv '$remote_tokenizer' '$remote_tokenizer.bak-$backup_suffix'
fi
if ! test -d '$remote_tokenizer'; then
  mv '$remote_stage/tokenizer' '$remote_tokenizer'
fi
chmod 0644 '$remote_module'
chmod 0444 '$remote_tokenizer/tokenizer.json' '$remote_tokenizer/tokenizer_config.json' '$remote_tokenizer/chat_template.jinja'
chmod 0555 '$remote_tokenizer'
rm -f '/tmp/glm52-live-$backup_suffix.manifest' '/tmp/glm52-new-$backup_suffix.manifest'
rm -rf '$remote_stage'
test \"\$(sha256sum '$remote_module' | awk '{print \$1}')\" = '$local_module_hash'
test \"\$(stat -c %a:%U '$remote_module')\" = 644:nvidia
test \"\$(stat -c %a:%U '$remote_tokenizer')\" = 555:nvidia
for path in '$remote_tokenizer/tokenizer.json' '$remote_tokenizer/tokenizer_config.json' '$remote_tokenizer/chat_template.jinja'; do
  test \"\$(stat -c %a:%U \"\$path\")\" = 444:nvidia
done"

ssh spark-1 "set -eu; test ! -e '$remote_offline'; mkdir -p '$remote_offline/litellm' '$remote_offline/tests/fixtures'"
scp "$test_source" "spark-1:$remote_offline/litellm/test_glm52_contract_guard.py"
scp "$candidate_config" "spark-1:$remote_offline/config.yaml"
scp "$fixture_source/chat.json" "$fixture_source/reasoning-none.json" \
  "$fixture_source/tools.json" "$fixture_source/tool-result.json" \
  "$fixture_source/structured.json" "$fixture_source/tokenize-golden.json" \
  "spark-1:$remote_offline/tests/fixtures/"
ssh spark-1 "cp '$remote_module' '$remote_offline/litellm/glm52_contract_guard.py'; chmod -R a-w '$remote_offline'"

ssh spark-1 "set -euo pipefail
image_id=\$(docker inspect litellm --format '{{.Image}}')
docker run --rm --network none --entrypoint python \
  -e LITELLM_LOCAL_MODEL_COST_MAP=true \
  -v '$remote_parent:/app/custom_callbacks:ro' \
  -v '$remote_offline:/work:ro' \
  -w /app \
  \"\$image_id\" -c \"import importlib, yaml; from litellm.integrations.custom_logger import CustomLogger; guard='custom_callbacks.glm52_contract_guard.glm52_contract_guard'; data=yaml.safe_load(open('/work/config.yaml')); callbacks=data.get('litellm_settings',{}).get('callbacks',[]); assert callbacks and callbacks[0] == guard; custom=[item for item in callbacks if isinstance(item,str) and item.startswith('custom_callbacks.')]; assert custom; [(_ for _ in ()).throw(AssertionError(item)) if not isinstance(getattr(importlib.import_module(item.rsplit('.',1)[0]),item.rsplit('.',1)[1]),CustomLogger) else None for item in custom]\"
docker run --rm --network none --entrypoint python \
  -e GLM52_TOKENIZER_DIR=/app/custom_callbacks/glm52-tokenizer \
  -e LITELLM_LOCAL_MODEL_COST_MAP=true \
  -v '$remote_parent:/app/custom_callbacks:ro' \
  -v '$remote_offline:/work:ro' \
  -w /work/litellm \
  \"\$image_id\" test_glm52_contract_guard.py"

event "alias-guard" GO "candidate guard and tokenizer installed; exact-image offline checks passed"
printf 'guard candidate installed and validated offline\n'
