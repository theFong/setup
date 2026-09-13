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
- `scripts/acceptance.sh --run-root PATH`
- `scripts/generate-private-acceptance.py --help`
- `scripts/verify-private-acceptance.py --help`
- `scripts/sync-runbook.sh [--check|--force]`

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
- **Milestone 3 metadata gate — NO-GO, rolled back, and corrected
  (2026-09-12):** the first alias candidate omitted `supports_vision`, so
  LiteLLM inferred `supports_vision: true` from the GLM-5.3 backend. The alias
  was restored immediately from the exact backup while both station GLM ranks
  remained hot. The corrected candidate explicitly sets `supports_vision:
  false`; its retry became ready in 9.057 seconds and live `/model/info` now
  reports the legacy 320,000-token, reasoning, function-calling, no-vision
  contract while native `glm-5.3-flash` retains its 1,048,576-token vision
  contract. Operationally, the alias phase has used three proxy restarts: the
  initial planned restart, one hot rollback restart, and one corrected retry.
  The separate planned publication restart remains outstanding. This history
  is intentionally not collapsed into the two-planned-restart target.
- **Milestone 4 — GO (2026-09-12):** after the corrected seven-window hot soak,
  both station GLM ranks were stopped together. Post-stop inspection confirmed
  both GPUs and port 8000 were free. Private and public alias suites again
  passed the full legacy contract, including a pre-backend 320,001-token 400;
  all eight pre-existing public models returned 200; private and public ingress
  remained deny-by-default; and the scoped cutover key was revoked and returned
  401. The old station counter was frozen at 16,401 before shutdown, while all
  post-stop GLM traffic continued through the external GLM-5.3 backend. This is
  the cold-rollback boundary: restoring station GLM now requires a coordinated
  two-rank model load before the alias rollback can be applied.
- **Milestone 5 eager canary — GO (2026-09-12):** DeepSeek V4.1 Flash is live
  privately on Shamu/Tilikum with TP=2, PP=1, eager execution, a 131,072-token
  window, one sequence, and 0.90 GPU-memory utilization. Shamu is the sole
  authenticated HTTP rank on its NetBird address; Tilikum is headless and has
  no serving key. The pinned CX8 path initialized with GPUDirect RDMA, both
  containers remained running with zero restarts/OOMs, and vLLM reported a
  6,953,138-token KV pool. The runtime's effective defaults enabled prefix
  caching and 16,384 maximum batched tokens even though the initial profile did
  not make those values explicit. Three consecutive expanded qualification
  runs passed all ten cases: deterministic text, UTF-8, stop sequences,
  streaming, usage accounting, reasoning, tool calls, tool-result continuation,
  strict structured output, and native vision. Evidence is in
  `feature-eager-expanded-{1,2,3}.json` under the run root. DeepSeek reasoning
  is enabled by default and can consume the entire completion budget, returning
  `content: null`; contract and surface probes must explicitly send
  `reasoning_effort: "none"` unless reasoning behavior itself is under test.
- **Milestone 6 graph canary — GO (2026-09-12):** both DeepSeek ranks were
  stopped together and relaunched with the `graphs-128k` profile. Relative to
  the effective eager configuration, the only runtime change was removing
  `--enforce-eager`; prefix caching and the 16,384 maximum-batched-token value
  were made explicit. Breakable CUDA graph capture completed in 42 seconds,
  both containers remained running with zero restarts, and the KV pool grew to
  8,263,348 tokens (63.04 full 131,072-token requests), up 18.8% from eager.
  The correctly labeled `feature-graphs-128k-1.json` artifact passed all ten
  qualification cases. The first graph launch events were incorrectly labeled
  `eager` by hard-coded lifecycle text; a TDD regression fix now records the
  selected profile, and an append-only correction event supersedes those two
  labels without rewriting operational history.
- **Milestone 7 DSpark canary — GO (2026-09-12):** the strict profile schema
  now renders a checkpoint-native speculative configuration and rejects a
  draft block that does not match this pinned checkpoint. The exact resolved
  configuration is method `dspark`, model `/model`, five speculative tokens,
  greedy draft sampling, and standard rejection sampling. vLLM resolved
  `DSparkV41DraftModel` from the target checkpoint and confirmed block size 5,
  target layers `[37, 38, 39]`, and Markov rank 256. Both ranks were replaced
  together with the `dspark-128k` TP=2/PP=1 profile; DSpark graph capture took
  22 seconds, the KV pool was 8,282,419 tokens, and both containers remained
  running with zero restarts/OOMs. `feature-dspark-128k-1.json` passed all ten
  surface cases. Live metrics prove the drafter was active: the qualification
  workload accepted 103 of 144 draft tokens, not merely a no-op configuration.
