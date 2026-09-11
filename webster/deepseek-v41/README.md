# DeepSeek V4.1 Flash station cutover

This package records and executes the limited-downtime migration from the
station-hosted GLM-5.2 engine to a separately published DeepSeek V4.1 Flash
service. The public `glm-5.2` name remains a compatibility contract served by
GLM-5.3: a shared 320,000-token prompt-plus-completion window, reasoning and
function calling, no advertised vision, and the legacy reject/clamp behavior.

## Control sequence

```text
freeze rollback -> stage additively -> route alias -> restart once -> hot soak
-> stop both GLM ranks -> private canary/tuning -> register new name -> restart once
```

There are exactly two planned LiteLLM restarts: the compatibility alias cutover
and the independent `deepseek-v4.1-flash` registration. Each uses a 60-second
readiness decision threshold and a named, hash-verified rollback file. LiteLLM
continues to bind only `127.0.0.1:4446`; Caddy remains the sole ingress.

The old Shamu/Tilikum GLM ranks stay hot for a 30–60 minute soak after the first
restart. During that interval rollback is a config restore and one proxy restart.
Stopping both GLM ranks crosses the important boundary: rollback then includes a
coordinated cold model load and grows to a 5–15 minute operation (with a 20-minute
timeout for a cold page cache).

Port `8000` has two mutually exclusive station owners. Shamu is the only HTTP
rank and binds its NetBird address; Tilikum is always headless and keyless. Never
run GLM and DeepSeek concurrently, and never restart only one rank.

## Commands and rollback index

The implementation creates these coordinated entry points:

- `scripts/stop-glm52-tp2.sh` and `scripts/start-glm52-tp2.sh`
- `scripts/stop-deepseek-v41-tp2.sh` and `scripts/start-deepseek-v41-tp2.sh`
- `scripts/restore-litellm-config.sh --phase alias|publish --run-root PATH`

Before the alias restart, discard the candidate and take no service action.
During the hot soak, restore the alias backup. After station release, stop both
DeepSeek ranks, cold-start both GLM ranks, validate direct health, then restore
the alias backup. After publication, restore only the pre-publication LiteLLM
backup while leaving the private canary available for diagnosis.

No cleanup belongs to this change. Checkpoints, immutable images, credentials,
stopped containers, backups, failure logs, and benchmark evidence remain until a
separate cleanup approval.

## Milestone records

Append only redacted GO/NO-GO decisions here. Full evidence remains outside Git
under `/home/ubuntu/deepseek-v41-runs/$CHANGE_ID/`.
