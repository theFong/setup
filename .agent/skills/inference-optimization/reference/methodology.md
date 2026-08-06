# Methodology and Meta-Lessons

Distilled from a multi-day inference optimization that reached the right answer
by an unnecessarily expensive route. Each item cost real time.

## 1. Validate hardware before optimizing

Covered in [hardware-validation.md](hardware-validation.md). It is first here
too because it dominates every other lesson: roughly ten server restarts and a
full profiling exercise were spent characterizing a GPU that was throttled.
Every conclusion drawn from it had to be retracted.

**A hardware fault invalidates conclusions drawn before you found it.** When
you discover a throttled or faulty part, do not only re-run the experiment you
were on — go back and re-validate every tuning result measured on that machine.
In the run this skill came from, a speculative-decoding "crossover" had already
been written up as a headline finding and shipped; on healthy hardware it
reversed completely. Keep a list of what was measured where, so the blast radius
is knowable.

**Invariance is the tell.** When a number does not move for batch size, context
length, kernel backend, graph mode, or any flag you change, the cause is almost
never the software you are editing.

In a distributed job, validate **every node**, not the cluster. A tensor-parallel
server runs at the speed of its worst rank, so one degraded GPU presents as a
uniformly slow cluster: measured, a single power-braked GPU held a two-node
server at ~9 tok/s that reached ~90 once it was fixed. See
[multi-node.md](multi-node.md).

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

### Write the governing identity down, then bound each term

Before tuning, state throughput as an equation and measure whether each term can
actually move. For speculative decoding it is exactly:

```
tokens/s  =  acceptance_length / step_time
```

On one measured deployment both terms turned out to be pinned:

- **`step_time` was invariant** — identical for code and prose prompts, and
  unchanged by every configuration tried. It moved only with batch size and
  context length, meaning ~85% of a single-stream step was fixed weight
  streaming, not token work.
- **`acceptance_length` was capped by the checkpoint**, whose draft block size
  set a hard maximum of k+1. Real workloads landed well under it, and the drafter
  produced the whole block in one parallel pass, so there was no per-draft-token
  latency to reclaim either.

Dividing the cap by the floor gives the ceiling **with a hypothetical perfect
drafter** — which came out only ~40% above what was already being achieved, and
below the target that had been requested.

This converts "make it faster" into a closed question, and it is the cheapest
possible experiment: two measurements and a division, versus a restart-and-guess
loop at ~1 h per hypothesis. When the ceiling lands below the goal, **say so and
redirect** — the honest deliverable is "this is a hardware property, here is the
axis that is not saturated" (see §12), not another week of knobs.

## 3. Matching magnitude is not evidence of mechanism

An arithmetic estimate ("if the kernel reads all 256 experts, that is ~138 GB,
which at achievable bandwidth is ~35–38 ms") matched the measured 38 ms/step
almost exactly. It was still wrong — swapping to a completely different MoE
kernel moved the number by only 20%.

Order-of-magnitude agreement is weak evidence. Say so when presenting it, and
design a test that *discriminates* rather than one that merely confirms.

## 4. Read the sources, not the labels

### The running artifact is a variable — verify it first

The most expensive single lesson here. Days were spent explaining a performance
gap between two clusters as a driver difference, a userspace-library mismatch,
and a kernel bug — while the actual delta was that **the reference machine was
running a different container image than everyone believed**.

What made it invisible:

- **Baked-in version strings lie.** Environment variables in the image announced
  a nightly build tag; `docker inspect --format '{{.Config.Image}}'` reported a
  stable release. The env vars were stale metadata from the build, not truth.
- **Published configs are not running configs.** The launch command shared
  publicly differed from the one on disk in the container, in both directions
  over time (documented graph mode, actually eager; later the reverse).
- The reference system had been **updated mid-investigation**, invalidating
  comparisons made a day earlier.

When reproducing someone else's number, treat the artifact as the first thing to
compare, not the last:

```bash
docker inspect "$C" --format '{{.Config.Image}}{{"\n"}}{{.Config.Cmd}}'
docker inspect "$C" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
docker exec "$C" python3 -c "import vllm; print(vllm.__version__)"
```

Read the **mounted launch script**, not the documentation. And confirm the
library versions the process actually loaded (see [multi-node.md](multi-node.md)).

### Newer is not better; the right build is the one with your kernels

For a new accelerator, build selection is a correctness question before it is a
performance one. On one generation: the current stable release lacked the
architecture's kernels entirely and would not start; two nightlies deadlocked
mid-decode; a *later stable release* was the fix and ran ~10x faster than the
nightlies that did start. Pin what you validated and re-verify on every bump.

### Two errors from reading filenames instead of code

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
- **Prefix caching.** Re-running a long-context benchmark with the same or a
  similar prompt measures the cache, not prefill. A 337k-token request appeared
  to prefill in 2.4 s on a near-identical payload. Vary the prompt per run, or
  disable prefix caching when prefill is the number you are reporting.
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

## 10. Assume more than one cause

A large gap is often a product of independent factors, and fixing one leaves a
still-large gap that invites you to discard a correct fix.

Measured: a ~100x shortfall was **two** unrelated problems — a software/config
delta worth ~9x, and a hardware fault on one node worth ~7x. Correcting the
software took the server from ~1 to ~9 tok/s, still ~10x short, which looked like
evidence that the config theory was wrong. It was not; the remaining factor was a
loose power cable.

- After a fix lands, **re-measure and re-decompose** rather than judging it
  against the original target.
- A partial improvement that does not reach the goal is not a refuted hypothesis.
- Conversely, do not stop at the first cause that produces a real gain.

## 11. Reproducing someone else's number

- **Ask what the number measures.** A headline "up to N tok/s" was a short-output,
  warm-cache peak; sustained throughput on the same hardware and software was
  ~30% lower. Both are true; only one is a service level. Reproduce the
  *methodology* (output length, temperature, concurrency, warm state) before
  concluding anything about the gap.
- **Get access to the reference system if it exists.** One direct comparison of
  the running artifact was worth more than days of local hypothesis testing —
  and see §4 for why the artifact, not the documentation, is the thing to compare.
- **Compare static facts first** (hardware, topology, fabric, driver, image,
  launch command), then dynamic ones. Cheap, and it retires whole branches.
- **A claim can be real and still not reproducible for you.** Ending with
  "confirmed, and here is what it takes" is a complete result; so is "confirmed
  for their configuration, blocked on ours by X".

## 12. Deliver the operational wins separately

Even with the headline question unresolved, this exercise produced durable
results worth shipping on their own: a concurrency-dependent speculative-decoding
profile, a silent data-loss bug in non-streaming reasoning, and a validated
deployment recipe. **Ship those independently** rather than holding them behind
the open question.
