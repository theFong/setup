# Onboarding a Cluster

Six phases, in order. The output is a self-contained `<cluster>-cluster` skill
that the next agent loads automatically and can trust.

**The rule that governs all six: never document intent.** Everything written
into the skill must have been observed on the machine during this session, or be
explicitly marked as reported-by-the-operator. A confidently wrong table is worse
than a missing one.

---

## Phase 0 — Scope and consent

Before touching anything, establish with the operator:

1. **What is production here?** Which endpoint, model, or job would page someone
   if it went down? This becomes the skill's Safety Rules section, which is the
   single highest-value part of the output.
2. **What is the blast radius of the probe?** `scripts/probe-cluster.sh` is
   read-only — it reads `/proc`, `/sys`, `/etc/os-release`,
   `/etc/docker/daemon.json` and runs query-only commands. Say so, and say that
   it runs `sudo -n true` (and only that) to detect passwordless sudo. Get a
   yes before sweeping nodes you do not own.
3. **Is anything mid-incident or mid-deploy?** If so, onboard later. A snapshot
   of a broken fleet becomes a permanent lie in the skill.
4. **What is the cluster called?** This becomes the skill name
   (`<cluster>-cluster`) and its trigger keywords. Ask; do not invent one.

Do not skip this phase because it feels like paperwork. Safety rules and
ownership are the two things that cannot be discovered by probing.

---

## Phase 1 — Enumerate the hosts

Get a host list before probing. In rough order of reliability:

```bash
brev ls && brev ls nodes            # if the fleet is brev-managed (see the brev-cli skill)
awk '/^Host /{print $2}' ~/.ssh/config ~/.brev/ssh_config 2>/dev/null
kubectl get nodes -o wide           # if Kubernetes-managed
sinfo -N -o '%N %f'                 # if Slurm-managed
```

Then reconcile with the operator: ask explicitly **"is anything missing from
this list, and is anything on it decommissioned?"** Control planes routinely
disagree with reality. Expect to find nodes that are listed but disconnected,
and nodes that exist but were never registered.

Record for each host, before probing:

- the **name you will use in the skill** (usually the SSH alias, which is often
  *not* the hostname — record both)
- which **site** it is at, if there is more than one
- whether it is a control-plane/head node, a worker, or a cloud VM

**Sites matter more than they look.** Two sites with no route between them is a
different fleet topology from one flat LAN, and it changes every access
instruction in the skill. Ask directly.

---

## Phase 2 — Probe

```bash
SKILL_DIR=~/.claude/skills/cluster-ops     # or ~/.codex/skills/cluster-ops
"$SKILL_DIR/scripts/probe-cluster.sh" --self-test          # prove the collector works here
"$SKILL_DIR/scripts/probe-cluster.sh" -o /tmp/<cluster>-probe.json \
    head node-1 node-2 node-3
```

Notes:

- Hosts are whatever `ssh <name>` already resolves. Fix SSH first — the script
  does not manage keys, and uses `BatchMode=yes` so it never hangs on a prompt.
- A host that fails still gets a record, with an `error` field, and the script
  exits nonzero. **Do not drop failed hosts from the skill** — a node that could
  not be probed is a finding. Record it as unverified.
- `--include-local` adds the machine you are running on (usually the head node,
  where agents run).
- Re-run it after any infra change. It is the cheapest way to keep a skill true.

Then read the JSON. Do not paste it into the skill; it is input, not output.

### Reading the probe output

| Field | What it decides in the skill |
|---|---|
| `host` vs `hostname` | The inventory table keys on `host` (the alias). Record `hostname` too when they differ — they usually do. |
| `ssh_user`, `sudo_nopasswd`, `docker_needs_sudo` | The **access asymmetry** column. Nodes drift into opposite shapes; automation breaks on it. See diagnostics §6. |
| `gpus`, `arch`, `kernel` | Hardware rows. Driver/kernel skew across a pair is worth noting but is not automatically fatal (diagnostics §3.6). |
| `gpu_module_power` | A wattage = real module meter. **`N/A` = die-only**: power and cost figures from this node are understated, often ~3.5x. Say so in the skill (diagnostics §4.1). |
| `containers` | What actually runs where, plus `restart=` per container. Anything not `always`/`unless-stopped` **will not survive a reboot** (diagnostics §2.1). Flag `exited` containers — they are either dead services or leftovers nobody removed. |
| `docker_default_runtime` | `nvidia` here means *every* container gets CDI injection, so a stale CDI spec takes the whole node down, not just GPU containers (diagnostics §2.4). Compare across a pair; they drift. |
| `cdi_specs` | Empty on a node that needs GPU containers is worth a look. |
| `interfaces`, `default_routes` | The address-plane table. Watch for: two addresses on one subnet (dual-homed, §1.5), `mtu=1500` on an RDMA rail (§3.5), and Wi-Fi-only nodes. |
| `netbird`, `tailscale` | Which overlays are installed. **Two overlays present is a finding, not a detail** (§1.1). Note which prefix belongs to which. |
| `ts_input_drops` | Non-empty means the CGNAT collision is live right now. `unknown (needs root)` means unverified, not clean. |
| `listeners` | The port map. Loopback-only entries are deliberate ingress design — record *why* in the skill, or someone will "fix" it by rebinding to `0.0.0.0`. |
| `rdma_ports` | ACTIVE count ÷ PCIe views = cable count. Read `phys_state`, not `rate` (§3.1). An ACTIVE port with no IP is unusable spare capacity (§3.2). |
| `failed_units` | Free leads. Chase them before writing "healthy". |

---

## Phase 3 — Interview

