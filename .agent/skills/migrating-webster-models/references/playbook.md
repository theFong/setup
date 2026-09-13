# Limited-downtime model migration playbook

## Contents

1. Predeclare success
2. Preserve the public contract
3. Stage before the GPU boundary
4. Handoff and private canary
5. Tune with AIPerf Weka traces
6. Select and qualify
7. Publish through LiteLLM
8. Recover and roll back
9. Close the migration

## 1. Predeclare success

Define pass/fail thresholds before results exist:

- zero request errors, engine deaths, OOMs, and unexpected restarts;
- context-window and completion-budget behavior match the intended alias contract;
- required chat, streaming, reasoning, tool, structured-output, and long-context probes pass;
- rank 0 accepts the private upstream key and rejects missing/wrong keys;
- rank 1 is headless, has no inference key, and exposes no HTTP listener;
- queue depth is bounded at target load and both ranks use the pinned fabric;
- LiteLLM stays loopback-only and public ingress rejects non-inference/admin paths;
- previous artifacts remain present, checksum-valid, and startable.

Record a rollback trigger and maximum soak window. Do not choose thresholds after seeing candidate results.

## 2. Preserve the public contract

Snapshot the old alias with authenticated and unauthenticated probes plus LiteLLM model metadata. Treat these as independent fields:

- alias and response `model` name;
- shared prompt-plus-completion limit and over-limit status;
- vision/audio/tool/reasoning/structured-output behavior;
- defaults, ignored parameters, timeout/retry policy, and prices.

A replacement backend may have a larger context or more modalities. That does not authorize exposing them through an existing alias. Use a separate alias for the candidate's native capabilities.

When an already-running compatible backend can carry the old alias, repoint and verify that continuity route before stopping the occupied pair. This converts user-visible downtime into a backend cold-rollback interval. It does not make the retired backend hot.

## 3. Stage before the GPU boundary

While the old model is live:

1. Pin image digest, checkpoint revision, tokenizer revision, runtime dependencies, and hashes.
2. Copy artifacts to both nodes and verify identical manifests.
3. Render rank-specific start commands. Rank 1 must be separately constructed with `--headless` and without any API-key source.
4. Stage mode-0600 secrets only on rank 0 and the authorized proxy host.
5. Prepare profiles, probes, benchmark client, result summarizer, stop/start scripts, and recovery controller.
6. Preserve old container inspection, launch parameters, config, credentials, images, weights, and a tested restore command. Exclude all of them from cleanup.

Preserve executable bits when staging controllers and Python entry points. Before the
first live invocation, execute each staged entry point with `--help` or an equivalent
read-only check; a checksum alone does not prove that the remote copy can run.

Treat a recovery controller as a **dependency closure**, not a shortlist of top-level
scripts. Starting from every systemd `ExecStart`, recursively inventory each sourced
file, relative executable, Python entry point, and generated profile; stage and hash
the complete set. Run a packaging gate from the deployed directory that resolves and
executes every dependency through a read-only path. A top-level `--help` check is not
enough when it exits before loading a helper. Do not enable the timer or invoke its
healthy path until that gate passes. On Webster, an omitted pair-verifier made the
fail-closed watchdog fence and reload both ranks, creating roughly five minutes of
model-only downtime even though the serving pair had been healthy.

Measure `getent ahosts "$(hostname)"` and `sudo -n true` on any worker that
requires sudo. Slow hostname resolution can add a fixed delay to every remote Docker
operation and make healthy coordination look hung; repair the host's self-resolution
before timing lifecycle or recovery behavior.

If a Brev alias stalls during RSA public-key negotiation or suddenly resolves to a
different gateway key/port, run `brev refresh` and inspect `ssh -G <alias>` before
changing controller logic. Refresh rotating gateway metadata before the downtime
window; keep `SSH_AUTH_SOCK` unset for every cluster command.

Make preflight capture the phase-specific owner. Baseline/stage/alias inspect the old
model, private canary may inspect both stopped identities, and publication inspects the
running candidate. Never make publication depend on inspecting a stopped old container.

Do not initialize a second model on a fully occupied pair. Weight presence is safe staging; loading them into GPU memory is the cutover.

## 4. Handoff and private canary

1. Capture pre-stop evidence and stop both old ranks concurrently.
2. Verify both recorded container identities are stopped, serving/rendezvous listeners are absent, and no workload GPU process remains.
3. Start rank 0 and rank 1 as one generation with fixed roles and a pinned TP fabric. PP stays 1 unless a measured memory or partitioning requirement justifies PP>1; PP adds pipeline bubbles and operational state, while TP=2 already spans the two station GPUs.
4. Keep the candidate private. Require both containers running with zero restarts, a real authenticated completion, 401 for missing/wrong credentials, exact rank-0 bind, no rank-1 listener/key, matching artifacts, and NCCL evidence.
5. If a gate fails, stop both candidate ranks before retrying. Never repair one rank in place while its peer survives.

