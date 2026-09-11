# GLM-5.2 Compatibility Alias and DeepSeek V4.1 Flash Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve the original public `glm-5.2` contract while routing it to GLM-5.3, then qualify and publish `deepseek-v4.1-flash` on the Shamu/Tilikum DGX Station pair with a cache-controlled AIPerf Weka workload.

**Architecture:** LiteLLM keeps `glm-5.2` as a compatibility deployment whose request guard uses the original tokenizer and chat template to enforce the legacy 320,000-token shared window before forwarding to the existing GLM-5.3 backend. After a hot rollback soak, the station pair is released and runs a pinned DeepSeek V4.1 vLLM TP2/PP1 canary over the 400 Gb/s ConnectX-8 rail, with Engram embeddings in each node's local Grace memory; features and performance changes advance one gate at a time before a separate public registration.

**Tech Stack:** Bash, Python 3 standard library, `unittest`, PyYAML, Jinja2, Hugging Face `tokenizers`/Hub, Docker, vLLM, CUDA, NCCL, LiteLLM 1.95.0, Caddy, NetBird, Prometheus, Langfuse, AIPerf, systemd, tmux.

**Spec:** `docs/superpowers/specs/2026-09-11-glm52-to-deepseek-v41-cutover-design.md`

## Global Constraints

- Keep the external endpoint exactly `https://webster-models-extnode-3gdrajbr0hiykknxzitck9yaiwo.apps.run.brev.nvidia.com`.
- Keep LiteLLM bound only to `127.0.0.1:4446`; Caddy remains the sole ingress and its `:4444`/`:4445` policy does not change.
- Keep the public model name `glm-5.2`, all existing virtual-key scopes, and its original 320,000-token shared prompt-and-completion contract.
- `glm-5.2` continues to advertise reasoning and function calling, does not advertise vision, and does not advertise the GLM-5.3 1,048,576-token window.
- Exact generations are allowed to change because the alias changes weights; the API surface, capability metadata, limits, and limit behavior are not allowed to drift.
- Attribute `glm-5.2` input/output cost to the GLM-5.3 backend values actually serving it: `6e-08` and `1.7e-06` dollars per token until a newer measured value is approved.
- Leave native `glm-5.3-flash` on `http://100.73.165.55:8000/v1` with its independent 1,048,576-token and vision contract.
- Do not remove, rename, repoint, pool, retune, or restart Baker's `deepseek-v4-flash` deployment at `http://100.73.127.129:8888/v1`.
- The alias cutover and the final DeepSeek registration each receive one planned LiteLLM restart, targeting less than 30 seconds with a 60-second rollback decision threshold.
- Never use `LITELLM_MASTER_KEY` for a completion, probe, replay, or benchmark. Mint a named, model-scoped virtual key and revoke it at the end of the work block.
- Keep the station GLM-5.2 ranks hot for 30–60 minutes after the alias restart; do not shorten this soak to start DeepSeek sooner.
- Stop and start both ranks together. Tilikum is rank 1, always uses `--headless`, receives no serving API key, and exposes no HTTP listener.
- Shamu is rank 0 and the only HTTP listener. Bind port 8000 only to Shamu's NetBird address `100.73.140.127`, never `0.0.0.0`, loopback, or the Webster LAN address.
- Run station NCCL only over Shamu `10.10.1.1` and Tilikum `10.10.1.2`, interface `enP1p3s0f1np1`, HCA `mlx5_1`; do not use NetBird for collectives.
- Preserve `--network host`, `--ipc host`, `--ulimit memlock=-1:-1`, `--ulimit stack=67108864:67108864`, `--cap-add CAP_IPC_LOCK`, and the rank-1 headless invariant.
- Use DeepSeek V4.1 checkpoint `deepseek-ai/DeepSeek-V4.1-Flash` at revision `dba1be0a40aa45a94ad051997016db3960a90277`, exactly 48 weight shards and 510,286,023,000 weight bytes.
- Keep a complete checkpoint on local NVMe on both stations and each rank's Engram embedding shard in that station's local pinned Grace memory; remote Engram access is a failed gate.
- Require at least 805,306,368,000 free bytes (750 GiB) before staging on each station and at least 214,748,364,800 free bytes (200 GiB) after the checkpoint, immutable runtime, build cache, and evidence are present.
- Do not compile GPU kernels or launch a second GPU workload while station GLM-5.2 is serving.
- Recheck vLLM PR `#56214` at runtime-pin time. Its observed head `0bfb653d3b5161660db9ada0d84c2cdd60961de7` and unstable state are evidence, not an approved pin.
- Do not run a floating vLLM branch, image tag, Hugging Face revision, AIPerf revision, or Weka dataset revision. Record the source commit, image ID, saved-image SHA-256, dependency lock, CUDA, NCCL, driver, kernel, and local diff.
- Start DeepSeek at TP=2, PP=1. EP is optional after the baseline; PP=2 is a matched fallback experiment only when its trigger criteria are met.
- Introduce features in this order: eager text, 320K/API contract, CUDA graphs, DSpark, vision, 1M. A failed feature returns to the preceding known-good profile.
- Run Weka from `head`, with the full subagent corpus, a pinned dataset revision, a persistent terminal, explicit time bounds, controlled cache state, and a completion record matching `^EXIT=`.
- Never put AIPerf mmap files on station NVMe or evict the serving checkpoint's page cache. Give each run an exact `mktemp` directory on `head` and delete only that resolved directory after artifacts are copied.
- Do not delete the GLM checkpoint, credentials, launch/restore scripts, stopped containers, LiteLLM backups, DeepSeek checkpoint, failed-variant logs, or benchmark evidence in this project.
- Keep secrets out of Git, argv, logs, terminal output, rank 1, benchmark artifacts, and documentation. Credential files are mode `0600`; evidence records only paths, modes, ownership, and non-reversible fingerprints.
- Update `/home/ubuntu/.claude/skills/webster-cluster/SKILL.md` only after live verification, then run `/home/ubuntu/ops-bot/sync-skills.sh` and resolve reverse-direction drift before any forced sync.
- Preserve the unrelated modified and untracked files already present in `/home/ubuntu/.setup`; each commit stages only paths named by its task.

---

## Characterization Decision: Preserve the Shared 320K Contract with a Narrow Guard

Read-only characterization on the live LiteLLM 1.95.0 container established:

```text
Router(enable_pre_call_checks=True)
  prompt > max_input_tokens                 -> REJECTED
  short prompt + max_tokens=1_000_000       -> ACCEPTED
```

The installed `_pre_call_checks()` counts only input tokens. It never combines
`max_tokens` or `max_completion_tokens` with the prompt. Enabling it globally would add
CPU cost and behavioral changes to every model without enforcing the legacy shared
window.

The station vLLM 0.25.1 source uses `get_max_tokens()` to compute:

```python
effective_max_tokens = min(max_model_len - prompt_tokens, requested_or_default_max_tokens)
```

It rejects only when the rendered prompt itself exceeds the model window; an explicit
larger output request is clamped to the remaining window. Therefore the compatibility
guard must:

1. run only when the incoming public model is exactly `glm-5.2`;
2. render with the original GLM-5.2 `chat_template.jinja` and `tokenizer.json`;
3. return HTTP 400 when the rendered prompt exceeds 320,000 tokens;
4. set the active output-limit field to `min(requested, 320000 - prompt_tokens)`;
5. set `max_tokens` to the remaining budget when neither output-limit field is present;
6. fail closed for an alias request it cannot count; and
7. leave native `glm-5.3-flash` and all other models byte-for-byte untouched.

The guard is a `CustomLogger.async_pre_call_hook`, placed first in
`litellm_settings.callbacks`, so rejection or clamping happens before routing and before
the GLM-5.3 backend sees the request. Its renderer is accepted only after its token IDs
match the still-hot GLM-5.2 `/tokenize` behavior on plain, reasoning-disabled, tool,
tool-result, structured-output, and long-boundary fixtures.

