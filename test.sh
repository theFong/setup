#!/usr/bin/env bash
#
# test.sh — isolated negative tests for install.sh and omp-setup.sh: prove
# failure paths return nonzero without running the full bootstrap. Success
# paths are validated by the scripts themselves on every run (assert_installed
# / assert_* helpers, see
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

# assert_runs must reject a binary that resolves on PATH but does not execute
# (truncated download, broken venv shim, wrong-architecture build) — the case
# assert_installed cannot see.
mkdir -p "$scratch/brokenbin"
printf '#!/usr/bin/env bash\nexit 3\n' > "$scratch/brokenbin/setup-broken-tool"
chmod +x "$scratch/brokenbin/setup-broken-tool"
FAILED=""
if assert_runs "broken test tool" broken-test-tool "$scratch/brokenbin/setup-broken-tool" --version >/dev/null 2>&1; then
  echo "FAIL: assert_runs accepted a binary that exits nonzero" >&2
  exit 1
fi
if summary >/dev/null 2>&1; then
  echo "FAIL: summary returned zero after a tool failed to run" >&2
  exit 1
fi
FAILED=""

# webshell/install.sh must refuse a non-Linux host, and refuse it before
# installing anything. A uname shim makes this runnable on any platform; the
# guard is the second thing main() does, so a scratch HOME must come back
# untouched (the real /usr/local/bin cannot be asserted on — a machine running
# this may legitimately have the webshell installed already).
mkdir -p "$scratch/fakebin" "$scratch/wsguard"
printf '#!/usr/bin/env bash\necho Darwin\n' > "$scratch/fakebin/uname"
chmod +x "$scratch/fakebin/uname"
# SETUP_SKIP_MAIN is exported at the top of this file so functions can be
# sourced; it must be unset here or the installer would skip main() and exit 0,
# making this test pass for entirely the wrong reason.
if (
  export PATH="$scratch/fakebin:$PATH" HOME="$scratch/wsguard"
  unset SETUP_SKIP_MAIN
  ./webshell/install.sh
) >/dev/null 2>&1; then
  echo "FAIL: webshell installer ran on a non-Linux host" >&2
  exit 1
fi
if [ -n "$(ls -A "$scratch/wsguard" 2>/dev/null)" ]; then
  echo "FAIL: webshell installer touched HOME before refusing an unsupported platform" >&2
  exit 1
fi

# verify() must reject a private-mode webshell that answers unauthenticated
# requests — the "shell exposed with no password" regression, and the check
# that used to live as a curl assertion in the workflow. A throwaway HTTP
# server stands in for a broken ttyd: it returns 200 where verify() demands
# 401, so this also proves verify() is not a no-op. Needs python3; skipped
# where it is absent.
if command -v python3 >/dev/null 2>&1; then
  ws_port=39998
  python3 -m http.server "$ws_port" --bind 127.0.0.1 --directory "$scratch" >/dev/null 2>&1 &
  ws_srv=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:$ws_port/" && break
    sleep 0.3
  done
  printf '[Service]\nExecStart=/usr/local/bin/ttyd --interface 127.0.0.1 --credential u:p --port %s --writable tmux new -A -s main\nKillMode=process\n' \
    "$ws_port" > "$scratch/ttyd-open.service"
  if (
    export WEBSHELL_UNIT="$scratch/ttyd-open.service" SETUP_SKIP_MAIN=1
    source ./webshell/install.sh
    MODE=private; PORT="$ws_port"; WSUSER=u; PASSWORD=p
    verify
  ) >/dev/null 2>&1; then
    kill "$ws_srv" 2>/dev/null || true
    echo "FAIL: verify() accepted a private webshell serving unauthenticated requests" >&2
    exit 1
  fi
  kill "$ws_srv" 2>/dev/null || true
  wait "$ws_srv" 2>/dev/null || true
else
  echo "skip: python3 not available; webshell auth-enforcement test not run" >&2
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