- **Milestone 8 initial Weka sweep — partial GO, then NO-GO
  (2026-09-12):** `dspark-1m-seqs1` completed a paired warmup and scored run
  with zero errors, restarts, or preemptions. The scored run completed 383
  requests at 0.42554 requests/s and 189.95 output tokens/s, with 2.32-second
  p90 TTFT and three completed root workflows in 900.03 seconds. The next
  profile, `dspark-1m-seqs2`, failed before readiness during FlashInfer's
  16,384-token autotune dummy run with `Invalid MXFP8 split-K tactic`; rank 0
  exited without OOM while rank 1 remained resident, so both ranks were fenced
  together. A new cache hash with no saved cache file rules out stale-cache
  replay, and NCCL had initialized successfully. The historical profiles,
  error excerpt, container state, and NO-GO event are preserved. A later
  paired stop exposed that fixed `*-prestop.log` names could overwrite prior
  evidence; the original full failure logs were replaced before that flaw was
  caught. `capture` now allocates a numbered path when a name already exists,
  with a regression test proving repeated captures retain both files. The
  supported workaround is now a strict
  `ENABLE_FLASHINFER_AUTOTUNE=0` profile field that renders
  `--no-enable-flashinfer-autotune`. Fair replacement profiles use this same
  setting for `max-num-seqs` 1, 2, 4, and 8; mixed autotune results will not be
  compared.
- **Milestone 8 completed — GO (2026-09-12):** the fair no-autotune Weka sweep
  completed paired warmup/scored runs at `max-num-seqs` 1, 2, 4, and 8 with
  zero request errors, preemptions, engine deaths, OOMs, or restarts. Scored
  request throughput was 0.42400, 0.43550, 0.43986, and 0.44377 requests/s;
  output throughput was 189.30, 199.80, 202.03, and 207.01 tokens/s; p90 TTFT
  was 2.211, 1.181, 1.068, and 1.037 seconds. `seqs=8` gained only 0.89%
  request throughput over `seqs=4`, while observed concurrency peaked at three,
  so `dspark-1m-noautotune-seqs4` won on KV headroom. The final clean winner
  passed 10/10 feature cases, the exact 1,048,576-token boundary suite, and the
  mode-0600 acceptance manifest. The scored run averaged 1,477.41 W. Published
  energy-only prices use `1.3e-8` input from a 15,047-token/s cold-prefill
  observation and `9.6e-7` output from measured Weka throughput; the 99.866%
  cache-hit aggregate input rate was explicitly rejected as pricing evidence.
- **Coordinated recovery — GO (2026-09-12):** the head-hosted systemd watchdog
  is enabled every minute. A healthy run preserved both container identities.
  A real paired-stop fault produced `BREACH`, fenced both ranks, relaunched the
  exact winning profile, and returned authenticated readiness in 5m09s with new
  identities and zero restarts, followed by another healthy no-op. Tilikum's
  fixed ten-second sudo delay was independently traced to missing hostname
  resolution and removed by adding `127.0.1.1 tilikum`; the prior hosts file is
  preserved as `/etc/hosts.bak-deepseek-v41-20260912T163400Z`.
- **Milestone 9 publication — GO (2026-09-12):** the exact pre-publication
  LiteLLM config was preserved at
  `spark-1:/home/nvidia/litellm/config.yaml.bak-deepseek-v41-publish-20260912T165510Z`
  with SHA-256
  `84a0dea58c561f991c3870bcc6eb5bbd8e3d47aee4be59b457e40dcc17f0ee30`.
  The candidate appended only `deepseek-v4.1-flash`, advertising the native
  1,048,576-token vision/reasoning/tools/structured-output contract. Semantic
  validation and exact-image offline callback/router construction passed before
  one atomic promotion and one proxy restart. Liveliness/readiness returned in
  19.616 seconds; the container remained at zero restart failures and bound only
  to `127.0.0.1:4446`. The automated acceptance entry point passed direct auth
  rejection/success, all nine private models, five public controls, legacy
  `glm-5.2` metadata, native DeepSeek metadata, Caddy 403/401 policy, revoked-key
  rejection, 11/11 Prometheus targets, a fresh Langfuse trace, active watchdog,
  rank isolation, and the hash-verified rollback path. GLM station containers
  and all Baker containers remain untouched and preserved.
- **Post-publication review hardening — GO (2026-09-12):** publication preflight
  now validates the complete mode-0600 acceptance manifest, artifact hashes,
  six-hour freshness, evidence ordering, exact runtime/profile/topology, feature
  and long-context results, qualified Weka metrics, rank identities, and PP=2
  rationale. The direct feature suite expanded from 10 to 17 cases, adding
  three-repeat determinism, named/required/parallel tools, `json_object`, malformed
  input, wrong-model rejection, disconnect queue drain, and automatic redacted
  two-rank log capture on failure. All 17 cases passed live without a restart.
  Fresh rank/API evidence was captured before the generated acceptance timestamp
  `2026-09-12T18:43:41Z`; the generator and an independent live publish preflight
  both accepted it. AIPerf now rejects missing, malformed, cancelled, partial, or
  unqualified results and includes Shamu vLLM metrics. Serving fast paths verify
  the exact paired generation and profile before reuse. Skill synchronization now
  requires explicit `--force` for divergent regular directories and verifies exact
  rendered Hermes content. These checks introduced no model or LiteLLM downtime.
