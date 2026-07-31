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

log "all negative tests passed"
