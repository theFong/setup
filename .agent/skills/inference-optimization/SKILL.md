---
name: inference-optimization
description: Diagnose and optimize LLM inference throughput on GPU servers (vLLM, SGLang, TensorRT-LLM). Use when benchmarking a model server, chasing a tokens/sec regression, comparing hardware, tuning speculative decoding or MoE backends, or when inference is "slower than it should be". Trigger keywords - tok/s, tokens per second, inference slow, throughput, decode speed, TTFT, benchmark, speculative decoding, MoE backend, vLLM tuning, GPU underperforming, single-stream, concurrency.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
argument-hint: [validate|baseline|profile|tune] [host]
---
<!--
Token Budget:
- Level 1 (YAML): ~140 tokens
- Level 2 (This file): ~1900 tokens (target <2000)
- Level 3 (reference/): Loaded on demand
-->

# Inference Optimization

Systematic method for making an LLM inference server fast, and for telling the
difference between slow software and broken hardware.

## The One Rule

**Validate the hardware before you optimize anything.** Skipping this is the
single most expensive mistake available in this work. A throttled GPU produces
performance that is *invariant to every software change you make*, so you can
burn a day testing hypotheses that were never capable of mattering.

See [reference/hardware-validation.md](reference/hardware-validation.md) for the
case study: identical GPUs, identical config, **7x** throughput difference.

## Phase 0 — Hardware Validation (never skip)

```bash
# 1. Throttle flags. "HW Slowdown: Active" with no thermal cause = power brake.
nvidia-smi -i "$GPU" -q -d PERFORMANCE | grep -A8 'Clocks Event Reasons'

# 2. Power ceiling. Compare Current vs Default -- a cap below default is a red flag.
nvidia-smi -i "$GPU" -q -d POWER | grep -E 'Power Limit|Power Draw'

# 3. Clocks under load vs Max Clocks.
nvidia-smi -i "$GPU" -q -d CLOCK | grep -A3 'Max Clocks'

# 4. THE decisive test: power draw during sustained decode.
nvidia-smi --query-gpu=utilization.gpu,power.draw,clocks.sm --format=csv -l 1 -i "$GPU"
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

## Phase 1 — Trustworthy Baseline

Bad measurements cause worse decisions than no measurements.

- **Drain to idle first** — leftover in-flight requests wreck TTFT.
  Poll `vllm:num_requests_running` / `_waiting` to 0.
- **Warm up, then re-run** — first touch of each batch/sequence shape pays JIT.
  Cold vs warm measured **175 s vs 3.3 s** TTFT on the same case.
- **Read decode and prefill separately** — aggregate metrics that divide by
  wall-clock-including-prefill understate decode by 3-4x.
- **Disable thinking/reasoning** for raw throughput, or it silently consumes
  decode budget.
- Use the *same harness* as any number you are comparing against.

## Phase 2 — Profile Before Hypothesizing

Do not test hypotheses blind. Profiling early is cheaper than four wrong guesses.

```bash
# vLLM engine must run in-process or the profiler sees nothing.
VLLM_ENABLE_V1_MULTIPROCESSING=0
# torch.profiler -> chrome trace -> aggregate by kernel name
```

What to extract: kernel count per step, median kernel duration, and the top-10
share of GPU time. **A flat distribution (no kernel >15%) means there is no
single fix** — stop hunting for one.

## Phase 3 — Tune

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

## Meta-Lessons

The habits that would have saved the most time are in
[reference/methodology.md](reference/methodology.md). The short version:

- Invariance is a signal — suspect the environment.
- Matching magnitude is not evidence of mechanism.
- Read upstream sources before inferring from filenames or quoting effort.
- State confidence honestly and retract clearly when measurements disagree.

## References

- **[reference/hardware-validation.md](reference/hardware-validation.md)** — GPU health checks, faulty-GPU case study
- **[reference/methodology.md](reference/methodology.md)** — benchmarking pitfalls, reasoning discipline
- **[reference/vllm-tuning.md](reference/vllm-tuning.md)** — vLLM knobs, MoE backends, measured results
