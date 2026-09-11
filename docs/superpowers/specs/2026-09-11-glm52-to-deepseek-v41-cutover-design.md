# GLM-5.2 Deprecation and DeepSeek V4.1 Flash Station Cutover Design

**Date:** 2026-09-11
**Status:** Approved

## Summary

This change deprecates the public `glm-5.2` implementation without removing its
client-visible model name. LiteLLM will route both `glm-5.2` and
`glm-5.3-flash` requests to the existing `glm-5.3-flash` backend. The current
GLM-5.2 TP2 deployment on `shamu` and `tilikum` will remain hot for a 30–60
minute rollback soak, then both ranks will be stopped together.

The freed DGX Station GB300 pair will be used to qualify
`deepseek-ai/DeepSeek-V4.1-Flash` on vLLM. The primary topology is TP=2, PP=1
over the stations' direct 400 Gb/s ConnectX-8 link. Engram tables will reside in
each station's local Grace memory, while the non-Engram weights are tensor
parallel across the two GPUs. PP=2 is a measured fallback, not the starting
configuration.

DeepSeek V4.1 will remain on a private, authenticated canary endpoint while its
runtime, API behavior, long-context behavior, and real-workload performance are
qualified. Features will be introduced progressively: eager text, the 320K
contract, CUDA graphs, DSpark speculative decoding, vision, and finally the 1M
context target. Only a passing configuration will be registered in LiteLLM as
the new model name `deepseek-v4.1-flash`. The existing Baker
`deepseek-v4-flash` route is not replaced or modified.

The work is organized as nine gated milestones so the public endpoint sees at
most two planned LiteLLM restart blips: one to repoint the legacy GLM alias and,
later, one to expose the qualified DeepSeek model. Station model restarts do not
require LiteLLM restarts.

## Goals

- Preserve the `glm-5.2` client-visible name and existing virtual-key scopes
  and its original 320K client contract while serving those requests from the
  current `glm-5.3-flash` backend.
- Reclaim `shamu` and `tilikum` without a GLM-5.2 client outage beyond the
  single planned LiteLLM restart.
- Establish a reproducible, pinned vLLM runtime for DeepSeek V4.1 Flash.
- Fit and serve the model on two DGX Station GB300 systems using local NVMe,
  local Grace memory, and the direct ConnectX-8 fabric.
- Qualify correctness before adding performance features.
- Optimize against AIPerf's Weka trace, including the full subagent replay,
  under controlled cache conditions.
- Preserve a fast rollback until the alias cutover has soaked and a recoverable
  rollback after the stations have been repurposed.
- Capture commands, timestamps, artifacts, measurements, failure modes, and
  rollback decisions in a form that can become a repeatable playbook and Codex
  skill.

## Non-goals

- Remove the public `glm-5.2` name or force clients to change configuration.
- Change the external inference URL, Caddy policy, or LiteLLM bind address.
- Replace, pool with, or retune Baker's `deepseek-v4-flash` deployment.
- Expose an unqualified DeepSeek V4.1 backend through LiteLLM.
- Treat PP=2 as the default merely because there are two physical stations.
- Tune every upstream or experimental vLLM patch in one image.
- Claim a 1M production contract before correctness and resource headroom pass
  at that length.
- Delete the GLM-5.2 checkpoint, rollback scripts, stopped containers, or
  configuration backups during this project.
- Package the final skill before the operational procedure has been exercised
  and corrected against live evidence.

## Existing State and Constraints

### Production routing

| Public model | Current backend | Intended state after this change |
|---|---|---|
| `glm-5.2` | `http://100.73.140.127:8000/v1` on the station TP2 pair | Existing `glm-5.3-flash` backend, retained as a deprecated compatibility alias |
| `glm-5.3-flash` | `http://100.73.165.55:8000/v1` | Unchanged backend and native model name |
| `deepseek-v4-flash` | Baker at `http://100.73.127.129:8888/v1` | Unchanged |
| `deepseek-v4.1-flash` | Not registered | Added only after private qualification |

