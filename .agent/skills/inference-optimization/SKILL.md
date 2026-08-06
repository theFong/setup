---
name: inference-optimization
description: Diagnose and optimize LLM inference throughput on GPU servers (vLLM, SGLang, TensorRT-LLM). Use when benchmarking a model server, chasing a tokens/sec regression, sizing a model against available memory, comparing hardware, tuning speculative decoding or MoE backends, debugging a multi-node or tensor-parallel deployment, or when inference is "slower than it should be". Trigger keywords - tok/s, tokens per second, inference slow, throughput, decode speed, TTFT, benchmark, speculative decoding, MoE backend, vLLM tuning, GPU underperforming, single-stream, concurrency, multi-node, tensor parallel, NCCL, KV cache, context length, will it fit, OOM at startup, tool calling.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
argument-hint: [validate|capacity|baseline|profile|tune] [host]
---
<!--
Token Budget:
- Level 1 (YAML): ~180 tokens
- Level 2 (This file): ~2000 tokens (target <2200)
- Level 3 (reference/): Loaded on demand
-->

# Inference Optimization

Systematic method for making an LLM inference server fast, and for telling the
difference between slow software, broken hardware, and a configuration that was
never going to fit.

## The One Rule

**Validate the hardware before you optimize anything.** Skipping this is the
single most expensive mistake available in this work. A throttled GPU produces
performance that is *invariant to every software change you make*, so you can
burn a day testing hypotheses that were never capable of mattering.

**In a multi-node job, validate every node.** Tensor parallelism runs at the
speed of its worst rank, so one sick GPU presents as a uniformly slow cluster:
measured, a single power-braked GPU held a two-node server at ~9 tok/s that
reached ~90 once the cable was reseated.

See [reference/hardware-validation.md](reference/hardware-validation.md) for the
case study: identical GPUs, identical config, **7x** throughput difference.

## Phase 0 — Hardware validation (never skip)

```bash
# The decisive test: power draw during sustained decode.
nvidia-smi --query-gpu=utilization.gpu,power.draw,clocks.sm --format=csv -l 1 -i "$GPU"

# Throttle flags. "HW Slowdown: Active" with no thermal cause = power brake.
nvidia-smi -i "$GPU" -q -d PERFORMANCE | grep -A8 'Clocks Event Reasons'
```

**Read `power.draw`, not `utilization.gpu`.** GPU "utilization" is the fraction
of time *any* kernel is resident — it reads 99% on a starved GPU. Power is the
honest signal for whether real work is happening.

| Symptom | Meaning |
|---|---|
| 99% util, power near idle, at max clocks | **Throttled or faulty** — stop and check hardware |
| 99% util, power near TDP | Genuinely busy — optimize software |
| Perf invariant to every config change | Environment, not software |

**If more than one machine exists, baseline a second one before deep work.**
One comparative run costs less than a day of misattributed profiling.

## Phase 1 — Capacity: will it even fit?

For a model that nearly fills its GPUs, **memory is the design space** — you
cannot tune a configuration that does not fit, and most "can we serve X at Y"
questions are settled by arithmetic before any benchmark.

```
KV pool = (HBM x utilization) - weights - activation reserve
context x concurrent_sequences <= KV pool tokens
```

- **Read it from the boot log**, do not compute it: `GPU KV cache size: N tokens`
  and `Maximum concurrency for N tokens per request`. Below 1.0x it will not start.
- **Features are resident weights.** A speculative-decoding draft head cost
  ~12 GiB/GPU and cut usable context from ~360k to ~82k until utilization was
  raised from 0.92 to 0.97.
- **The pool shrinks as you raise `max-model-len`** (activation is profiled at
  the configured length), so you cannot extrapolate the ceiling from a pool
  measured lower. Approach it in steps.
- **On fixed HBM you pick two of {context, concurrency, accuracy}.** When a
  requirement is unreachable, say which constraint must move rather than tuning
  toward an impossibility.

Details and measured tables: [reference/memory-budget.md](reference/memory-budget.md)

## Phase 2 — Trustworthy baseline

