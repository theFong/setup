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

# Agent skills: assert_agent_skill must fail when a skill is not readable
# through every agent directory, rather than reporting a clean link. Run against
# a scratch HOME so the real skill installation is never consulted or touched.
mkdir -p "$scratch/skillhome"
if (export HOME="$scratch/skillhome"; assert_agent_skill cluster-ops) >/dev/null 2>&1; then
  echo "FAIL: assert_agent_skill unexpectedly passed for an uninstalled skill" >&2
  exit 1
fi

# cluster-ops: assert_cluster_probe must fail when the probe script is missing.
# A skill that ships a broken or absent discovery script would only fail later,
# mid-survey against someone's production fleet.
if (export HOME="$scratch/skillhome"; assert_cluster_probe) >/dev/null 2>&1; then
  echo "FAIL: assert_cluster_probe unexpectedly passed with no probe script" >&2
  exit 1
fi

# cluster-ops: probe-cluster.sh must reject misuse instead of silently sweeping
# nothing. Both paths exit before any SSH is attempted.
probe=.agent/skills/cluster-ops/scripts/probe-cluster.sh
if bash "$probe" >/dev/null 2>&1; then
  echo "FAIL: probe-cluster.sh with no hosts unexpectedly succeeded" >&2
  exit 1
fi
if bash "$probe" --bogus-option >/dev/null 2>&1; then
  echo "FAIL: probe-cluster.sh unknown option unexpectedly succeeded" >&2
  exit 1
fi

# cluster-ops: an unreachable host must be RECORDED and must make the sweep
# exit nonzero. Dropping it silently would leave a node missing from an
# inventory that reads as complete. .invalid never resolves (RFC 2606), so this
# fails fast and touches no real host.
if command -v ssh >/dev/null 2>&1; then
  probe_out="$scratch/probe.json"
  if bash "$probe" -t 2 -o "$probe_out" no-such-host.invalid >/dev/null 2>&1; then
    echo "FAIL: probe-cluster.sh returned zero despite an unreachable host" >&2
    exit 1
  fi
  if ! grep -q '"error"' "$probe_out" 2>/dev/null; then
    echo "FAIL: probe-cluster.sh did not record an entry for the failed host" >&2
    exit 1
  fi
else
  echo "skip: ssh not available; probe unreachable-host test not run" >&2
fi

log "all negative tests passed"