## File Map

Create this repository-managed operational package:

```text
webster/deepseek-v41/
  README.md                              limited-downtime sequence, gates, rollback index
  .gitignore                             rejects live manifests, secrets, logs, images, checkpoints
  manifest.env.example                   immutable and execution-time pin field names
  litellm/
    glm52_contract_guard.py              exact legacy prompt count and output clamp
    test_glm52_contract_guard.py         unit and golden-token contract tests
  runtime/
    Dockerfile                           pinned-source vLLM OpenAI image build wrapper
    constraints.txt                      frozen Python dependency output copied from the build
    README.md                             pin decision and reproducible build procedure
  scripts/
    common.sh                             shared constants, redaction, evidence, remote helpers
    preflight.sh                          read-only baseline and fail-closed invariants
    stage-artifacts.sh                    low-priority checkpoint/tokenizer/image staging
    verify-checkpoint.py                 shard, byte, revision, and cross-node manifest checks
    pin-runtime.py                       GitHub PR/CI/release evidence and immutable pin selection
    build-runtime.sh                     reproducible arm64 image build/save/copy/load
    render-litellm-cutover.py            semantic alias/callback rewrite with no other changes
    verify-litellm-config.py             allowed semantic diff and invariant validation
    install-glm52-guard.sh                idempotent callback/tokenizer install on spark-1
    restore-litellm-config.sh             phase-specific validated proxy rollback
    stop-glm52-tp2.sh                    coordinated old-engine stop with evidence capture
    start-glm52-tp2.sh                   coordinated cold rollback with explicit 320000/8
    start-deepseek-v41-tp2.sh             TP2/PP1 launch and startup gate
    stop-deepseek-v41-tp2.sh              coordinated DeepSeek stop
    deepseek-v41-watchdog.sh              split-brain-safe health and two-rank recovery
    contract-probe.py                     alias, API, listener, auth, and boundary probes
    feature-qualification.py             progressive deterministic correctness suite
    run-weka.sh                           pinned full-subagent cold/warm replay runner
    summarize-aiperf.py                  metric, telemetry, error, and sample report
    acceptance.sh                         end-to-end final and cross-model checks
    sync-runbook.sh                       canonical Webster edit/sync verification wrapper
  tests/
    test_static.py                       repository safety and invariant tests
    test_failure_paths.sh                fake-host negative/idempotency tests
    fixtures/
      chat.json                          plain chat token fixture
      reasoning-none.json                reasoning-disabled fixture
      tools.json                         tool definition and forced-auto fixture
      tool-result.json                   assistant tool call plus observation fixture
      structured.json                    response-format fixture
      tokenize-golden.json               token IDs/counts captured from old vLLM
      aiperf-profile.json                representative successful summary
      aiperf-errors.jsonl                representative mixed error records
```

Modify during implementation:

- `test.sh` — invoke the new Python and shell suites.
- `/home/ubuntu/.claude/skills/webster-cluster/SKILL.md` — final verified live state only.
- `/home/ubuntu/.codex/skills/webster-cluster/` and
  `ops-bot:~/.hermes/skills/devops/webster-cluster/` — only through
  `/home/ubuntu/ops-bot/sync-skills.sh`.

Large and possibly sensitive live evidence stays outside Git under the exact run root
`/home/ubuntu/deepseek-v41-runs/$CHANGE_ID/`. The redacted decision summary and
paths to that evidence are appended to `webster/deepseek-v41/README.md` after each
completed milestone.

## Operational Milestone Mapping

| Approved milestone | Plan tasks | Irreversibility boundary |
|---|---|---|
| 1. Baseline/freeze | 1–2, 6 | None; read-only capture and recoverable backups |
| 2. Pre-stage | 3, 8, 6 | None; additive files only |
| 3. Alias cutover | 4–7 | First LiteLLM restart; hot GLM makes rollback fast |
| 4. Soak/release | 7 | Stopping GLM changes rollback from seconds to a 5–15 minute cold load |
| 5. Minimal TP2 canary | 8–9 | Port/GPU ownership changes; old artifacts remain recoverable |
| 6. Feature qualification | 10 | None public; failed private features revert to last passing profile |
| 7. TP2 tuning/PP2 fallback | 11 | None public; each variant is reproducible and reversible |
| 8. Weka qualification | 12 | None public; benchmark state is isolated on `head` |
| 9. Register/publish record | 13 | Second LiteLLM restart; rollback removes only the new model entry |

Required execution order is Tasks 1–5, Task 6 Steps 1–2, Task 8, Task 6 Steps 3–5,
then Tasks 7 and 9–13. Task 6 deliberately brackets Task 8: its first two steps freeze
the live baseline and rollback state before any staging; Task 8 pins/builds/stages the
runtime; its remaining steps stage and cross-check the checkpoint and guard before the
milestone-2 GO record. The alias is not cut over until both the checkpoint and selected
immutable runtime image are present on both stations. Tasks 4 and 5 can be implemented
and tested while upstream runtime CI is still pending.

### Task 1: Add Repository Contract and Failure-Path Tests

**Files:**

- Create: `webster/deepseek-v41/tests/test_static.py`
- Create: `webster/deepseek-v41/tests/test_failure_paths.sh`
- Create: `webster/deepseek-v41/tests/fixtures/aiperf-profile.json`
- Create: `webster/deepseek-v41/tests/fixtures/aiperf-errors.jsonl`
- Modify: `test.sh`

**Interfaces:**

- Consumes: the approved design and the global constraints above.
- Produces: `python3 -m unittest discover -s webster/deepseek-v41/tests -p 'test_*.py'` and `bash webster/deepseek-v41/tests/test_failure_paths.sh`.

- [ ] **Step 1: Write the failing foundation contract suite**

Create a standard-library `unittest` suite with helpers `read(relative_path) -> str`
and `shell_script_paths() -> list[Path]`. Include these exact core assertions and extend
them to every file in the file map:

```python
def test_station_topology_is_pinned(self):
    common = read("scripts/common.sh")
    for literal in (
        'SHAMU_NETBIRD="100.73.140.127"',
        'SHAMU_RAIL="10.10.1.1"',
        'TILIKUM_RAIL="10.10.1.2"',
        'NCCL_IFACE="enP1p3s0f1np1"',
        'NCCL_HCA="mlx5_1"',
    ):
        self.assertIn(literal, common)

def test_baker_route_is_never_a_mutation_target(self):
    for path in shell_script_paths():
        text = path.read_text()
        self.assertNotIn("100.73.127.129:8888", text)
        self.assertNotRegex(text, r"ssh\s+baker-spark-[12]")

def test_no_secret_on_command_line(self):
    text = "\n".join(path.read_text() for path in shell_script_paths())
    self.assertNotRegex(text, r"--api-key(?:=|\s+)[^\"'$]")
    self.assertNotRegex(text, r"Authorization:\s*Bearer\s+\$\{")
```

Initially assert the checkpoint revision/count/bytes, pre/post free-space thresholds,
mode-0600 evidence creation, exact two-restart wording in README, and no mutation command
aimed at Baker. Each subsequent task adds the assertions for the assets it introduces;
the suite must not refer to a future task's absent files.

- [ ] **Step 2: Add negative and idempotency tests with fake executables**

`test_failure_paths.sh` creates a scratch directory with `mktemp -d`, installs fake
`ssh`, `docker`, `curl`, `systemctl`, `sha256sum`, and `nvidia-smi` ahead of `PATH`, and
records exact invocations in `$TEST_LOG`. Initially prove these paths exit nonzero:

- preflight sees less than 750 GiB free before staging;
- Shamu or Tilikum rail/HCA/interface is absent;
- the run root resolves outside `/home/ubuntu/deepseek-v41-runs/`;
- a credential metadata capture reports a mode other than `0600`.

