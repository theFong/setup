# Setup

Portable dotfiles and Claude Code configuration. Clone to `~/.setup` on any machine to get a consistent environment.

## What's Inside

- **CLAUDE.md** — Global instructions for Claude Code (commit conventions, long-running task handling, etc.)
- **.agent/skills/** — Custom Claude Code skills (brev-cli, outlook-calendar, skill-creator, etc.)
- **setup.md** — Shell/zsh prompt configuration notes

## Installation

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