Add generation/profile/rank labels before the first candidate launch. If stronger
evidence code arrives after an otherwise exact pair is already serving, do not spend a
cold restart only to attach metadata: accept a **legacy pair identity** only after exact
image, argv/profile, role, security, fabric, zero-restart, and bounded start-skew checks,
then derive it from both immutable container IDs and start timestamps. Reject partial
labels or a mismatch on either rank. Future launches must carry the explicit labels.

## 5. Tune with AIPerf Weka traces

Treat Weka as dependency-aware workflow replay, not an RPS microbenchmark.

### Validate scheduling first

Run a small fixture and calculate exact request overlap and root-tree count. Fixed schedule can release many roots at nearly the same recorded instant; if it creates an artificial burst, do not use it for the topology sweep.

For Webster's 393-trace corpus, the validated production-like mode is:

```text
--no-fixed-schedule --concurrency 1
```

Concurrency limits root session trees; nested children still fan out naturally. Observe vLLM running and waiting request gauges to confirm that behavior.

### Place the corpus and driver safely

Keep `corpus-manifest.json` beside `traces/`, never inside it. AIPerf treats every
JSON file inside the trace directory as a workload trace, so an identity manifest in
that directory corrupts the workload before traffic begins. Verify the source JSONL,
all split files, repository revision, trace count, and manifest hashes on the machine
that will drive the run.

Size the client host for the expanded corpus, not the compressed source. The 393-trace
Weka replay expands into a 5.70 GiB mmap containing 9,843 conversations and 98,827
turns, while cache-miss reconstruction uses roughly 12 GiB across AIPerf's dataset
manager and workers before steady traffic. Webster's 8 GiB head plus 8 GiB swap is not
a qualified driver for this corpus: 300-, 900-, and 1,200-second configuration guards
all expired before request dispatch. The 900-second attempt parsed all files in 889.3
seconds and missed its notification deadline; the 1,200-second attempt parsed them in
924.9 seconds but remained swap-bound in post-parse materialization until the command
deadline. All three failures sent zero model requests.

Run the full corpus from a high-memory controller such as rank 0. Keep both
`AIPERF_DATASET_CONFIGURATION_TIMEOUT` and
`AIPERF_SERVICE_PROFILE_CONFIGURE_TIMEOUT` pinned to at least 1,200 seconds and include
both values in the rendered command, but treat those guards as failure bounds rather
than substitutes for memory. Gate the runner on at least 32 GiB of physical controller
memory before corpus hashing or AIPerf launch so an undersized driver fails immediately
instead of consuming a 20-minute evidence window. A timeout before dataset
configuration completes does not publish the mmap cache, so the next cache-miss
attempt must parse from cold again. On
the station, the preserved mmap cache restored the 5.70 GiB backing store by hardlink
and configured the full 9,843-conversation dataset in 2.46 seconds. Do not run a second
driver while one benchmark or grace-period drain is active.

The station-side runner must keep rank-0 Docker inspection local and reach only rank 1
over SSH. Set `WEBSTER_LOCAL_SHAMU=1`, point `WEBSTER_RUNS_ROOT` at the staged station
run root, and require the lifecycle verifier's `--verify-only` path before traffic.
That verifier must fail on a missing or mismatched rank instead of restarting the
serving pair. Preserve the AIPerf checkout's `.git` metadata so the runner can verify
the pinned commit rather than trusting the installed version string. If a required
runtime patch makes that checkout intentionally dirty, require the exact dirty path set
and the SHA-256 of `git diff --binary HEAD -- <runtime-sources>` in every repetition's
provenance. Acceptance must reject a missing or different runtime patch hash.

### Control cache state

For each candidate profile:

1. stop both ranks;
2. start the profile and verify health;
3. run the same full trace pool twice with the same seed and root-tree concurrency;
4. label repetition 1 warmup and repetition 2 comparison;
5. compare only repetition 2;
6. restart before the next profile so candidates cannot inherit KV/prefix cache.

Keep model revision, tokenizer, quantization, runtime, max length, batched-token cap, GPU utilization, speculative method, sampling, trace set, and output limits fixed. Change one tuning dimension at a time.

