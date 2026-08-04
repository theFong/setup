---
name: {{CLUSTER}}-cluster
description: {{CLUSTER_TITLE}} cluster operations - node inventory, {{OVERLAY}} mesh, SSH access, {{PRIMARY_SERVICE}}, {{OBSERVABILITY_STACK}}, and what runs where. Use when working on any {{CLUSTER_TITLE}} node, changing what it serves, or touching {{LOAD_BEARING_THING}}. Trigger keywords - {{CLUSTER}}, cluster, {{NODE_NAMES_COMMA_SEPARATED}}, {{SERVICE_NAMES}}, {{MODEL_NAMES}}, {{HARDWARE_KEYWORDS}}.
allowed-tools: Bash, Read, Edit, Write, WebFetch, AskUserQuestion
---
<!--
Token Budget:
- Level 1 (YAML): ~120 tokens
- Level 2 (This file): target <2000 tokens
- Level 3 (reference/): loaded on demand
Last verified: {{YYYY-MM-DD}} ({{ONE_LINE_STATE_OF_THE_WORLD}})
-->

# {{CLUSTER_TITLE}} Cluster

Operating manual for the {{CLUSTER_TITLE}} fleet: {{HARDWARE_SUMMARY}},
{{NETWORK_SUMMARY}}.

{{ONE_PARAGRAPH_ANYTHING_UNUSUAL — a second site, a standalone deployment, a
node that is deliberately different. Delete if the fleet is uniform.}}

## Safety Rules - CRITICAL

**{{WHAT_IS_PRODUCTION_HERE}}. Treat it as production.**

1. **NEVER {{IMMUTABLE_THING}}.** {{WHY — e.g. clients are pinned to it}}:
   `{{VALUE}}`
2. **Seldom restart {{SINGLE_POINT_OF_FAILURE}}.** {{WHY}}. Batch config changes
   into one restart; validate config before restarting.
3. **{{BIND_OR_EXPOSURE_RULE}}** — e.g. the proxy must keep binding
   `127.0.0.1:{{PORT}}` only; {{INGRESS}} is the sole ingress.
4. **{{CREDENTIAL_RULE}}** — e.g. never add an admin path to the API port's
   allowlist when the master key doubles as an admin credential.
5. **Update this skill whenever models or infra change** (see Maintenance
   Contract).

<!-- Keep this list short and real. Rules nobody would break are noise. -->

## Quick Start

```bash
{{HOST_LISTING_COMMAND}}          # e.g. brev ls / brev ls nodes / kubectl get nodes
{{REFRESH_COMMAND}}               # if SSH config is generated and can go stale

ssh {{EXAMPLE_NODE}}              # {{ANY_SSH_CONFIG_CAVEAT}}
ssh {{EXAMPLE_NODE}} 'docker ps'
```

Agents run on the **{{AGENT_HOME_NODE}}** node. All cluster access is
{{ACCESS_DIRECTION — e.g. outbound SSH}} from there.

<!-- DELETE IF THE FLEET HAS ONE ACCESS PATH -->
### Getting in when {{PRIMARY_PATH}} is refused

{{FALLBACK_ACCESS_INSTRUCTIONS}}. See cluster-ops
`reference/diagnostics.md` §1.4 for the general jump-host pattern and the three
things that bite.

## Node Inventory

| Node | {{CONTROL_PLANE_COL}} | {{OVERLAY}} | Hardware | SSH user / sudo |
|---|---|---|---|---|
| `{{NODE}}` | {{TYPE}} | `{{OVERLAY_IP}}` | {{HARDWARE}} | `{{USER}}` — {{SUDO_AND_DOCKER_SHAPE}} |

<!-- The access column is not optional. Nodes drift into opposite shapes (docker
     without sudo on one, passwordless sudo but sudo-docker on its twin) and
     automation breaks on it. See diagnostics §6. -->

{{ANY_NODE_NOT_IN_THE_TABLE — decommissioned, disconnected, unprobed. An
unprobed node is a finding, not an omission.}}

### Address planes

<!-- DELETE ROWS THAT DO NOT EXIST. Do not invent planes. -->

| Plane | Range | Covers |
|---|---|---|
| {{SITE}} LAN | `{{CIDR}}` | {{NODES}} |
| {{OVERLAY}} | `{{CIDR}}` | {{NODES}} |
| Interconnect | `{{CIDR}}` | {{NODE_PAIR}} — {{FABRIC}} |
| Cloud VPC | `{{CIDR}}` | {{NODES}} |

| Node | LAN address | iface | Notes |
|---|---|---|---|
| `{{NODE}}` | `{{IP}}` | `{{IFACE}}` | {{DUAL_HOMED_OR_WIFI_ONLY_OR_BMC}} |

{{CALL_OUT_DUAL_HOMED_NODES — a node with two addresses on one subnet answers on
both; pinning a service to the wrong one silently degrades. diagnostics §1.5.}}

