# Setup

Portable dotfiles and Claude Code configuration. Clone to `~/.setup` on any machine to get a consistent environment.

## What's Inside

- **install.sh** — New-machine bootstrap: installs tooling and links Claude config (see below)
- **test.sh** — Isolated negative tests for install.sh failure paths, run by CI and safe to run locally
- **STYLE_GUIDE.md** — Required validation, portability, and agent-compatibility rules
- **AGENTS.md** — Codex repository instructions that reference the shared style guide
- **CLAUDE.md** — Claude Code instructions that reference the shared style guide
- **webshell/** — Browser terminal (ttyd + tmux) with persistent sessions, clickable tabs, and copy-to-clipboard (see below)
- **.agent/skills/** — Custom Claude Code skills (brev-cli, outlook-calendar, skill-creator, etc.)
- **setup.md** — Shell/zsh prompt configuration notes

## Quick Start (new machine)

One line to install everything and link the Claude config:

```bash
curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/install.sh | bash
```

This installs **Claude Code, Codex CLI, Brev CLI, Hugging Face CLI, opencode,
tmux, git, gh, jq, ripgrep, fzf, wget, curl, htop, Go, and Ookla speedtest**,
then clones this repo to `~/.setup` and symlinks the Claude config into
`~/.claude`. It works on macOS (Homebrew) and Linux (apt/dnf/apk), and is safe
to re-run — anything already present is skipped.

Each install is verified by checking that its expected command is available on
`PATH`. The bootstrap continues attempting the remaining tools after a failure,
then exits nonzero if anything is still missing.

The repo-managed Brev skill is linked into Claude Code (`~/.claude/skills`),
Codex (`~/.codex/skills`), and the shared agent skill directory
(`~/.agents/skills`). Existing Brev skill installations are preserved.

It also sets Claude Code's default permission mode to **auto mode** by writing
`"permissions": {"defaultMode": "auto"}` into `~/.claude/settings.json`
(merged, never clobbering other settings; the legacy top-level `defaultMode`
key written by older bootstraps is removed since Claude Code does not read the
mode from there). This setting is Claude Code-specific — Codex approval
settings are not modified. To undo, set it to `"default"`; to only auto-accept
edits, use `"acceptEdits"`; for full skip-all-prompts mode, use
`"bypassPermissions"`.

After it finishes, open a new shell so PATH changes take effect. Run `claude`
or `codex` to sign in, `brev login` to authenticate Brev, and `hf auth login`
to authenticate Hugging Face.

## Web Shell (browser terminal)

A tmux-backed terminal in the browser: sessions survive refresh/disconnect
(and their layout survives reboots), the status bar acts as clickable tabs
(`+ new shell` / `✕ close`, double-click to rename), and highlight-to-copy
lands on your local clipboard via OSC 52.

```bash
~/.setup/webshell/install.sh              # private (default): 127.0.0.1 + password
~/.setup/webshell/install.sh --public     # bind wt0 (Netbird), no password — needs an auth proxy in front
```

**Private** (default) binds `127.0.0.1:7681` with a generated password
(printed once); reach it with `ssh -L 7681:127.0.0.1:7681 <host>` →
`http://localhost:7681`. **Public** binds a mesh/private interface (default
`wt0`) with no password and assumes an authenticating HTTPS proxy in front —
don't use it without one. Flags: `--iface`, `--port`, `--session`,
`--force-build`; env: `WEBSHELL_*`. `--verify-only` health-checks an existing
install (service active, HTTP serving, auth enforced) and exits nonzero on
failure — CI runs it, and it works as a cron/liveness probe too.

Notes baked into the setup (hard-won):
- ttyd is **built from source** — release/apt builds bundle an xterm.js
  without the OSC 52 clipboard handler, so copy silently fails.
- tmux 3.2a never emits OSC 52 itself (even with `Ms`/terminal-features set);
  copy bindings pipe through `webshell/tmux-clip`, which writes the escape
  straight to the client tty.
- Clipboard needs a secure context (https or localhost) and the page focused.
- `~/.tmux.conf` is symlinked to `webshell/tmux.conf`.
- Reboots restore your windows macOS-Terminal-style: tmux-resurrect +
  tmux-continuum (via tpm) auto-save layout, working dirs, and visible pane
  text every 15 min and replay them when the tmux server next starts —
  `ttyd.service` starts one on connect, so just reopen the webshell.
  Processes are **not** resumed; panes reopen as fresh shells. Manual
  save/restore: `prefix + Ctrl-s` / `prefix + Ctrl-r`.
- `ttyd.service` uses `KillMode=process`: restarting/upgrading ttyd only
  bounces the browser connection — the tmux server (your shells) survives.
  Continuum only auto-saves/restores when its server is the machine's sole
  tmux server, so scratch servers on other sockets don't clobber saves.
- Re-running the installer keeps the deployed mode, interface, and port
  unless you pass `--private`/`--public` (or `WEBSHELL_*`) explicitly.
- **Tab groups** (tmux sessions) are mouse-driven: a second status row lists
  the groups with the current one highlighted. Click it (or any empty area of
  the tab row) for the groups picker — switch / new / rename / close. Click
  the tab you are already on to rename it, close it, or move it to another
  group; clicking any other tab just switches to it. Wheel over the bar
  cycles groups. Everything is reachable by **left** click: browsers hijack
  right-click before the terminal sees it.
- The pickers are `display-popup` + `fzf`, not tmux's `display-menu`, and that
  is not cosmetic: a tmux menu is dismissed by any pointer-motion event, and
  xterm.js reports motion with no button held — so in a browser the menu
  vanishes as soon as you move the mouse toward it. A popup is a real pane,
  so motion goes to the program inside it (`choose-tree` was measured too and
  dies the same way). Inside the popup you get a real tty, so fzf handles
  mouse clicks and wheel, and prompts are plain `read`. Menu contents are
  generated by `webshell/tmux-groups`, which `--print`s its labels so the
  installer and `test.sh` can check the UI headlessly.
- **File browser/viewer**: `prefix + f`, or click the bar and pick
  `📁 browse files…`. Opens a popup in the current pane's directory with a
  live preview beside the list — click a folder to descend, `../` to go up, a
  file to page it in `less`, `q` back to the list, `esc` to close. Typing
  filters (fzf), hidden files are shown, and binary files are named rather
  than dumped. It is a viewer only — nothing there can modify a file.
  Implemented in `webshell/tmux-files`.
- **Copying out of a file.** Drag-select-to-copy works in a tmux *pane* but
  does nothing inside a popup — popups are not panes and have no copy-mode on
  this build (measured), so dragging inside the browser popup is a no-op.
  `ctrl-o` therefore opens the file in a pane **beside the current one**, in
  the same tab, where the normal drag-select copy works (`less` runs there
  without `--mouse` on purpose, so tmux keeps the drag). `ctrl-t` does the
  same as its own tab when a 50% split is too narrow, and `ctrl-y` / `alt-y`
  copy the whole file / its path without selecting anything. All land in the
  browser clipboard via `tmux-clip`'s OSC 52, which needs a secure context —
  fine over the https app URL, and over an SSH tunnel to localhost. Pasting
  back: `prefix + ]` for the tmux buffer, or the browser's normal paste.

## North/South Internet Check

Evaluate internet throughput (download/upload/latency to an external server)
with the Ookla `speedtest` CLI installed above. One-liner:

```bash
speedtest --accept-license --accept-gdpr
```

The flags auto-accept Ookla's license/GDPR prompt on first run so it works
non-interactively (in scripts or over SSH); after the first run plain
`speedtest` works too. Useful extras:

```bash
speedtest --servers                       # list nearby servers
speedtest --server-id=<id>                # pin a specific server
speedtest --format=json                   # machine-readable output
```

## Manual Installation

If you only want the Claude config (no tooling):

```bash
git clone https://github.com/theFong/setup ~/.setup

# Symlink Claude Code config
ln -s ~/.setup/CLAUDE.md ~/.claude/CLAUDE.md
ln -s ~/.setup/.agent/skills ~/.claude/skills
```

## How It Works

Rather than storing Claude Code configuration directly in `~/.claude/`, this repo acts as the source of truth. Symlinks point from `~/.claude/` back into this repo:

```
~/.claude/CLAUDE.md   →  ~/.setup/CLAUDE.md
~/.claude/skills/     →  ~/.setup/.agent/skills/
```

This means all configuration is version-controlled and portable across machines. Edit files here, commit, and push — then pull on any other machine to stay in sync.
