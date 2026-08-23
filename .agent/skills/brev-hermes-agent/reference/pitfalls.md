# Pitfalls — every one of these failed SILENTLY

Ordered by how much time each cost when building the agent (2026-08-22/23). The theme:
almost none announce themselves. `brev ls` says RUNNING, the installer says it finished,
the skill file is on disk — and the thing does not work.

## Provisioning

**`brev create` cannot pin a region; retrying is useless.**
It never sends `location`, so the API uses the instance-type catalog default
(`asia-south1` for `n2d-standard-2`). Three delete/recreate cycles landed in Mumbai —
deterministic, not capacity. `store.CreateWorkspacesOptions` declares
`Location`/`SubLocation` with `omitempty`, but only the *launchable* code path populates
them. Fix: POST the create yourself with `location` + `subLocation`.
Upstream: brevdev/brev-cli#454.
→ Symptom: instance works fine, just ~238 ms away from everything it talks to.

**Lifecycle / `--startup-script` runs as NON-ROOT.**
First privileged command fails; `set -e` kills the remainder. `brev ls` still reports a
healthy instance. Ours applied *nothing* — no swap, no packages — and looked fine.
→ Check `/var/log/brev/oncreate_lifecycle_script_*.log`, not the instance status.
→ Fix: provision over SSH with `sudo` afterwards, idempotently.

**`brev refresh` can write an unusable SSH entry.**
It emits `Host <name> → <public-ip>:22`, which is firewalled; the real listener is the
brev gateway on the API's `sshPort` field. Put a corrected `Host` block **above** the
brev `Include` in `~/.ssh/config` (ssh is first-match-wins), and re-read `sshPort` after
any recreate — it changes.

**`brev delete` hangs.** Repeatedly, on multiple instances, even with stdin closed,
while the API answered the same query in <1 s. Not reproducible on demand.
→ Fallback: `DELETE /api/workspaces/{id}` → 202.

## Hermes install

**Missing `libatomic1` → `exit 127` + infinite Node re-download.**
The bundled Node cannot load `libatomic.so.1`, so the installer decides Node is "too
old", downloads it again, and loops. The top-level output is just `127`; the real error
is buried in the log.
→ `sudo apt-get install -y libatomic1` first. `--skip-browser` does NOT skip Node.

**Binary is at `~/.local/bin/hermes`**, not `~/.hermes/bin` (uv/uvx live there).
→ A systemd unit with the wrong path crash-loops `203/EXEC` — 120 restarts before we
caught it. Check `systemctl --user status` after writing any unit.

**`model.api_key` must be set in `config.yaml`.**
Hermes does not read `OPENAI_API_KEY` from `.env` for `provider: custom`. It sends a
literal `no-key-required`, and the gateway returns a 401 naming a key you never set —
which reads like a proxy bug.
→ `hermes config set model.api_key '<key>'`.

**`base_url` must not have a trailing slash.**

## Exposure

**A secure link's SSO protects the public path ONLY.**
On a `NETWORK_MEMBER_TYPE_SHARED` instance every mesh peer reaches the port directly.
Verified before firewalling: another node got HTTP 200 on `/api/status`. Jupyter on 8888
had the same hole and was only found by auditing listeners against firewall rules.
→ Firewall every exposed port; re-audit whenever a new service is added.

**Probing your own mesh IP from the same host is routed over `lo`.**
The firewall's `-i lo ACCEPT` allows it, so the check returns 200 and looks like a
breach. → Always verify from a *different* node.

**iptables does not survive reboot.** If a firewall is the only thing in front of an
unauthenticated surface, it needs a `systemd` oneshot unit or it silently disappears.

**Websocket close 1006 + reconnect loop = Host/Origin guard, not a proxy failure.**
Hermes re-checks the DNS-rebinding guard at upgrade time (FastAPI middleware does not
run for WebSocket routes), and it checks **Origin as well as Host**. Rewriting only Host
gives `/api/pty` → 403.
→ The real reason token is in **`~/.hermes/logs/gui.log`** (`origin_mismatch origin=…
bound=…`), *not* journalctl. Add `proxy_set_header Origin http://127.0.0.1:<port>;`.
→ Caveat: a synthetic `curl` upgrade probe without the `?token=` fails with
`no_credential` instead — a *different* 403 that sends you down the wrong path.

**Rewriting Origin forfeits that layer's CSRF protection.** Only acceptable behind a
firewall + SSO. Do not copy the pattern into a directly-exposed deployment.

## Skills

**`~/.claude/skills/` is invisible to Hermes.** It has its own loader rooted at
`~/.hermes/skills/<category>/<name>/`. A copy in the wrong place looks installed and
does nothing. Frontmatter also differs (`metadata.hermes.{category,tags}`, no
`allowed-tools`).
→ Verify with `hermes skills list` **and** by asking the agent to list its skills.

**The `description` field drives retrieval.** A narrow one means the skill never loads
for the questions it should answer. Ours missed security/network queries until widened.

**Hermes can self-patch skills**, and a curator marks them stale at 30 d / archives at
90 d. A one-way `rsync --delete` from a canonical copy will silently destroy
agent-authored edits.
→ Record a hash of what you last pushed and refuse to sync on drift. Compare against
*last pushed*, not against current canonical — otherwise every normal edit trips it.

## Collectors / cron

**Python 3.10 rejects escaped quotes inside f-string expressions.** `f"{d.get(\"k\")}"`
is a SyntaxError; piped through `2>/dev/null || echo UNREACHABLE` it silently became a
bogus "Prometheus unreachable" for every run. Use `%`-formatting in embedded snippets.

**A LAN address is not reachable from a cloud instance.** Our collector used a service's
LAN IP; the agent dutifully reported it down. Use the mesh address.

**Bound every remote call with `timeout`.** One wedged host otherwise stalls the whole
job and runs pile up. Exit 0 even when findings exist — a non-zero exit is the
"watchdog itself broke" signal.

**Approvals fail closed for cron** (`cron_mode: deny`) and for single-query mode. That
is correct, but it means a flagged command in a scheduled job silently returns
`approval_required` rather than prompting anyone.

## Model behaviour (a self-hosted reasoning model, likely other reasoning models)

**Reasoning bills against the SAME completion budget as content.** With a tight
`max_tokens` you get HTTP 200, `content: null`, `finish_reason: "length"` — which looks
like truncation but is reasoning eating the whole budget. Leave `max_tokens` generous.

**`reasoning_effort` is binary here, not a ladder.** Measured n=3 on an identical
prompt: `none` mean **45** completion tokens; `medium` **811**; `max` **914** — and the
medium/max ranges overlap heavily. `none` disables thinking; everything else just leaves
it on. Setting `high`/`max` to "think harder" is a no-op.

**LiteLLM returned `completion_tokens_details.reasoning_tokens` as null** on this route,
so reasoning cannot be measured separately from `usage` — infer from `completion_tokens`
versus rendered content length.
