# Setup

Portable dotfiles and Claude Code configuration. Clone to `~/.setup` on any machine to get a consistent environment.

## What's Inside

- **install.sh** — New-machine bootstrap: installs tooling and links Claude config (see below)
- **omp-setup.sh** — Installs and configures [omp](https://omp.sh) (oh-my-pi) against the Brev-hosted model endpoint (see below)
- **pi-setup.sh** — Same, for the [pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) coding agent; one-liner installable (see below)
- **codex-setup.sh** — Adds Webster models alongside OpenAI models in Codex CLI and Codex Desktop through a localhost-only proxy (see below)
- **test.sh** — Isolated negative tests for the installers, run by CI and safe to run locally
- **STYLE_GUIDE.md** — Required validation, portability, and agent-compatibility rules
- **AGENTS.md** — Codex repository instructions that reference the shared style guide
- **CLAUDE.md** — Claude Code instructions that reference the shared style guide
- **claude/statusline.sh** — Claude Code status line showing session id and context usage (see below)
- **webshell/** — Browser terminal (ttyd + tmux) with persistent sessions, clickable tabs, and copy-to-clipboard (see below)
- **.agent/skills/** — Custom agent skills (brev-cli, cluster-ops, inference-optimization, skill-creator, etc.)
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

The repo-managed skills (**brev-cli**, **cluster-ops**, and
**inference-optimization**) are linked into Claude Code (`~/.claude/skills`),
Codex (`~/.codex/skills`), and the shared agent skill directory
(`~/.agents/skills`). Existing skill installations are preserved. Each path is
then checked to resolve to a **readable** `SKILL.md` — a dangling symlink would
otherwise satisfy the create-if-absent guard and leave every agent silently
without the skill — along with every `reference/` document that `SKILL.md` links,
and the cluster-ops discovery script is run in self-test mode against the local
machine. So a skill that reached only one agent, arrived without the reference
docs it defers to, or ships a probe script broken on this platform, fails the
bootstrap instead of surfacing later.

- **brev-cli** — manage GPU cloud instances.
- **cluster-ops** — cluster onboarding and portable fleet diagnostics.
- **inference-optimization** — diagnose and tune LLM inference throughput,
  single-node or multi-node. Leads with GPU hardware validation, because a
  throttled GPU makes every software measurement meaningless (see the skill's
  `reference/` for a case study where identical GPUs differed 7x). Also covers
  sizing a model against the KV-cache budget, tensor-parallel and NCCL pitfalls,
  and validating that tool calling survives every hop to the client.

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
  vanishes as soon as you move the mouse toward it. A popup is a real pane, so
  motion goes to the program inside it (`choose-tree` was measured too and
  dies the same way). Inside the popup you get a real tty, so fzf handles
  mouse clicks and wheel, and prompts are plain `read`. Both helpers `--print`
  their labels so the installer and `test.sh` can check the UI headlessly.
- **File browser/viewer**: `prefix + f`, or click the bar and pick
  `📁 browse files…`. Opens in the current pane's directory with a live
  preview beside the list — click a folder to descend, `../` to go up, a file
  to page it in `less`, `esc` to close. Typing filters, hidden files are
  shown, and binary files are named rather than dumped. Viewer only: nothing
  there can modify a file. Implemented in `webshell/tmux-files`.
- **Copying out of a file.** Drag-select-to-copy works in a tmux *pane* but
  does nothing inside a popup — popups are not panes and have no copy-mode on
  this build (measured), so dragging inside the browser popup is a no-op.
  `ctrl-o` therefore opens the file in a pane **beside the current one**, in
  the same tab, where the normal drag-select copy works (`less` runs there
  without `--mouse` on purpose, so tmux keeps the drag). `ctrl-t` does the
  same as its own tab, and `ctrl-y` / `alt-y` copy the whole file / its path
  without selecting anything. All land in the browser clipboard via
  `tmux-clip`'s OSC 52, which needs a secure context (the https app URL, or a
  tunnel to localhost). Paste back with `prefix + ]` or the browser's paste.
- **Tab groups** (tmux sessions) are fully mouse-driven: a second status row
  lists the groups with the current one highlighted. Click that row — or
  right-click anywhere on the bar — for the groups menu (switch / new /
  rename / close). Right-click a tab to rename it, close it, or move it to
  another group; mouse-wheel over the bar cycles groups. Menus come from
  `webshell/tmux-groups`. Groups survive reboots like everything else
  (resurrect saves and restores all sessions).

## omp (oh-my-pi)

`omp-setup.sh` installs [omp](https://omp.sh) if it isn't already present, points
it at the Brev-hosted `webster` model proxy, defaults it to **GLM 5.2**, and turns
on **nerd mode** — Nerd Font symbols plus the `nerd` status line preset
(tok/sec spark, TTFT, context %, cost, cache reads, elapsed time).

One line on a new machine — note the key goes on the **right** of the pipe, so
the `bash` running the script sees it:

```bash
curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/omp-setup.sh | WEBSTER_API_KEY=sk-... bash
```

Pass flags after `-s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/omp-setup.sh | WEBSTER_API_KEY=sk-... bash -s -- --no-smoke
```

From a local clone:

```bash
OMP_WEBSTER_API_KEY=sk-... ~/.setup/omp-setup.sh
```

Or without the env var — run from a terminal and it prompts for the key (hidden
input). Piping to `bash` consumes stdin, so a piped run cannot prompt and exits
non-zero instead of writing an empty key:

```bash
~/.setup/omp-setup.sh
```

| Flag | Effect |
|---|---|
| _(none)_ | Install + configure + verify |
| `--check` | Verify an existing install; changes nothing, exits non-zero on drift |
| `--no-smoke` | Skip the live model round-trip (still checks the endpoint) |

What it writes:

| Where | What |
|---|---|
| `~/.omp/agent/models.yml` | `webster` provider: base URL, API key, LiteLLM discovery (mode `0600`) |
| `~/.omp/agent/config.yml` | `symbolPreset: nerd`, `statusLine.preset: nerd`, `modelRoles.default: webster/glm-5.2` |

It is idempotent and merge-safe: re-running reuses the key already on disk,
preserves other providers and other model roles (`advisor`, `smol`, `tiny`, …),
and backs up `models.yml` to `models.yml.bak` before any change.

**The API key is never stored in this repo** — pass it via `OMP_WEBSTER_API_KEY`
(or `WEBSTER_API_KEY`) or let the script prompt for it.

Verification runs on every install (`assert_omp_config` / `assert_omp_endpoint` /
`assert_omp_smoke`, per [STYLE_GUIDE.md](STYLE_GUIDE.md)): it reads the settings
back out of `omp`, lists models from the endpoint to confirm the URL and key are
good and that `glm-5.2` is served, then sends a real one-shot prompt through the
*configured default* model and asserts the reply. Failure paths — dead endpoint,
endpoint missing the model, no API key, stale duplicate provider entry — are
covered in `test.sh`.

It is not wired into `install.sh`, because it needs a secret the bootstrap does
not have. Run it separately after the bootstrap.

Nerd mode needs a [Nerd Font](https://nerdfonts.com) selected in your terminal;
without one the status line renders as tofu boxes. Fall back with
`omp config set symbolPreset unicode && omp config set statusLine.preset full`.

## Codex OpenAI + Webster proxy

`codex-setup.sh` installs a localhost-only Responses API router that keeps the
OpenAI/ChatGPT login already managed by Codex for OpenAI models and substitutes
the Webster API key only when a Webster model is selected. Both model families
then appear in the Codex CLI and Codex Desktop model picker. Setup queries
Webster's `/v1/models` endpoint with the supplied key, so each user sees only
the models that key can access; no Webster model IDs are hardcoded.

First sign in once with `codex login`, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/codex-setup.sh \
  | WEBSTER_API_KEY=sk-... bash
```

The environment prefix belongs on `bash`, to the right of the pipe. The script
can also prompt for the key through `/dev/tty`, or read it with `--key-file`:

```bash
curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/codex-setup.sh \
  | bash -s -- --key-file /path/to/webster-key
```

| Flag | Effect |
|---|---|
| _(none)_ | Install + configure + verify |
| `--check` | Verify source, secret permissions, endpoint, service, catalog, and Codex config without changing anything |
| `--key-file PATH` | Read the Webster key from a file's first line |

What it writes:

| Where | What |
|---|---|
| `~/.codex/model-proxy/` | Dependency-free proxy runtime and Webster key plus its discovered model list; the config is mode `0600` |
| `~/.codex/openai-webster-models.json` | Combined model catalog loaded by Codex at startup (mode `0600`) |
| `~/.codex/config.toml` | Merge-safe `openai_webster` provider and `model_catalog_json` selection |
| `~/Library/LaunchAgents/com.thefong.codex-model-proxy.plist` | Always-on user service on macOS |
| `~/.config/systemd/user/codex-model-proxy.service` | Always-on user service on Linux |

The proxy listens only on `127.0.0.1:4815`. It strips the incoming OpenAI
credential and ChatGPT account header before Webster requests, never logs
request bodies or headers, and never writes OpenAI credentials anywhere new.
The Webster key lives only in the owner-readable proxy config.

The installer preserves the current selected model and unrelated Codex config.
Re-run it to update the proxy and rediscover both the key's Webster access and
the OpenAI portion of the catalog. Setup fails instead of installing an empty
catalog when the key cannot access any models. Generated Webster entries clone
the complete stock Codex catalog shape so strict Codex Desktop versions can
deserialize every entry.
After an install or catalog refresh, fully quit and reopen Codex Desktop; its
model catalog is loaded when the app server starts.

It is not wired into `install.sh`, because it needs both a Webster secret and an
existing Codex login. Run it separately after the bootstrap.

## Claude Code + Webster proxy

`claude-code-setup.sh` installs a localhost-only Anthropic Messages gateway
that adds Webster models to Claude Code's `/model` picker without replacing the
built-in Claude choices. Normal Sonnet, Opus, Haiku, and other Claude requests
continue to Anthropic with the login already managed by Claude Code. Only model
IDs beginning with `claude-webster-` are translated to Webster's OpenAI Chat
Completions API, with the Webster key substituted at that boundary.

First run `claude` and sign in once. Claude Code 2.1.129 or newer is required
for gateway model discovery. Then run:

```bash
curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/claude-code-setup.sh \
  | WEBSTER_API_KEY=sk-... bash
```

The installer also reuses the Webster key installed by `codex-setup.sh` when it
is available, so a machine with the Codex proxy already configured can omit the
environment variable:

```bash
curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/claude-code-setup.sh | bash
```

| Flag | Effect |
|---|---|
| _(none)_ | Install + configure + verify |
| `--check` | Verify Claude login, source, secret permissions, endpoint, service, catalog, and settings without changing anything |
| `--key-file PATH` | Read the Webster key from a file's first line |

What it writes:

| Where | What |
|---|---|
| `~/.claude/model-proxy/` | Dependency-free proxy runtime and Webster config; the config is mode `0600` |
| `~/.claude/settings.json` | Merge-safe gateway URL, model-discovery switch, and tool-search setting |
| `~/.claude/cache/gateway-models.json` | Seeded Webster catalog for `/model`, including Claude.ai subscription logins |
| `~/Library/LaunchAgents/com.thefong.claude-code-model-proxy.plist` | Always-on user service on macOS |
| `~/.config/systemd/user/claude-code-model-proxy.service` | Always-on user service on Linux |

The installer seeds Claude Code's gateway cache as well as enabling live model
discovery. This keeps the Webster entries visible for Claude.ai subscription
logins, whose discovery request has no `ANTHROPIC_AUTH_TOKEN` or
`ANTHROPIC_API_KEY` environment credential to send.

The proxy listens only on `127.0.0.1:4816`. It never logs request bodies or
headers. For Webster models it strips the incoming Claude bearer token, API
key, and Anthropic headers before adding the Webster credential. For Claude
models it passes the original request and login through unchanged. The
Webster key lives only in the owner-readable proxy config.

Start a new Claude Code process after installation and run `/model`. The four
Webster entries appear with the built-in Claude entries and are labeled
`(Webster)`. You can also launch one directly:

```bash
claude --model claude-webster-glm-5-2
```

The installer preserves unrelated Claude settings and is byte-identical on a
safe re-run. It is not wired into `install.sh`, because it needs a Webster
secret and an existing Claude login.

## pi

`pi-setup.sh` is the sibling of `omp-setup.sh` for the
[pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) coding
agent: same `webster` endpoint, same **GLM 5.2** default, plus a footer status
line showing generation speed, active model, and session id.

Hand this to someone and they are set up in one command:

```bash
curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/pi-setup.sh \
  | WEBSTER_API_KEY=sk-... bash
```

The env prefix goes on `bash`, not before `curl` — `WEBSTER_API_KEY=sk-... curl … | bash`
sets a shell variable that never reaches the script. Omit it entirely and it
prompts for the key with hidden input, reading `/dev/tty` because stdin is the
pipe carrying the script.

| Flag | Effect |
|---|---|
| _(none)_ | Install + configure + verify, merging into any existing config |
| `--exclusive` | Make `webster` the only provider in `models.json` |
| `--check` | Verify an existing install; changes nothing, exits non-zero on drift |
| `--key-file PATH` | Read the key from a file's first line |

What it writes:

| Where | What |
|---|---|
| `~/.pi/agent/models.json` | `webster` provider: base URL, API key, `glm-5.2` with real limits (mode `0600`) |
| `~/.pi/agent/settings.json` | `defaultProvider: webster`, `defaultModel: glm-5.2` |
| `~/.pi/agent/extensions/tokps-session.ts` | Footer line: `73.4 tok/s • webster/glm-5.2 • 019feddc-…` |

**pi needs Node.js ≥ 22.19**, and the script installs or upgrades it
(NodeSource on apt/dnf, Homebrew on macOS) rather than trusting whatever `node`
is on `PATH`. The distro `nodejs` on Ubuntu 22.04/24.04 is 18.x, which is not
merely missing a feature: pi's ESM uses import attributes
(`with { type: "json" }`), so Node 18 fails to *parse* it. The package installs
cleanly through npm and then dies at startup with
`SyntaxError: Unexpected token 'with'`. The version is asserted up front so
that surfaces as a clear message here instead. A pi already on `PATH` that
cannot start is reinstalled rather than reported as present, so re-running
after a Node upgrade actually repairs it.

Unlike omp, pi has no endpoint discovery, so the model is declared with the
backend's real limits rather than the proxy's metadata — the proxy reports a
null context window, while vLLM rejects `max_tokens` above
`max_model_len=320000`. Override with `PI_CONTEXT_WINDOW` / `PI_MAX_TOKENS`,
or target a different endpoint entirely with `PI_PROVIDER` / `PI_BASE_URL` /
`PI_MODEL`.

The footer rate is **decode speed** — output tokens over the time from first
streamed content to end of generation — so a turn that runs a slow bash command
doesn't dilute it. Providers only report usage on the final stream event, so it
lands at the end of each turn rather than ticking up live. The session id on
that line is what `pi --session <partial-uuid>` takes to resume (`--fork` to
branch instead of append).

**The API key is never stored in this repo** — pass it via `WEBSTER_API_KEY`
(shared with `omp-setup.sh`) or `PI_API_KEY`, use `--key-file`, or let it
prompt. `PI_NO_PROMPT=1` makes a missing key a hard failure instead, for cron
and provisioning.

Verification runs on every install and under `--check`, per
[STYLE_GUIDE.md](STYLE_GUIDE.md): the provider and default model as they landed
on disk, that `pi` starts with the extension loaded, and that the endpoint
actually accepts the key. A rejected key (HTTP 401/403) is a failure, not a
warning — otherwise a typo'd paste only surfaces on the first prompt. An
unreachable endpoint just warns, so offline machines still get configured
(`PI_SKIP_ENDPOINT_CHECK=1` skips it outright). Failure paths — no key,
unreadable `--key-file`, unparseable `models.json`, a rejected key, and
credential file permissions — are covered in `test.sh`.

Re-running is safe: other providers survive a merge, an unparseable config is
left untouched, and the extension is only rewritten when its content differs.
Like `omp-setup.sh`, it is not wired into `install.sh`, because it needs a
secret the bootstrap does not have.

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

$PROBE --self-test                              # verify the collector on this machine
$PROBE --brev --brev-instances -o /tmp/acme.json  # enumerate + sweep a brev-managed fleet
$PROBE -o /tmp/acme.json head node-1 node-2     # or name hosts explicitly
$PROBE --hosts-file hosts.txt --include-local   # or read them from a file
```

For brev-managed fleets it drives the CLI directly: `--brev` enumerates physical
nodes and `--brev-instances` cloud instances, which are **two separate lists**
(`brev ls --all` is not a substitute for either). Names double as SSH aliases
via `~/.brev/ssh_config`, and non-Connected nodes are swept anyway and flagged
up front, since `Connected` is control-plane registration rather than
reachability. The sweep never runs `brev refresh` itself — that writes to
`~/.brev/`, and it stays read-only.

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
