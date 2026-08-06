# Hardware Validation

Everything here exists because a faulty GPU consumed roughly a day of
optimization work that could not possibly have succeeded.

## Case study: 7x from hardware alone

Two DGX Stations, both **NVIDIA GB300, 256703 MiB, compute capability 10.3**,
same driver, same container image, same model, byte-identical config.

| | Prototype unit | Production unit |
|---|---|---|
| Single-stream decode | 45.4 tok/s | **317.7 tok/s** |
| ms per decode step | 38–87 ms | **3.4–4.3 ms** |
| Power draw under load | **190–240 W** | **600 W** |
| GPU utilization | 80–100% | 99% |
| SM clock | 2070 MHz (= max) | 2070 MHz (= max) |
| `HW Slowdown` | **Active** | Not Active |
| Module power limit | **950 W** (default 1600) | 1600 W (= default) |

Both machines reported **maximum clocks** and **high utilization**. The only
honest signals were `HW Slowdown: Active`, the reduced power ceiling, and above
all the **power draw under sustained load**.

### The reasoning error to avoid

The throttle flag and the reduced cap were both observed early and dismissed
with this argument:

> "Clocks are at max and we are drawing 240 W of a 950 W budget, so power is not
> the limiter — the GPU is being starved of work, not held back."

That is backwards. **Drawing a fraction of the budget at 99% utilization is the
signature of a throttled GPU**, not of a latency-bound workload. The low power
draw was repeatedly cited as evidence *for* a software theory when it was
evidence *against* the hardware.

Rule: an asserted `HW Slowdown` is a blocker, not a footnote. Stop and get a
second machine.

## When it really is hardware: exhaust remote levers, then discriminate

Once a power brake is confirmed, the useful question is **environment or box** —
because the answers are "call the facility" and "open the chassis" respectively.

Remote levers, in increasing order of disruption. None of these cleared a
genuine power-delivery fault, and knowing that saves a day of hoping:

```bash
nvidia-smi -r -i "$GPU"                  # GPU reset
reboot                                   # warm reboot
ipmitool -H "$BMC" -U "$U" -P "$P" -I lanplus chassis power off   # BMC off,
ipmitool ... chassis power on                                    #   drain, on
ipmitool ... mc reset cold               # BMC cold reset
# full AC cord pull + hold power button ~30 s (drains standby rails)
```

A brake that survives an AC drain is physical. `0x80` (HW Power Brake) is an
**external signal into the GPU**, not a software state — it cannot be cleared by
anything you type.

**Then design the discriminating test.** The candidates were "this circuit cannot
deliver enough power" and "this machine cannot". Two experiments settled it:

1. Power the healthy machine fully off so the suspect one had the circuit to
   itself — still braked. Rules out contention.
2. **Swap the two machines' outlets.** The healthy box ran at full speed on the
   suspect outlet; the suspect box stayed braked on the proven-good outlet.

The fault followed the **box**, not the outlet. That is a one-hour test that
converts "maybe it's the power in this room" into a hardware ticket with
evidence. The actual defect was a partially seated GPU power cable inside the
chassis; reseating it restored full performance.

Order of physical remediation: reseat GPU power connectors, then check the PSU,
then RMA. Note that moving the machine to a different outlet is *not* a fix — if
the fault follows the box, it will follow it there too.

## Checks, in order

```bash
GPU=0

# Throttle reasons. Thermal is common and benign-ish; a power brake with no
# thermal cause means power delivery, a bad cable, or a failing part.
nvidia-smi -i "$GPU" -q -d PERFORMANCE | grep -A8 'Clocks Event Reasons'

# Power ceilings. "Current" below "Default" means something capped it.
# Check BOTH the GPU limit and the module/board limit -- they differ.
nvidia-smi -i "$GPU" -q -d POWER | grep -E 'Power Limit|Power Draw'

# Clocks: compare live SM clock against Max Clocks.
nvidia-smi -i "$GPU" -q -d CLOCK | grep -A3 -E 'Max Clocks|Clocks$'

# Sustained-load sample -- the decisive one.
nvidia-smi --query-gpu=utilization.gpu,power.draw,clocks.sm,temperature.gpu \
           --format=csv -l 1 -i "$GPU"
```

Sanity target: a large-model decode workload on a datacenter GPU should pull a
substantial fraction of TDP. Idle-ish power at high utilization is wrong.

## Interpreting the counters

- **`utilization.gpu` is time-based.** It counts any interval where a kernel was
  resident, regardless of how few lanes were active. It reads 99% on a starved
  or throttled GPU. Never use it alone as evidence of saturation.
- **`utilization.memory` may be unreliable** on unified-memory parts
  (Grace-Blackwell). It read a constant 0% across every configuration tested,
  including ones that were demonstrably moving weights. Do not build an argument
  on it.
- **`power.draw` is the trustworthy signal** for whether real work is happening.
- **Max clocks do not imply health.** Both machines sat at 2070 MHz while
  differing 7x in throughput.

## Multi-node jobs

The checks above are per-GPU, and a distributed server hides which rank is sick:
tensor parallelism runs at the speed of its worst rank, so one degraded GPU looks
like a uniformly slow cluster. Run a standalone compute benchmark on **every**
node before launching or profiling the distributed job — see
[multi-node.md](multi-node.md).

## Multi-GPU hosts

- Enumerate before assuming: a "single GPU" station may carry an extra
  workstation card. Seen: `index 0 = RTX PRO 6000 (96 GiB, cc 12.0)`,
  `index 1 = GB300 (251 GiB, cc 10.3)`.
- **Pin by UUID, not index.** Indices reorder across reboots and driver reloads.
  `nvidia-smi --query-gpu=index,name,uuid,compute_cap --format=csv`
- Check the interconnect with `nvidia-smi topo -m`. Cards connected only via
  `SYS` (PCIe) must not share a tensor-parallel group; mixed architectures make
  it worse.

## Compute capability is not cosmetic

Kernel availability is gated on it. Datacenter and consumer parts of the same
generation are different targets:

- `sm_100` / `sm_103` — datacenter Blackwell (tcgen05 / UMMA, tensor memory)
- `sm_120` / `sm_121` — consumer Blackwell and GB10

Kernels written for one will not run on the other. Before planning a port,
grep for the gate:

```bash
grep -rn "supported_compute_capability\|get_smem_capacity_in_bytes\|sm_1[0-2][0-9]" <kernel_dir>
```

A decorator such as `@supported_compute_capability([120, 121])`, hardcoded
`get_smem_capacity_in_bytes("sm_120")`, and `sm120_*` layout helpers together
mean a *rewrite* against a different tensor-core model — weeks to months — not a
retarget. Check this **before** quoting an effort estimate.
