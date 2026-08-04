# Authoring and Maintenance Contract

How to write a cluster skill that stays true, and what "keeping it true"
obliges you to do. Applies to every `<cluster>-cluster` skill generated from
this one.

---

## The contract

**A cluster skill is the source of truth for its fleet, and it is updated in the
same change as the infrastructure — not afterwards.**

A stale entry is worse than a missing one: it sends the next agent to the wrong
IP or port with confidence. "I'll document it after" is how that happens, every
time.

---

## Authoring rules

### Structure

| Rule | Why |
|---|---|
| Body under **~2000 tokens** | It loads on every trigger. Detail belongs in `reference/`, which loads on demand. |
| **Tables, not prose**, for inventory, ports, addresses, models | They are scanned during an incident, not read. |
| **Safety Rules first**, right after the summary | The reader may stop there. Put what must not be broken where it cannot be missed. |
| One `reference/topology.md` for the full address/port detail | Keeps the body scannable while nothing is lost. |
| One `reference/runbooks.md` for procedures | Anything with numbered steps and a verification command. |
| Delete inapplicable sections outright | Empty headings train readers to skim. |

### Front matter

- `description:` must carry **real trigger keywords** — cluster name, every node
  name, every model name, every service name, plus the vocabulary someone would
  actually type. This is what makes the skill load when a node is mentioned.
- Keep the `name:` as `<cluster>-cluster` so multiple fleets coexist without
  colliding.

### Content

- **Every fact is observed, or marked as reported.** Anything the operator
  asserted but you did not verify is labelled *reported, not verified* with the
  date it was asserted.
- **Stamp `Last verified: YYYY-MM-DD`** in the token-budget comment at the top.
- **Record why, not only what.** "`X` is deliberately not behind the shared
  router because the router is prefix-cache-blind" survives; "`X` is not behind
  the router" gets undone by the next person tidying up.
- **Record negative results.** "We chased the fabric and it was not the cause"
  saves the next investigation.
- **Link portable patterns, do not copy them.** Cite `cluster-ops`
  `reference/diagnostics.md` §N. Copying means a fix reaches one fleet.
- **Note the access shape per node** (SSH user, sudo, docker-without-sudo).
  Automation breaks on the asymmetry.
- **Mark measured numbers with how they were measured** — workload, prompt type,
  concurrency, whether TTFT was excluded. An unlabelled number is not
  reproducible.

---

## When to update

| Change | Update |
|---|---|
| Add / remove / repoint a model or job | Models table |
| Move a service or change a port | Inference/service stack + Port map in `reference/topology.md` |
| Add / remove a node | Node inventory + overlay address table |
| Re-cable or re-address an interconnect | Network section + `reference/topology.md` |
| Add a scrape target or dashboard | Observability table |
| Change access policy on an ingress port | **Safety Rules** |
| Change a node's SSH user, sudo, or docker access | Node inventory access column |
| Fix or discover a gap | Known gaps in `reference/topology.md` |
| Learn a new portable failure mode | `cluster-ops` `reference/diagnostics.md`, **not** the cluster skill |

That last row matters. Ask of every new lesson: *would this be true on a
different cluster?* If yes, it belongs in the portable file.

---

## Update procedure

1. Make the infra change and **verify it live**. Never document intent.
2. Edit the affected table(s). Keep them tables.
3. Update `Last verified: YYYY-MM-DD`.
4. Re-run the probe for the touched hosts and diff against what you wrote:
   ```bash
   ~/.claude/skills/cluster-ops/scripts/probe-cluster.sh -o /tmp/verify.json <hosts...>
   ```
5. **Mirror to Codex** — `~/.codex/skills/<cluster>-cluster`. If it is a symlink
   to the same directory, nothing to do; if it is a copy, edit both. The two must
   not drift.
6. If a fact was *wrong* rather than merely outdated, also correct any saved
   memory or note that repeats it.

---

## Anti-drift rules

- **If you are reasoning from memory about which node runs what, stop and
  verify.** Placement changes repeatedly. The tables are only trustworthy
  because they are re-verified on every edit.
- **A read-only validator proves less than a reboot.** A node with 45 days of
  uptime has never exercised its restart path.
- **Re-probe before a big claim.** "The fleet is healthy" needs today's data.
- **When the skill and the machine disagree, the machine is right** — fix the
  skill in that same session, while you know the truth.

---

## Retiring a cluster skill

When a fleet is decommissioned, do not delete the skill silently. Either:

- mark it **HISTORICAL** at the top with the decommission date, keeping the
  hard-won diagnostics that are still true elsewhere; or
- move any portable lesson into `cluster-ops` `reference/diagnostics.md` first,
  then remove the skill and its Codex mirror.

The second option is usually right. The failure patterns outlive the hardware.