LiteLLM runs on `spark-1`, binds only to `127.0.0.1:4446`, and is fronted by
Caddy on ports 4444 and 4445. The public inference endpoint is load-bearing.
Configuration changes must therefore be validated offline, batched, backed up,
and deployed with one restart per planned routing event.

The latest seven-day traffic snapshot recorded 1,344 `glm-5.2` calls with a
prompt-length p90 of approximately 198,850 tokens, and 22,748
`glm-5.3-flash` calls with a p90 of approximately 177,962 tokens. These data
support a compatibility floor of 320K for the replacement station service and
make long-context, multi-turn behavior a primary benchmark regime rather than
an edge case.

The legacy alias retains its original compatibility contract: model name
`glm-5.2`; a 320,000-token shared prompt-and-completion ceiling; existing
reasoning, streaming, structured-output, and function-calling metadata; and no
advertised vision or 1M capability. Requests above the shared 320K ceiling must
continue to fail before reaching the GLM-5.3 backend. This preserves the option
to restore the former backend without first unwinding client dependencies on
GLM-5.3-only capabilities. Exact generations cannot remain identical because
the underlying weights change; “original contract” refers to the API surface,
advertised capabilities, limits, and failure behavior. Energy-cost metadata
will describe the backend that actually serves the request so accounting stays
truthful.

### Station topology

- `shamu` is rank 0 and will host the only HTTP listener.
- `tilikum` is rank 1 and must remain headless.
- NCCL traffic uses `10.10.1.1` and `10.10.1.2` on
  `enP1p3s0f1np1` / `mlx5_1`, the configured 400 Gb/s ConnectX-8 rail.
- NetBird is the service plane. The HTTP listener binds to Shamu's NetBird
  address, never `0.0.0.0` or the Webster LAN.
- Both stations have approximately 744 GiB of host memory and one approximately
  250.69 GiB GPU.
- Measured Grace CPU-to-GPU bandwidth is approximately 375–379 GB/s, making
  local Grace memory the intended Engram tier. Cross-station Engram lookup is
  not part of the design.

The existing GLM-5.2 deployment uses the same rank ownership and direct rail.
Its rank-1 `--headless` requirement, memory-lock settings, API isolation, and
coordinated stop/start behavior remain the rollback template.

### DeepSeek artifact sizing

The selected checkpoint revision is:

```text
repository: deepseek-ai/DeepSeek-V4.1-Flash
revision:   dba1be0a40aa45a94ad051997016db3960a90277
```

The revision's safetensors index declares 510,286,023,000 logical tensor bytes
(475.24 GiB). Its 48 shard files total 510,296,708,312 on-disk bytes after
safetensors headers. Engram tables account for approximately 189.13 GiB and the
remaining weights for approximately 286.11 GiB. With TP=2, the ideal
non-Engram GPU share is approximately 143.06 GiB per rank, leaving about
107.63 GiB of each GPU for runtime state, graphs, activations, and KV cache.
Each station must keep a complete local checkpoint on NVMe and its local Engram
tables in local Grace memory.

Before staging, each station must demonstrate enough free NVMe for the complete
checkpoint, the runtime image, caches, and a temporary download margin. The
implementation plan will set the exact minimum from the downloader's real
layout; it may not assume that the nominal 475.24 GiB checkpoint is the only
disk consumer.

The pinned release intentionally has no Jinja chat template, generation config,
or processor config. Its protocol reference is `encoding/encoding.py` plus the
published encoding fixtures, and the candidate vLLM source registers
`deepseek_v41` with its native `DeepseekV4Renderer`. Checkpoint verification must
require those published assets rather than inventing conventional Transformers
files that do not exist at this revision.

### Runtime support state