Treat a FlashInfer autotune failure as a profile failure first. If the pinned runtime
exposes a supported no-autotune flag, validate that flag under test, then rerun every
compared profile with autotune disabled; never compare mixed autotune modes.

Never trust process exit status alone. Reject a run when `.aiperf_results_ready.json` reports `was_cancelled: true`, when `EXIT` is nonzero/missing, when records are partial, or when request errors exist. Preserve cancelled evidence under an unmistakable non-benchmark name. Never rewrite a failed `EXIT`; move the entire closed run directory to a reason-and-timestamp suffix and create a new canonical run. A summarizer bug, including failure to parse grouped request counts such as `completed=1,036`, requires a regression fix plus a genuine benchmark rerun. It never authorizes repairing old evidence in place.

For every publishable repetition, capture and hash AIPerf stdout/stderr, the benchmark
window, raw request records, exported profile and server metrics, rank 0/1 state before
and after, and bounded logs from both serving containers. Reject HTTP failures recorded
in raw Weka requests and fatal rank markers including `EngineDeadError`, NCCL
errors/timeouts, and RPC timeouts. Rebuild each summary from those raw inputs during
acceptance instead of trusting a stored summary.

Repetition 1 is warmup only. Repetition 2 is scored only when its pre-run rank states
exactly match repetition 1's post-run states and it records the exact warmup provenance
hash. Promote only repetition 2 into the scored-summary path. An earlier or externally
started run that lacks this evidence remains exploratory even if AIPerf exits zero.

Record root workflows completed, request throughput, root latency if available, TTFT p50/p90/p99, TPOT/ITL, input/output tokens per second, exact peak request overlap, error types, cache hits/cached tokens, running/waiting queue, KV use, preemptions, GPU power/utilization/memory, and throttling.

### Choose lexicographically

1. Disqualify correctness failures, errors, OOMs, restarts, unbounded queues, or SLO breaches.
2. Prefer the highest completed root-workflow rate at target load.
3. If throughput differs by less than the predeclared tolerance, prefer lower p95 root latency, then p99 TTFT, fewer preemptions, and more memory headroom.
4. If still tied, choose the smaller `max-num-seqs`.

Price output tokens from measured active power divided by qualified output throughput.
Price input tokens from a demonstrably cold-prefill request. Do not use aggregate input
throughput when prefix-cache hits dominate; that measures cache effectiveness rather
than prefill compute. Record whether the result covers energy only or also includes
hardware, labor, network, and margin.

Perform the dynamic pricing derivation only after the final scored repetition exists.
Use `energy_usd_per_second = facility_power_watts / 1000 * rate_usd_per_kwh / 3600`,
then divide by the measured cold-prefill throughput for input and by the selected Weka
output throughput for output. Preserve the unrounded direct values and record any
rounded published values separately. Recompute the evidence after any generation,
cold-prefill, Weka, power, or electricity-rate change; never copy numbers from an older
successful run.

## 6. Select and qualify

Restart the warm-run winner cleanly, then run:

- representative chat and streaming requests;
- reasoning on/off and usage-accounting probes;
- tool auto/required/named/parallel behavior and tool-result continuation;
- JSON schema and `json_object` output with documented thinking requirements;
- malformed-JSON and wrong-model rejection;
- three identical deterministic requests with one normalized output;
- a streamed client disconnect followed by running/waiting queue drain;
- near-limit valid requests and clean over-limit rejection;
- sustained representative load with rank logs, GPU metrics, restarts, and queue checks.

For this repository, the 17-case qualification command is:

```bash
webster/deepseek-v41/scripts/feature-qualification.py \
  --base-url http://100.73.140.127:8000/v1 \
  --metrics-url http://100.73.140.127:8000/metrics \
  --model deepseek-ai/DeepSeek-V4.1-Flash \
  --key-file "$RUN_ROOT/credentials/deepseek-v41.key" \
  --stage dspark \
  --output-json "$RUN_ROOT/feature-dspark-1m-seqs4-final.json" \
  --failure-log-output "$RUN_ROOT/logs/feature-final-server-failure.log" \
  --server-log-node shamu --server-log-node tilikum
```

Keep `--failure-log-output` armed even on an expected GO. A failure captures redacted,
bounded logs from both ranks; a success records that capture was armed and unnecessary.

Document unsupported behavior rather than silently widening or narrowing an existing alias contract.

## 7. Publish through LiteLLM

Build a **freshness budget** backward from the six-hour publication gate. Complete long
Weka and context jobs first, generate dynamic pricing from their final artifacts, then
capture short-lived rank/API evidence and write `private-acceptance.json` last. If a
late correction invalidates a dependency, recapture every downstream artifact; never
touch timestamps merely to make evidence appear fresh.

