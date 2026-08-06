# Multi-Node Serving

Everything a single-GPU playbook does not tell you, plus the failure modes that
only appear once a model is sharded across machines.

## The slowest rank sets the pace

In tensor parallelism every decode step ends in a collective, so the job runs at
the speed of its **worst** rank. One degraded GPU is not a proportional loss.

Measured: a two-node server whose second GPU was power-braked to ~15% of normal
compute ran at **~9 tok/s**. With that one cable reseated, the identical software
ran at **~90**. The healthy node had been sitting in collectives the whole time,
reporting high utilization while doing nothing.

**Validate every node standalone before launching the distributed job.** This
takes 30 seconds per node and is the cheapest test available:

```bash
docker run --rm --gpus all --entrypoint python3 "$IMAGE" -c '
import torch, time
x = torch.randn(8192, 8192, device="cuda", dtype=torch.bfloat16)
for _ in range(10): torch.mm(x, x)
torch.cuda.synchronize(); t = time.time()
for _ in range(50): torch.mm(x, x)
torch.cuda.synchronize()
print(round(2*8192**3/((time.time()-t)/50)/1e12, 1), "TFLOPS")'
```

Run it everywhere and compare. Healthy peers agree within a few percent; the pair
above read **1861 vs 271 TFLOPS**. Any distributed metric collected before this
check is uninterpretable — an aggregate number cannot tell you which rank is sick.

## Exonerate the fabric explicitly, and early

"It must be the network" is the most attractive wrong answer in distributed
serving. Measure the link directly instead of inferring it from application
symptoms:

```bash
ib_write_lat -d "$HCA" -x "$GID"   # latency
ib_write_bw  -d "$HCA" -x "$GID"   # bandwidth
```

Against a known-good reference pair the numbers were **3.12 µs / 215 Gb/s** vs
**1.52 µs / 225 Gb/s** — close enough to exonerate the link and retire an entire
line of investigation in ten minutes.

Next cheapest discriminator: a bare collective soak (allgather/allreduce of the
exact shape the engine hangs on, same image and env, outside the engine). If the
collective is clean standalone, the fabric is not your problem — the engine's use
of it is. That test cleared 20k allgathers while the server it mimicked was
deadlocking.

Note also that a network-bound rank *idles*. High utilization with low power
across all ranks is a hardware or kernel symptom, not a fabric one.

## Setting an environment variable is not loading a library

The loader mechanism is framework-specific, and the failure is silent.

- vLLM loads NCCL from **`VLLM_NCCL_SO_PATH`**. Swapping the same library in via
  `LD_PRELOAD` is ignored — the process keeps the bundled version and you measure
  no change. This cost a full test cycle and produced a false negative on a
  hypothesis that was actually correct.
- **Verify from inside the running process**, not from your launch script:
  ```bash
  python3 -c "import torch; print(torch.cuda.nccl.version())"
  ```
- Path-construction trap: `pkg.__file__` is `None` for a **namespace package**,
  so a `__file__`-derived path evaluates to empty, the variable is "set" to
  nothing, and the loader silently falls back. Use `list(pkg.__path__)[0]`.
- Fail loudly in the launcher rather than running slow:
  ```bash
  [ -f "$VLLM_NCCL_SO_PATH" ] || { echo "FATAL: NCCL .so not found"; exit 1; }
  ```

Generalization: for any performance-critical shared library (NCCL, RCCL, a
collective plugin, a MOFED userspace lib), confirm the **loaded** version from
the process. The gap between "I set the variable" and "the process loaded it" is
where days go.

## Role asymmetry between ranks

Launchers expect one head and N−1 followers. A follower running the head's exact
command starts its own API server and dies with an error that does not name the
cause (`collective_rpc should not be called on follower node`). Look for a
`--headless`-style flag before concluding the cluster is broken.

## Interconnect config does not persist by itself

Manually assigned IPs on the high-speed link do **not** survive reboot, and a
network manager will actively flush them from managed interfaces. Create real
profiles:

```bash
nmcli con add type ethernet ifname "$IFACE" con-name roce \
  ipv4.method manual ipv4.addresses 10.10.1.1/24
nmcli con up roce
```

Recognize the symptom: the cluster worked yesterday, and after a reboot the ranks
cannot rendezvous. Check that the addresses still exist before suspecting
cabling — the link was never unplugged.

Pin the transport explicitly so bootstrap does not wander onto a container
bridge: `NCCL_IB_HCA`, `NCCL_IB_GID_INDEX` (RoCE v2 needs an explicit index),
`NCCL_SOCKET_IFNAME` / `GLOO_SOCKET_IFNAME`.

## Startup cost is an experiment tax — budget it

A large multi-node start is weight load + rendezvous + compile + KV profiling +
graph capture. Measured for a ~430 GB checkpoint across two nodes, warm caches:

| Phase | Time |
|---|---|
| container start, library install, rendezvous | ~75 s |
| **weight load (disk-bound)** | **~3.8 min** |
| `torch.compile` | ~88 s |
| KV cache profiling | ~35 s |
| cudagraph capture | ~6 s |
| **total to serving** | **~7.5 min** |

With a **cold** compile/autotune cache the same stack took up to **~40 min** at
long context. Mount a persistent cache directory on every node — the JIT cache is
the swing factor, and weight load off NVMe is the floor you cannot optimize away.

Note that KV profiling and graph capture scale with `max-model-len`, so
long-context configs cost more per experiment. At ~8 minutes a restart, a
six-config sweep is an hour of pure waiting: this is why "change one thing per
restart" matters far more here than on a single GPU.