The installed vLLM 0.25.1 build does not recognize
`DeepseekV41ForCausalLM`. Upstream support is being developed in
[vLLM PR #56214](https://github.com/vllm-project/vllm/pull/56214). Its last
observed head was `0bfb653d3b5161660db9ada0d84c2cdd60961de7`, with an unstable CI
state. That hash is evidence, not an approved runtime pin.

The runtime milestone must recheck the PR, its CI, review status, and merge or
release state immediately before pinning. The chosen source commit, base image,
container digest, dependency lock, CUDA version, NCCL version, driver versions,
and local patch diff must be recorded. No deployment may use a floating branch
or tag.

Potential follow-on optimizations include Engram overlap
([#56220](https://github.com/vllm-project/vllm/pull/56220)), bounded SWA replay
([#56227](https://github.com/vllm-project/vllm/pull/56227)), and attention/FP4 KV
work ([#56344](https://github.com/vllm-project/vllm/pull/56344)). They are
separate experimental deltas. None may be bundled into the first known-good
runtime, and each must prove its own correctness and performance effect.

## Target Architecture

```text
Existing public clients
        |
        | model = glm-5.2 or glm-5.3-flash
        v
Caddy :4444 -> LiteLLM 127.0.0.1:4446
                         |
                         v
             GLM-5.3 Flash backend

Private qualification client on head
        |
        | authenticated OpenAI-compatible API over NetBird
        v
Shamu rank 0, DeepSeek V4.1, TP=2 / PP=1
        |
        | NCCL only: 10.10.1.1 <-> 10.10.1.2, mlx5_1
        v
Tilikum rank 1, headless

Each station:
  local NVMe -> pinned checkpoint
  local Grace RAM -> local Engram tables
  local GPU -> TP shard + activations + graphs + KV cache
```

The canary will reuse the station model port `8000` after GLM-5.2 is stopped.
This preserves the existing NetBird-only service shape and the interface-scoped
LAN guard. DeepSeek credentials live in separate mode-0600 files and do not
overwrite GLM rollback credentials. Reusing the port means only one station
model can run at a time; every transition must stop both ranks before starting
the other model.

## Nine Milestones

Each milestone ends at a gate. A failed gate stops progression and invokes the
stated rollback or leaves the current production path untouched.

### Milestone 1 — Capture baseline and freeze rollback state

Record the exact live LiteLLM configuration, container ID, image, start time,
restart count, loopback bind, model list, callbacks, routing plugin, virtual-key
behavior, and public security responses. Capture the GLM-5.2 and GLM-5.3
backend model lists, health, container inspections, launch scripts, GPU/host
memory, direct-rail state, and recent traffic/error metrics.

Create timestamped backups without printing credentials. Record file ownership,
mode, and hashes for credential-bearing files. Confirm that the current
GLM-5.2 coordinated launch and restore paths exist on both stations. No config,
container, or route changes occur in this milestone.

**Gate:** the baseline is internally consistent, all current models pass a small
authenticated completion, the external root returns 403, unauthenticated
`/v1/models` returns 401, LiteLLM is on `127.0.0.1:4446`, and rollback artifacts
can be located without relying on shell history.

### Milestone 2 — Pre-stage immutable artifacts without a serving change

While GLM-5.2 still serves, stage the checkpoint revision and the selected
vLLM image on both stations. Use low-priority, rate-limited, sequential I/O so
checkpoint downloads or image extraction do not contend materially with the
production engine. Do not compile GPU kernels or start a second GPU workload
alongside GLM.

The model resides on local NVMe on both nodes. Validate the Hugging Face
revision, shard inventory, per-file hashes, total size, tokenizer and processor
files, and byte-for-byte agreement between nodes. Validate image digests and
source revision on both nodes. Keep temporary download state out of the model's
final immutable directory.

**Gate:** both stations have identical pinned artifacts, enough remaining disk
and memory headroom, and no material GLM health or latency regression during
staging. Any unexplained production degradation aborts staging before the alias
cutover.

### Milestone 3 — Repoint the deprecated `glm-5.2` alias

Back up `spark-1:~/litellm/config.yaml`. Change only the legacy `glm-5.2`
deployment so it targets the existing authenticated GLM-5.3 backend. Keep the
native `glm-5.3-flash` entry. Preserve the legacy name, virtual-key scopes,
callbacks, Caddy policy, all unrelated model entries, and the legacy alias's
320K text/reasoning/function-calling contract. Do not advertise GLM-5.3's 1M or
vision capabilities under `glm-5.2`. Update only the alias's backend and
energy-cost attribution, and mark its description as a deprecated compatibility
alias. Enforce the 320K shared prompt-and-completion ceiling at LiteLLM so an
over-limit request cannot begin depending on behavior the rollback backend does
not support.

Validate YAML structure, callback imports, the expected model/deployment
counts, backend authentication, and the rendered target before restarting.
Restart LiteLLM exactly once.

Use a temporary named virtual key scoped to the GLM aliases for real probes;
never use the master key as workload traffic. Test both model names and verify
from backend metrics or request metadata that they reached GLM-5.3, not the
station GLM-5.2 process. Revoke the temporary key after validation.

**Gate:** LiteLLM returns within the downtime budget; both GLM names complete,
the old backend receives no new alias probe, unrelated models still complete,
a Langfuse trace records the correct alias and backend, the root/401 security
checks are unchanged, the bind remains loopback-only, and restart count is
zero after the deliberate restart. `/model/info` and `/v1/models` still expose
the original `glm-5.2` limits and capabilities, a request above the shared 320K
limit fails without reaching GLM-5.3, and the native `glm-5.3-flash` name retains
its independent 1M and vision contract.

**Rollback:** restore the timestamped config and perform one validated LiteLLM
restart. Because the station GLM remains hot, this rollback does not require a
model reload.

### Milestone 4 — Soak the alias, then release the stations

Keep both GLM-5.2 station ranks running for 30–60 minutes after the successful
alias change. During the soak, observe request success, p50/p90 latency,
streaming, reasoning controls, tool calling, structured outputs, long prompts,
over-limit rejection, cost attribution, and Langfuse traces. Compare
`glm-5.2` compatibility-alias traffic with native `glm-5.3-flash` traffic and
confirm that no request reaches the old station backend.

At the end of a clean soak, stop the two GLM-5.2 ranks as one coordinated
operation. Do not delete their containers, launch scripts, credentials,
checkpoint, or backups. Confirm that `glm-5.2` continues to serve through
GLM-5.3 after the stop.

**Gate:** the soak contains no unexplained compatibility or availability
regression, both old ranks are stopped, no station process listens on port
8000, GPU memory is released on both stations, and the public aliases remain
healthy.

**Rollback:** before the stop, restore the LiteLLM config as in Milestone 3.
After the stop, first stop any DeepSeek ranks, then restore GLM-5.2 on both
stations with the coordinated scripts and only then restore the LiteLLM route.
The latter path may take 5–15 minutes because a cold GLM checkpoint load has
previously taken 14m41s.

### Milestone 5 — Bring up the minimal TP2 DeepSeek canary

Launch the pinned V4.1 runtime with TP=2, PP=1 and the smallest useful eager,
text-only profile. Keep CUDA graphs, DSpark speculative decoding, vision, and
the 1M target disabled. Start rank 0 first and rank 1 headless, using the
station rail for NCCL. Engram data must be served from each node's local Grace
memory; the canary fails if a rank reads Engram remotely or silently falls back
to an unintended device.

Rank 0 binds only to Shamu's NetBird address on port 8000 and requires a private
vLLM bearer key for OpenAI routes. Health and metrics may remain unauthenticated
only if they are restricted to the intended mesh listener. Rank 1 receives no
API credential, has no HTTP listener, and exposes no model API. Both ranks must
have explicit, coordinated lifecycle scripts and a restart policy or watchdog
that cannot restart a single rank into split brain.

**Gate:** the architecture is recognized without a local model-code fork unless
that fork is pinned and documented; weights and Engram tables land in the
intended tiers; NCCL uses only `mlx5_1`; both ranks remain healthy; unauthenticated
and wrong-key OpenAI calls return 401; a correct-key text completion is
semantically valid and repeatable; the LAN address refuses port 8000; and rank
1 is headless with no credential or listener.

### Milestone 6 — Qualify features progressively

Advance through the following sequence without combining steps:

1. Eager text correctness and short-context OpenAI compatibility.
2. A 320K shared prompt/completion contract, matching or exceeding the retired
   GLM route's practical context requirement.
3. CUDA graphs and compilation, with eager mode retained as the diagnostic
   fallback.
4. DSpark speculative decoding, including acceptance-length and output-quality
   checks.
5. Vision inputs and multimodal request parsing.
6. The checkpoint's 1M context target, including memory headroom and recovery
   behavior.

At every step, rerun deterministic prompts, streaming, stop sequences,
reasoning controls, tool calls and tool-result continuation, structured JSON,
usage fields, cancellation, and over-limit errors. Add new batch shapes only
after warmup covers them. Community reports of garbled output under CUDA graphs
and DSpark make eager-vs-graph and DSpark-off-vs-on output comparisons mandatory.

**Gate:** each newly enabled feature passes before the next is introduced. A
feature that corrupts output, destabilizes a rank, or consumes unacceptable KV
headroom is disabled without blocking qualification of the last known-good
profile. The production candidate is the highest passing profile, not
necessarily the feature-maximal profile.

### Milestone 7 — Optimize TP2 and measure PP2 only as fallback

Tune the TP=2, PP=1 candidate one factor at a time. Candidate variables include
GPU memory utilization, maximum sequences, batched-token budget, chunked
prefill, async scheduling, graph capture sizes, prefix caching, DSpark settings,
and expert parallelism. EP is optional and enters only after the non-EP TP2
baseline is stable. Each variant must preserve the same runtime and checkpoint
pins so its effect is attributable.

PP=2 uses one pipeline stage per station with TP=1 and is benchmarked only if
TP2 cannot meet a correctness, memory, or throughput gate, or if measurements
show collectives dominate. It may reduce per-layer cross-node collectives, but
it introduces pipeline bubbles, makes low-concurrency latency vulnerable, and
can create stage or Engram imbalance. PP2 is accepted only if it passes the same
API/correctness suite and materially improves the target Weka workload without
an unacceptable p90/p99 regression.

**Gate:** a reproducible TP2 candidate is selected from controlled measurements.
If PP2 is tested, the decision record contains matched TP2/PP2 results and an
explicit keep/reject decision. Configuration folklore or GPU utilization alone
is not evidence.

### Milestone 8 — Run the controlled AIPerf Weka qualification

Run AIPerf from `head`, not on either serving station, under `tmux` or an
equivalent persistent session. Pin the AIPerf source/version and dataset
manifest. The primary workload is the full Weka trace including subagent
replay; the no-subagent variant may be used only as a diagnostic control.
Preserve conversation/session identifiers so parent and subagent turns that
share a prefix exercise the intended prefix-cache behavior.

Use duration-bounded runs with a finite grace period and an explicit long
request timeout. Do not use a request-count termination that can cut a
multi-turn session and wait forever. Completion watchers must match an exact
terminal record such as `^EXIT=`, never the word `DONE`. Retain raw records,
aggregate JSON, client logs, server logs, Prometheus snapshots, and the rendered
command for every run.

Freeze the comparison matrix in the run manifest before testing variants. It
starts with matched closed-loop concurrency points 1, 2, 4, and 8; concurrency
16 is added only if 8 is stable and has resource headroom. Add an open-loop
arrival-rate sweep derived from the observed seven-day traffic distribution.
Every candidate receives the same sequence, duration, grace period, timeout,
and randomization seed.

Cache state is an experimental variable:

- A cold comparison requires a coordinated two-rank restart and proof that the
  relevant cache counters began cold.
- A warm comparison runs the same configuration twice and reports the second
  run.
- Never compare one warm candidate with one cold candidate.
- Report request rate and completed sessions alongside token throughput.
- Record prefix-cache hit rate, input sequence length, and output sequence
  length for every result.
- Remove abandoned AIPerf mmap files on `head` between runs; do not place them
  on station NVMe or evict the serving checkpoint's page cache.

At minimum, report completion/error rate, requests/s, sessions/s, input and
output token throughput, per-user decode rate, TTFT p50/p90/p99, inter-token
latency, end-to-end latency, cache-hit rate, KV occupancy, queue depth, GPU and
host-memory headroom, NCCL traffic, and power. Review a representative output
sample for tool-call, JSON, reasoning, multimodal, and garbling failures.

**Gate:** the selected profile completes the frozen concurrency and arrival-rate
matrix with at least 99% server-side success, zero engine deaths, zero NCCL
timeouts, no detected output corruption, and reproducible warm results. The
report identifies the Pareto choice rather than hiding latency to maximize one
throughput number. If no candidate passes, DeepSeek remains private and the
public routing state is unchanged.

### Milestone 9 — Register the new model and publish the operating record

After qualification, add exactly one new LiteLLM model name:
`deepseek-v4.1-flash`. It points to the authenticated station rank-0 endpoint.
Do not modify or alias Baker's `deepseek-v4-flash`. Populate model limits,
reasoning, tool, structured-output, and vision capability metadata only for
features that passed Milestone 6. Set energy pricing from measured marginal
power and measured throughput, not a hardware peak estimate.

Validate the full LiteLLM config and custom callbacks offline, then perform the
second and final planned LiteLLM restart. Use a temporary named virtual key
scoped to the new model for end-to-end probes and revoke it afterward. Verify a
Langfuse trace and all security invariants.

Update the canonical Webster cluster skill only after live verification. Update
its current-state summary, Models table, restart procedure, topology details,
known gaps, and verification date, then run `head:~/ops-bot/sync-skills.sh` to
refresh both the Codex and Hermes mirrors. Resolve reverse-direction drift
before forcing a sync.

Publish the change record and benchmark report. Extract the validated procedure
into a repeatable model-cutover playbook, then package it as a narrowly scoped
skill in a separate reviewed change. The skill must encode preflight,
low-downtime routing, credential handling, coordinated-rank lifecycle,
progressive feature gates, cache-controlled AIPerf methodology, rollback, and
anti-drift documentation checks.

**Gate:** the new model completes direct, private-Caddy, and public endpoint
probes; unrelated models still complete; LiteLLM remains loopback-only with
zero restart count; public root and unauthenticated model-list responses remain
403/401; Baker is unchanged; Prometheus and Langfuse observe the new route; all
three Webster skill copies agree; and the operating record contains no secret.

## Downtime Budget and Change Windows

The goal is continuity, not literal zero process restarts.

| Event | Expected user impact | Budget | Failure action |
|---|---|---:|---|
| Artifact staging | None | No endpoint downtime | Throttle or stop staging if production health moves |
| Legacy alias change | One global LiteLLM blip | Target <30 seconds; 60-second decision threshold | If readiness is not restored by 60 seconds, inspect once, then restore the backed-up config and restart |
| GLM station stop | None for `glm-5.2`; it is already on GLM-5.3 | No LiteLLM restart | Restart both GLM ranks only if alias rollback is required |
| DeepSeek bring-up and tuning | None; private canary only | No LiteLLM restart | Stop both ranks, preserve logs, return to last known-good profile |
| DeepSeek registration | One global LiteLLM blip | Target <30 seconds; 60-second decision threshold | Restore the backed-up config and restart if readiness or cross-model probes fail |

The two planned LiteLLM restarts are separated by the full private
qualification period and are never spent on tuning hunches. The target total
planned front-door interruption is under 60 seconds. If either restart crosses
its 60-second decision threshold, allow up to one additional 60-second recovery
restart for that event; do not begin another change while the front door is
unhealthy.

The 30–60 minute hot-GLM soak is the most important downtime control. Before it
ends, alias rollback needs only a short proxy restart. After it ends, restoring
the physical GLM backend can require a long cold model load, so the soak may not
be shortened merely to begin DeepSeek work sooner.

## Acceptance and Abort Rules

These rules apply across milestones:

- Never proceed on a partially healthy two-rank engine. Stop or start both
  ranks as one operation.
- Any semantic corruption, repeated garbling, engine death, NCCL timeout,
  unexplained credential exposure, listener on the wrong interface, or
  regression of Caddy's 403/401 policy is an immediate abort.
- A container being `Up` is not health evidence. Require a direct model-list or
  completion probe and inspect recent logs for engine failure.
- Do not lower correctness, security, or rollback gates to rescue a performance
  result.
- A feature or optimization that fails returns to the last known-good private
  profile. It does not force restoration of GLM routing because `glm-5.2`
  remains served by GLM-5.3.
- A public registration failure removes only `deepseek-v4.1-flash`; it does not
  repoint `deepseek-v4-flash` or alter the GLM aliases.
- A decision to restore the old GLM route after its ranks are stopped requires
  stopping DeepSeek first because the deployments share GPUs and port 8000.

## Artifact and Evidence Record

Each milestone appends to one UTC-timestamped change record. It must include:

- operator, start/end time, milestone, go/no-go decision, and reason;
- config backup paths and hashes, excluding secret contents;
- checkpoint repository, exact revision, shard manifest, and total bytes;
- vLLM commit, PR state at pin time, local diff, image digest, Python lock,
  CUDA, NCCL, driver, kernel, and firmware versions;
- launch commands with secret values redacted and the fully rendered
  non-secret engine configuration;
- listener, firewall, credential-file mode, and rank-isolation checks;
- LiteLLM container identity, bind, restart duration/count, health, callbacks,
  routes, and security responses before and after each restart;
- direct and end-to-end probe results plus Langfuse trace identifiers;
- AIPerf version, dataset identity, full command, cache state, raw artifacts,
  aggregate metrics, and server telemetry window;
- every failed variant, its logs, and why it was rejected;
- exact rollback command, estimated duration, and the last point at which it
  was rehearsed or proven.

Secrets must never be printed, committed, placed in command-line arguments,
copied to rank 1, or stored in benchmark artifacts. Record only their file
locations, ownership, modes, and non-reversible fingerprints where comparison
is necessary.

## Rollback Matrix

| Failure point | Production route | Recovery |
|---|---|---|
| Before alias restart | Unchanged | Discard staged config; no service action |
| Alias restart fails | Intended alias may be unavailable | Restore LiteLLM backup and restart once; station GLM is still hot |
| Alias soak fails | Alias is on GLM-5.3 | Restore LiteLLM backup and restart once; keep station GLM running |
| Private DeepSeek startup or tuning fails | GLM aliases remain on GLM-5.3 | Stop both DeepSeek ranks, capture logs, restore last known-good private profile or pause |
| Need old GLM after station release | GLM alias still on GLM-5.3 until changed | Stop DeepSeek, restore both GLM ranks, verify direct health, restore LiteLLM config, restart once |
| New public DeepSeek route fails | Other models remain unchanged | Restore pre-registration LiteLLM config and restart once; diagnose canary privately |

No rollback deletes evidence or checkpoints. Cleanup is a separate, explicitly
approved operation after a stable production soak.

## Documentation and Repeatability Deliverables

The finished project produces four durable artifacts:

1. This approved design and its implementation plan.
2. A chronological cutover record containing actual commands, observed
   durations, gate results, and rollback decisions.
3. A benchmark bundle with machine-readable AIPerf outputs and a concise
   TP2/PP2/feature decision report.
4. A tested model-cutover playbook suitable for conversion into a Codex skill.

The eventual skill is derived from successful evidence, not from this design's
untested commands. It should separate invariant safety rules from
model-specific parameters, accept an old alias, replacement backend, target
nodes, artifact pins, canary port, soak duration, and benchmark profile as
inputs, and fail closed at every gate. It must support both Claude Code and
Codex or document a deliberate exception, and it must include validation and
safe re-run behavior consistent with the setup repository's style guide.

## Final Definition of Done

The project is complete only when:

- `glm-5.2` is a verified deprecated alias to the current GLM-5.3 backend while
  retaining its original 320K client contract;
- the old station GLM ranks are stopped but recoverable;
- DeepSeek V4.1 Flash runs on both stations from pinned artifacts under a
  documented, reproducible configuration;
- the selected profile passes API, correctness, security, long-context,
  stability, and Weka workload gates;
- `deepseek-v4.1-flash` is independently exposed without changing Baker's
  `deepseek-v4-flash`;
- both planned LiteLLM restarts stayed within the recorded change budget or
  their rollback paths were exercised successfully;
- the Webster source-of-truth skill and both mirrors reflect verified live
  state; and
- the operational notes are sufficient to create and test the repeatable
  cutover skill without reconstructing decisions from chat history.
