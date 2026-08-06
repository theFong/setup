#!/usr/bin/env bash
#
# statusline.sh — Claude Code status line.
#
# Claude Code pipes the session status JSON to this script on stdin (wired up by
# install.sh as statusLine.command in ~/.claude/settings.json) and renders the
# result on one line under the prompt:
#
#   <model> · <cwd> · ctx NN% (used/window) · <session-id>
#
# The session id is printed in full so it can be pasted straight into
# `claude --resume <id>`. Context usage is colored green/yellow/red at 50%/80%.
#
# Fields read from the status JSON: .model.display_name, .cwd (falling back to
# .workspace.current_dir), .session_id, and .context_window. Claude Code
# versions that predate .context_window simply omit that segment.

set -uo pipefail

# Without jq — or on input jq cannot parse — print nothing rather than spilling
# an error into the prompt.
command -v jq >/dev/null 2>&1 || exit 0

jq -r --arg e "$(printf '\033')" '
  def human:
    if . >= 1000000 then ((. / 100000 | floor) / 10 | tostring) + "M"
    elif . >= 1000 then ((. / 1000) | floor | tostring) + "k"
    else tostring end;

  def color($c): $e + "[" + $c + "m" + . + $e + "[0m";
  def dim: color("2");

  ($ENV.HOME // "") as $home
  | (.cwd // .workspace.current_dir // "") as $cwd
  | (if $home != "" and ($cwd | startswith($home)) then "~" + $cwd[($home | length):] else $cwd end) as $dir
  | (.context_window // {}) as $ctx
  | ($ctx.used_percentage // null) as $raw
  | (if $raw == null then null else ($raw | floor) end) as $pct
  | ($ctx.total_input_tokens // 0) as $used
  | ($ctx.context_window_size // 0) as $size
  | [
      (.model.display_name // "?" | color("36")),
      ($dir | color("34")),
      (if $pct == null then empty
       else ("ctx " + ($pct | tostring) + "%"
             | color(if $pct >= 80 then "31" elif $pct >= 50 then "33" else "32" end))
            + (" (" + ($used | human) + "/" + ($size | human) + ")" | dim)
       end),
      (.session_id // "" | if . == "" then empty else dim end)
    ]
  | join(" " + ("·" | dim) + " ")
' 2>/dev/null || true