Subsequent tasks add their checkpoint, runtime, LiteLLM, lifecycle, AIPerf, and skill
drift failures before implementing those behaviors. Run each successful fake path twice
and compare `$TEST_LOG` so idempotent operations are harmless on a second run.

- [ ] **Step 3: Wire the suites into the repository runner**

Append exactly:

```bash
python3 -m unittest discover -s webster/deepseek-v41/tests -p 'test_*.py'
bash webster/deepseek-v41/tests/test_failure_paths.sh
if [ -f webster/deepseek-v41/litellm/test_glm52_contract_guard.py ]; then
  python3 webster/deepseek-v41/litellm/test_glm52_contract_guard.py
fi
```

- [ ] **Step 4: Confirm the intended red state**

Run:

```bash
python3 -m unittest discover -s webster/deepseek-v41/tests -p 'test_*.py'
bash webster/deepseek-v41/tests/test_failure_paths.sh
```

Expected: failures name missing operational files; failures must not touch any remote
host.

Do not commit this red state. Task 2 supplies the foundation files, reruns the suite to
green, and commits the tests with their first implementation.

### Task 2: Implement the Manifest, Evidence, and Preflight Foundation

**Files:**

- Create: `webster/deepseek-v41/.gitignore`
- Create: `webster/deepseek-v41/manifest.env.example`
- Create: `webster/deepseek-v41/scripts/common.sh`
- Create: `webster/deepseek-v41/scripts/preflight.sh`
- Create: `webster/deepseek-v41/README.md`
- Test: `webster/deepseek-v41/tests/test_static.py`
- Test: `webster/deepseek-v41/tests/test_failure_paths.sh`

**Interfaces:**

- Consumes: `CHANGE_ID` in UTC form `YYYYMMDDTHHMMSSZ` and an optional read-only `RUN_ROOT` override.
- Produces: a mode-0700 run root with `manifest.env`, `events.tsv`, `baseline/`, `logs/`, `metrics/`, `aiperf/`, and redacted `summary.md`.

- [ ] **Step 1: Define immutable constants and safe evidence helpers**

`common.sh` uses `set -euo pipefail`, rejects a `RUN_ROOT` outside
`/home/ubuntu/deepseek-v41-runs/`, creates directories with umask `077`, and exports:

```bash
SHAMU_NETBIRD="100.73.140.127"
SHAMU_LAN="192.168.1.75"
SHAMU_RAIL="10.10.1.1"
TILIKUM_NETBIRD="100.73.89.150"
TILIKUM_RAIL="10.10.1.2"
NCCL_IFACE="enP1p3s0f1np1"
NCCL_HCA="mlx5_1"
CANARY_PORT="8000"
MIN_FREE_BEFORE_STAGE_BYTES="805306368000"
MIN_FREE_AFTER_STAGE_BYTES="214748364800"
CHECKPOINT_REPO="deepseek-ai/DeepSeek-V4.1-Flash"
CHECKPOINT_REVISION="dba1be0a40aa45a94ad051997016db3960a90277"
CHECKPOINT_SHARDS="48"
CHECKPOINT_WEIGHT_BYTES="510286023000"
```

Implement `event milestone decision reason`, `capture name command...`,
`require_eq label expected actual`, `require_file_mode_600 host path`, and
`redact_stream`. `capture` writes stdout/stderr to the run root and prints only the
artifact path and exit status to the terminal.

- [ ] **Step 2: Define manifest fields without approving a floating runtime**

`manifest.env.example` contains the fixed checkpoint values plus empty, required
execution-time fields `VLLM_COMMIT`, `VLLM_BASE_IMAGE_DIGEST`, `VLLM_IMAGE_ID`,
`VLLM_IMAGE_TAR_SHA256`, `AIPERF_COMMIT`, `WEKA_REPOSITORY`, and `WEKA_REVISION`.
Comments state that `pin-runtime.py` or `run-weka.sh --pin` writes each value and that
preflight rejects an empty value. The template is documentation, never sourced as a
live manifest.

`.gitignore` rejects `manifest.env`, `*.key`, `*.env`, `runs/`, `artifacts/`, `*.tar`,
`*.tar.zst`, checkpoint directories, Hugging Face caches, and Python caches.

- [ ] **Step 3: Implement read-only preflight capture**

`preflight.sh --phase baseline|stage|alias|canary|publish` captures without printing
secret values:

- Git commit/status and the approved spec hash;
- `brev ls` and `brev ls nodes`;
- hostnames, UTC time, uptime, kernel, driver, GPU, RAM, root/NVMe bytes, NetBird
  address, and interface/HCA/link state on Shamu and Tilikum;
- jumbo/non-jumbo rail reachability without changing MTU;
- GLM container ID/image/start/restart/health, launch/restore script SHA-256, listener,
  rank arguments, and GPU memory on both stations;
- credential path, owner, mode, size, and SHA-256 only through files written beneath
  the mode-0700 run root; terminal output shows no fingerprint;
- LiteLLM container ID/image/start/restart/network/bind, callbacks, router plugin,
  redacted model entries, config mode/hash, Caddy root 403, unauthenticated models 401,
  and all current model completion probes through a temporary scoped key;
- Prometheus target health and a Langfuse trace window.

`--phase stage` additionally enforces 750 GiB free. `--phase canary` requires GLM ranks
stopped and no listener. `--phase publish` requires the private DeepSeek acceptance
record. Every failed requirement appends `NO-GO` and exits nonzero.

- [ ] **Step 4: Document the limited-downtime strategy**

README's first page records this exact control sequence:

```text
freeze rollback -> stage additively -> route alias -> restart once -> hot soak
-> stop both GLM ranks -> private canary/tuning -> register new name -> restart once
```

It includes the 60-second LiteLLM decision threshold, the point where rollback grows
from seconds to 5–15 minutes, exact stop/start scripts, the two-backend port collision,
and the rule that cleanup needs separate approval.

- [ ] **Step 5: Run tests and commit**

```bash
python3 -m unittest discover -s webster/deepseek-v41/tests -p 'test_*.py'
bash webster/deepseek-v41/tests/test_failure_paths.sh
git add test.sh webster/deepseek-v41/.gitignore webster/deepseek-v41/manifest.env.example \
  webster/deepseek-v41/README.md webster/deepseek-v41/scripts/common.sh \
  webster/deepseek-v41/scripts/preflight.sh webster/deepseek-v41/tests
git commit -m "feat: add cutover preflight and evidence capture"
```

Expected: both suites pass; no SSH fake log contains a secret value.

### Task 3: Implement Low-Priority Immutable Artifact Staging

**Files:**

- Create: `webster/deepseek-v41/scripts/stage-artifacts.sh`
- Create: `webster/deepseek-v41/scripts/verify-checkpoint.py`
- Test: `webster/deepseek-v41/tests/test_static.py`
- Test: `webster/deepseek-v41/tests/test_failure_paths.sh`

**Interfaces:**

- Consumes: fixed checkpoint constants and `--node shamu|tilikum`.
- Produces: `/home/alecfong/deepseek-v41/models/DeepSeek-V4.1-Flash-dba1be0a` and a sorted SHA-256 manifest on each node; `/home/nvidia/litellm/energy-pricing/glm52-tokenizer/` on spark-1.

- [ ] **Step 1: Write checkpoint verification before the downloader**

`verify-checkpoint.py PATH` loads `model.safetensors.index.json`, resolves every
referenced weight shard, and exits nonzero unless the unique shard count is 48 and the
sum of their `st_size` values is 510,286,023,000. It also requires config, generation
config, tokenizer, processor, and chat-template files; rejects symlinks escaping PATH;
and emits sorted `sha256  bytes  relative/path` lines to stdout.

