---
name: brev-hermes-agent
description: Build a Hermes Agent on a Brev instance end to end - provision the VM in the region you actually want, install Hermes, point it at a self-hosted OpenAI-compatible model, expose its web UI safely behind SSO, connect Telegram, write skills and a personality, and schedule recurring jobs. Use when creating any new agent on Brev, adding a monitoring/ops/research bot, exposing an agent UI securely, or debugging a Hermes install. Trigger keywords - hermes agent, nous, build an agent, agent on brev, ops bot, monitoring agent, telegram bot, ttyd, webshell, secure link, agent skill, cron job, gateway, reasoning effort, dashboard 1006, agent personality, system prompt.
allowed-tools: Bash, Read, Edit, Write, WebFetch, AskUserQuestion
---
<!--
Token Budget:
- Level 1 (YAML): ~140 tokens
- Level 2 (this file): ~2000 tokens
- Level 3 (reference/): loaded on demand
Distilled from building a real cluster monitoring + security agent end to end.
Every gotcha below cost actual debugging time; none are theoretical.
-->

# Building a Hermes Agent on Brev

Recipe for standing up a [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(Nous Research, MIT) on a Brev instance — **whatever the agent is for**. Backed by any
OpenAI-compatible model, reachable from a browser and a phone, optionally doing
scheduled work.

Steps 1-6 and 10 are identical for every agent. Steps 7-9 are where an agent becomes
*a particular* agent.

**Read [reference/pitfalls.md](reference/pitfalls.md) before you start.** Roughly half
the steps below have a failure mode that is silent — the install "succeeds" while doing
nothing, the model 401s with a key you never set, the chat reconnect-loops with a
useless error code. Knowing them up front turns a day into an hour.

## Pick the archetype — it drives everything after step 6

| archetype | typical trigger | needs | autonomy |
|---|---|---|---|
| **Monitor / ops** | cron | collector scripts, read access to what it watches | read-only, escalates |
| **Research / digest** | cron or ad-hoc | web/API access, a summarisation style | read-only |
| **Assistant / triage** | inbound message | inbox/queue integration, a decision rubric | may act, gated |
| **Domain expert** | ad-hoc question | reference skills carrying the facts | read-only |
| **Builder / automator** | ad-hoc or event | repo + tool access, a test loop | acts, tightly gated |

Most agents are one of these plus a couple of skills. The mechanics do not change; the
skills, personality, jobs, and `approvals.deny` do.

## Decide these first

| question | why it matters |
|---|---|
| **What is this agent's ONE job?** | drives the skills, the personality, and the schedule. A vague agent is a bad agent. |
| **Does it act, or only report?** | determines `approvals.deny`. An agent with credentials and no deny-list is a liability, not a feature. |
| **How is it triggered?** | cron, inbound message, or you asking. Decides whether you need step 8 at all. |
| **Which region?** | must match whatever it talks to; cross-region cost us ~238 ms/hop. **The CLI cannot set this** — see step 1. |
| **Who may reach the UI?** | SSO-gated vs public. Never public for an agent with a shell. |

## 1. Provision the VM — in the region you actually want

**`brev create` cannot pin a region.** It never sends `location`, so the API falls back
to the instance-type catalog default (`asia-south1` for `n2d-standard-2`). Retrying does
not help — it is deterministic, not capacity. Upstream: brevdev/brev-cli#454.

POST it yourself (see the `brev-cli` skill for the full body and how to capture it):
```bash
curl -X POST "$BASE/api/organizations/$ORG/workspaces" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"name":"my-agent","workspaceGroupId":"GCP","workspaceClassId":"2x8",
       "workspaceTemplateId":"<id>","instanceType":"n2d-standard-2",
       "diskStorage":"120Gi","workspaceVersion":"v1",
       "vmBuild":{"forceJupyterInstall":true},
       "location":"us-west2","subLocation":"us-west2-a"}'
```
Sizing: 2 vCPU / 8 GB is plenty (Hermes' own floor is 1 GB / 1 core without browser
tools). Skip Playwright and it is a light process.

⚠️ **`brev delete` has hung repeatedly.** Use `DELETE /api/workspaces/{id}` → 202.

## 2. Provision the box — with `sudo`, not `--startup-script`

**Brev lifecycle scripts run as NON-ROOT.** A `--startup-script` that does anything
privileged dies at the first `sudo`-less command, and with `set -e` the rest never runs —
while `brev ls` still says the instance is fine. Ours silently applied *nothing*.

Run provisioning over SSH afterwards instead, idempotently:
```bash
sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo apt-get install -y curl git jq ripgrep ffmpeg tmux python3 python3-venv libatomic1
```
Swap matters: 8 GB of RAM with Node + Python + a long agent context gets tight.

⚠️ **`brev refresh` may write a broken SSH entry** (raw public IP on port 22, which is
firewalled). The real listener is the gateway on the API's `sshPort`. Put a corrected
`Host` block **above** the brev `Include` in `~/.ssh/config` — ssh is first-match-wins.

## 3. Install Hermes

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
  | bash -s -- --skip-setup --skip-browser --skip-computer-use
```
**Install `libatomic1` FIRST.** Without it the bundled Node cannot load, and the
installer reports a bare `exit 127` while silently re-downloading Node in a loop. The
real error only appears if you read the log. `--skip-browser` does **not** skip Node.

The binary lands at **`~/.local/bin/hermes`**, *not* `~/.hermes/bin` (that holds
uv/uvx). A systemd unit with the wrong path crash-loops on `203/EXEC`.

## 4. Point it at your model

```bash
hermes config set model.provider custom
hermes config set model.default   <served-model-name>
hermes config set model.base_url  https://<endpoint>/v1     # NO trailing slash
hermes config set model.api_key   '<key>'
hermes config set model.context_length 320000
```
⚠️ **`model.api_key` must be in `config.yaml`.** Hermes does **not** read
`OPENAI_API_KEY` from `.env` for a custom provider — it sends a literal
`no-key-required` and your gateway 401s. This is the single most confusing early failure.

Requirements: the endpoint must do **tool calling** (the agent is entirely tool-driven)
and advertise **≥64K context**. Smoke-test with `hermes -z "say hello"` before anything else.

On reasoning: `reasoning_effort` defaults to `""` (provider default). For a self-hosted reasoning model we
measured it as **binary** — `none` disables thinking, every other value just leaves it
on; `low`/`medium`/`high`/`max` are not honored as a ladder. Don't expect a quality dial.

## 5. Expose the UI — SSO in front, firewall underneath

The dashboard is **`hermes dashboard`, port 9119** (`hermes serve` = headless). Port
8642 is a JSON API with no HTML. It is mobile-responsive.

**The safe shape** (this exact layout is running in production):
```
brev secure link (Pomerium -> SSO)  ->  nginx :9119  ->  hermes 127.0.0.1:9120
```
Bound to `0.0.0.0` Hermes *forces* its own auth gate on (`--insecure` is a no-op).
Bound to loopback the gate is off but a DNS-rebinding guard accepts only loopback
Host/Origin. So nginx must rewrite **both**:
```nginx
proxy_set_header Host   127.0.0.1:9120;
proxy_set_header Origin http://127.0.0.1:9120;   # omit this -> websocket 1006 loop
```
Create the link with `EnvironmentService/OpenHTTPPort` and `authorizedEmails`
(see `brev-cli`). **Never `allowPublicUnauthenticated` for an agent** — an
authenticated session is a shell (`/api/pty`), reads every secret (`/api/env`), and the
Files API has **no path containment** unless you set `HERMES_DASHBOARD_FILES_ROOT`.

🔒 **The step everyone misses.** If the instance is `NETWORK_MEMBER_TYPE_SHARED`, the
SSO link protects the *public* path only — **every mesh peer can hit the port directly**.
Firewall every exposed port to the brev ingress peers, via a `systemd` oneshot
(**iptables does not survive reboot**), and verify **from another host** (probing your
own mesh IP routes over `lo` and gives a false 200). Full script:
[reference/exposure.md](reference/exposure.md).

## 6. Telegram (do this in the web UI)

Easiest path, and it handles pairing for you:

1. Get a bot token from **@BotFather** in Telegram.
2. Open the dashboard → messaging/platform settings → **Telegram** → paste the token.
3. **Set the allowed users before starting it.** Otherwise the first stranger to
   message the bot claims it (first-DM-wins pairing).
4. Scan the **QR code** the UI shows to open the chat on your phone, then set your
   chat as the **home channel** so cron jobs have somewhere to deliver.
5. `hermes gateway install && hermes gateway start` (real systemd unit).

Equivalent env keys if scripting: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`,
`TELEGRAM_HOME_CHANNEL` in `~/.hermes/.env`. Long-polling by default — no inbound ports.

## 7. Skills and personality — where the agent becomes itself

**Skills live in `~/.hermes/skills/<category>/<name>/SKILL.md`.** A copy under
`~/.claude/skills/` is **silently invisible** — Hermes has its own loader. Frontmatter
needs `metadata.hermes.{category,tags}` instead of `allowed-tools`.

Two kinds of skill, and separating them is the single most useful structural choice:

- **Reference skills** carry *facts* — topology, inventory, API shapes, domain data.
  They change when the world changes.
- **Judgment skills** carry *how to decide* — how to weigh evidence, what counts as
  urgent, what to do when a check fails. They change when your policy changes.

Keep them apart so either can be maintained without touching the other, and let judgment
skills say "read the `<reference>` skill for the facts."

Give every skill a rich `description`: it drives retrieval, and a narrow one means the
skill never loads when it should. This is the most common reason a skill "doesn't work".

**Personality is operating posture, not flavour.** The lines that earn their keep are
constraints on behaviour:

- **A silence rule** for anything that notifies you: *"reply exactly `[SILENT]` when
  nothing needs action."* Notification fatigue is what kills a scheduled agent — a
  channel that pings "all clear" hourly gets muted, and then the real alert is missed.
- **"Distinguish 'I could not check' from 'it is fine.'"** Unverified is a finding, not
  a pass. Applies to any agent that reports on something.
- **An explicit action boundary** — *"you escalate; you do not remediate"*, or whatever
  the real boundary is — paired with `approvals.deny` so it is enforced, not just asked for.
- **A severity/priority ladder with examples**, plus "do not inflate."
- **A fixed output shape** so a phone notification is actionable. For a monitor:
  headline / evidence / RECOMMEND / CHECKED / UNVERIFIED. For a digest: what changed /
  why it matters / what to read. Pick one and make it mandatory.

## 8. Scheduled jobs (only if the agent is triggered by time)

```bash
hermes cron create "every 30m" \
  "<what to do with the attached output. Report only what needs action and what
    CHANGED since last run. If nothing, reply exactly [SILENT].>" \
  --script collect.sh --skill <judgment-skill> --skill <reference-skill> \
  --name <job> --deliver telegram --continuity
```

Four patterns worth knowing:

| pattern | shape | good for |
|---|---|---|
| **collect → interpret** | deterministic script gathers evidence, agent judges it | monitoring, anything where gathering is cheap and judging is the hard part |
| **zero-token watchdog** | `--no-agent --script x.sh`; empty stdout = silent, nonzero exit = alert | high-frequency checks where no reasoning is needed |
| **agent-only** | no script; the agent uses its own tools | research, digests, inbox triage |
| **continuity digest** | `--continuity` so each run sees its last output | anything where *what changed* matters more than current state |

Prefer **collect → interpret** whenever the inputs are scriptable: it keeps token cost
flat and makes runs reproducible, because the evidence is the same regardless of model.

- Scripts **must** live in `~/.hermes/scripts/`.
- **`timeout`-bound every remote call** in a collector, or one wedged host stalls the
  schedule and runs pile up.
- Exit 0 even when there are findings — a nonzero exit is the "watchdog itself broke" signal.
- Approvals **fail closed** for cron (`cron_mode: deny`) by design.

## 9. A utility shell (optional but very useful)

`ttyd` + `tmux` gives a browser terminal with tabs and sessions that survive refresh —
handy when the agent is wedged and you are on a phone. Use
[theFong/setup `webshell/`](https://github.com/theFong/setup/tree/main/webshell):
```bash
sudo apt-get install -y cmake libwebsockets-dev libjson-c-dev   # build deps first
./install.sh                       # private: loopback + generated password
./install.sh --public --iface lo   # loopback, NO password (auth proxy assumed)
```
**Bind loopback either way** and front it with nginx + secure link + firewall exactly
like the dashboard. It builds ttyd from source deliberately — release builds ship an
xterm.js with no OSC 52, so clipboard silently fails.

Whether to keep its password is a real judgement call, not a default. A second factor
only helps if the firewall fails — so it is worth keeping **unless** a co-located
surface is already unauthenticated behind that same firewall (e.g. the Hermes dashboard,
whose `/api/pty` is also a shell). In that case the password buys inconsistency rather
than defense, and dropping it is defensible. Note "public" mode means *no built-in auth,
an auth proxy is assumed* — it does **not** mean bind `0.0.0.0`; pair it with
`--iface lo`.

⚠️ **This is a root shell** wherever the service user has passwordless sudo, and it has
**no approval layer** — `approvals.deny` does not apply. Treat the firewall + SSO as
load-bearing, and add its port to the firewall list in the same change.

## 10. Constrain what it can do

```yaml
approvals:
  mode: smart
  deny:                      # evaluated BEFORE any yolo/off mode; unbypassable
    - "*<destructive-verb>*"        # e.g. deletes, deploys, sends, pays
  smart_policy: |
    ESCALATE <the class of action only a human should authorise>.
    APPROVE <the read-only or reversible actions this agent needs>.
```
Verify, don't assume: `hermes approvals test '<cmd>'` → `0`=allow, `2`=prompt, `3`=deny.
Also note secrets are stripped from tool subprocesses (vars matching
`KEY|TOKEN|SECRET|…`); allowlist via `terminal.env_passthrough`.

## Verify it actually works

Test the *behaviour*, never just the file:
```bash
hermes -z "List the names of every skill you have available."      # skill discovery
hermes -z "Consult <skill> and answer <question about it>."         # retrieval works
hermes cron run <job-id>                                            # then confirm delivery
grep "delivered to telegram" ~/.hermes/logs/*.log
```
A skill on disk that the agent cannot retrieve is worse than no skill — it looks done.

## Worked example — a cluster monitoring + security agent

Everything above is archetype-agnostic; this is one instantiation, to make it concrete.

| decision | choice |
|---|---|
| job | watch a GPU cluster's health; review its security posture |
| autonomy | **read-only** — escalates, never remediates |
| trigger | cron: health every 30 m, security every 6 h |
| interface | SSO-gated web UI + Telegram for alerts |

**Skills** — one reference, two judgment:
- `cluster-facts` (reference) — node inventory, ports, expected state
- `health` (judgment) — what "degraded" means, what to do when a node is unreachable
- `security` (judgment) — severity ladder, this fleet's real failure modes

**Jobs** — both *collect → interpret*, `--continuity`, delivering to Telegram, both
replying `[SILENT]` unless action is needed.

**`approvals.deny`** — every infrastructure-mutating verb (create/delete/stop, network
and exposure changes, credential issuance), verified with `hermes approvals test`.

**What made it useful rather than noisy:** the silence rule, a fixed output shape
(headline / evidence / RECOMMEND / CHECKED / UNVERIFIED), and skills that encode *this*
fleet's real historical failure modes instead of generic best practice — an agent that
knows the one service which dies while its container still reports healthy is worth more
than one that recites checklists.

Swap the three skills and the two job prompts and the same scaffold is a research
digest, an inbox triage bot, or a deploy verifier. Steps 1-6 and 10 do not change.
