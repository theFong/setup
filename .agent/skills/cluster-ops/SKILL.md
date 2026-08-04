---
name: cluster-ops
description: Onboard a compute cluster and generate a durable per-cluster operations skill from it, then keep that skill true. Carries portable GPU-fleet failure patterns - overlay-network collisions, containers that do not survive reboot, RDMA/interconnect verification, telemetry that lies, ingress and routing rules. Use when a cluster has no skill yet, when a cluster skill is stale or wrong, when adding or decommissioning a node, or when diagnosing a fleet problem the cluster's own skill does not cover. Trigger keywords - onboard cluster, new cluster, document cluster, cluster skill, node inventory, probe nodes, fleet, overlay mesh, netbird, tailscale, wireguard, cgnat, dcgm, nvidia-smi power, roce, infiniband, nccl, restart policy, cdi spec, prometheus targets, prefix cache routing.
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, WebFetch, AskUserQuestion
argument-hint: [onboard <cluster-name> | diagnose <symptom> | verify <cluster>]
---
<!--
Token Budget:
- Level 1 (YAML): ~150 tokens
- Level 2 (this file): ~1500 tokens
- Level 3 (reference/, templates/): loaded on demand
-->

# Cluster Ops

Generic machinery for operating compute clusters: an onboarding flow that turns
an unknown fleet into a trustworthy `<cluster>-cluster` skill, and the portable
failure patterns that recur across every fleet.

**This skill holds what is true of clusters in general. A `<cluster>-cluster`
skill holds what is true of one fleet.** Keep facts on the right side of that
line and a fix reaches every cluster instead of one.

## Rule 0 — an existing cluster skill wins

If a skill already exists for the fleet in question, **use it**. It has the
addresses, the safety rules, and the incident history. Come here only to:

- onboard a fleet that has no skill yet
- diagnose something that skill does not cover → `reference/diagnostics.md`
- add/remove a node, or repair a skill that has gone stale → `reference/contract.md`

Never let a generic answer here override a specific fact there. If the two
disagree, **the machine is right** — verify, then fix the cluster skill in the
same session.

## Onboarding a new cluster

Full procedure, including the interview questions and the field-by-field
reading of probe output: **[reference/onboarding.md](reference/onboarding.md)**.

| Phase | Do |
|---|---|
| 0. Scope | What is production? What is the blast radius? Anything mid-incident? What is the cluster called? |
| 1. Enumerate | Get the host list from the control plane, then ask what is missing or decommissioned |
| 2. Probe | `scripts/probe-cluster.sh` across every node — read-only |
| 3. Interview | Safety rules, why-it-runs-there, history, what is known-broken |
| 4. Render | Fill `templates/`, delete inapplicable sections, real trigger keywords |
| 5. Verify | Re-probe, diff against what you wrote, downgrade anything inferred |
| 6. Install | Repo skills dir + Codex mirror; report what is *not* covered |

```bash
SKILL_DIR=~/.claude/skills/cluster-ops
"$SKILL_DIR/scripts/probe-cluster.sh" --self-test                  # prove the collector runs here
"$SKILL_DIR/scripts/probe-cluster.sh" -o /tmp/acme-probe.json head node-1 node-2
```

The probe is **read-only by construction**: it reads `/proc`, `/sys`,
`/etc/os-release` and `/etc/docker/daemon.json`, runs query-only commands, and
uses `sudo` for nothing but `sudo -n true` to detect passwordless sudo. Say that
to the operator before sweeping nodes they own. A host that fails still gets a
record and the script exits nonzero — **an unprobed node is a finding**.

## Non-negotiables for a generated skill

1. **Never document intent.** Verify live, then write. A confidently wrong table
   sends the next agent to the wrong IP.
2. **Safety Rules first** — what is load-bearing, what must never change, what
   needs a window. This is the highest-value section and cannot be probed.
3. **Record the access shape per node** (SSH user, sudo, docker-without-sudo).
   Twins drift into opposite shapes and automation breaks on it.
4. **Record *why*, not only what** — especially anything deliberately not pooled,
   not exposed, or not upgraded. Undocumented reasons get "tidied up".
5. **Label every measured number** with workload and method, or it is not
   reproducible.
6. **Cite diagnostics by section; do not copy them** into the cluster skill.
7. **Mirror to `~/.codex/skills/`.** Equivalent Claude Code and Codex support is
   a standing requirement of this repo.

## Portable failure patterns

Load **[reference/diagnostics.md](reference/diagnostics.md)** when a symptom
matches. Each entry has the fingerprint that identifies it and the fix that
worked.

| Symptom | § |
|---|---|
| Some mesh services on a node work, others don't, while peers report Connected | 1.1 — two overlays colliding in CGNAT `100.64.0.0/10` |
| SSH refused via the control plane, node otherwise healthy | 1.4 — jump via a LAN peer |
| A service degrades under load after "working" | 1.5 — pinned to a dual-homed node's second address |
| Container with `unless-stopped` did not come back after reboot | 2.1–2.4 — policy replay, manual-stop flag, stale CDI spec |
| Container crash-loops after a boot or a quiet month | 2.5 — entrypoint bind-mounted from `/tmp` |
| Fabric is cabled and ACTIVE but NCCL won't use it | 3.2–3.3 — GIDs need configured addresses; NM flushes manual IPs |
| Disagreement about how many cables are plugged in | 3.1 — ACTIVE devices ÷ PCIe views; ignore lane encoding |
| Power or cost figures look impossibly low | 4.1 — `nvidia-smi` is die-only on some platforms |
| GPU shows 95% util but throughput is flat | 4.2 — spinning sync kernels count as busy |
| Throughput or cost numbers that seem too good | 4.3–4.4 — prefix-cache hits inflate prefill rates; short windows break pricing |
| Chasing single-stream speed with config changes | 5.1 — measure the roofline first; the headroom is usually concurrency |
| Tempted to load-balance two identical model servers | 5.2 — generic routers are prefix-cache-blind and halve the hit rate |
| Model narrates or loops instead of acting | 5.5 — sampling defaults, fixable at the proxy |
| A script works on one node of a pair and fails on its twin | 6 — access asymmetry; `sudo` must precede `env` |
| A number that changed on the second boot | 7 — first-boot measurements are artifacts |

## Keeping a cluster skill true

**Update the skill in the same change as the infra, not afterwards.** Triggers,
procedure, anti-drift rules, and how to retire a skill:
**[reference/contract.md](reference/contract.md)**.

Ask of every new lesson: *would this be true on a different cluster?* If yes it
belongs in `reference/diagnostics.md` here, not in the cluster skill.

## Related Skills

| Need | Go to |
|---|---|
| This fleet's addresses, models, ports, incident history | the `<cluster>-cluster` skill |
| Provisioning: create/delete instances, GPU search, port forward, file copy | **`brev-cli`** (or your provider's skill) |
| Authoring a skill that is not a cluster skill | **`skill-creator`** |
