# Memory Budget

For a model that nearly fills its GPUs, **memory is the design space** — not
kernel efficiency. You cannot tune a configuration that does not fit, and most
"can we serve X at Y" questions are settled by arithmetic before any benchmark.

## The two lines everything follows from

```
KV pool  =  (HBM x gpu_memory_utilization)  -  weights  -  activation reserve
context x concurrent_sequences  <=  KV pool tokens
```

Read the result off the server's own boot log rather than computing it:

```
Available KV cache memory: 16.36 GiB
GPU KV cache size: 362,713 tokens
Maximum concurrency for 300,000 tokens per request: 1.21x
```

"Maximum concurrency" is the number to watch: it is pool ÷ max-model-len, i.e.
how many full-length sequences fit. Below 1.0 the server refuses to start.

## Weights per GPU dominate everything downstream

Same model family, two nodes at 252 GiB/GPU:

| Variant | Weights/GPU | KV headroom | KV pool | Max ctx @ batch 1 | @ batch 4 |
|---|---|---|---|---|---|
| full (256 experts) | ~216 GiB | ~16 GiB | 362k tok | ~350k | ~90k |
| pruned (168 experts) | ~144 GiB | ~108 GiB | **1.23M tok** | ~1.2M | ~300k |

A 33% smaller checkpoint bought **3.4x the KV pool**. Adding nodes does the same
thing — capacity planning for long context is mostly a weights-per-GPU exercise,
and "we need more GPUs" is usually a statement about KV room, not FLOPs.

## Features are resident weights, and can make your target infeasible

A speculative-decoding draft head is memory that competes with the KV cache.
Measured cost **~12 GiB/GPU** on a model already at 216 GiB/GPU — most of what
was left:

| Config | Available KV | Usable context |
|---|---|---|
| no spec decode, util 0.92 | 16.0 GiB | ~360k |
| **spec decode, util 0.92** | **3.74 GiB** | **~82k** — refuses to start at 300k |
| spec decode, util **0.97** | 16.36 GiB | ~350k |

The failure mode is a startup error, not slow inference:

```
To serve at least one request with the model's max seq len (300000),
13.53 GiB KV cache is needed, which is larger than the available KV cache
memory (3.74 GiB). ... estimated maximum model length is 82944.
```

`gpu_memory_utilization` is the lever that buys it back: 0.92 → 0.97 recovered
~12 GiB and made the same configuration viable at ~100 tok/s. High utilization
leaves little headroom for activation spikes, so **validate at your real maximum
context**, not on a short prompt — a config that boots can still OOM in service.

## The pool shrinks as you raise max-model-len

Non-obvious, and it will cost you a restart. The engine profiles activation
memory at the *configured* max length, so a longer max-len reserves more and
leaves **less** for KV. You therefore cannot extrapolate the ceiling from a pool
measured at a lower max-len.

Measured at identical utilization:

| max-model-len | Available KV | KV pool | Result |
|---|---|---|---|
| 300,000 | 16.36 GiB | 362,713 tok | fits, 1.21x |
| 350,000 | 15.97 GiB | 354,223 tok | fits, **1.01x** |
| 360,000 | 15.92 GiB | — | **refuses**: needs 16.23 GiB; estimates true max ~353k |

Reading "362,713 tokens" at a 300k setting and concluding "360k will fit" is
wrong — that was a real failed launch. Approach the ceiling in steps and trust
the engine's own `estimated maximum model length` over your arithmetic.

## Cudagraph capture sizes are charged to the same residual

Raising the batch cap means widening the decode cudagraph capture list, and those
graphs come out of the pool's budget. Measured: going from one capture size to
four — to cover 8 sequences where speculative decode makes the decode batch
`seqs x 5` — cost **~0.23 GiB**. Small in absolute terms, and still enough to push
a max-model-len that previously fit **below its own minimum**, so the server
refused to start.

Budget the concurrency change and the context length together. Note also that the
profiler is not perfectly repeatable: one setting near the edge **started twice
and failed once on identical config**. Leave real margin instead of sitting on the
engine's `estimated maximum model length`.

## CPU KV offload extends the cache, not the working set