Before download, query the pinned Hugging Face revision's LFS metadata and compute
`missing_file_bytes + largest_missing_file_bytes + 214748364800`. Require free space to
be at least the greater of that exact value and 805306368000. This accounts for the
downloader's largest partial-file peak and the 200 GiB post-stage reserve; the already
staged runtime image/build cache is reflected in the live free-space measurement rather
than guessed from a nominal image size. Save the LFS layout used in the calculation.

Tests create sparse fake shards with injected expected-size metadata so the suite does
not allocate 475 GiB. Cover missing, duplicate, extra, size-mismatch, traversal, and
cross-node manifest mismatch cases.

- [ ] **Step 2: Implement safe, resumable staging**

For one node at a time, `stage-artifacts.sh`:

1. checks production GLM health and the 750 GiB floor;
2. downloads revision-pinned files into the sibling directory
   `.DeepSeek-V4.1-Flash-dba1be0a.incomplete` using `ionice -c3 nice -n 19` and one Hub
   worker;
3. records one-minute GLM error/latency and disk-pressure snapshots every five minutes;
4. stops and returns nonzero if success rate moves below 99% or p90 exceeds twice the
   captured baseline for two consecutive windows;
5. verifies the checkpoint and writes `MANIFEST.sha256`;
6. atomically renames the incomplete directory to its final name and removes write bits;
7. enforces the 200 GiB post-stage floor.

The command is resumable: an incomplete directory resumes, an identical final directory
verifies and exits zero, and a divergent final directory is never overwritten.

- [ ] **Step 3: Stage the legacy tokenizer guard assets additively**

Copy only `tokenizer.json`, `tokenizer_config.json`, and `chat_template.jinja` from
Shamu's existing GLM checkpoint to a temporary spark-1 directory, compare SHA-256 to
the source over SSH, then atomically rename it to
`/home/nvidia/litellm/energy-pricing/glm52-tokenizer`. The directory is readable by the
LiteLLM container but contains no credential.

- [ ] **Step 4: Validate on fixtures and commit**

```bash
python3 -m unittest discover -s webster/deepseek-v41/tests -p 'test_*.py'
bash webster/deepseek-v41/tests/test_failure_paths.sh
git add webster/deepseek-v41/scripts/stage-artifacts.sh \
  webster/deepseek-v41/scripts/verify-checkpoint.py webster/deepseek-v41/tests
git commit -m "feat: add immutable DeepSeek artifact staging"
```

Expected: idempotent fixture staging passes and every mismatch exits nonzero without
removing the divergent directory.

### Task 4: Implement and Prove the Exact `glm-5.2` Contract Guard

**Files:**

- Create: `webster/deepseek-v41/litellm/glm52_contract_guard.py`
- Create: `webster/deepseek-v41/litellm/test_glm52_contract_guard.py`
- Create: `webster/deepseek-v41/tests/fixtures/chat.json`
- Create: `webster/deepseek-v41/tests/fixtures/reasoning-none.json`
- Create: `webster/deepseek-v41/tests/fixtures/tools.json`
- Create: `webster/deepseek-v41/tests/fixtures/tool-result.json`
- Create: `webster/deepseek-v41/tests/fixtures/structured.json`
- Create: `webster/deepseek-v41/tests/fixtures/tokenize-golden.json`

**Interfaces:**

- Consumes: incoming LiteLLM request dicts and `/app/custom_callbacks/glm52-tokenizer/`.
- Produces: `glm52_contract_guard = GLM52ContractGuard()` returning a request dict or raising HTTP 400.

- [ ] **Step 1: Write failing unit tests for public-model isolation and shared-budget behavior**

Use an injected `count_prompt(data) -> int` in tests. Cover:

```python
def test_prompt_over_limit_is_rejected_before_routing():
    guard = GLM52ContractGuard(counter=lambda _: 320_001)
    with self.assertRaises(HTTPException) as error:
        asyncio.run(guard.async_pre_call_hook(None, None, {"model": "glm-5.2", "messages": []}, "completion"))
    self.assertEqual(error.exception.status_code, 400)

def test_requested_output_is_clamped_like_old_vllm():
    guard = GLM52ContractGuard(counter=lambda _: 319_900)
    data = {"model": "glm-5.2", "messages": [], "max_tokens": 500}
    result = asyncio.run(guard.async_pre_call_hook(None, None, data, "completion"))
    self.assertEqual(result["max_tokens"], 100)

def test_native_glm53_is_untouched():
    data = {"model": "glm-5.3-flash", "messages": [], "max_tokens": 500_000}
    original = copy.deepcopy(data)
    self.assertEqual(run_guard(data), original)
```

Also test `max_completion_tokens` precedence, Responses `max_output_tokens`, absent output limit, exact-limit prompt,
negative remaining budget, invalid/boolean/zero output fields, text-only content arrays,
tool definitions, tool-result history, `reasoning_effort`, `chat_template_kwargs`,
Responses input normalization, concurrent lazy initialization, missing tokenizer files,
and renderer failure. Counting failures must fail closed only for `glm-5.2`.

- [ ] **Step 2: Implement the tokenizer and template renderer**

Use `tokenizers.Tokenizer.from_file`, Jinja2's immutable sandbox with
`trim_blocks=True`/`lstrip_blocks=True`, and a deterministic `tojson` filter matching
the original Transformers renderer. Render `messages`, `tools`,
`add_generation_prompt=True`, `reasoning_effort`, and every supported
`chat_template_kwargs` key, then count `encode(rendered, add_special_tokens=False).ids`.

Normalize LiteLLM Responses input through its installed Responses-to-chat transform.
Load the tokenizer once under a lock. Do not make a network request or silently fall
back to tiktoken. Raise a 400 body with code `context_length_exceeded` for prompt
overflow and `contract_tokenization_failed` if the legacy contract cannot be evaluated.

- [ ] **Step 3: Capture golden tokens from the still-hot old backend**

Run each fixture against Shamu's authenticated `/tokenize` route without logging the
key. Store only rendered token IDs/counts and the non-secret fixture name in
`tokenize-golden.json`. If this vLLM build does not expose `/tokenize`, run a temporary
CPU-only Python process inside the existing GLM image with the read-only checkpoint
mount and Transformers tokenizer; do not start an engine or allocate the GPU.

Require exact token-ID equality for all short fixtures. Generate boundary fixtures by
binary-searching repeated non-special text until local counts are 319,999, 320,000, and
320,001, and validate the old route's accept/accept/reject behavior.

- [ ] **Step 4: Run tests in the exact LiteLLM image**

Run the module tests locally, then mount the repository module and staged tokenizer into
an ephemeral `ghcr.io/berriai/litellm:main-latest` container by the currently running
image ID, with `--network none`, and run the same tests. Expected: all pass and no
network socket is opened.

- [ ] **Step 5: Commit the guard**

```bash
git add webster/deepseek-v41/litellm webster/deepseek-v41/tests/fixtures
git commit -m "feat: preserve the GLM-5.2 shared token contract"
```

### Task 5: Implement Semantic LiteLLM Rendering and Offline Validation

**Files:**

- Create: `webster/deepseek-v41/scripts/render-litellm-cutover.py`
- Create: `webster/deepseek-v41/scripts/verify-litellm-config.py`
- Create: `webster/deepseek-v41/scripts/install-glm52-guard.sh`
- Create: `webster/deepseek-v41/scripts/restore-litellm-config.sh`
- Create: `webster/deepseek-v41/scripts/contract-probe.py`
- Test: `webster/deepseek-v41/tests/test_static.py`
- Test: `webster/deepseek-v41/tests/test_failure_paths.sh`

**Interfaces:**

- Consumes: `config.yaml.before`, a staged guard, and the staged legacy tokenizer.
- Produces: `config.yaml.candidate`, an allowed-diff report, and read-only/live contract probe JSON.

- [ ] **Step 1: Write config fixtures and failing allowed-diff tests**

Tests use configs containing unrelated models, callbacks, router plugins, virtual-key
settings, and secret-shaped values. `verify-litellm-config.py BEFORE AFTER --phase alias`
must allow only:

