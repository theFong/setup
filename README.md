# Setup

Portable dotfiles and Claude Code configuration. Clone to `~/.setup` on any machine to get a consistent environment.

## What's Inside

- **install.sh** — New-machine bootstrap: installs tooling and links Claude config (see below)
- **test.sh** — Isolated negative tests for install.sh failure paths, run by CI and safe to run locally
- **STYLE_GUIDE.md** — Required validation, portability, and agent-compatibility rules
- **AGENTS.md** — Codex repository instructions that reference the shared style guide
- **CLAUDE.md** — Claude Code instructions that reference the shared style guide
- **claude/statusline.sh** — Claude Code status line showing session id and context usage (see below)
- **webshell/** — Browser terminal (ttyd + tmux) with persistent sessions, clickable tabs, and copy-to-clipboard (see below)
- **.agent/skills/** — Custom agent skills (brev-cli, cluster-ops, skill-creator, etc.)
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

Each install is verified twice: the expected command must be on `PATH`, and the
CLIs this bootstrap exists to install must actually execute (`assert_runs`
invokes each one's version command, since a truncated download or a
wrong-architecture build still satisfies `command -v`). The bootstrap continues
attempting the remaining tools after a failure, then exits nonzero if anything
is still missing or does not run.

The repo-managed skills (**brev-cli** and **cluster-ops**) are linked into
Claude Code (`~/.claude/skills`), Codex (`~/.codex/skills`), and the shared
agent skill directory (`~/.agents/skills`). Existing skill installations are
preserved. Each path is then checked to resolve to a **readable** `SKILL.md` —
a dangling symlink would otherwise satisfy the create-if-absent guard and leave
every agent silently without the skill — and the cluster-ops discovery script is
run in self-test mode against the local machine. So a skill that reached only
one agent, or a probe script broken on this platform, fails the bootstrap
instead of surfacing later.

It also sets Claude Code's default permission mode to **auto mode** by writing
`"permissions": {"defaultMode": "auto"}` into `~/.claude/settings.json`
(merged, never clobbering other settings; the legacy top-level `defaultMode`
key written by older bootstraps is removed since Claude Code does not read the
mode from there). To undo, set it to `"default"`; to only auto-accept
edits, use `"acceptEdits"`; for full skip-all-prompts mode, use
`"bypassPermissions"`.

Codex gets the equivalent **Auto** approval preset by writing top-level
`approval_policy = "on-request"` and `sandbox_mode = "workspace-write"` into
`~/.codex/config.toml`: Codex works autonomously inside a workspace-write
sandbox and only prompts to escalate. The keys are inserted above any
`[table]` section (top-level TOML keys must precede table headers); everything
else in the file is preserved. To undo, delete both keys; for full
skip-all-prompts mode, use `approval_policy = "never"` with
`sandbox_mode = "danger-full-access"`.

After it finishes, open a new shell so PATH changes take effect. Run `claude`
or `codex` to sign in, `brev login` to authenticate Brev, and `hf auth login`
to authenticate Hugging Face.

## Claude Code Status Line

Claude Code has no built-in setting to always show the session id or context
usage, but it pipes both to the status line command, so the bootstrap points
`statusLine.command` at `~/.setup/claude/statusline.sh`:

```
Opus 5 · ~/setup · ctx 24% (248k/1M) · 2fa86bc7-74ec-4c0d-bcd4-12cdb70798be
```

Model, working directory, context-window usage, and the full session id — full
rather than shortened so it can be pasted into `claude --resume <id>`. The
percentage turns yellow at 50% and red at 80%. Older Claude Code versions that
do not send `context_window` just drop that segment, and the line stays empty
rather than erroring if `jq` is missing.

Edit `claude/statusline.sh` to change what it renders; the bootstrap verifies
on every run that the script is wired into `~/.claude/settings.json` and that
it actually renders a sample payload. Delete the `statusLine` key from
`~/.claude/settings.json` to undo. Like the permission mode above, this is
Claude Code-specific — Codex CLI has no status line hook. The equivalent Codex
workflow is `codex resume`, whose session picker (or `--last`) selects a past
session without needing the id in front of you.

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
install (service active, HTTP serving, auth enforced, the deployed unit still
matching the intended mode/interface/port, `KillMode=process` present, and
session restore actually working) and exits nonzero on failure — CI runs it,
and it works as a cron/liveness probe too.

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
- **Tab groups** (tmux sessions) are fully mouse-driven: a second status row
  lists the groups with the current one highlighted. Click that row — or
  right-click anywhere on the bar — for the groups menu (switch / new /
  rename / close). Right-click a tab to rename it, close it, or move it to
  another group; mouse-wheel over the bar cycles groups. Menus come from
  `webshell/tmux-groups`. Groups survive reboots like everything else
  (resurrect saves and restores all sessions).

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

## Cluster Onboarding (`cluster-ops` skill)

`.agent/skills/cluster-ops/` turns an undocumented compute cluster into a
per-cluster operations skill an agent can trust, and carries the portable
GPU-fleet failure patterns that recur across every fleet.

Ask an agent to onboard a cluster, or drive the discovery sweep directly:

```bash
PROBE=~/.claude/skills/cluster-ops/scripts/probe-cluster.sh

$PROBE --self-test                                 # verify the collector on this machine
$PROBE -o /tmp/acme.json head node-1 node-2        # sweep the fleet
$PROBE --hosts-file hosts.txt --include-local      # or read hosts from a file
```

The sweep is **read-only by construction**: it reads `/proc`, `/sys`,
`/etc/os-release` and `/etc/docker/daemon.json`, runs query-only commands (`ip`,
`ss`, `docker ps`, `nvidia-smi`, `systemctl list-units`), and uses `sudo` for
nothing but `sudo -n true` to detect passwordless sudo. It emits one JSON record
per host covering identity, GPUs, containers and their restart policies,
addresses on every plane (LAN / overlay / RDMA fabric), listening ports, and
per-node access shape. A host that cannot be reached still gets a record, with
an `error` field, and the sweep exits nonzero — an unprobed node is a finding,
not an omission.

The skill then walks a six-phase flow (scope → enumerate → probe → interview →
render → verify) and fills `templates/` to produce a `<cluster>-cluster` skill,
installed for both Claude Code and Codex. Layout:

| Path | Holds |
|---|---|
| `SKILL.md` | Entry points, non-negotiables, symptom → diagnostics index |
| `reference/onboarding.md` | The six phases, the interview questions, how to read probe output |
| `reference/diagnostics.md` | Portable failure patterns: overlay collisions, reboot survival, RDMA verification, telemetry that lies, ingress and routing |
| `reference/contract.md` | Authoring rules, when to update, anti-drift, how to retire a skill |
| `templates/` | The cluster skill, topology, and runbook templates |
| `scripts/probe-cluster.sh` | The read-only discovery sweep |

The split is deliberate: `cluster-ops` holds what is true of clusters in
general, a `<cluster>-cluster` skill holds what is true of one fleet. Keeping
facts on the right side of that line means a fix reaches every cluster instead
of one.

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
