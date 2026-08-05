# {{CLUSTER_TITLE}} Runbooks

Operational procedures. Read the Safety Rules in SKILL.md first.

Every runbook here follows the same shape: **do the thing, then verify it, then
update the skill.** A procedure without a verification step is a wish.

<!-- DELETE ANY RUNBOOK THAT DOES NOT APPLY. A template heading with no content
     is worse than no heading. -->

## Adding or repointing a {{WORKLOAD}}

1. Bring the backend up on its node and confirm it serves locally:
   `ssh {{NODE}} 'curl -s localhost:{{PORT}}/{{HEALTH_PATH}}'`
2. Edit `{{CONFIG_PATH}}` on **{{NODE}}**. Back up first:
   `cp -a {{FILE}} {{FILE}}.bak-<what>-$(date -u +%Y%m%dT%H%M%SZ)`
3. Use {{WHICH_ADDRESS_PLANE}} as the target address, never
   {{WHAT_ROTATES_OR_MOVES}}.
4. Restart **once**: `{{RESTART_COMMAND}}`. Then verify all of:
   - `{{BIND_CHECK}}` — bound where the safety rules say
   - `{{HEALTH_CHECK}}` → expected {{CODE}}
   - the workload appears in `{{LISTING_ENDPOINT}}`
5. Send one real request and confirm it lands in {{TELEMETRY}}.
6. **Update SKILL.md's table and mirror to `~/.codex/skills/`.**

## Validating {{SERVICE}} config before restarting

Because restarts are costly, check the things that commonly abort startup:

- {{COMMON_STARTUP_FAILURE_1 — with the exact error it produces}}
- {{COMMON_STARTUP_FAILURE_2}}

{{VALIDATION_COMMAND_THAT_RENDERS_CONFIG_WITHOUT_LAUNCHING}}

## Restarting {{WORKLOAD}} ({{TOPOLOGY — e.g. 2-node TP2}})

{{WHERE_THE_RECIPE_LIVES, on which nodes, and which file holds the config}}

Always drive it from **{{HEAD_NODE}}**; never start a rank by hand.

```bash
ssh {{HEAD_NODE}} '{{STOP_COMMAND}}'
ssh {{HEAD_NODE}} '{{START_COMMAND}}'   # ~{{DURATION}}
# If the compose file sets no restart policy, this is MANDATORY on every node:
ssh {{HEAD_NODE}} 'docker update --restart unless-stopped {{CONTAINER}}'
ssh {{WORKER_NODE}} 'docker update --restart unless-stopped {{CONTAINER}}'
```

Gotchas:

- {{PRECONDITION_THAT_ABORTS_THE_START — e.g. port already listening}}
- {{CREDENTIAL_OR_KEY_REQUIREMENT_BETWEEN_NODES}}
- {{ANYTHING_THAT_DRIFTS_ACROSS_REBOOTS — e.g. GID indexes; do not pin them}}
- {{EXPECTED_STARTUP_DURATION_AND_WHY}} — so a slow start is not read as a hang
- {{FIRST_BOOT_MEASUREMENT_ARTIFACTS}} (see diagnostics §7)

## Restarting a backend without touching {{SHARED_PROXY}}

{{SHARED_PROXY}} tolerates a dead upstream — it errors for that workload only
and recovers when the backend returns. Restart the backend container directly
and leave the proxy alone. Strongly preferred over bouncing the front door.

## Checking fleet health

```bash
{{ALL_TARGETS_COMMAND}}
{{RECENT_TRACES_OR_LOGS_COMMAND}}
```

Re-probe anything that looks off:

```bash
~/.claude/skills/cluster-ops/scripts/probe-cluster.sh {{NODES}}
```

## Testing the external endpoint

```bash
BASE={{URL}}
curl -s -o /dev/null -w '%{http_code}\n' $BASE/            # expect {{CODE}} ({{WHY}})
curl -s $BASE/{{PATH}}                                      # expect {{CODE}} ({{WHY}})
```

{{HOW_TO_READ_THE_RESULT — which combination means healthy, and which specific
failure means the proxy is up but the backend is not.}}

## {{HARDWARE}} node checks

```bash
ssh {{NODE}} 'nvidia-smi --query-gpu=name,clocks.sm,power.draw --format=csv'
ssh {{NODE}} 'nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv'
```

{{WHAT_THE_THROTTLE_VALUES_MEAN_HERE}}. A hardware power-brake bitmask means
physical service, not a config fix — diagnostics §4.7.

{{IF_MODULE_POWER_IS_N/A_ON_THIS_HARDWARE: say that nvidia-smi is die-only here
and give the figure that should be used instead — diagnostics §4.1.}}

## Adding a node

For provisioning the machine itself, use the **{{PROVISIONING_SKILL}}** skill.
Everything below is the {{CLUSTER_TITLE}}-specific wiring that must follow.

1. Join it to {{OVERLAY}} and confirm the peer count from **both** directions.
2. Run {{EXPORTERS}} on it, bound to {{WHICH_ADDRESS}}.
3. Add a scrape target using the node's {{ADDRESS_PLANE}}, with a `node` label
   matching the name used in the inventory table.
4. Reload {{METRICS_STACK}} and confirm the target is `up`.
5. Probe it and diff against what you are about to write:
   `~/.claude/skills/cluster-ops/scripts/probe-cluster.sh {{NEW_NODE}}`
6. **Update SKILL.md's node inventory, the port map, and the target count.**

## Decommissioning a node

1. Confirm nothing routes to it ({{CONFIG_FILES_TO_GREP}}).
2. Remove its scrape targets, or the alert will fire forever.
3. Remove it from {{OVERLAY}} and the control plane.
4. **Update every table that named it**, and say when and why it went.
   A node silently vanishing from the inventory reads as an error later.