# cluster-ops: --brev must fail loudly when the brev CLI (or jq) is missing,
# rather than enumerating nothing and reporting a clean, empty sweep — which
# would read as "the fleet has no nodes". Run with a PATH containing neither.
if (export PATH=/nonexistent; /bin/bash "$probe" --brev) >/dev/null 2>&1; then
  echo "FAIL: probe-cluster.sh --brev unexpectedly succeeded without the brev CLI" >&2
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

# assert_agent_skill must reject a DANGLING symlink, not merely a missing one:
# link_agent_skills' create-if-absent guard is satisfied by a broken link, which
# would leave every agent silently without the skill. All three dirs get a
# dangling link, so unreadability is the only thing that can fail the assertion.
mkdir -p "$scratch/danglinghome/.claude/skills" \
         "$scratch/danglinghome/.codex/skills" \
         "$scratch/danglinghome/.agents/skills"
for d in .claude .codex .agents; do
  ln -s "$scratch/does-not-exist" "$scratch/danglinghome/$d/skills/brev-cli"
done
if (export HOME="$scratch/danglinghome"; assert_agent_skill brev-cli) >/dev/null 2>&1; then
  echo "FAIL: assert_agent_skill accepted a dangling skill symlink" >&2
  exit 1
fi

# assert_agent_skill must also fail when SKILL.md links a reference/ document
# that is not installed. A progressive-disclosure skill whose level-3 files are
# missing reads as healthy at boot and only fails when an agent tries to open
# one mid-task.
mkdir -p "$scratch/skill-src/dangling-skill"
printf -- '---\nname: dangling-skill\ndescription: test\n---\nSee [x](reference/missing.md)\n' \
  > "$scratch/skill-src/dangling-skill/SKILL.md"
for d in .claude .codex .agents; do
  mkdir -p "$scratch/refhome/$d/skills"
  ln -s "$scratch/skill-src/dangling-skill" "$scratch/refhome/$d/skills/dangling-skill"
done
if (export HOME="$scratch/refhome"; assert_agent_skill dangling-skill) >/dev/null 2>&1; then
  echo "FAIL: assert_agent_skill accepted a skill with a missing reference doc" >&2
  exit 1
fi

# ...and must pass once that document exists, so the check above cannot be
# satisfied by an assertion that simply always fails.
mkdir -p "$scratch/skill-src/dangling-skill/reference"
echo "present" > "$scratch/skill-src/dangling-skill/reference/missing.md"
if ! (export HOME="$scratch/refhome"; assert_agent_skill dangling-skill) >/dev/null 2>&1; then
  echo "FAIL: assert_agent_skill rejected a skill whose reference docs all resolve" >&2
  exit 1
fi

# Every repo-managed skill must carry a SKILL.md with name/description
# frontmatter, or agents cannot discover it, and every reference document it
# links must exist in the repo.
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
  for ref in $(grep -o 'reference/[A-Za-z0-9._-]*\.md' "$skill_md" 2>/dev/null | sort -u || true); do
    if [ ! -f "$skill_dir/$ref" ]; then
      echo "FAIL: $skill_md links $ref, which does not exist" >&2
      exit 1
    fi
  done
done

# webshell helpers must fail loudly when misused rather than drawing a broken
# UI. These paths exit before any tmux call, so no server or client is needed.
if ./webshell/tmux-groups >/dev/null 2>&1; then
  echo "FAIL: tmux-groups without a subcommand unexpectedly succeeded" >&2
  exit 1
fi
if ./webshell/tmux-groups --print tab-menu >/dev/null 2>&1; then
  echo "FAIL: tmux-groups tab-menu without a window id unexpectedly succeeded" >&2
  exit 1
fi
if ./webshell/tmux-groups --print bogus-subcommand >/dev/null 2>&1; then
  echo "FAIL: tmux-groups unknown subcommand unexpectedly succeeded" >&2
  exit 1
fi
if ./webshell/tmux-files bogus-subcommand >/dev/null 2>&1; then
  echo "FAIL: tmux-files unknown subcommand unexpectedly succeeded" >&2
  exit 1