## Network

**{{OVERLAY}} mesh** — {{WHICH_NODES}}, interface `{{IFACE}}` on `{{CIDR}}`.
{{REACHABILITY_STATUS_AND_HOW_VERIFIED}}.

{{IF_A_SECOND_OVERLAY_EXISTS: name it, give its range, and state which prefix
belongs to which. Two overlays in CGNAT 100.64.0.0/10 is a live hazard —
diagnostics §1.1.}}

**{{WHAT_DOES_NOT_USE_THE_OVERLAY}}** — {{e.g. which upstream is pinned to a LAN
address and would break if a node moved}}.

<!-- DELETE IF THERE IS NO RDMA FABRIC -->
**Interconnect.** {{NIC_MODEL}}, {{CABLE_COUNT}} cable(s), {{PORT_STATE_SUMMARY}}.

| HCA | netdev | IP |
|---|---|---|
| `{{HCA}}` | `{{NETDEV}}` | `{{IP}}` |

{{MTU_AND_ADDRESSING_STATE}}. Cable counting, GID rules, and the NM-profile
requirement are in diagnostics §3.

<!-- DELETE IF THE FLEET SERVES NOTHING -->
## Service Stack ({{NODE}})

```
{{ASCII_INGRESS_DIAGRAM}}
```

{{HOW_THE_INGRESS_POLICY_WORKS — which port allows what, what returns 403}}

- {{SERVICE}}: container `{{NAME}}`, config `{{PATH}}`, {{DB_OR_DEPS}}

## {{MODELS_OR_WORKLOADS}}

| {{NAME}} | {{ARTIFACT}} | Runs on | Backend |
|---|---|---|---|
| `{{NAME}}` | `{{CHECKPOINT_OR_IMAGE}}` | {{NODES}}, **{{PARALLELISM}}** | {{RUNTIME}}, `{{ADDR}}`, container `{{CONTAINER}}` |

{{WHY_EACH_RUNS_WHERE — which constraints are physical and which are historical.
Also record anything deliberately NOT pooled behind the shared router, and why;
that decision gets undone without a written reason. diagnostics §5.2.}}

{{RESTART_POLICY_CAVEATS — if a compose file sets no policy, say the exact
`docker update --restart` command and on which nodes. diagnostics §2.3.}}

Measured {{DATE}}, {{HOW — workload, prompt type, concurrency, TTFT excluded?}}:
{{NUMBERS}}. <!-- An unlabelled number is not reproducible. -->

Full operating detail is in [reference/runbooks.md](reference/runbooks.md).

<!-- DELETE IF THERE IS NO TELEMETRY -->
## Observability ({{NODE}})

| Service | Port | Notes |
|---|---|---|
| {{SERVICE}} | `{{PORT}}` | {{WHAT_IT_HOLDS_AND_ANY_NON_DEFAULT_CHOICE}} |

**{{N}}/{{N}} scrape targets UP** ({{DATE}}). {{WHAT_IS_NOT_SCRAPED_AND_SO_IS
_INVISIBLE}}.

{{POWER_MEASUREMENT_CAVEAT — if any node reports `N/A` for module power,
nvidia-smi is die-only there and must not be used for cost. diagnostics §4.1.}}

## Maintenance Contract

**This skill is the source of truth and must be updated in the same change as
the infra.** When you add/remove/repoint a workload, move a service, change
ports, or alter the mesh: update the affected table here, refresh
`Last verified`, and mirror the edit to `~/.codex/skills/{{CLUSTER}}-cluster`.

Full rules, update triggers, and the re-probe command: cluster-ops
[reference/contract.md](../cluster-ops/reference/contract.md).

## Troubleshooting

<!-- Cluster-SPECIFIC incidents only, with the actual fingerprint and the fix
     that was applied. Portable patterns belong in cluster-ops diagnostics.md —
     cite them by section instead of restating them. -->

**{{SYMPTOM}}** — {{FINGERPRINT: what is observable, including what stays
healthy and therefore misleads}}. Cause: {{ROOT_CAUSE}}. Fix applied
{{DATE}}: {{FIX}}. {{WHAT_MUST_STAY_THIS_WAY}}.

**{{SYMPTOM}}** — {{...}}

Portable failure patterns — overlay collisions, reboot survival, RDMA
verification, telemetry traps — are in cluster-ops
[reference/diagnostics.md](../cluster-ops/reference/diagnostics.md).

More: [reference/runbooks.md](reference/runbooks.md),
[reference/topology.md](reference/topology.md).

## Related Skills

| Need | Go to |
|---|---|
| Onboarding another cluster, or a failure this skill does not cover | **`cluster-ops`** |
| {{PROVISIONING_TOOL_TASKS}} | **`{{PROVISIONING_SKILL}}`** |
| Which node, which workload, which port, how to change it safely | this skill |