Offloading KV to host memory is the obvious move when the pool is tight, and on
coherent-memory parts it looks free — measured **379 GB/s H2D / 375 GB/s D2H**
GPU↔host, versus ~55 GB/s for PCIe Gen5 x16. The transfers really are that fast: a
CPU-tier hit promoted a **50k-token prefix in 5 ms** against ~7.7 s to prefill it,
roughly 1,500x, at a 49.7% hit rate.

It still lost end to end, and the reason generalizes.

**Offload connectors extend the prefix cache, not the number of resident
sequences.** They are an L2 lookup tier: blocks are copied out on eviction and
copied back on a later prefix hit. They do not raise the batch cap and do not let
more sequences decode concurrently. They help **prefill**, and only when requests
actually share prefixes.

Meanwhile every offload path **costs GPU KV pool**:

- Engines commonly reject KV connectors while the CUDA allocator is in an
  expandable/VMM mode, because the connector pins KV pages the allocator may
  remap. Turning that mode off reintroduces fragmentation and forces utilization
  down — and the resulting OOM message will recommend the very flag you removed.
- An out-of-process cache server still holds **GPU** memory if it reaches the
  engine's KV buffers over IPC (measured **~9.5 GiB**), capping utilization via
  the engine's own free-memory check.

Measured net where weights already filled ~88% of HBM: pool **−49%**, cutting
resident 50k-token sequences from ~7 to ~3.6. Requests then queued for blocks, and
that queueing delay swamped the prefill savings — throughput and TTFT both got
worse than with no offload at all.

**Decide with one question: is the pool binding on admission, or is prefill
binding on latency?** Offload addresses the second. If sequences are queueing for
blocks, spending pool to buy a prefill cache trades the scarce resource for the
abundant one. It becomes attractive with a smaller checkpoint, more HBM or nodes,
or heavy prefix reuse at low concurrency.

## The trilemma: pick two

On fixed HBM with the checkpoint chosen, you choose two of **{long context,
concurrency, accuracy}**. Measured across one two-node pair:

| Profile | Context | Concurrency | Per-stream | Accuracy |
|---|---|---|---|---|
| latency (spec decode, util 0.97) | 350k | 1 | ~100 tok/s | full |
| capacity (context-parallel KV) | 300k | 2 | ~40 tok/s | full |
| throughput (no spec decode) | 64k | 4 | batched | full |
| pruned checkpoint | 300k | 4 | ~90 tok/s | degraded |

No row is "the optimized config". **Ship a profile per workload shape** and
document what each gives up — the same conclusion the speculative-decoding
crossover reaches, arrived at from the memory side. When a requirement cannot be
met, say which constraint has to move (fewer concurrent users, shorter context,
a smaller checkpoint, or more nodes) rather than tuning toward an impossibility.

## Sharding KV across nodes buys capacity, not speed

Decode context parallelism splits each sequence's KV across ranks, roughly
multiplying the pool by the CP degree — measured **360k → 664k tokens** on two
nodes, which moved 300k context from batch-1 to batch-2. The cost is a collective
in the decode path: cheap within a node over NVLink, expensive across nodes on
every attention step. Measured cross-node with spec decode off: **~40 tok/s per
stream vs ~100** for the latency profile.

Use it to fit concurrent long-context sessions, not to make one session faster.

## Sparse attention changes the long-context curve

Architectures with sparse or selected attention attend to a subset of the KV, so
decode cost stays roughly flat as context grows — measured **~100 tok/s at both a
short prompt and a real 297k-token prompt**. With dense attention, expect decode
to degrade as occupancy rises.

Know which you have before promising "usable at N tokens": *fitting* the context
and *sustaining throughput at it* are different claims, and users feel the second
one. Always verify with a genuinely long request, not a short one against a large
`max-model-len`.

## Pruned checkpoints: measure the shape of the loss, not just the score

Expert-pruned variants trade accuracy for exactly the headroom above. One pruned
MoE scored **68% vs 89%** for its full counterpart on a reasoning benchmark — but
the interesting part was the failure shape: **15% of answers hit the token cap
without concluding** (~39k mean tokens/question), and 44% of its wrong answers
were non-answers rather than incorrect answers. On completed questions it scored
~80%.

That is a **termination/coherence** failure, not uniform knowledge loss, and it
predicts agentic timeouts and runaway serving cost that a single accuracy number
does not. When evaluating a compressed checkpoint, record truncation rate and
mean tokens per answer alongside the score.