Bad measurements cause worse decisions than no measurements.

- **Drain to idle first** — leftover in-flight requests wreck TTFT.
  Poll `vllm:num_requests_running` / `_waiting` to 0.
- **Warm up, then re-run** — first touch of each batch/sequence shape pays JIT.
  Cold vs warm measured **175 s vs 3.3 s** TTFT on the same case.
- **Read decode and prefill separately** — aggregate metrics that divide by
  wall-clock-including-prefill understate decode by 3-4x.
- **Vary long prompts between runs** — prefix caching makes a repeat prefill look
  ~100x faster than it is.
- **Disable thinking/reasoning** for raw throughput, or it silently consumes
  decode budget.
- Use the *same harness* as any number you are comparing against.

## Phase 3 — Profile before hypothesizing

Do not test hypotheses blind. Profiling early is cheaper than four wrong guesses.

```bash
# vLLM engine must run in-process or the profiler sees nothing.
VLLM_ENABLE_V1_MULTIPROCESSING=0
# torch.profiler -> chrome trace -> aggregate by kernel name
```

What to extract: kernel count per step, median kernel duration, and the top-10
share of GPU time. **A flat distribution (no kernel >15%) means there is no
single fix** — stop hunting for one.

## Phase 4 — Tune

Highest-yield knobs, in order:

1. **Speculative decoding has a concurrency crossover.** Big win at low
   concurrency, big *loss* at high. Measured: +34% at C=1, **-3.1x at C=32**.
   Ship two profiles, not one.
2. **Draft length `k`** — raise it for single-stream only; acceptance degrades
   past the checkpoint's block size.
3. **Backend/kernel selection** — verify what your quantization actually
   supports before assuming a backend is available.
4. **Fused custom ops** — check they were not silently disabled.

Details and the full measured tables: [reference/vllm-tuning.md](reference/vllm-tuning.md)

Multi-node specifics — library loading, fabric exoneration, rank roles, and the
startup cost that makes each experiment expensive:
[reference/multi-node.md](reference/multi-node.md)

## Phase 5 — Validate the delivery path

Fast weights nobody can use is not a finished job. Each hop
(engine → gateway → client) can silently drop a capability, and the symptom is
rarely an error.

- **Tool calling needs explicit parser flags.** Without them a tools payload 400s
  or comes back as prose describing the call. Parser names are version-specific —
  read them out of the validator's error, not the model card.
- **Gateways strip unknown parameters.** An agent that "replies and takes no
  action" is usually stripped `tools`, not an incapable model. Bypass the proxy
  to bisect.
- **Streaming and non-streaming parse differently.** Test the mode your client
  uses; non-streaming can drop reasoning content entirely.
- **Served limits are not the model's limits.** `max_model_len` is the truth;
  clients reading a model card's context length will overrun it and get a 400.

Details: [reference/serving-stack.md](reference/serving-stack.md)

## Meta-Lessons

The habits that would have saved the most time are in
[reference/methodology.md](reference/methodology.md). The short version:

- Invariance is a signal — suspect the environment.
- Matching magnitude is not evidence of mechanism.
- **Verify the running artifact**, not version labels or published configs.
- **Assume more than one cause** — a partial fix is not a refuted hypothesis.
- Read upstream sources before inferring from filenames or quoting effort.
- State confidence honestly and retract clearly when measurements disagree.

## References

- **[reference/hardware-validation.md](reference/hardware-validation.md)** — GPU health checks, faulty-GPU case study, isolating a physical fault
- **[reference/memory-budget.md](reference/memory-budget.md)** — KV/weights budget, the context-concurrency-accuracy trilemma
- **[reference/multi-node.md](reference/multi-node.md)** — tensor-parallel serving, NCCL loading, fabric checks, startup cost
- **[reference/serving-stack.md](reference/serving-stack.md)** — parsers, gateways, streaming, served limits
- **[reference/methodology.md](reference/methodology.md)** — benchmarking pitfalls, artifact verification, reasoning discipline
- **[reference/vllm-tuning.md](reference/vllm-tuning.md)** — vLLM knobs, MoE backends, measured results