```text
model_list[model_name=glm-5.2].litellm_params.model
model_list[model_name=glm-5.2].litellm_params.api_base
model_list[model_name=glm-5.2].litellm_params.api_key
model_list[model_name=glm-5.2].model_info.input_cost_per_token
model_list[model_name=glm-5.2].model_info.output_cost_per_token
model_list[model_name=glm-5.2].model_info.description
litellm_settings.callbacks (one first-position guard insertion)
```

It requires exactly one deployment for each existing public name, preserves every
non-GLM-5.2 object by deep equality, leaves `router_settings.plugins` equal to
`["custom_callbacks.kv_router.plugin"]`, and rejects global
`enable_pre_call_checks: true`.

- [ ] **Step 2: Implement the alias renderer**

The renderer parses YAML, finds exactly one `glm-5.2` and one `glm-5.3-flash` entry,
and copies the native entry's `model`, `api_base`, and `api_key` into the compatibility
entry without printing them. It modifies the following keys in place, preserving
`mode` and every other existing metadata field:

```yaml
max_input_tokens: 320000
max_output_tokens: 320000
supports_function_calling: true
supports_reasoning: true
input_cost_per_token: 6.0e-08
output_cost_per_token: 1.7e-06
description: Deprecated GLM-5.2 compatibility alias served by GLM-5.3-Flash; legacy 320000-token shared window, reasoning, and function-calling contract retained; no advertised vision capability.
```

It removes `supports_vision` from only that model info and inserts
`custom_callbacks.glm52_contract_guard.glm52_contract_guard` exactly once at callback
index zero. The output is mode `0600`, is never written over the source, and is accepted
only after `verify-litellm-config.py` returns zero.

- [ ] **Step 3: Implement idempotent guard installation and offline import checks**

`install-glm52-guard.sh --candidate` copies the module and tokenizer to timestamped
temporary paths beneath `/home/nvidia/litellm/energy-pricing`, verifies hashes and
ownership, and atomically promotes them. A second identical install exits zero; a
divergent live file is backed up, never erased. Use the running LiteLLM image ID with
`--network none` to parse YAML, import every dotted callback, assert each custom object
subclasses `CustomLogger`, and invoke the guard fixture tests.

- [ ] **Step 4: Implement boundary and routing probes**

`contract-probe.py` reads a key from a mode-0600 file, never argv. It supports
`--base-url`, `--models`, `--backend-metrics-before`, and `--output-json`. It checks
chat, stream, reasoning off/on, tool auto, tool-result continuation, structured JSON,
the response `model` field against the captured pre-cutover behavior, and a long prompt.
Its over-limit case submits a 320,001-token rendered prompt and requires 400; backend
request counters must not move. Any response-model drift is resolved in the compatibility
callback and covered by non-streaming and streaming tests before the live restart.

Implement `restore-litellm-config.sh --phase alias|publish --run-root PATH`. It reads the
phase-specific absolute backup path from mode-0600 `rollback.env`, rejects paths outside
`/home/nvidia/litellm/` or without the recorded SHA-256, restores mode `0600`, restarts
LiteLLM once, and runs bind/readiness/root/401/cross-model checks. No rollback command
depends on shell history or a manually substituted path.

- [ ] **Step 5: Run tests and commit**

```bash
python3 -m unittest discover -s webster/deepseek-v41/tests -p 'test_*.py'
bash webster/deepseek-v41/tests/test_failure_paths.sh
git add webster/deepseek-v41/scripts webster/deepseek-v41/tests
git commit -m "feat: add validated LiteLLM alias cutover tooling"
```

### Task 6: Execute Milestones 1 and 2 — Freeze Rollback and Stage Artifacts

**Files:**

- Modify: `webster/deepseek-v41/README.md` with redacted milestone records.
- Create outside Git: `/home/ubuntu/deepseek-v41-runs/$CHANGE_ID/`.

**Interfaces:**

- Consumes: Tasks 1–5 and the live cluster.
- Produces: a GO record for milestones 1 and 2; no route, container, or service change.

- [ ] **Step 1: Create the evidence root and baseline**

```bash
cd /home/ubuntu/.setup
CHANGE_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ROOT="/home/ubuntu/deepseek-v41-runs/$CHANGE_ID"
umask 077
mkdir -p "$RUN_ROOT"
webster/deepseek-v41/scripts/preflight.sh --phase baseline --run-root "$RUN_ROOT"
```

Expected: GO; all existing public model probes pass, root is 403, unauthenticated models
is 401, LiteLLM bind is only `127.0.0.1:4446`, and both GLM ranks are healthy.

- [ ] **Step 2: Back up exact rollback state without exposing credentials**

Use one UTC timestamp for `spark-1:/home/nvidia/litellm/config.yaml`, callback files,
both GLM scripts, both container inspections, and credential metadata. Copy redacted
config/inspect output to the run root; leave secret-bearing backups mode `0600` only on
their source host. Record exact restore paths in `events.tsv`.

- [ ] **Step 3: Stage Shamu, observe, then stage Tilikum**

```bash
webster/deepseek-v41/scripts/stage-artifacts.sh --node shamu --run-root "$RUN_ROOT"
webster/deepseek-v41/scripts/stage-artifacts.sh --node tilikum --run-root "$RUN_ROOT"
```

Do not run these concurrently. Expected: identical manifests, 48 shards,
510,286,023,000 bytes, and GLM success/latency inside the abort thresholds.

- [ ] **Step 4: Stage and prove the guard without restarting LiteLLM**

Install candidate guard/tokenizer assets, run the exact-image offline checks, render the
candidate config, and verify its semantic diff. Do not replace live config and do not
restart LiteLLM.

- [ ] **Step 5: Record the gate and commit only the redacted record**

```bash
git add webster/deepseek-v41/README.md
git commit -m "docs: record DeepSeek cutover staging gate"
```

### Task 7: Execute Milestones 3 and 4 — Alias Cutover, Hot Soak, and GLM Stop

**Files:**

- Create: `webster/deepseek-v41/scripts/stop-glm52-tp2.sh`
- Create: `webster/deepseek-v41/scripts/start-glm52-tp2.sh`
- Modify: `webster/deepseek-v41/README.md`
- Test: `webster/deepseek-v41/tests/test_failure_paths.sh`

**Interfaces:**

- Consumes: verified candidate config and hot GLM ranks.
- Produces: `glm-5.2` routed to GLM-5.3 under the legacy contract; old ranks stopped but recoverable.

- [ ] **Step 1: Implement coordinated stop and cold rollback wrappers**

`stop-glm52-tp2.sh` captures both logs/inspects, stops Shamu and Tilikum as one
operation, and verifies both containers stopped, both GPUs released, and no station
port-8000 listener. If one stop fails it retries the other stop and exits nonzero; it
never leaves a single live rank intentionally.

`start-glm52-tp2.sh` first stops both DeepSeek ranks, then launches Shamu and Tilikum
with the existing scripts and explicit values:

```bash
GLM_NODE_RANK=0 GLM_HOST_IP=10.10.1.1 GLM_MAX_MODEL_LEN=320000 GLM_MAX_NUM_SEQS=8 /home/alecfong/serve_glm52.sh
GLM_NODE_RANK=1 GLM_HOST_IP=10.10.1.2 GLM_MAX_MODEL_LEN=320000 GLM_MAX_NUM_SEQS=8 GLM_DOCKER='sudo -n docker' /home/alecfong/serve_glm52.sh
```

It waits up to 20 minutes, samples rank-1 GPU memory, requires authenticated direct
health, `--headless`, no rank-1 listener/key, and zero restart count.

- [ ] **Step 2: Install the guard and atomically promote the candidate config**

Run the install script, copy live config to its timestamped mode-0600 backup, re-run
allowed-diff validation against that exact live file, and rename the candidate over
`config.yaml`. Abort before restart on any mismatch.

