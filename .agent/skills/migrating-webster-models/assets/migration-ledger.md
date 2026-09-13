# Model migration ledger

## Scope

- Change:
- Owner:
- Started (UTC):
- Public aliases:
- Occupied GPU pair:
- Excluded systems:

## Immutable contract

| Field | Before | Required after | Evidence |
|---|---|---|---|
| Alias / response model | | | |
| Shared context window | | | |
| Modalities | | | |
| Reasoning / tools / structured output | | | |
| Authentication | | | |
| Timeout / retries / pricing | | | |

## Artifacts and rollback

| Artifact | Node/path or identity | Hash/mode | Preserved? |
|---|---|---|---|
| Previous image/checkpoint/tokenizer | | | |
| Previous launch/config | | | |
| Candidate image/checkpoint/tokenizer | | | |
| Rank-0 secret source | | redacted | |
| LiteLLM before-edit backup | | | |

## Reversibility ledger

| UTC | Action | Class | Gate/evidence | Rollback time now |
|---|---|---|---|---|
| | | reversible staging / cold boundary / publication / destructive | | |

## Benchmark matrix

| Profile | Repetition | Cache state | Requests/errors | Root trees | Peak overlap | Throughput | TTFT p90 | Queue/preemption | Rank health | Result path |
|---|---:|---|---:|---:|---:|---:|---:|---|---|---|
| | 1 | warmup | | | | | | | | |
| | 2 | comparison | | | | | | | | |

Predeclared disqualifiers:

Winner and rationale:

## Cutover and recovery verification

- Rank 0 private/authenticated:
- Missing/wrong key rejected:
- Rank 1 headless/keyless/no HTTP:
- Matching generation/artifacts/fabric:
- LiteLLM loopback bind and one restart:
- Legacy alias contract probe:
- New alias probe:
- Public ingress policy:
- Langfuse/Prometheus trace:
- Either-rank recovery test:
- Cold rollback rehearsal:

## Outcome

- Published (UTC):
- Measured continuity interruption:
- Current cold rollback estimate:
- Preserved evidence paths:
- Known limitations / follow-ups:
