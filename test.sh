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

# webshell: verify_session_restore must fail when the restore plugins are
# missing. Sourced in a subshell against a scratch HOME (a copy of the real
# tmux.conf but no plugins installed), so the real HOME and any live tmux
# saves are never touched; scratch tmux servers run on their own sockets and
# are killed by the function itself. Needs tmux, which the bootstrap installs
# before CI runs this; skip locally where it is absent.
if command -v tmux >/dev/null 2>&1; then
  mkdir -p "$scratch/wshome"
  cp webshell/tmux.conf "$scratch/wshome/.tmux.conf"
  if (
    export HOME="$scratch/wshome" SETUP_SKIP_MAIN=1
    source ./webshell/install.sh
    verify_session_restore
  ) >/dev/null 2>&1; then
    echo "FAIL: verify_session_restore unexpectedly passed without plugins" >&2
    exit 1
  fi
else
  echo "skip: tmux not available; webshell restore negative test not run" >&2
fi

log "all negative tests passed"
