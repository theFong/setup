# vLLM Tuning Notes

Concrete knobs and measured results. Versions move fast — treat numbers as
illustrative of *shape*, and re-measure on your stack.

## Speculative decoding: measure the crossover, do not assume one

Speculative decoding submits `k+1` tokens per sequence to the verify pass. The
common expectation is a crossover — a win at low concurrency, a loss at high,
because the verify batch grows with concurrency. **Whether that crossover exists
on your hardware is an empirical question, and getting it wrong is expensive in
both directions.**

Measured on a *healthy* datacenter GPU (single GB300, MoE model, k=8,
`max_num_seqs=32`, OSL=256), aggregate decode tok/s:

| ISL | C | Spec ON | Spec OFF | Winner |
|---|---|---|---|---|
| 256 | 1 | **278** | 158 | ON +76% |
| 256 | 8 | **1198** | 866 | ON +38% |
| 256 | 16 | **1875** | 1431 | ON +31% |
| 8K | 8 | **591** | 409 | ON +44% |
| 8K | 16 | **654** | 456 | ON +43% |
| 32K | 8 | **225** | 92 | ON +145% |
| 32K | 16 | **218** | 112 | ON +95% |
| 128K | 8 | **46** | 35 | ON +29% |
| 128K | 16 | **54** | 37 | ON +45% |

**No crossover anywhere up to C=16.** Speculation wins at every context length
and every concurrency tested, by 29–145%. The only cost is KV pool: freeing the
draft model's cache gave +23% pool (6.0M → 7.4M tokens), which does not come
close to paying for the throughput.

### The cautionary tale

An earlier version of this file reported the opposite — a crossover at C=16 with
spec-off winning by 3.1x at C=32 — and recommended shipping two profiles. Those
numbers were real measurements, taken on a GPU that turned out to be **power
throttled** (see hardware-validation.md). On a starved part the `k+1` verify
batch is extra work it cannot absorb; with headroom it is nearly free and the
accepted tokens are pure gain.

Two lessons, both of which cost real time:

1. **Re-validate every tuning conclusion after finding a hardware fault.** The
   fault invalidates conclusions drawn *before* you found it, not just the ones
   you were working on at the time.
2. A plausible mechanism ("the verify batch exceeds the tuned kernel range") is
   not evidence. It made a hardware artifact look like a software law.

If you do see a crossover, confirm the machine is healthy first, then look for a
corroborating signal such as an autotuner shape warning:

```
No tuned config covers flashinfer::trtllm_fp4_block_scale_moe
input_shapes=(torch.Size([184, 4096]), ...); falling back to runner=MoERunner
tactic=-1. This shape is outside the tuning bucket range.
```

`32 seqs x (k=5 + 1) = 192` tokens lands right at that boundary — a real effect,
but on healthy hardware it was not large enough to flip the decision.

## Draft length `k`

Raising `k` above the checkpoint's native draft block size adds work per kernel
(helps single-stream) but degrades acceptance:

| `k` | C=1 | C=2 | C=4 | acceptance length |
|---|---|---|---|---|
| 5 | 34.6 | **38.2** | **34.9** | ~3.0 |
| 8 | **38.8** | 35.2 | 29.0 | ~2.05–2.49 |

Single-stream only. Check `dspark_block_size` / equivalent in `config.json` —
below it, drafts are truncated; above it, acceptance falls off.

Watch the acceptance metrics:
```
vllm:spec_decode_num_draft_tokens_total
vllm:spec_decode_num_accepted_tokens_total
```
Healthy is ~0.6 acceptance / ~3 accepted per draft. If yours matches a system
you are losing to, acceptance is **not** your problem — look elsewhere.

## Fused custom ops can be silently disabled

vLLM turns its hand-written fused CUDA ops off when `torch.compile` is enabled,
expecting Inductor to fuse instead. **If the model does not support compile, you
get neither:**

```
WARNING `torch.compile` is turned on, but the model does not support it.
compilation_config={'custom_ops': ['+quant_fp8', 'none', ...],
                    rms_norm=['native']}
```