fi
# copying must refuse anything that would put junk on the clipboard
if ./webshell/tmux-files copy /usr/local/bin ttyd >/dev/null 2>&1; then
  echo "FAIL: tmux-files copied a binary file" >&2
  exit 1
fi
if ./webshell/tmux-files copy-path "$scratch" no-such-entry >/dev/null 2>&1; then
  echo "FAIL: tmux-files copy-path accepted a missing path" >&2
  exit 1
fi
# the viewer must refuse a non-file path rather than paging garbage
if ! ./webshell/tmux-files view "$scratch" 2>&1 | grep -q "not a file"; then
  echo "FAIL: tmux-files view accepted a directory" >&2
  exit 1
fi

# omp-setup.sh: sourced in subshells throughout, because it defines its own
# log/warn/have and would otherwise replace install.sh's helpers for every test
# after this point.

# merge_models_yml must not shadow the managed provider with a hand-written
# entry of the same id. YAML keeps the LAST duplicate key, so leaving an old
# `webster:` in place would silently point omp at the previous endpoint while
# the file still reads as correctly configured.
mkdir -p "$scratch/omp"
printf 'providers:\n  litellm:\n    baseUrl: https://other.example.com/v1\n  webster:\n    baseUrl: https://STALE.example.com/v1\n    apiKey: sk-stale\n' \
  > "$scratch/omp/models.yml"
if ! (
  export SETUP_SKIP_MAIN=1 OMP_BASE_URL=https://fresh.example.com/v1
  source ./omp-setup.sh
  merge_models_yml "$scratch/omp/models.yml" sk-fresh
) >/dev/null 2>&1; then
  echo "FAIL: merge_models_yml reported no change when the file needed rewriting" >&2
  exit 1
fi
if grep -q 'STALE.example.com' "$scratch/omp/models.yml"; then
  echo "FAIL: merge_models_yml left a stale duplicate webster provider in place" >&2
  exit 1
fi
if [ "$(grep -c '^  webster:$' "$scratch/omp/models.yml")" != "1" ]; then
  echo "FAIL: merge_models_yml produced a duplicate webster key" >&2
  exit 1
fi
if ! grep -q 'other.example.com' "$scratch/omp/models.yml"; then
  echo "FAIL: merge_models_yml dropped an unrelated provider" >&2
  exit 1
fi
# GNU stat first, then BSD/macOS. The order matters and both must be quieted:
# GNU reads -f as --file-system and prints a block of filesystem info for the
# file while failing on the format string, so trying BSD first captures that
# output *and* falls through, concatenating both.
omp_mode=$(stat -c '%a' "$scratch/omp/models.yml" 2>/dev/null \
  || stat -f '%Lp' "$scratch/omp/models.yml" 2>/dev/null || true)
if [ "$omp_mode" != "600" ]; then
  echo "FAIL: merge_models_yml left an API key world-readable (mode '$omp_mode')" >&2
  exit 1
fi

# ...and a second run must be a no-op (return nonzero for "no change"), so a
# re-bootstrap neither rewrites the file nor churns a backup.
if (
  export SETUP_SKIP_MAIN=1 OMP_BASE_URL=https://fresh.example.com/v1
  source ./omp-setup.sh
  merge_models_yml "$scratch/omp/models.yml" sk-fresh
) >/dev/null 2>&1; then
  echo "FAIL: merge_models_yml rewrote an already-current models.yml" >&2
  exit 1
fi

# key_from_models_yml must read back the key it wrote, or every re-run would
# re-prompt (and a non-interactive re-run would fail outright).
omp_key=$(
  export SETUP_SKIP_MAIN=1
  source ./omp-setup.sh
  key_from_models_yml "$scratch/omp/models.yml"
)
if [ "$omp_key" != "sk-fresh" ]; then
  echo "FAIL: key_from_models_yml did not read back the stored key (got '$omp_key')" >&2
  exit 1
fi

# assert_omp_endpoint must fail on a dead endpoint rather than reporting a
# healthy provider. Port 1 on loopback refuses instantly, so this needs no
# network and cannot hang.
if (
  export SETUP_SKIP_MAIN=1
  source ./omp-setup.sh
  assert_omp_endpoint "http://127.0.0.1:1/v1" sk-irrelevant
) >/dev/null 2>&1; then
  echo "FAIL: assert_omp_endpoint accepted an unreachable endpoint" >&2
  exit 1