- [ ] **Step 3: Restart LiteLLM once and enforce the 60-second decision**

Record `date +%s%N`, run `docker restart litellm`, and poll readiness every second.
When ready, record duration, ID, start time, bind, restart count, callback imports, and
logs. If not ready by 60 seconds, inspect logs once, restore the named backup, restart
once, and stop the milestone.

- [ ] **Step 4: Prove both aliases and the legacy boundary**

Mint `cutover-$CHANGE_ID` scoped only to `glm-5.2`, `glm-5.3-flash`, and one unrelated
control model. Run `contract-probe.py` through loopback Caddy and the public URL.
Require old-station request counters unchanged, GLM-5.3 counters/traces increased,
legacy metadata unchanged, native GLM-5.3 metadata unchanged, and the 320,001-token
request rejected before backend counters move. Revoke the key.

- [ ] **Step 5: Soak for 30–60 minutes**

For at least 30 minutes and up to 60, collect five-minute success, p50/p90, stream,
reasoning, tool, structured, limit, cost, and trace checks. Any unexplained regression
restores the LiteLLM backup and performs one validated restart while station GLM stays
hot.

- [ ] **Step 6: Cross the cold-rollback boundary deliberately**

After a clean soak, record `GO release-stations`, execute `stop-glm52-tp2.sh`, then
re-run both alias probes. Record that rollback now requires stopping DeepSeek, loading
both GLM ranks for up to 20 minutes, validating direct health, restoring config, and one
LiteLLM restart.

- [ ] **Step 7: Run tests and commit**

```bash
git add webster/deepseek-v41/scripts/stop-glm52-tp2.sh \
  webster/deepseek-v41/scripts/start-glm52-tp2.sh \
  webster/deepseek-v41/README.md webster/deepseek-v41/tests
git commit -m "ops: complete the GLM compatibility alias cutover"
```

### Task 8: Pin and Package the DeepSeek V4.1 vLLM Runtime

**Files:**

- Create: `webster/deepseek-v41/runtime/Dockerfile`
- Create: `webster/deepseek-v41/runtime/constraints.txt`
- Create: `webster/deepseek-v41/runtime/README.md`
- Create: `webster/deepseek-v41/scripts/pin-runtime.py`
- Create: `webster/deepseek-v41/scripts/build-runtime.sh`
- Test: `webster/deepseek-v41/tests/test_static.py`
- Test: `webster/deepseek-v41/tests/test_failure_paths.sh`

**Interfaces:**

- Consumes: GitHub PR/release API evidence and the still-serving station pair.
- Produces: one immutable arm64 vLLM image loaded identically on both nodes and a source bundle in the run root.

- [ ] **Step 1: Implement a fail-closed runtime pin decision**

`pin-runtime.py --pr 56214 --manifest "$RUN_ROOT/manifest.env"` saves raw GitHub PR,
review, commit-status, and check-run JSON. It selects:

1. the containing released vLLM commit when a published release includes merged V4.1
   support; otherwise
2. PR merge commit when merged and all required checks pass; otherwise
3. the exact PR head only when not draft, review requirements pass, every required CI
   check succeeds, and `mergeable_state` is clean.

It exits nonzero for `unstable`, pending, failing, missing, or changing evidence. With
the observed state `open/unstable` at head
`0bfb653d3b5161660db9ada0d84c2cdd60961de7`, the expected result is NO-GO until upstream
state improves or a separately reviewed local patch decision is recorded.

- [ ] **Step 2: Freeze source, dependencies, and base image**

Clone by commit, verify HEAD, save `git bundle`, `git diff --binary`, submodule states,
and the source tar SHA-256. Resolve every `FROM` reference in the selected upstream
Dockerfile to a registry digest and write it to the manifest. Build output writes a
complete `pip freeze` to `runtime/constraints.txt` and captures CUDA/NCCL versions.

- [ ] **Step 3: Build once on Shamu and transfer immutably**

Use the upstream arm64 `vllm-openai` Docker target at the selected commit, with the
repository Dockerfile acting only as a digest-pinned wrapper. Run the build beneath a
scope capped at four CPUs, 96 GiB RAM, and low I/O weight; no GPU device enters the
builder. Tag for human readability but launch only by local image ID. Save the image,
SHA-256 the tar, copy over `10.10.1.2` with `rsync --checksum --bwlimit=250000`, verify
before load, and assert both nodes report the same image ID and internal vLLM commit.
Monitor GLM during build/save/copy/load and abort on the same two-window success/latency
threshold used for checkpoint staging.

- [ ] **Step 4: Prove architecture and Engram flags without serving**

Run `vllm serve --help` in the image and require `DeepseekV41ForCausalLM` registry
support plus `--engram-config`. Parse the checkpoint config and require nonempty
`engram_layer_ids`. Validate this exact baseline flag:

```text
--engram-config {"cpu_offload":true,"embedding_across_dp":false}
```

Do not include PRs #56220, #56227, or #56344 in the baseline image.

Do not run model import, kernel JIT, GPU architecture probes, or a serving process in
this task. Those begin only after the hot alias soak and coordinated GLM stop.

- [ ] **Step 5: Run tests and commit the reproducible runtime record**

```bash
python3 -m unittest discover -s webster/deepseek-v41/tests -p 'test_*.py'
bash webster/deepseek-v41/tests/test_failure_paths.sh
git add webster/deepseek-v41/runtime webster/deepseek-v41/scripts \
  webster/deepseek-v41/tests webster/deepseek-v41/README.md
git commit -m "build: pin the DeepSeek V4.1 vLLM runtime"
```

### Task 9: Execute Milestone 5 — Bring Up the Minimal TP2/PP1 Canary

**Files:**

- Create: `webster/deepseek-v41/scripts/start-deepseek-v41-tp2.sh`
- Create: `webster/deepseek-v41/scripts/stop-deepseek-v41-tp2.sh`
- Create: `webster/deepseek-v41/scripts/deepseek-v41-watchdog.sh`
- Modify: `webster/deepseek-v41/README.md`
- Test: `webster/deepseek-v41/tests/test_failure_paths.sh`

**Interfaces:**

- Consumes: pinned image ID, complete local checkpoints, separate rank-0 mode-0600 key.
- Produces: authenticated eager text canary at `http://100.73.140.127:8000/v1`.

- [ ] **Step 1: Implement coordinated lifecycle scripts**

The start script validates both checkpoints/image IDs, GLM stopped, port free, 200 GiB
free, rail/HCA active, and passwordless Shamu-to-Tilikum SSH. It starts rank 0 then rank
1 as detached containers with host network/IPC, InfiniBand device, memory-lock/stack
ulimits, CAP_IPC_LOCK, image ID, read-only checkpoint, node-local cache, and:

```text
NCCL_IB_HCA=mlx5_1
NCCL_SOCKET_IFNAME=enP1p3s0f1np1
GLOO_SOCKET_IFNAME=enP1p3s0f1np1
VLLM_HOST_IP=10.10.1.1|10.10.1.2
--nnodes 2 --node-rank 0|1 --master-addr 10.10.1.1 --master-port 29511
--tensor-parallel-size 2 --pipeline-parallel-size 1
--engram-config {"cpu_offload":true,"embedding_across_dp":false}
--enforce-eager --max-model-len 131072 --max-num-seqs 1
```

Rank 0 adds `--host 100.73.140.127 --port 8000` and reads its key from an env file.
Rank 1 adds `--headless`, explicitly unsets all serving-key variables, and has no HTTP
argument. Both use restart `no`; recovery belongs only to the coordinated watchdog.

- [ ] **Step 2: Implement split-brain-safe health ownership**

The watchdog checks both container start times, both process/rank arguments, direct
health, one correct listener, one headless rank, NCCL timeout/engine-death logs, and GPU
memory. A failure captures logs and invokes coordinated stop/start only after a
20-minute startup grace and 30-minute cooldown. It never calls `docker restart` or
starts one rank.