Forcing them back on is worth real throughput:

```
--compilation-config '{"custom_ops":["all"]}'
```

Measured +5.5% at C=1 alone, and **super-additive** with a larger `k`:

| Config | C=1 |
|---|---|
| baseline | 34.6 |
| `custom_ops=all` | 36.5 |
| `k=8` | 38.8 |
| **both** | **45.4** (+31%) |

They compound because they act on different terms — kernel *count* and work
*per* kernel.

Check the startup config dump for `custom_ops` and `rms_norm` to see what you
actually got.

## Backends are gated per quantization scheme

A backend in the global registry may still be rejected for your weights:

```
ValueError: moe_backend='flashinfer_b12x' is not supported for MXFP4 MoE.
Expected one of ['deep_gemm', 'flashinfer_trtllm', 'flashinfer_cutlass',
                 'triton', 'marlin', 'aiter', 'xpu', ...]
```

And the advertised list may itself be optimistic — a second, deeper gate:

```
ValueError: Unsupported mxfp4_backend: FLASHINFER_CUTLASS_MXFP4_MXFP8.
Expected TRTLLM, Triton, AITER, or XPU backend.
```

Enumerate empirically before planning. For MXFP4 MoE on NVIDIA the real set was
TRTLLM (best) or Triton; `marlin` loaded but ran 20% slower.

## CUDA graphs vs compile

```
VLLM_USE_BREAKABLE_CUDAGRAPH=0   # opt out of auto breakable-graph mode
```
Auto-enabling this disables the compile pipeline (`CompilationMode.NONE`).
Setting it to 0 restored graph capture (`FULL_AND_PIECEWISE`, 52 graphs, ~28%
lower step time in isolation) — but *also* flipped `custom_ops` off, netting
zero. Watch for knobs that trade one optimization for another; verify both
halves in the config dump.

## Profiling vLLM

- `VLLM_TORCH_PROFILER_DIR` may not exist in your version — grep the env
  registry; `/start_profile` returns 404 when unsupported.
- The engine runs in a **subprocess** by default, so a parent-process profiler
  captures nothing. Set `VLLM_ENABLE_V1_MULTIPROCESSING=0`.
- The argument parser initializes the device — profiling scripts need a GPU
  attached even to build the parser.
- `enforce_eager=True` gives per-kernel attribution (CUDA graphs collapse into
  one blob). Read the *ranking*, not absolute times.
- `prof.key_averages()` can return empty; exporting a chrome trace and
  aggregating the JSON by kernel name is more robust.

## Silent correctness traps

- **Non-streaming reasoning can be dropped entirely.** Thinking tokens are
  generated and billed in `completion_tokens`, then discarded — 13.7K tokens
  vanished in one measured run. Streaming delivered 30,777 chars under
  `delta.reasoning` (note: **not** `reasoning_content`). Use streaming if you
  need the trace.
- **Truncation mid-thought returns nothing.** A parser buffering until a closing
  think tag yields empty `content` *and* empty reasoning if `max_tokens` cuts it
  off. A high-effort prompt capped at 2000 tokens reliably returned 2000 tokens
  of nothing. Budget generously.

## Memory sizing for MoE checkpoints

Do not assume dense BF16. A "304B parameter" MoE shipped pre-quantized (fp8
dense + fp4 experts) at **166.9 GB on disk**, not ~608 GB — the difference
between needing a cluster and needing one GPU. Check `config.json` for
`quantization_config` and `expert_dtype`, and sum the actual shard sizes:

```bash
curl -sL "https://huggingface.co/api/models/$REPO?blobs=true" |
  python3 -c 'import json,sys; d=json.load(sys.stdin);
  print(sum(s.get("size",0) or 0 for s in d["siblings"])/1e9, "GB")'
```

KV cache dtype matters more than expected: per-layer compression ratios can make
the pool far larger than the dtype alone implies. Read the actual boot line:

```
GPU KV cache size: 5,985,299 tokens
Maximum concurrency for 1,048,576 tokens per request: 5.71x
```
