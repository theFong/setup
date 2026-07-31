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

# configure_claude_statusline must fail when the repo-managed status line
# script is missing, and must not write a statusLine key pointing at it.
mkdir -p "$scratch/nostatusline/.claude"
printf '{}\n' > "$scratch/nostatusline/.claude/settings.json"
if (export HOME="$scratch/nostatusline"; configure_claude_statusline) >/dev/null 2>&1; then
  echo "FAIL: configure_claude_statusline unexpectedly succeeded without its script" >&2
  exit 1
fi
if jq -e 'has("statusLine")' "$scratch/nostatusline/.claude/settings.json" >/dev/null 2>&1; then
  echo "FAIL: configure_claude_statusline wired up a missing script" >&2
  exit 1
fi

# assert_claude_statusline must fail when settings.json does not reference the
# script, and when the script exists but renders nothing usable.
mkdir -p "$scratch/statusline"
printf '{}\n' > "$scratch/statusline/settings.json"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "$scratch/statusline/statusline.sh"
chmod +x "$scratch/statusline/statusline.sh"
if assert_claude_statusline "$scratch/statusline/settings.json" "$scratch/statusline/statusline.sh" >/dev/null 2>&1; then
  echo "FAIL: assert_claude_statusline passed with no statusLine in settings" >&2
  exit 1
fi
jq --arg c "$scratch/statusline/statusline.sh" \
  '.statusLine = {type: "command", command: $c}' \
  "$scratch/statusline/settings.json" > "$scratch/statusline/settings.next"
mv "$scratch/statusline/settings.next" "$scratch/statusline/settings.json"
if assert_claude_statusline "$scratch/statusline/settings.json" "$scratch/statusline/statusline.sh" >/dev/null 2>&1; then
  echo "FAIL: assert_claude_statusline passed for a script that renders nothing" >&2
  exit 1
fi

# The real status line script must render the sample payload, and must stay
# quiet (rather than erroring into the prompt) on input jq cannot parse.
real_statusline="$(dirname "$0")/claude/statusline.sh"
if ! printf '%s' "$STATUSLINE_SAMPLE" | "$real_statusline" | grep -q 'ctx 25%'; then
  echo "FAIL: claude/statusline.sh did not render context usage for the sample payload" >&2
  exit 1
fi
if [ -n "$(printf 'not json' | "$real_statusline" 2>&1)" ]; then
  echo "FAIL: claude/statusline.sh emitted output for unparseable input" >&2
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

# webshell mode adoption and the deployed-mode assertion, exercised against a
# scratch unit file (WEBSHELL_UNIT) so they need no root, no systemd, and no
# installed webshell — the regression here once locked every client out of a
# proxy-fronted box, and it is not reachable from a passing bootstrap.
ws_unit="$scratch/ttyd.service"
printf '[Service]\nExecStart=/usr/local/bin/ttyd --interface eth0 --port 9999 --writable tmux new -A -s main\nKillMode=process\n' \
  > "$ws_unit"

# A flagless re-run must keep the installed public mode, interface, and port.
adopted=$(
  export WEBSHELL_UNIT="$ws_unit" SETUP_SKIP_MAIN=1
  source ./webshell/install.sh
  adopt_installed_mode >/dev/null
  printf '%s %s %s' "$MODE" "$IFACE" "$PORT"
)
if [ "$adopted" != "public eth0 9999" ]; then
  echo "FAIL: flagless re-run did not adopt the installed mode (got '$adopted')" >&2
  exit 1
fi

# An explicit mode must still win over the installed one.
adopted=$(
  export WEBSHELL_UNIT="$ws_unit" WEBSHELL_MODE=private SETUP_SKIP_MAIN=1
  source ./webshell/install.sh
  adopt_installed_mode >/dev/null
  printf '%s' "$MODE"
)
if [ "$adopted" != "private" ]; then
  echo "FAIL: explicit --private did not override the installed public mode (got '$adopted')" >&2
  exit 1
fi

# assert_deployed_mode must reject a unit that does not match the intended
# mode: public-but-credentialed (still bound private) and private-but-not.
if (
  export WEBSHELL_UNIT="$ws_unit" SETUP_SKIP_MAIN=1
  source ./webshell/install.sh
  MODE="private"; PORT=9999
  assert_deployed_mode
) >/dev/null 2>&1; then
  echo "FAIL: assert_deployed_mode accepted a public unit while in private mode" >&2
  exit 1
fi
printf '[Service]\nExecStart=/usr/local/bin/ttyd --interface 127.0.0.1 --credential u:p --port 9999 --writable tmux new -A -s main\n' \
  > "$scratch/ttyd-private.service"
if (
  export WEBSHELL_UNIT="$scratch/ttyd-private.service" SETUP_SKIP_MAIN=1
  source ./webshell/install.sh
  MODE="public"; IFACE="127.0.0.1"; PORT=9999
  assert_deployed_mode
) >/dev/null 2>&1; then
  # Interface deliberately matches, so only the leftover --credential can fail
  # this — otherwise the check would pass for the wrong reason.
  echo "FAIL: assert_deployed_mode accepted a leftover credential in public mode" >&2
  exit 1
fi

# ...a unit bound to a different interface than this run intends (everything
# else matches, so only the interface check can fail this).
if (
  export WEBSHELL_UNIT="$ws_unit" SETUP_SKIP_MAIN=1
  source ./webshell/install.sh
  MODE="public"; IFACE="wt0"; PORT=9999
  assert_deployed_mode
) >/dev/null 2>&1; then
  echo "FAIL: assert_deployed_mode accepted a unit bound to the wrong interface" >&2
  exit 1
fi

# ...and a unit serving a different port than this run intends.
if (
  export WEBSHELL_UNIT="$ws_unit" SETUP_SKIP_MAIN=1
  source ./webshell/install.sh
  MODE="public"; IFACE="eth0"; PORT=7681
  assert_deployed_mode
) >/dev/null 2>&1; then
  echo "FAIL: assert_deployed_mode accepted a unit serving the wrong port" >&2
  exit 1
fi

# webshell: tmux-groups must fail loudly when misused instead of opening a
# menu with missing context. These paths exit before any tmux call, so no
# server or client is needed.
if ./webshell/tmux-groups >/dev/null 2>&1; then
  echo "FAIL: tmux-groups without a subcommand unexpectedly succeeded" >&2
  exit 1
fi
if ./webshell/tmux-groups --print tab-menu >/dev/null 2>&1; then
  echo "FAIL: tmux-groups tab-menu without window/client unexpectedly succeeded" >&2
  exit 1
fi
if ./webshell/tmux-groups --print bogus-subcommand >/dev/null 2>&1; then
  echo "FAIL: tmux-groups unknown subcommand unexpectedly succeeded" >&2
  exit 1
fi

log "all negative tests passed"