- [ ] **Step 3: Launch and verify security/lifecycle**

Require correct key 200, missing/wrong key 401, `/health` and `/metrics` mesh-only,
Shamu LAN port refused, Tilikum NetBird/LAN port refused, rank 1 no credential, and no
listener on any unintended interface. Verify NCCL logs name only `mlx5_1` and direct-rail
addresses; sample Grace and GPU allocations to prove local Engram placement.

- [ ] **Step 4: Run the eager semantic smoke suite**

Run three repetitions each of deterministic plain text, UTF-8, stop sequence,
streaming, and usage accounting. Require coherent nonempty output, no replacement-token
rate above the fixture threshold, exact stream reconstruction, and prompt/completion
usage fields.

- [ ] **Step 5: Run tests and commit**

```bash
git add webster/deepseek-v41/scripts webster/deepseek-v41/tests \
  webster/deepseek-v41/README.md
git commit -m "feat: launch the private DeepSeek V4.1 TP2 canary"
```

### Task 10: Execute Milestone 6 — Progressive Correctness Qualification

**Files:**

- Create: `webster/deepseek-v41/scripts/feature-qualification.py`
- Modify: `webster/deepseek-v41/README.md`
- Test: `webster/deepseek-v41/tests/test_static.py`

**Interfaces:**

- Consumes: direct private canary and named profile manifests.
- Produces: one JSON result per feature stage and `last-known-good.env`.

- [ ] **Step 1: Encode the reusable API/correctness suite**

Implement cases for deterministic text, UTF-8, streaming equivalence, stop sequences,
reasoning control, tool auto, named/required tool behavior recording, parallel tool
shape, tool-result continuation, strict schema JSON, `json_object`, usage details,
disconnect cancellation/queue drain, malformed input, wrong model, and over-limit
errors. Vision uses a repository-owned 2x2 PNG fixture encoded in the request; no remote
image URL is fetched.

Each case records request hash, status, finish reason, token usage, latency, normalized
output hash, semantic validator result, and the last 100 server log lines on failure.

- [ ] **Step 2: Qualify eager text and the 320K floor**

Run short cases, then tokenizer-sized 128K, 256K, 319K, 320K, and 320K+1 prompts with
small outputs. Require no rank death, stable memory, and clean 400 above the configured
window. Save the exact profile as the first last-known-good candidate.

- [ ] **Step 3: Enable compilation/CUDA graphs and compare output**

Remove `--enforce-eager`, warm every intended batch shape, and rerun the full text/API
suite. Compare eager and graph outputs at temperature zero plus semantic validators.
Any garbling, graph break, uncaptured production shape, or unacceptable KV loss returns
to eager.

- [ ] **Step 4: Enable DSpark alone and compare output/acceptance**

Add only the pinned runtime's documented DSpark configuration. Capture accepted draft
length by position, step time, rejection mode, output hashes, and quality validators.
Synthetic/forced acceptance is forbidden. Any correctness drift or engine instability
returns to graphs-without-DSpark.

- [ ] **Step 5: Enable and qualify vision alone**

Run local image description, image-plus-text, malformed image, streaming multimodal,
and usage cases. Advertise vision in the final model only if all pass.

- [ ] **Step 6: Raise the context ceiling to 1,048,576 last**

Test 512K, 768K, 1M-minus-headroom, exact 1M, and over-limit with concurrency one.
Require no host swap storm, OOM, rank loss, NCCL timeout, or recovery failure. If 1M
fails, retain the highest passing ceiling and record that exact value for publication.

- [ ] **Step 7: Select and commit the highest passing profile**

```bash
git add webster/deepseek-v41/scripts/feature-qualification.py \
  webster/deepseek-v41/README.md webster/deepseek-v41/tests
git commit -m "test: qualify DeepSeek V4.1 serving features"
```

### Task 11: Execute Milestone 7 — Tune TP2 and Conditionally Benchmark PP2

**Files:**

- Modify: `webster/deepseek-v41/scripts/start-deepseek-v41-tp2.sh`
- Modify: `webster/deepseek-v41/scripts/feature-qualification.py`
- Modify: `webster/deepseek-v41/README.md`

**Interfaces:**

- Consumes: highest passing correctness profile.
- Produces: frozen TP2 production candidate and an optional matched PP2 decision record.

- [ ] **Step 1: Freeze the one-factor matrix before running it**

Record baseline and candidate values for GPU memory utilization, max sequences, batched
tokens, chunked prefill, async scheduling, graph capture sizes, prefix caching, DSpark,
and EP. Change exactly one factor, restart both ranks, run correctness smoke, warm once,
measure three times, and return to baseline before the next factor.

- [ ] **Step 2: Measure the variables that explain throughput**

For every run capture request/session rate, TTFT p50/p90/p99, ITL, decode/user,
aggregate tokens, prefix-hit rate, KV occupancy, queue depth, preemptions, accepted draft
length, step time, GPU/Grace memory, NCCL bytes/packets, power, errors, and engine logs.
Do not infer progress from GPU utilization alone.

- [ ] **Step 3: Test EP only after stable non-EP TP2**

Use the same image/checkpoint and change only the documented EP switch. Require the full
API suite plus three matched warm workload repetitions. Reject EP if it introduces
semantic drift, imbalance, instability, or no Pareto improvement.

- [ ] **Step 4: Apply the PP2 trigger and matched decision rule**

Run PP=2/TP=1 only if TP2 fails correctness/memory/throughput, or NCCL synchronization
accounts for at least 15% of steady-state step time. PP2 must use the same context,
features, seed, cache state, concurrency, duration, and output checks. Keep PP2 only if
it improves sessions/s by at least 10% with no more than 5% p90/p99 regression, or
improves p90 by at least 10% with no more than 5% sessions/s regression. Otherwise
record `PP2 rejected` and retain TP2.

- [ ] **Step 5: Re-run correctness and commit the chosen profile**

```bash
git add webster/deepseek-v41/scripts webster/deepseek-v41/README.md
git commit -m "perf: select the DeepSeek V4.1 station profile"
```

### Task 12: Execute Milestone 8 — Run Controlled Full-Subagent Weka Replay

**Files:**

- Create: `webster/deepseek-v41/scripts/run-weka.sh`
- Create: `webster/deepseek-v41/scripts/summarize-aiperf.py`
- Modify: `webster/deepseek-v41/README.md`
- Test: `webster/deepseek-v41/tests/test_static.py`

**Interfaces:**

- Consumes: direct private canary and a mode-0600 benchmark key file on `head`.
- Produces: raw AIPerf/telemetry bundles and a Pareto report for the frozen matrix.

- [ ] **Step 1: Pin the client and corpus**

Create an isolated venv from an exact `ai-dynamo/aiperf` commit, record its commit and
lock, and resolve `semianalysisai/cc-traces-weka-062126` to an immutable Hugging Face
revision. Require the full 393-trace subagent corpus. The rolling
`semianalysis_cc_traces_weka_with_subagents` alias may resolve discovery metadata but is
not accepted as the recorded pin.

- [ ] **Step 2: Implement safe persistent runs**

`run-weka.sh` reads the API key file into an exported environment variable, never argv;
uses `mktemp -d -p /home/ubuntu/deepseek-v41-tmp`; writes the fully rendered non-secret
command; and runs under tmux. It traps exit to write exactly `EXIT=0` or the nonzero
integer exit status and copies all
artifacts before recursively deleting only the resolved temporary directory after
validating its prefix and ownership.

Every run uses the pinned tokenizer, direct URL `http://100.73.140.127:8000`, chat,
streaming, full subagents, an explicit 900-second benchmark duration, 300-second grace,
900-second request timeout, and fixed seed. No request-count termination is allowed.

- [ ] **Step 3: Run the frozen closed-loop matrix**