Probing finds facts. It cannot find intent, history, or constraint. Ask, using
`AskUserQuestion` where the answer is a choice among a few options:

**Safety (highest value — get these right)**

1. Which endpoints/services are load-bearing, and what must never change about
   them (URL, port, bind address)?
2. What has an ingress policy in front of it, and what does that policy allow?
3. What is safe to restart, and what needs a maintenance window?
4. Is any credential dual-purpose (an API key that is also an admin key)?

**Placement and intent**

5. Why does each model/job run where it does? (Which constraints are physical —
   memory fit, fabric — and which are historical?)
6. Is anything deliberately *not* behind the shared router or load balancer? Why?
   This is exactly the decision a future agent will undo without the reason
   written down (diagnostics §5.2).
7. What upstream config points at a **LAN** address rather than an overlay
   address? Those break silently if a node moves.

**History**

8. What has broken before, and what was the actual cause? Cross-reference
   `reference/diagnostics.md` — if it matches a known pattern, cite the pattern
   instead of re-describing it.
9. What has been investigated and ruled out? Record negative results; they are
   what stops the investigation being repeated.
10. What is known-broken or unmonitored right now? This becomes "Known gaps",
    and it is the section operators read first.

**Measurement**

11. What are the real performance numbers, measured how, on which prompts or
    workload? Unlabelled figures are not reproducible (diagnostics §7).

Anything the operator asserts but you cannot verify goes in marked as
**reported, not verified**, with the date.

---

## Phase 4 — Render the skill

Copy the templates into place under their real names and fill them in:

```bash
CLUSTER=acme
DEST=~/.setup/.agent/skills/"$CLUSTER"-cluster
mkdir -p "$DEST/reference"
cp "$SKILL_DIR/templates/cluster-skill-template.md" "$DEST/SKILL.md"
cp "$SKILL_DIR/templates/topology-template.md"      "$DEST/reference/topology.md"
cp "$SKILL_DIR/templates/runbooks-template.md"      "$DEST/reference/runbooks.md"
```

Drop `reference/runbooks.md` or `reference/topology.md` entirely if the fleet
does not need them, and remove the links to them from `SKILL.md`. Then, in the
copies:

- Replace every `{{PLACEHOLDER}}`. Grep for `{{` at the end; none may remain.
- **Delete every section that does not apply.** An empty "Inference Stack"
  heading is noise, and noise is what makes a skill stop being read. A
  three-node CPU cluster should produce a short skill.
- Keep the tables as tables. They are scanned, not read.
- Write the `description:` front-matter with **real trigger keywords**: the
  cluster name, every node name, every model name, every service name. This is
  what makes the skill load automatically when someone mentions a node.
- Set `Last verified: YYYY-MM-DD` in the token-budget comment.
- **Keep the body under ~2000 tokens.** Detail goes in `reference/`. If the body
  is growing past that, the excess belongs in `reference/topology.md` or
  `reference/runbooks.md`.
- Do **not** copy portable failure patterns into the new skill. Link to
  `cluster-ops` `reference/diagnostics.md` by section number so a fix in one
  place reaches every fleet.

See `reference/contract.md` for the authoring rules in full.

---

## Phase 5 — Verify

Before telling the operator it is done, prove each claim:

```bash
# 1. Re-probe and diff against what you wrote.
"$SKILL_DIR/scripts/probe-cluster.sh" -o /tmp/<cluster>-verify.json <hosts...>

# 2. Every address in the skill resolves and answers.
for h in <hosts...>; do ssh "$h" 'hostname; ip -br addr'; done

# 3. Every service in the port map is actually listening.
ssh <node> 'ss -ltn'

# 4. Every documented endpoint returns what the skill says it returns.
curl -s -o /dev/null -w '%{http_code}\n' <endpoint>

# 5. No placeholders survived.
grep -rn '{{' ~/.setup/.agent/skills/<cluster>-cluster/ && echo "UNFILLED"
```

Then walk the skill top to bottom and ask of every sentence: *did I see this, or
did I infer it?* Delete or downgrade anything inferred.

---

## Phase 6 — Install and register

1. Place the skill at `~/.setup/.agent/skills/<cluster>-cluster/` (the repo's
   skills directory, which `~/.claude/skills` already points at).
2. **Mirror it for Codex.** Equivalent Claude Code and Codex support is a
   standing requirement of this repo:
   ```bash
   mkdir -p ~/.codex/skills
   ln -s ~/.setup/.agent/skills/<cluster>-cluster ~/.codex/skills/<cluster>-cluster
   ```
   A symlink keeps the two copies from drifting. If the environment needs a real
   copy, add it to the update checklist so both get edited together.
3. Confirm it loads: start a fresh session and check the skill appears in the
   available-skills list with your trigger keywords.
4. Tell the operator what is **not** covered — unprobed nodes, unverified
   claims, gaps found. That list is the honest deliverable alongside the skill.

---

## Anti-patterns

| Do not | Because |
|---|---|
| Copy another cluster's numbers, addresses, or model names | They will be wrong, and they will be believed. Every fact comes from *this* fleet. |
| Write a section because the template has one | Empty scaffolding trains readers to skim. Delete what does not apply. |
| Document a change you just made without verifying it | The whole discipline. Verify, then write. |
| Paste probe JSON into the skill | It is input. The skill holds the interpretation, in tables. |
| Duplicate `diagnostics.md` into the cluster skill | Then a fix reaches one fleet instead of all of them. Cite section numbers. |
| Onboard a fleet mid-incident | You will canonise a broken state. |
| Leave a failed host out of the inventory | An unprobed node is a finding. Record it as unverified. |
