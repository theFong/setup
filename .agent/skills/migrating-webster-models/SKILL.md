---
name: migrating-webster-models
description: Use when replacing, upgrading, qualifying, publishing, rolling back, or recovering a model on Webster's fully occupied multi-node GPU pairs, especially vLLM TP deployments behind LiteLLM where public aliases and capability contracts must survive a bounded cold cutover. Triggers include model migration, limited downtime, in-place GPU replacement, AIPerf Weka tuning, TP rank recovery, alias preservation, and rollback planning.
---

# Migrating Webster Models

## Core principle

Treat a tensor-parallel pair as one fault and deployment unit. Reduce downtime by staging every reversible artifact before GPU handoff, not by rolling ranks independently.

**REQUIRED BACKGROUND:** Use `webster-cluster` for current nodes, routes, ports, credentials, and maintenance rules.

## Start with invariants

Write a migration ledger from [assets/migration-ledger.md](assets/migration-ledger.md). Record:

- public alias, context accounting, modalities, parameters, response model name, auth behavior, and prices;
- rank roles, TP/PP, listeners, fabric, image/checkpoint/tokenizer hashes, and secrets placement;
- current health, rollback artifacts, owner, timestamps, and sanitized evidence paths.

Classify each action before executing it:

| Class | Examples | Rule |
|---|---|---|
| Reversible staging | download, checksum, render disabled config | perform while the old backend is live |
| Cold boundary | stop the old fully occupied TP pair | announce that rollback now requires a full paired boot |
| Publication | enable/repoint a LiteLLM alias | validate offline, batch into one restart, verify immediately |
| Destructive | delete checkpoint, credential, backup, container, or prior route | exclude from migration; require separate authority |

## Execute in gates

1. Capture baseline contracts and live probes. Never infer a public contract from the replacement model.
2. Pre-stage immutable weights, image, tokenizer, config, keys, tests, and rollback state on both ranks without initializing the candidate GPU runtime.
3. Establish continuity. If the public alias can route to a compatible existing backend, validate it before retiring the hot backend. If no complete spare pair exists, call the handoff a bounded outage, not blue/green.
4. Drain bounded in-flight work, then stop and fence both ranks together. Confirm listeners and GPU processes are gone.
5. Start one pinned generation with rank 0 authenticated on its private interface and rank 1 headless/keyless. Do not publish until inference, auth rejection, listener isolation, hashes, and NCCL evidence pass.
6. Tune with cache-controlled real workloads. Read [references/playbook.md](references/playbook.md) before using AIPerf or comparing profiles.
7. Qualify the winner for feature correctness, long context, errors, OOM/preemption, restarts, observability, and rollback. For the DeepSeek V4.1 package, require its 17-case suite with repeated determinism, complete tool modes, both JSON modes, negative requests, disconnect queue drain, and failure-log capture armed on both ranks.
8. Generate `private-acceptance.json` last from hashed evidence, validate it with `verify-private-acceptance.py`, then run publication preflight. Render and validate the complete LiteLLM config offline. Preserve old alias metadata explicitly, add the new alias, keep LiteLLM on `127.0.0.1:4446`, back up, restart once, and run direct/private/public probes.
9. Soak, then install coordinated recovery. A failure of either rank removes the pair from service, fences both identities, and starts both only after authoritative absence is proven.
10. Synchronize `webster-cluster` and this skill wherever the fleet state changed. Require exact rendered Hermes content; use `--force` only after reviewing and intentionally replacing divergent consumer edits.

## Stop conditions

Fail closed when a rank is unreachable, identities/hashes differ, the worker has a key or HTTP listener, the previous generation cannot be fenced, a benchmark was cancelled/partial, acceptance evidence is stale or captured after `accepted_at`, LiteLLM validation differs from the live file, or rollback artifacts are not readable.

Prefix every Webster cluster command with `env -u SSH_AUTH_SOCK`. Never print credentials, run two station models together, restart one TP rank alone, or touch Baker while migrating the Webster stations.
