# Setup

Portable dotfiles and Claude Code configuration. Clone to `~/.setup` on any machine to get a consistent environment.

## What's Inside

- **install.sh** — New-machine bootstrap: installs tooling and links Claude config (see below)
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

This installs **Claude Code, Codex CLI, Brev CLI, opencode, tmux, git, gh, jq,
ripgrep, fzf, wget, curl, htop, Go, and Ookla speedtest**, then clones this repo
to `~/.setup` and symlinks the Claude config into `~/.claude`. It works on
macOS (Homebrew) and Linux (apt/dnf/apk), and is safe to re-run — anything
already present is skipped.

Each install is verified by checking that its expected command is available on
`PATH`. The bootstrap continues attempting the remaining tools after a failure,
then exits nonzero if anything is still missing.

The repo-managed Brev skill is linked into Claude Code (`~/.claude/skills`),
Codex (`~/.codex/skills`), and the shared agent skill directory
(`~/.agents/skills`). Existing Brev skill installations are preserved.

It also sets Claude Code's default mode to **auto-accept edits** ("auto mode")
by writing `"defaultMode": "acceptEdits"` into `~/.claude/settings.json`
(merged, never clobbering existing settings). To undo, set it back to
`"default"`; for full skip-all-prompts mode, use `"bypassPermissions"`.

After it finishes, open a new shell so PATH changes take effect. Run `claude`
or `codex` to sign in, and `brev login` to authenticate Brev.

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