1. Capture fresh rank-0, rank-1, and authenticated API evidence after all qualification artifacts are stable.
2. Run `generate-private-acceptance.py` with those three evidence paths and the recorded selection/PP=2 rationale. It writes `accepted_at` after the captures, hashes every referenced artifact, writes mode 0600, and invokes `verify-private-acceptance.py` itself.
3. Run `preflight.sh --phase publish`; it must independently invoke `verify-private-acceptance.py` with a six-hour freshness limit. A file merely named `private-acceptance.json` is not authority to publish.
4. Back up the exact live config immediately before rendering.
5. Render from that live snapshot so unrelated routes and callbacks cannot disappear.
6. Add the candidate alias and preserve the legacy alias contract fields explicitly.
7. Validate syntax, complete model inventory, upstream auth source, loopback bind, Caddy policy, and rollback diff offline.
8. Restart LiteLLM once.
9. Verify liveliness/readiness, restart count, `127.0.0.1:4446`, unauthenticated 401, public root/admin denial, authenticated model metadata, direct candidate inference, legacy alias inference, and the new alias.
10. Confirm a fresh trace and metrics sample in Langfuse/Prometheus without exposing credentials.

Build publication probes from the live registry, then require the declared
**migration-critical aliases** explicitly. Scope the temporary publication key and
public requests to those aliases; keep exhaustive deployment coverage in the private
preflight. This prevents an unrelated retired model from blocking publication while
still failing when a migration-owned alias disappears.

Validate errors at the same serialization boundary clients consume. An HTTP 400 and a
nested provider code do not preserve a public contract when LiteLLM rewrites the
client-visible top-level error code. Exercise the exact live image and public ingress,
and assert the status plus the top-level code and message before declaring the legacy
contract intact.

If any gate fails, restore the exact backup and perform one validated restart. Do not hand-edit forward on a sick proxy.

## 8. Recover and roll back

Use one external coordinated controller with a singleton lock and cooldown. Container restart policy remains `no` when it could replay only one rank.

Test the controller once with a real paired fault before publication. Keep its
recent-log matcher narrow enough that ordinary stopped-container history does not
manufacture an engine/NCCL reason; rank or health failure remains sufficient to trigger
recovery even when the diagnostic reason is imperfect.

On either-rank failure:

1. make the backend unavailable or use a separately validated fallback;
2. acquire the lock and record both container identities/generation;
3. stop/fence both ranks;
4. if a node is unreachable, fail closed until fencing or power state proves the old process dead;
5. confirm workload listeners and GPU processes are absent;
6. start both ranks from one pinned profile;
7. run the entire private-canary gate before restoring traffic;
8. log cause, actions, duration, and old/new identities.

Cold rollback follows the same state machine with the preserved prior manifest. Stop/fence both candidate ranks, start both previous ranks, verify them fully, then atomically restore the prior route. Never delete the failed candidate during rollback.

When a model leaves the live registry, disable every stale recovery controller that can
recreate it. Registry removal, stopped containers, and a clean listener are not enough
while an enabled timer still owns the old model. Verify the stale recovery controller
is disabled/inactive and that no replacement container appears across its next normal
interval. Preserve its scripts and rollback artifacts unless cleanup was separately
authorized.

## 9. Close the migration

Run one acceptance entry point that checks direct authenticated inference and 401
rejection, every private model, the new and legacy public aliases, metadata, ingress
denials, rank roles, the watchdog, Prometheus, Langfuse, and the hash-verified rollback
path. Revoke its scoped key and verify the revoked key returns 401.

Update the ledger with measured continuity and cold-rollback intervals, final hashes/profile, benchmark evidence, LiteLLM backup, watchdog result, and unresolved limitations. Run `sync-runbook.sh --check` and require byte-exact local mirrors plus exact rendered Hermes trees. If a regular consumer directory diverged, inspect the diff and preserve useful edits; only then run `sync-runbook.sh --force`. Commit only scoped files, run repository validation, push, and attach the evidence paths to the PR.

Reconcile downstream consumers after retiring a model: virtual-key scopes, UI model
lists, Prometheus targets, metrics proxies, rollback probes, and documentation must
match the live registry. Remove a retired model from those surfaces and add the
replacement only where that consumer is authorized to use it. Validate both the
backing configuration and the running process's view. A read-only file bind can keep a
running container on a deleted inode after an atomic host-file replacement; if a reload
still exposes the old state, confirm host/container hashes before performing a narrowly
scoped service recreate and measure its interruption.