fi

# ...and must also fail on an endpoint that answers but does not serve the
# model being made the default — otherwise reachability alone would pass.
if command -v python3 >/dev/null 2>&1; then
  omp_port=39997
  mkdir -p "$scratch/ompsrv/v1"
  printf '{"data":[{"id":"some-other-model"}]}' > "$scratch/ompsrv/v1/models"
  python3 -m http.server "$omp_port" --bind 127.0.0.1 --directory "$scratch/ompsrv" >/dev/null 2>&1 &
  omp_srv=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:$omp_port/" && break
    sleep 0.3
  done
  if (
    export SETUP_SKIP_MAIN=1
    source ./omp-setup.sh
    assert_omp_endpoint "http://127.0.0.1:$omp_port/v1" sk-irrelevant
  ) >/dev/null 2>&1; then
    kill "$omp_srv" 2>/dev/null || true
    echo "FAIL: assert_omp_endpoint accepted an endpoint not serving the default model" >&2
    exit 1
  fi
  # ...and must pass when the model IS served, so the two checks above cannot be
  # satisfied by an assertion that simply always fails.
  printf '{"data":[{"id":"glm-5.2"}]}' > "$scratch/ompsrv/v1/models"
  if ! (
    export SETUP_SKIP_MAIN=1
    source ./omp-setup.sh
    assert_omp_endpoint "http://127.0.0.1:$omp_port/v1" sk-irrelevant
  ) >/dev/null 2>&1; then
    kill "$omp_srv" 2>/dev/null || true
    echo "FAIL: assert_omp_endpoint rejected an endpoint serving the default model" >&2
    exit 1
  fi
  kill "$omp_srv" 2>/dev/null || true
  wait "$omp_srv" 2>/dev/null || true
else
  echo "skip: python3 not available; omp endpoint model-presence test not run" >&2
fi

# omp-setup.sh must refuse to run with no API key rather than writing a
# provider entry with an empty key that fails on first use. Runs with a scratch
# HOME and closed stdin (no tty, so it cannot prompt); the scratch HOME must
# come back untouched.
mkdir -p "$scratch/omphome"
if (
  export HOME="$scratch/omphome" OMP_SKIP_PROFILE=1
  export PI_CODING_AGENT_DIR="$scratch/omphome/agent"
  unset SETUP_SKIP_MAIN OMP_WEBSTER_API_KEY WEBSTER_API_KEY
  ./omp-setup.sh </dev/null
) >/dev/null 2>&1; then
  echo "FAIL: omp-setup.sh ran without an API key" >&2
  exit 1
fi
if [ -f "$scratch/omphome/agent/models.yml" ]; then
  echo "FAIL: omp-setup.sh wrote models.yml before refusing a missing API key" >&2
  exit 1
fi

# --help must work when the script is piped to bash (curl | bash), where there
# is no script file to read the header comment back out of: $0 is "bash", so
# the file-based path would grep the shell binary and print nothing usable.
# SETUP_SKIP_MAIN is exported at the top of this file; it must be unset here or
# the piped shell would skip main() and print nothing, passing for the wrong
# reason.
help_out=$( (unset SETUP_SKIP_MAIN; bash -s -- --help < ./omp-setup.sh) 2>&1 || true)
if ! printf '%s' "$help_out" | grep -q 'WEBSTER_API_KEY'; then
  echo "FAIL: omp-setup.sh --help printed nothing usable when piped to bash" >&2
  exit 1
fi

# An unknown flag must be rejected instead of silently reconfiguring the agent
# with defaults the caller did not ask for.
if (
  export SETUP_SKIP_MAIN=1
  source ./omp-setup.sh
  main --bogus-flag
) >/dev/null 2>&1; then
  echo "FAIL: omp-setup.sh accepted an unknown flag" >&2
  exit 1
fi

log "all negative tests passed"