Run concurrency 1, 2, 4, and 8 with identical trace sequence and
`--no-fixed-schedule`; add 16 only if 8 has 99% success, zero engine deaths/timeouts,
and at least 20% free KV headroom. For warm comparisons run each point twice and report
only repetition two. For cold comparisons call the coordinated restart, prove cache
counters reset, and run each candidate from the same cold state.

- [ ] **Step 4: Run the fixed-schedule and arrival-rate qualification**

Run one full recorded-timeline replay with subagent SPAWN/JOIN behavior. Derive three
open-loop arrival rates from the seven-day observed p50, p90, and peak five-minute
request rates and freeze them in the manifest before execution. Keep trace delay rules,
duration, grace, timeout, and seed matched across candidates.

- [ ] **Step 5: Summarize correctness and performance**

`summarize-aiperf.py` counts failed JSONL rows before reading aggregates and emits:
completion/error rate, requests/s, sessions/s, input/output tok/s, per-user decode,
TTFT p50/p90/p99, ITL, end-to-end latency, ISL/OSL, cache hit, KV occupancy, queue,
preemptions, GPU/host memory, NCCL, and power. Scan representative plain, reasoning,
tool, JSON, vision, and long-context output for garbling.

The selected profile requires at least 99% server-side success, zero engine deaths,
zero NCCL timeouts, zero corruption flags, and reproducible warm results. Choose the
Pareto point; do not hide latency to maximize aggregate tokens.

- [ ] **Step 6: Commit the runner and redacted decision record**

```bash
git add webster/deepseek-v41/scripts/run-weka.sh \
  webster/deepseek-v41/scripts/summarize-aiperf.py \
  webster/deepseek-v41/README.md webster/deepseek-v41/tests
git commit -m "perf: qualify DeepSeek V4.1 on Weka traces"
```

### Task 13: Execute Milestone 9 — Register the New Model and Publish the Record

**Files:**

- Create: `webster/deepseek-v41/scripts/acceptance.sh`
- Create: `webster/deepseek-v41/scripts/sync-runbook.sh`
- Modify: `webster/deepseek-v41/scripts/render-litellm-cutover.py`
- Modify: `webster/deepseek-v41/scripts/verify-litellm-config.py`
- Modify: `webster/deepseek-v41/README.md`
- Modify live after verification: `/home/ubuntu/.claude/skills/webster-cluster/SKILL.md`

**Interfaces:**

- Consumes: selected passing profile, measured costs, and pre-registration LiteLLM backup.
- Produces: one new public `deepseek-v4.1-flash` entry plus synchronized Webster operating documentation.

- [ ] **Step 1: Extend the renderer/verifier for one additive model**

`--phase publish` allows exactly one new `model_name: deepseek-v4.1-flash`; it rejects
any change to `deepseek-v4-flash`, the GLM aliases, callbacks, router plugin, global
settings, and Caddy. The entry points to authenticated Shamu NetBird port 8000, uses the
actual served model name/image profile, sets the highest passing context, advertises
only passing reasoning/tool/structured/vision features, and uses measured marginal
input/output energy costs from the accepted Weka profile.

- [ ] **Step 2: Validate offline and perform the second planned restart**

Back up the exact live config, render to a candidate, run semantic diff, parse/import in
the pinned LiteLLM image with `--network none`, atomically promote, and restart once.
If readiness is absent at 60 seconds or any cross-model probe fails, restore the backup,
restart once, and leave DeepSeek private.

- [ ] **Step 3: Run end-to-end and security acceptance**

Mint `publish-$CHANGE_ID` scoped to the new model plus unrelated controls. Require
direct canary, private Caddy, and public completion; Langfuse trace; Prometheus series;
403 root; 401 unauthenticated models; loopback-only LiteLLM; zero restart count after
the planned restart; rank isolation/auth; no Baker metric/container/config change; and
successful `glm-5.2`, `glm-5.3-flash`, `deepseek-v4-flash`, and Inkling control probes.
Revoke the key.

- [ ] **Step 4: Update canonical operational truth only from live evidence**

Edit the canonical Webster skill's current-state summary, Models table, station restart
procedure, DeepSeek topology/profile, known gaps, and verification date. Do not copy
planned-but-failed features into the skill. Run:

```bash
/home/ubuntu/ops-bot/check-skill-drift.sh
/home/ubuntu/ops-bot/sync-skills.sh
```

If drift is reported, review and fold valid ops-bot changes into the canonical copy,
then sync. Verify Claude, Codex, and Hermes copies describe the same live state and
`hermes skills list` still includes Webster.

- [ ] **Step 5: Publish the repeatable playbook evidence**

README receives actual timings, backup paths, gate decisions, failed variants, selected
profile, rollback commands, benchmark report path, and the limited-downtime lessons:
control-plane route first, hot soak before data-plane release, private qualification,
coordinated ranks, exactly two front-door restarts, immutable artifacts, and no cleanup
inside the change. The subsequent skill-creation change will derive from this exercised
record rather than copying untested commands.

- [ ] **Step 6: Run full verification and commit**

```bash
bash -n webster/deepseek-v41/scripts/*.sh
python3 -m unittest discover -s webster/deepseek-v41/tests -p 'test_*.py'
bash webster/deepseek-v41/tests/test_failure_paths.sh
./test.sh
git diff --check
git add webster/deepseek-v41 test.sh
git commit -m "docs: publish the DeepSeek V4.1 cutover playbook"
```

Expected: all repository checks pass, all three Webster skill copies agree, no secret
scanner finding exists, and the final acceptance record is GO.

## Rollback Commands by Boundary

Before the alias restart, discard the candidate; no service action is required.

During the hot-GLM soak:

```bash
webster/deepseek-v41/scripts/restore-litellm-config.sh --phase alias --run-root "$RUN_ROOT"
```

After station release, stop DeepSeek, restore both GLM ranks, verify direct health, then
restore the LiteLLM backup and restart once:

```bash
webster/deepseek-v41/scripts/stop-deepseek-v41-tp2.sh --run-root "$RUN_ROOT"
webster/deepseek-v41/scripts/start-glm52-tp2.sh --run-root "$RUN_ROOT"
webster/deepseek-v41/scripts/restore-litellm-config.sh --phase alias --run-root "$RUN_ROOT"
```

After new-model registration, restore only the pre-registration LiteLLM backup and
restart once while leaving the private canary available for diagnosis:

```bash
webster/deepseek-v41/scripts/restore-litellm-config.sh --phase publish --run-root "$RUN_ROOT"
```

## Final Verification Checklist

- [ ] `glm-5.2` routes to GLM-5.3 but retains its public name, 320K shared window,
  reasoning/function metadata, no vision, and old clamp/reject behavior.
- [ ] Native `glm-5.3-flash` retains 1M and vision; Baker remains unchanged.
- [ ] Old GLM ranks are stopped together and all rollback artifacts remain.
- [ ] DeepSeek V4.1 runs from identical pinned checkpoint/runtime artifacts on both
  stations, TP2/PP1 unless the matched PP2 decision says otherwise.
- [ ] Engram is local Grace memory, NCCL is `mlx5_1`, rank 1 is headless/keyless, and
  rank 0 is authenticated/NetBird-only.
- [ ] The highest enabled feature profile passed the full correctness suite.
- [ ] Full-subagent Weka meets 99% success, zero death/timeout/corruption, controlled
  cache, and reproducibility gates.
- [ ] Exactly two planned LiteLLM restarts and their durations/rollback decisions are
  recorded.
- [ ] `deepseek-v4.1-flash` is independently registered and observed in Prometheus and
  Langfuse.
- [ ] Repository tests, `./test.sh`, shell syntax, and `git diff --check` pass.
- [ ] Canonical Claude, Codex, and Hermes Webster skills agree with verified live state.
- [ ] No secret exists in Git or the published evidence.
