# vLLM Tuning Notes

Concrete knobs and measured results. Versions move fast — treat numbers as
illustrative of *shape*, and re-measure on your stack.

## `max_num_seqs` is a hard cap, and 1 serializes everything

A batch cap of 1 does not mean "tuned for latency" — the engine runs exactly one
sequence at a time no matter how short the requests are. Aggregate throughput is
then **flat at every concurrency** and extra clients only add queueing:

| concurrency | seqs=1 | seqs=8 |
|---|---|---|
| 1 | 94.2 tok/s · TTFT 249 ms | 78.4 · 245 ms |
| 4 | 101.6 · TTFT 14,865 ms | 157.5 · 342 ms |
| 8 | **102.2 · TTFT 35,132 ms** | **311.1 · 437 ms** |

3.04x aggregate and 80x better TTFT, from one flag. **Flat aggregate throughput
with linearly growing TTFT is the signature of serialization, not of a saturated
GPU** — check the cap before profiling kernels.

The win is workload-shaped: at 50k-token inputs the same change gave only **+24%**,
because that regime is prefill-bound rather than decode-bound. Raising the cap also
widens cudagraph capture and shrinks the KV pool, so re-verify that the context
length still fits — see [memory-budget.md](memory-budget.md).

## Speculative decoding has a concurrency crossover

The most valuable tuning finding available, and it is rarely documented.

Speculative decoding submits `k+1` tokens per sequence to the verify pass. At
low concurrency that is free throughput. At high concurrency the verify batch
grows by `k+1` and can exceed the tuned range of the MoE/GEMM kernels, falling
off a performance cliff.

Measured (MoE model, single datacenter GPU):

| Concurrency | Spec ON | Spec OFF | Winner |
|---|---|---|---|
| 1 | **35.0** tok/s | 26.2 | ON (+34%) |
| 4 | **115.4** | 87.8 | ON (+31%) |
| 16 | 180.9 | **251.0** | OFF (+39%) |
| 32 | 132.0 | **411.7** | OFF (**+212%**) |

**Ship two profiles.** A single setting is wrong for half your traffic.

Corroborating signal — the autotuner warned at exactly the batch shape where the
cliff appeared:

```
No tuned config covers flashinfer::trtllm_fp4_block_scale_moe
input_shapes=(torch.Size([184, 4096]), ...); falling back to runner=MoERunner
tactic=-1. This shape is outside the tuning bucket range.
```

`32 seqs x (k=5 + 1) = 192` tokens — right at the untuned boundary.

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
