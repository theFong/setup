#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
webster_source="${WEBSTER_CLUSTER_SOURCE:-$HOME/.claude/skills/webster-cluster}"
migration_source="${WEBSTER_MIGRATION_SOURCE:-$repo_root/.agent/skills/migrating-webster-models}"
check_only=0
force=0
while (( $# )); do
  case "$1" in
    --check) check_only=1; shift ;;
    --force) force=1; shift ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

skills=(webster-cluster migrating-webster-models)
canonical_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).resolve(strict=False))
PY
}

skill_source() {
  case "$1" in
    webster-cluster) printf '%s\n' "$webster_source" ;;
    migrating-webster-models) printf '%s\n' "$migration_source" ;;
    *) printf 'ERROR: unsupported skill: %s\n' "$1" >&2; return 1 ;;
  esac
}
for skill in "${skills[@]}"; do
  source="$(skill_source "$skill")"
  [[ -f "$source/SKILL.md" ]] || {
    printf 'ERROR: source skill missing: %s (%s)\n' "$skill" "$source" >&2
    exit 1
  }
done

render_hermes() {
  local skill="$1" source="$2" output="$3"
  mkdir -p "$output/$skill"
  rsync -a --delete "$source/" "$output/$skill/"
  python3 - "$skill" "$output/$skill/SKILL.md" <<'PY'
import re
import sys
from pathlib import Path

name, raw_path = sys.argv[1:]
path = Path(raw_path)
text = path.read_text(encoding="utf-8")
match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
if not match:
    raise SystemExit("source skill has no frontmatter")
description_match = re.search(r"^description:\s*(.*)$", match.group(1), re.M)
if not description_match:
    raise SystemExit("source skill has no description")
description = description_match.group(1).strip()
tags = (
    "[webster, cluster, gpu, netbird, litellm, prometheus, grafana, monitoring]"
    if name == "webster-cluster"
    else "[webster, migration, gpu, vllm, litellm, aiperf, rollback]"
)
header = f"""---
name: {name}
description: {description}
version: 1.0.0
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    category: devops
    tags: {tags}
---
"""
path.write_text(header + text[match.end():], encoding="utf-8")
PY
}

sync_local() {
  local destination="$1" skill source destination_path
  for skill in "${skills[@]}"; do
    source="$(skill_source "$skill")"
    destination_path="$destination/$skill"
    if [[ "$(canonical_path "$destination_path")" == "$(canonical_path "$source")" ]]; then
      continue
    fi
    if [[ -L "$destination_path" ]]; then
      verify_tree "$source" "$destination_path" "existing $skill symlink" || {
        printf 'ERROR: refusing to overwrite divergent skill symlink: %s\n' \
          "$destination_path" >&2
        return 1
      }
      continue
    fi
    if [[ -e "$destination_path" ]] &&
      ! diff -qr "$source" "$destination_path" >/dev/null; then
      if (( ! force )); then
        printf 'ERROR: refusing to overwrite divergent skill directory: %s\n' \
          "$destination_path" >&2
        return 1
      fi
    fi
    mkdir -p "$destination_path"
    rsync -a --delete "$source/" "$destination_path/"
  done
}

verify_tree() {
  local expected="$1" actual="$2" label="$3"
  diff -qr "$expected" "$actual" >/dev/null || {
    printf 'ERROR: %s skill tree drifted\n' "$label" >&2
    return 1
  }
}

verify_hermes_skills() {
  local listing skill
  listing="$(env -u SSH_AUTH_SOCK ssh "$remote_host" \
    'export PATH=$HOME/.local/bin:$PATH; COLUMNS=240 hermes skills list --source local 2>/dev/null')"
  for skill in "${skills[@]}"; do
    grep -Fq "$skill" <<<"$listing" || {
      printf 'ERROR: Hermes does not list skill: %s\n' "$skill" >&2
      return 1
    }
  done
}

verify_remote_hermes_tree() {
  local expected="$1" skill="$2" changes
  changes="$(env -u SSH_AUTH_SOCK rsync -rlnic --delete \
    --out-format='%i %n%L' -e ssh \
    "$expected/$skill/" "$remote_host:$remote_root/$skill/")" || return 1
  [[ -z "$changes" ]] || {
    printf 'ERROR: Hermes %s content drifted:\n%s\n' "$skill" "$changes" >&2
    return 1
  }
}

