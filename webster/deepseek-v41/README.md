# DeepSeek V4.1 Flash station cutover

This package records and executes the limited-downtime migration from the
station-hosted GLM-5.2 engine to a separately published DeepSeek V4.1 Flash
service. The public `glm-5.2` name remains a compatibility contract served by
GLM-5.3: a shared 320,000-token prompt-plus-completion window, reasoning and
function calling, no advertised vision, rejection of explicit over-budget output,
and the legacy remaining-budget default when no output limit is supplied.

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

- **Milestone 1 — GO (2026-09-11):** evidence root
  `/home/ubuntu/deepseek-v41-runs/20260911T075859Z`. The read-only baseline
  passed for all eight existing public models with its scoped key revoked.
  Exact byte-verified rollback state was frozen with timestamp
  `20260911T081659Z` at
  `spark-1:/home/nvidia/litellm/deepseek-v41-rollback-20260911T081659Z` and
  `shamu|tilikum:/home/alecfong/deepseek-v41-rollback-20260911T081659Z`.
  Rank 1 remained headless and keyless; no service, route, container, or model
  process changed.
- **Runtime pin gate — NO-GO (2026-09-11):** vLLM PR `#56214` was open,
  non-draft, merge-blocked, unapproved, and still had 157 of 246 current commit
  statuses pending at head `7d81d62702b41885e2ff3ebc7ad9dfb638cc429c`.
  `VLLM_COMMIT` remains empty. No image build, checkpoint download, GPU kernel
  compilation, or station workload was started.
- **Runtime package gate — GO (2026-09-12):** PR `#56214` merged and the
  selected source is its merge commit
  `e77daef89e18e08321ae7b8b24827eedd5fe8673`. The arm64 image
  `sha256:3863bf0f59bd4df4012b7b7aed8a7d2be6ef9b42ee3a5299d014f83a1f1ba6ea`
  and saved-image checksum match on Shamu and Tilikum. The upstream four-family
  architecture build produced a 613.97 MiB wheel, so the private build retains
  the upstream size check with a recorded 700 MiB ceiling below its 800 MiB
  quota. GPU-blind checks verified `DeepseekV41ForCausalLM`,
  `--engram-config`, and nonempty Engram layers. The evidence preserves the
  earlier uv-cache, missing-tag, wheel-limit, help-device, and registry-glob
  NO-GO failures. No route, listener, checkpoint, or GPU owner changed; GLM
  remained live throughout.
- **Milestone 2 — GO (2026-09-12):** the pinned 48-shard checkpoint at revision
  `dba1be0a40aa45a94ad051997016db3960a90277` passed two complete hash passes
  per station and cross-node byte comparison. Both 9,257-byte manifests have
  SHA-256 `aad652a2b601f711599298493229f32fcc7216ca17d6bb0ccd451fd2fdd01fef`;
  Shamu retained 1,187,905,433,600 free bytes and Tilikum retained
  2,241,969,221,632. The low-priority rail seed and verifier windows recorded
  no production regression. The compatibility guard and original tokenizer
  then passed 18 tests inside the exact live LiteLLM image without a restart.
- **Milestone 3 — GO (2026-09-12):** the `glm-5.2` public deployment now uses
  the existing GLM-5.3 backend while retaining the original shared 320,000-token
  contract and public response name. The first planned LiteLLM restart became
  ready in 10.273 seconds with restart count zero and the required loopback-only
  command shape. Its exact rollback file is
  `spark-1:/home/nvidia/litellm/config.yaml.bak-deepseek-v41-alias-20260912T075404Z`.
  Private and public probes covered text, streaming, reasoning, tools, tool
  results, structured output, and a pre-backend 320,001-token rejection; the
  old station chat counter remained 16,400 while the GLM-5.3 counter advanced.
