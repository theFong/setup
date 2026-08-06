# Methodology and Meta-Lessons

Distilled from a multi-day inference optimization that reached the right answer
by an unnecessarily expensive route. Each item cost real time.

## 1. Validate hardware before optimizing

Covered in [hardware-validation.md](hardware-validation.md). It is first here
too because it dominates every other lesson: roughly ten server restarts and a
full profiling exercise were spent characterizing a GPU that was throttled.
Every conclusion drawn from it had to be retracted.

**Invariance is the tell.** When a number does not move for batch size, context
length, kernel backend, graph mode, or any flag you change, the cause is almost
never the software you are editing.

## 2. Profile before hypothesizing

Four hypotheses were tested by full server restarts before anyone profiled:

| Hypothesis | Result |
|---|---|
| Missing reasoning config | No effect |
| Compile pipeline disabled by a flag | Real fix, **zero** throughput change |
| MoE kernel bad at batch 1 (`marlin`) | **20% worse** |
| Sinkhorn/clustering kernels dominant | Actually 8.7% of time |

One profile then produced the actual distribution in a single run. **Profile
first.** A restart-and-guess loop costs ~1 h per hypothesis; a profile costs one.

What to extract:

- kernel launches per step
- median kernel duration
- top-10 share of total GPU time

If no kernel exceeds ~15%, **there is no single fix** — stop looking for one.

## 3. Matching magnitude is not evidence of mechanism

An arithmetic estimate ("if the kernel reads all 256 experts, that is ~138 GB,
which at achievable bandwidth is ~35–38 ms") matched the measured 38 ms/step
almost exactly. It was still wrong — swapping to a completely different MoE
kernel moved the number by only 20%.

Order-of-magnitude agreement is weak evidence. Say so when presenting it, and
design a test that *discriminates* rather than one that merely confirms.

## 4. Read the sources before inferring

Two errors from reading filenames instead of code:

- A vendor overlay was assumed to be hand-written performance kernels. Its own
  `PATCHES.md` stated the changes were multi-sequence **correctness** fixes and
  that single-stream was *byte-identical* to upstream.
- An effort estimate of "days, not months" was given for porting a kernel. The
  arch gate `@supported_compute_capability([120, 121])` and an `sm120` filename
  were both visible and unread. The true answer was a rewrite.

**Never quote an effort estimate before reading the code you propose to port.**

## 5. Benchmark hygiene

Each of these produced a materially wrong number at least once:

- **Cold-shape JIT.** First touch of every batch/sequence shape pays
  compilation. Measured 175 s TTFT cold vs 3.3 s warm on the identical case, and
  prefill that appeared to get *faster* with more concurrency (a physical
  impossibility that revealed the artifact). Always warm, then re-run.
- **Leftover in-flight requests.** A prior run still generating produced a 182 s
  TTFT on a trivial prompt. Poll running/waiting counters to zero before timing.
- **Prefill-contaminated aggregates.** A metric dividing total output tokens by
  wall-clock-including-prefill reported 47–140 tok/s while the engine's own
  counters showed 180–205. If aggregate is *below* per-stream, the denominator
  is wrong.
- **Reasoning tokens.** Thinking modes silently consume decode budget. Disable
  for raw throughput numbers.
- **Piping through `tail`/`head`.** Buffers everything until exit; no interim
  progress from long runs. Write to a file instead.
- **Comparing across harnesses.** Vendor the exact benchmark script used by any
  published number you are comparing against.

## 6. Change one thing per restart

Config changes invalidate autotune and JIT caches, turning a 10-minute boot into
an hour. Group *unrelated* changes into one restart; never confound two
hypotheses you actually care about telling apart.

Persist caches between runs where possible — check for cleanup flags that delete
compiled kernels on shutdown.

## 7. Verify a knob took effect

Setting a value is not applying it. Two silent failures:

- JSON passed through a compose env file had its quotes stripped and was
  rejected (`validation error`) — construct structured values inside the
  container instead.
- An env var name that did not exist in the installed version logged
  `Unknown environment variable` and was ignored. Grep the version's own env
  registry rather than trusting documentation for another release.

Always confirm from the server's startup config dump, not from your input file.

## 8. Check what the stack actually supports

Backend lists are advertised globally but gated per quantization scheme. A
backend can appear in the global registry and still be rejected:

```
moe_backend='X' is not supported for MXFP4 MoE.
Expected one of [...]
```

Enumerate the *supported-for-your-format* set before planning around a backend.

## 9. Report honestly

- State confidence proportional to evidence. "This is the answer" after one
  correlation invites the retraction that follows.
- When a measurement contradicts an earlier claim, retract it plainly, once, and
  continue. Do not bury it or restate it repeatedly.
- Distinguish what was **measured** from what was **inferred**. Measurements
  survive a retracted theory and remain useful; inferences do not.
- Flag confounds as they appear, not after they invalidate a conclusion.

## 10. Deliver the operational wins separately

Even with the headline question unresolved, this exercise produced durable
results worth shipping on their own: a concurrency-dependent speculative-decoding
profile, a silent data-loss bug in non-streaming reasoning, and a validated
deployment recipe. **Ship those independently** rather than holding them behind
the open question.