if [[ "${WEBSTER_SYNC_TEST_MODE:-0}" == "1" ]]; then
  claude_root="${TEST_SYNC_CLAUDE_ROOT:?TEST_SYNC_CLAUDE_ROOT is required}"
  codex_root="${TEST_SYNC_CODEX_ROOT:?TEST_SYNC_CODEX_ROOT is required}"
  hermes_root="${TEST_SYNC_HERMES_ROOT:?TEST_SYNC_HERMES_ROOT is required}"
  state_file="${TEST_SYNC_STATE_FILE:?TEST_SYNC_STATE_FILE is required}"
  expected_hermes="$(mktemp -d)"
  trap 'rm -rf "$expected_hermes"' EXIT
  for skill in "${skills[@]}"; do
    render_hermes "$skill" "$(skill_source "$skill")" "$expected_hermes"
  done
  if (( check_only )); then
    for skill in "${skills[@]}"; do
      source="$(skill_source "$skill")"
      verify_tree "$source" "$claude_root/$skill" "Claude $skill"
      verify_tree "$source" "$codex_root/$skill" "Codex $skill"
      verify_tree "$expected_hermes/$skill" "$hermes_root/$skill" "Hermes $skill"
    done
    printf 'skill mirrors verified\n'
    exit 0
  fi
  sync_local "$claude_root"
  sync_local "$codex_root"
  mkdir -p "$hermes_root"
  for skill in "${skills[@]}"; do
    if [[ -e "$hermes_root/$skill" ]] &&
      ! diff -qr "$expected_hermes/$skill" "$hermes_root/$skill" >/dev/null; then
      if (( ! force )); then
        printf 'ERROR: refusing to overwrite divergent Hermes skill directory: %s\n' \
          "$hermes_root/$skill" >&2
        exit 1
      fi
    fi
    mkdir -p "$hermes_root/$skill"
    rsync -a --delete "$expected_hermes/$skill/" "$hermes_root/$skill/"
  done
  mkdir -p "$(dirname "$state_file")"
  sha256sum "$webster_source/SKILL.md" "$migration_source/SKILL.md" >"$state_file"
  printf 'skill mirrors synchronized in test mode\n'
  exit 0
fi

claude_root="$HOME/.claude/skills"
codex_root="$HOME/.codex/skills"
remote_host="ops-bot"
remote_root="/home/ubuntu/.hermes/skills/devops"
drift_check="$HOME/ops-bot/check-skill-drift.sh"
existing_sync="$HOME/ops-bot/sync-skills.sh"
state_dir="$HOME/ops-bot/.skill-push-hashes.d"
migration_state="$state_dir/migrating-webster-models"
expected_hermes="$(mktemp -d)"
trap 'rm -rf "$expected_hermes"' EXIT
for skill in "${skills[@]}"; do
  render_hermes "$skill" "$(skill_source "$skill")" "$expected_hermes"
done

[[ -x "$drift_check" && -x "$existing_sync" ]] || {
  printf 'ERROR: existing Webster drift/sync controls are missing\n' >&2
  exit 1
}
if (( ! force )); then
  env -u SSH_AUTH_SOCK "$drift_check"
  remote_hash="$(env -u SSH_AUTH_SOCK ssh "$remote_host" \
    "if test -f '$remote_root/migrating-webster-models/SKILL.md'; then awk 'BEGIN{n=0} /^---\$/{n++; if(n<=2) next} n>=2' '$remote_root/migrating-webster-models/SKILL.md' | sha256sum | awk '{print \$1}'; fi" 2>/dev/null || true)"
  if [[ -f "$migration_state" && -n "$remote_hash" ]]; then
    require_hash="$(<"$migration_state")"
    [[ "$remote_hash" == "$require_hash" ]] || {
      printf 'ERROR: remote migrating-webster-models changed since the last push\n' >&2
      exit 2
    }
  elif [[ -n "$remote_hash" ]]; then
    local_hash="$(awk 'BEGIN{n=0} /^---$/{n++; if(n<=2) next} n>=2' \
      "$migration_source/SKILL.md" | sha256sum | awk '{print $1}')"
    [[ "$remote_hash" == "$local_hash" ]] || {
      printf 'ERROR: untracked remote migrating-webster-models differs from source\n' >&2
      exit 2
    }
  fi
fi

if (( check_only )); then
  for skill in "${skills[@]}"; do
    source="$(skill_source "$skill")"
    verify_tree "$source" "$claude_root/$skill" "Claude $skill"
    verify_tree "$source" "$codex_root/$skill" "Codex $skill"
  done
  for skill in "${skills[@]}"; do
    verify_remote_hermes_tree "$expected_hermes" "$skill"
  done
  verify_hermes_skills
  printf 'live skill mirrors verified\n'
  exit 0
fi

sync_local "$claude_root"
if (( force )); then
  env -u SSH_AUTH_SOCK "$existing_sync" --force
else
  env -u SSH_AUTH_SOCK "$existing_sync"
fi
sync_local "$codex_root"

if (( ! force )) && env -u SSH_AUTH_SOCK ssh "$remote_host" \
  "test -d '$remote_root/migrating-webster-models'"; then
  verify_remote_hermes_tree "$expected_hermes" migrating-webster-models
fi
env -u SSH_AUTH_SOCK ssh "$remote_host" \
  "mkdir -p '$remote_root/migrating-webster-models'"
env -u SSH_AUTH_SOCK rsync -a --delete -e ssh \
  "$expected_hermes/migrating-webster-models/" \
  "$remote_host:$remote_root/migrating-webster-models/"
for skill in "${skills[@]}"; do
  verify_remote_hermes_tree "$expected_hermes" "$skill"
done
verify_hermes_skills
mkdir -p "$state_dir"
env -u SSH_AUTH_SOCK ssh "$remote_host" \
  "awk 'BEGIN{n=0} /^---\$/{n++; if(n<=2) next} n>=2' '$remote_root/migrating-webster-models/SKILL.md' | sha256sum | awk '{print \$1}'" \
  >"$migration_state"
printf 'live Webster runbooks synchronized\n'