- **Recovery-package omission — NO-GO, recovered, and corrected
  (2026-09-12):** the first deployed watchdog bundle omitted the newly required
  `verify-serving-pair.py` dependency. Its fail-closed immutable-profile check
  consequently reported `BREACH` against a healthy pair and performed a coordinated
  fence/reload. The model was avoidably unavailable from approximately `23:07:19Z`
  until authenticated readiness returned at `23:12:48Z`; the public LiteLLM service
  and compatibility-routed `glm-5.2` remained available. The installed bundle now
  contains the verifier and its subsequent healthy paths preserve both container
  identities. Recovery packaging is therefore treated as a transitive dependency
  closure: stage and hash every sourced helper and executable, then exercise a
  read-only path from the installed directory before enabling the timer.
- **Hardened full-subagent Weka qualification — GO (2026-09-13):** the 393-trace
  corpus expands to a 5.70 GiB mmap, 9,843 conversations, and 98,827 turns, with
  roughly 12 GiB required during reconstruction. Head's 8 GiB of physical RAM plus
  swap failed before sending model traffic at 300-, 900-, and 1,200-second dataset
  configuration limits. Those three directories retain their exact `EXIT=1` files
  (all SHA-256
  `4bf4fca02e6eeaf7f1c510b82c756e7f8a3c567a230bae1094b254adc774f38b`);
  failed evidence is never rewritten. Moving the controller to Shamu and preserving
  the mmap cache reduced configuration to 2.46 seconds. The genuine warmup completed
  682 requests and three root workflows at 0.74757 requests/s and 288.50 output
  tokens/s, with 11.546-second p90 TTFT, 20 peak waiting requests, zero errors,
  cancellations, preemptions, or restarts, and 1,955.64 W average facility power.
  The genuine scored repetition completed 974 requests and five root workflows at
  0.89461 requests/s and 382.40 output tokens/s, with 10.542-second p90 TTFT, 28
  peak request concurrency (four running, 24 waiting), 4.84% peak KV use, 97.61%
  prefix-cache hits, zero errors, cancellations, preemptions, or restarts, and
  1,812.61 W average facility power. A comma-grouped completion count had exposed a
  summarizer defect; the parser received a regression fix, but acceptance required
  these new runs instead of repairing the old summary. Repetition 2 is promoted only
  because its rank states match repetition 1 and its provenance names the exact
  warmup hash.
- **Final evidence refresh — GO (2026-09-13):** pricing was recomputed only after
  the hardened scored run, using its measured power/output throughput and the final
  319,999-token cold prefill in 20.996604 seconds. The unrounded direct energy values
  are `1.552747272598342e-8` input and `6.188455008963091e-7` output dollars/token;
  published prices remain `1.3e-8` and `9.6e-7`. Fresh generation-bound rank and API
  captures then preceded the mode-0600 acceptance timestamp
  `2026-09-13T01:01:27Z`. Independent publication preflight and the complete
  acceptance matrix passed again against generation
  `20260912T230747Z-3280615`, with LiteLLM and both model ranks unrestarted.
- **Legacy-contract correction and final publication acceptance — GO
  (2026-09-13):** an exact image request proved the first live guard returned HTTP
  400 but exposed top-level error code `"400"`; `unsupported_vision` survived only
  in nested provider fields. The guard now raises a LiteLLM-native proxy exception
  whose serialized top-level code is `unsupported_vision`. Twenty exact-image guard
  tests and 23 focused local tests passed before one corrective LiteLLM restart.
  Readiness returned in **9.122 seconds**, restart count remained zero, the config
  SHA-256 remained
  `f8a9ddf5d1634015d6a9b167756cc3c56dfa19cae852fb4896191dbfe5182c30`,
  and the deployed guard SHA-256 became
  `2557630b10890c74d61ef3f7bc8d58558e894b04e05c9ed9847b9bd5d07a7dfe`.
  Publication probes now derive the current registry and require only the four
  migration-critical aliases. The complete live acceptance entry point returned
  `GO` for run root `/home/ubuntu/deepseek-v41-runs/20260911T075859Z`.
- **Retired Inkling reconciliation — GO (2026-09-13):** the live and on-disk
  LiteLLM registries already omitted `inkling-small-nvfp4`, both Spark nodes had
  zero Inkling containers, and the only Spark-2 port-8000 listener belonged to the
  unrelated Reachy Mini simulator. The stale `inkling-watchdog.timer` was disabled
  and stopped so it can no longer recreate the retired model. OpenWebUI's existing
  `openwebui-shamu-5` key now removes Inkling and adds
  `deepseek-v4.1-flash`; an authenticated completion through that key returned 200
  without an OpenWebUI or LiteLLM restart. Prometheus's dead Inkling `:9401` target
  was removed and the Prometheus-only recreate produced **643 ms** of observed
  metrics unavailability; all **10/10 Prometheus targets** are now up. The prior
  Prometheus config is recoverable at
  `/home/alecfong/observability/prometheus/prometheus.yml.bak-inkling-retirement-20260913T025930Z`.
  A fresh complete acceptance run returned `GO` after the reconciliation. Neither
  DeepSeek rank changed identity or restart count, and Baker remained untouched.
