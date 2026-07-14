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

# configure_codex must insert its keys above existing [table] headers (TOML
# reads keys after a header as belonging to that table), preserve same-named
# keys inside tables, and produce identical output when re-run. A fresh
# bootstrap only exercises the no-existing-config path, so the merge behavior
# is covered here.
mkdir -p "$scratch/home/.codex"
printf '# existing config\n[projects."/tmp"]\ntrust_level = "trusted"\napproval_policy = "never"\n' \
  > "$scratch/home/.codex/config.toml"
if ! (export HOME="$scratch/home"; configure_codex) >/dev/null 2>&1; then
  echo "FAIL: configure_codex failed on a config with existing tables" >&2
  exit 1
fi
if [ "$(head -n 2 "$scratch/home/.codex/config.toml")" != 'approval_policy = "on-request"
sandbox_mode = "workspace-write"' ]; then
  echo "FAIL: configure_codex did not place its keys above existing tables" >&2
  exit 1
fi
if ! grep -q 'approval_policy = "never"' "$scratch/home/.codex/config.toml"; then
  echo "FAIL: configure_codex removed a same-named key inside a table" >&2
  exit 1
fi
first_pass=$(cat "$scratch/home/.codex/config.toml")
if ! (export HOME="$scratch/home"; configure_codex) >/dev/null 2>&1; then
  echo "FAIL: configure_codex failed on re-run" >&2
  exit 1
fi
if [ "$(cat "$scratch/home/.codex/config.toml")" != "$first_pass" ]; then
  echo "FAIL: configure_codex is not idempotent across re-runs" >&2
  exit 1
fi

# assert_codex_mode must reject keys that only appear inside a table: Codex
# would not read them as its top-level approval settings.
printf '[profiles.x]\napproval_policy = "on-request"\nsandbox_mode = "workspace-write"\n' \
  > "$scratch/codex-table-scoped.toml"
if assert_codex_mode "$scratch/codex-table-scoped.toml" "on-request" "workspace-write" >/dev/null 2>&1; then
  echo "FAIL: assert_codex_mode accepted keys scoped inside a table" >&2
  exit 1
fi

log "all negative tests passed"
