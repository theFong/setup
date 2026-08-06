#!/usr/bin/env bash
#
# test.sh — isolated negative tests for install.sh: prove failure paths return
# nonzero without running the full bootstrap. Success paths are validated by
# install.sh itself on every run (assert_installed / assert_* helpers, see
# STYLE_GUIDE.md); this script covers only what a passing bootstrap cannot
# exercise. CI runs it, and it is safe to run locally — everything happens in
# scratch directories and the real $HOME is never touched.

set -euo pipefail
cd "$(dirname "$0")"

export SETUP_SKIP_MAIN=1
source ./install.sh

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# assert_installed must fail for a missing command, and summary must then
# return nonzero rather than reporting a clean bootstrap.
FAILED=""
if assert_installed "missing test tool" setup-test-tool-does-not-exist; then
  echo "FAIL: missing tool assertion unexpectedly succeeded" >&2
  exit 1
fi
if summary >/dev/null 2>&1; then
  echo "FAIL: summary unexpectedly returned zero after a failed assertion" >&2
  exit 1
fi

# configure_claude must fail on an unparseable settings file and leave it
# untouched rather than clobbering it.
mkdir -p "$scratch/home/.claude"
printf 'not json\n' > "$scratch/home/.claude/settings.json"
if (export HOME="$scratch/home"; configure_claude) >/dev/null 2>&1; then
  echo "FAIL: configure_claude unexpectedly succeeded on invalid JSON" >&2
  exit 1
fi
if [ "$(cat "$scratch/home/.claude/settings.json")" != "not json" ]; then
  echo "FAIL: configure_claude clobbered an unparseable settings file" >&2
  exit 1
fi

# link_agent_skill must fail (not silently succeed) when the skill source is
# absent, and assert_skill_linked must fail on a broken symlink rather than
# reporting a healthy install.
FAILED=""
if (export HOME="$scratch/home"; link_agent_skill setup-test-skill-does-not-exist) >/dev/null 2>&1; then
  echo "FAIL: link_agent_skill unexpectedly succeeded for a missing skill source" >&2
  exit 1
fi

mkdir -p "$scratch/home/.claude/skills" "$scratch/home/.codex/skills" "$scratch/home/.agents/skills"
ln -s "$scratch/nonexistent-skill-target" "$scratch/home/.claude/skills/broken-skill"
FAILED=""
if (export HOME="$scratch/home"; assert_skill_linked broken-skill) >/dev/null 2>&1; then
  echo "FAIL: assert_skill_linked unexpectedly succeeded on a broken symlink" >&2
  exit 1
fi

# Every repo-managed skill must carry a SKILL.md with name/description
# frontmatter, or agents cannot discover it.
for skill_dir in .agent/skills/*/; do
  skill_md="$skill_dir/SKILL.md"
  if [ ! -f "$skill_md" ]; then
    echo "FAIL: $skill_dir has no SKILL.md" >&2
    exit 1
  fi
  if ! head -1 "$skill_md" | grep -q '^---$'; then
    echo "FAIL: $skill_md does not start with YAML frontmatter" >&2
    exit 1
  fi
  for field in name description; do
    if ! sed -n '2,/^---$/p' "$skill_md" | grep -q "^$field:"; then
      echo "FAIL: $skill_md frontmatter is missing '$field'" >&2
      exit 1
    fi
  done
done

log "all negative tests passed"
