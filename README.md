# Setup

Portable dotfiles and Claude Code configuration. Clone to `~/.setup` on any machine to get a consistent environment.

## What's Inside

- **install.sh** — New-machine bootstrap: installs tooling and links Claude config (see below)
- **STYLE_GUIDE.md** — Required validation, portability, and agent-compatibility rules
- **AGENTS.md** — Codex repository instructions that reference the shared style guide
- **CLAUDE.md** — Claude Code instructions that reference the shared style guide
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
