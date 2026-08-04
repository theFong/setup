# Portable Cluster Diagnostics

Failure patterns that recur across GPU clusters regardless of vendor, site, or
model. Each one cost real time somewhere. They belong here, not in a per-cluster
skill — a cluster skill records *this cluster's* facts; this file records *how
clusters break*.

Cite the pattern from the cluster skill rather than copying it, so a fix in one
place reaches every fleet.

---

## 1. Overlay networks

### 1.1 Two overlays in the same CGNAT range silently fight

**Symptom:** some services on a node are reachable over the mesh and others are
not, while the mesh's own status command reports every peer `Connected`.

WireGuard-based overlays (Tailscale, NetBird, Nebula, plain `wg`) commonly
allocate from CGNAT `100.64.0.0/10`. Install two and the second one's firewall
rules will match the first one's traffic. The observed case: Tailscale's
`ts-input` chain drops any packet sourced from `100.64.0.0/10` that did not
arrive on `tailscale0`, which matches **all** traffic from a NetBird `100.x`
peer arriving on `wt0`. Tailscale inserts its jump at the top of `INPUT`, ahead
of the other overlay's own accept rule, so that rule never runs.

**The diagnostic fingerprint is host-network vs. container-published:**

| path | traverses | result |
|---|---|---|
| container **published** port | DNAT → FORWARD | **works** |
| host-network container, or any host process | INPUT → the hostile chain | **dropped** |

If `dcgm-exporter` on a published port is up but a `--net=host` reverse proxy,
the node exporter, and `sshd` are all unreachable *on the same node*, stop
looking at the services. Confirm with `iptables -L ts-input -n -v` (climbing
DROP counters) and `tcpdump -ni <overlay-if>` (inbound SYNs, no SYN-ACK).

**Why status lies:** handshakes and the management/signal channels are
untouched, so peer counts and `P2P` stay green. Only delivery to host sockets
dies. Control-plane health is not data-plane health.

**Fix:** stop and disable the overlay you are not using. Then hunt for units
that resurrect it — a `Wants=`/`Restart=on-failure` unit for a companion service
(e.g. a funnel/expose unit) will drag the daemon back up every few seconds. Two
things to check after: that the chain is gone (`No chain/target/match by that
name`) and that nothing re-enables it at boot.

**Prevention:** pick one overlay per fleet. Record in the cluster skill which
prefix belongs to which overlay, because an address starting `100.` is ambiguous
on sight.

### 1.2 A resurrect-unit can also be an exposure

Audit what a respawning unit actually *does* before re-enabling it. One found in
the wild published a model server's port straight to the internet, bypassing the
reverse proxy's allowlist entirely. It had never done harm only because the
daemon it depended on was logged out.

### 1.3 Overlay RTT is not fabric RTT

Overlay latency reflects the worst link in the path, including Wi-Fi. A
same-site pair measured **24 ms average, 97 ms max, 37 ms mdev** over the
overlay while sitting a metre apart, purely from wireless jitter. Fine for API
calls and 15-second scrapes. **Never put NCCL or any collective on the overlay.**

### 1.4 When the vendor SSH path breaks, jump via a LAN peer

**A control plane reporting `Connected` means registered, not reachable.** Treat
the two as independent facts. Cheap remedies first, in order:

1. **Re-sync the generated SSH config** — gateway ports rotate, so a host that
   worked yesterday resolves to a dead port today (`brev refresh`, or your
   provider's equivalent).
2. **Re-register the node's overlay agent** — `systemctl restart netbird` on the
   node clears a stale gateway mapping.
3. If both fail, the gateway path itself is broken. Jump via a LAN peer, below.

If `ssh <node>` dies with `kex_exchange_identification: Connection closed by
remote host` but the control plane still reports the node connected, the gateway
path is broken, not the node. Reach it over the LAN through a peer that still
answers:

```bash
ssh -i <key-authorized-on-the-node> -o IdentitiesOnly=yes \
    -o ProxyJump=<healthy-peer> <node-user>@<node-lan-ip> 'docker ps'
```

Three things that bite:

- **Pass the key that is actually authorized on the target.** The jump host's
  own default key usually is not in the target's `authorized_keys`.
- **Use the LAN IP and the node's own SSH user**, not the alias — the alias
  resolves back through the broken gateway.
- **This only works within one LAN.** Separate sites have no route between them;
  go over the overlay, or use the target's site-mate as the jump host.

### 1.5 Dual-homed nodes answer on two addresses

A node with wired and Wi-Fi NICs on the same subnet holds two leases and answers
on both; route metric decides only the *outbound* default. Pinning a service to
the wireless address works, then degrades under load. Prefer overlay IPs in
config files, and record every address plane in the cluster skill.

---

## 2. Containers that do not survive a reboot

### 2.1 Only `always` and `unless-stopped` are replayed

The daemon replays exactly those two policies on start. `on-failure` and `no`
are **not** replayed, so they never survive a boot no matter how healthy the
container looks now. Change a policy with `docker update --restart` — it does
not restart the container, so it is safe on a production service.

### 2.2 A hand-stopped container stays down through the next boot

Stopping a container by hand records a "manually stopped" flag, and the daemon
then skips its restart policy at boot even though the policy still reads
`unless-stopped`. The flag clears on the next `docker start`. **After any
maintenance that stops a container — driver upgrades, GPU unbinds — start it
once by hand or it stays down through the next reboot.**

### 2.3 Compose files that set no restart policy

Many recipes set none. Every fresh `up` then produces a container with policy
`no`. Run `docker update --restart unless-stopped <name>` on **every** node in a
multi-node deployment afterwards, including headless workers.

### 2.4 A stale CDI spec blocks every container at boot

Symptom: a container with a correct `unless-stopped` policy never returns after
a reboot, and the daemon log shows

```
failed to inject CDI devices: failed to stat CDI host device
  "/dev/nvidia-modeset": no such file or directory
```

The daemon **did** honour the policy — it tried once and gave up. Two things
compound it:

- **`"default-runtime": "nvidia"` in `/etc/docker/daemon.json` applies CDI
  injection to *every* container**, not just GPU ones. A node with that setting
  loses its entire container set; a node without it loses only GPU containers.
  This alone explains why one box in a pair survives reboots and its twin does
  not — check both, they drift.
- **The device nodes may never be recreated at boot.** A `modeset=0` modprobe
  override, or a `modprobe -r nvidia_drm nvidia_modeset` left over from
  passthrough experiments, removes `/dev/dri` permanently while the CDI spec
  generated months earlier still declares `card0` and `renderD128`.

Fix: regenerate the spec (`nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`,
back up the old one first), and add a oneshot unit that creates the device nodes
`Before=docker.service` plus a `docker.service.d` drop-in to wait on it.

**Verify the fix by rebooting.** A node with 45 days of uptime has never
exercised its reboot path; policies set and a read-only validator run are not
evidence.

### 2.5 Never bind-mount a container entrypoint from `/tmp`

`/usr/lib/tmpfiles.d/tmp.conf` carries `D /tmp 1777 root root 30d`, which empties
`/tmp` on every boot **and** sweeps 30-day-idle files — so the mount source
vanishes even without a reboot. When it is missing at container start the daemon
recreates the path as an empty **directory**, the container execs a directory,
and it crash-loops permanently.

Keep such files under `/opt` or the service's own directory. If something must
live in `/tmp`, add an `/etc/tmpfiles.d/<svc>.conf` that recopies it (`C`) and
exempts it from the age sweep (`x`); ordering is guaranteed because
`systemd-tmpfiles-setup.service` is `Before=sysinit.target` and `docker.service`
is `After=sysinit.target`.

### 2.6 App-before-database at boot is usually fine

Both start concurrently with no ordering guarantee. In practice the database is
ready in seconds, the app takes longer to start, and if it does lose the race it
exits and the daemon retries with backoff. Expect the service live within a
minute or two of boot. Do not add ordering machinery for this.

---

## 3. RDMA fabric and interconnects

### 3.1 Count cables as ACTIVE devices ÷ PCIe views

A multihost NIC exposes each physical port once per PCIe view, so one cable
lights the same port suffix in every view. Four ACTIVE devices across two views
is **two** cables; two ACTIVE is **one**.

**The lane-encoding string is not a cable signal.** `2X NDR` and `4X HDR` are
both 200 Gb/s. A DOWN port also reports a stale, meaningless rate (commonly
`40 Gb/sec (4X QDR)`) — read `phys_state`, not `rate`, to tell a dead port from a
live one.

### 3.2 GIDs must derive from configured addresses

RoCE v2 connection setup fails against EUI-64 default GIDs. An ACTIVE,
link-up port with **no IP** is spare capacity that NCCL cannot use. Give it an
address and a RoCE v2 GID appears, derived from that address.

GID **indexes differ per node** and drift across reboots. Never pin one literal
index for both ranks; use the stack's auto-resolution.

### 3.3 NetworkManager flushes manually added IPs — always create a profile

`ip addr add` does not survive NM. Create a profile with `autoconnect yes`:

```bash
nmcli con add type ethernet ifname <netdev> con-name <rail> \
  ipv4.method manual ipv4.addresses <addr>/24 \
  ipv6.method link-local connection.autoconnect yes
```

Related trap: **there is no DHCP server on a back-to-back cable**, so NM leaves
such interfaces stuck in `connecting (getting IP configuration)` forever. That
is why a cabled, ACTIVE rail can have no IPv4 for months.

### 3.4 Prove a cable is really back-to-back before trusting it

Link-up on both ends does not prove the two ends are each other. Bring the
interfaces up, then:

```bash
ping6 -I <netdev> ff02::1
```

Count the replies. On a multihost NIC you should see the local PCIe views **and
both of the peer's**, at sub-millisecond latency — against tens of milliseconds
for the same peer over Wi-Fi. That difference is the proof.

### 3.5 MTU and NCCL channel defaults

- A rail left at **MTU 1500** yields a small RoCE path MTU and fragments every
  collective. Raising it to 9000 (persisted in the NM profile, verified with
  `ping -M do -s 8972`) is real hygiene, but **may not move latency**: measured
  on one pair it cut packets/step 62% and changed step time by 0.0 ms.
- **NCCL can pick an absurd channel count for a tiny ring** — observed defaulting
  to **64 channels for a 2-rank ring**, slicing each ~48 KB allreduce into ~750 B
  fragments. Capping `NCCL_MAX_NCHANNELS`/`NCCL_MIN_NCHANNELS` at 4 freed NCCL
  buffer memory (+19.9% KV pool) and lifted aggregate throughput ~10%, with no
  effect on single-stream.

Both of these are worth doing for the memory and aggregate wins. Neither is a
single-stream fix — see §5.1.

### 3.6 Driver/kernel skew across a pair is not automatically fatal

A pair running different driver and kernel builds still initialised a 2-rank
NCCL job cleanly, because NCCL shipped **inside the container** and was therefore
identical on both ranks. Levelling drivers first is prudent, not a hard blocker.
Check where the NCCL in play actually comes from before blaming skew.

---

## 4. Telemetry that lies

### 4.1 `nvidia-smi` power scope differs by platform — never price from it blindly

Some modules publish a module-level meter covering CPU + GPU + memory + VR loss;
others publish **die-only** watts. The probe script reports
`gpu_module_power`: a wattage means a real module meter, `N/A` means die-only.

On a die-only platform the reading excludes CPU cores, LPDDR, NVMe, NIC, fans
and PSU loss. One node class reported **~13.8 W idle / ~44 W load** against a
published **~35 W idle / ~160 W typical wall** — an understatement of roughly
**3.5x** under load. A pair of them reported 154.6 W against a published ~320 W.

**A flat overhead multiplier cannot fix this.** Solving `(die + C)/eff = wall`
against published anchors needs a different `C` at idle than at load, because the
die reading does not track CPU/memory power at all. Use a published
per-node figure, or better a PDU/Redfish reading, and mark the number as
estimated in the cluster skill.

Corollary: **low wattage is not evidence the GPU is idle.** On a
memory-bandwidth-bound workload the die can read 38 W while the part is
saturated, because the meter cannot see the memory traffic doing the work.

### 4.2 `utilization.gpu` counts a spinning sync kernel as busy

A blocked NCCL or barrier kernel reports 95%+ utilisation. It tells you nothing
about whether real work is happening. Use step time and workload-level counters.

### 4.3 Prefix caching makes live prefill rates meaningless

`vllm:prompt_tokens_total` counts cache hits. Where agent traffic resends large
contexts to the same node, the live prefill rate read **7397 tok/s** against a
measured cold prefill of **2023 tok/s** — 3.6x optimistic. Measure cold prefill
with unique random prompts, and never derive cost from the live counter.

### 4.4 Short windows break rate-derived pricing

A cost script that only falls back when a rate is `<= 0` will happily use a
*small but nonzero* rate from a quiet 30-minute window and produce a wildly
inflated figure — observed 4-5 orders of magnitude off. Always compute over
`7d` or longer, and diff before applying.

### 4.5 Scraping a loopback-bound service

Do not rebind the service. Run a **metrics-only reverse proxy** beside it, bound
to the overlay IP, that proxies `/metrics` and returns 403 for every other path.
Two gotchas:

- Make it a **separate container** from the production ingress proxy. Production
  proxies often run with the admin API off, so editing their config means a
  restart that blips the endpoint.
- In Caddy, an IP in the site address is a **Host-header matcher** and will 400
  every scrape. Use a bare `:PORT` site address with an explicit `bind <ip>`.

### 4.6 Exporter version skew across node classes

The same-named exporter on two node classes can carry different schemas,
different formulas, and different exported labels. Verify by checksum, not by
service name. Record which nodes run which version.

### 4.7 A throttle bitmask can mean "send a technician"

`clocks_throttle_reasons.active` of `0x88` = HW Power Brake + HW Slowdown: an
external power-delivery signal that **cannot** be cleared in software. It means
physical service — reseat GPU power cables, then the PSU. Put this on a
dashboard; it has cost days when missed.

---

## 5. Serving and routing

### 5.1 Decide whether you are bandwidth-bound before tuning

For speculative decoding, `tokens/s = acceptance_length / step_time`. Measure
both before touching config. On one 2-node deployment, step time was **62 ms and
invariant** — identical for code and prose prompts and unchanged by every
setting tried — and acceptance was hard-capped by the checkpoint's draft block
size. That fixes the ceiling at ~97 tok/s with a *perfect* drafter and ~70 in
practice. No configuration reaches 100.

Communication was ruled out **empirically**: two real fabric defects were found
and fixed, packets/step fell 62%, and step time moved 0.0 ms. Record such a
negative result in the cluster skill so nobody re-runs the investigation.

**Where the headroom usually is: concurrency, not single-stream.** The same
hardware went 70 → 401 tok/s from C1 to C16.

### 5.2 Do not pool independent engines behind a KV-blind router

Generic proxy routing strategies (`simple-shuffle`, `latency-based`,
`least-busy`, `usage-based`, `cost-based`) are all prefix-cache-blind, and each
engine holds a **private** prefix cache. Where agent traffic resends large
contexts, one deployment measured a **79.4%** hit rate; round-robin across two
independent deployments would roughly halve it, and cold prefill was 3.6x slower
than warm. **Running two identical standalone deployments beats pooling them**
until you have a KV-aware router. Write the reason down, or someone will "fix"
it by adding the second endpoint to the pool.

### 5.3 Ingress: one front door, deny by default

- Bind the proxy to **loopback only**. Binding `0.0.0.0` silently bypasses the
  port-level access policy.
- Split ports by policy: an API port with an exact-path allowlist returning 403
  for everything else, and a separate admin port behind SSO.
- **Never add an admin path to the API port's allowlist** when the master key
  doubles as an admin credential — that hands every API client the whole control
  plane.
- Treat the external URL as immutable; clients are pinned to it.

### 5.4 Restart the backend, not the proxy

A proxy tolerates a dead upstream: it errors for that model only and recovers
when the backend returns. Restart the model container directly. Batch proxy
config changes into one restart, and validate config before restarting.

### 5.5 Sampling defaults can masquerade as model quality bugs

A model that narrates instead of acting, or loops, is often running with no
nucleus truncation because the serving flag made the engine defaults win over
the checkpoint's `generation_config.json`, and callers send no sampling params.
Fix at the proxy layer (a `top_p` default) — that is a proxy restart, not a
multi-minute model reload. Verify it truly reaches the engine by setting an
*invalid* value temporarily and confirming the engine rejects it.

---

## 6. Access asymmetry breaks automation

Nodes drift into opposite access shapes: one has docker-group membership but
password-gated sudo, its twin has passwordless sudo but needs `sudo docker`.
Scripts that assume one shape fail on half the fleet. Record the shape per node,
in a table, and have the probe re-derive it (`sudo_nopasswd`,
`docker_needs_sudo`).

**`sudo` must precede `env`.** `sudo env FOO=bar docker ...` works;
`env FOO=bar sudo docker ...` lets sudo's `env_reset` silently drop every
variable — which for a distributed job means the NCCL and cache settings vanish
with no error.

---

## 7. Measurements that are artifacts

- **Ignore the first boot's KV-cache figure on a cold node.** JIT compilation
  consumes memory during profiling and can understate the pool by ~2x: 635,176
  tokens on the first boot, 1,349,440 on the second at identical settings.
  Re-measure before believing a low pool or lowering memory utilisation.
- **A context-length ceiling is not an allocation.** Raising `max_model_len`
  200k → 600k cost no measurable memory; the KV *pool* is the real constraint and
  it trades against concurrency.
- **State which prompt produced a benchmark number.** Code-generation prompts
  accepted 4.5 draft tokens (~70 tok/s) and prose 3.2 (~51 tok/s) on the same
  engine. An unlabelled figure is not reproducible.
- **Watch for benchmark-inflating options.** Some rejection-sampling modes
  force-accept draft tokens on a decay curve: the throughput number goes up
  without sampling from the true model distribution. Not a speedup.

---

## 8. Verification discipline

- **Never document intent.** Make the change, verify it live, then write it
  down. A confidently wrong table sends the next agent to the wrong IP.
- **Weights loading is not proof of correctness.** One deployment loaded and
  served fine while silently running every request at the wrong reasoning
  effort, because the runtime image predated the checkpoint. Verify behaviour
  inside the container, not just that the process is up.
- **Re-verify before quoting.** Model placement, ports, and addresses change.
  If you are reasoning from memory about which node runs what, stop and check.
- **Record negative results.** "We investigated X and it was not the cause" is
  as valuable as a fix, and it is the only thing that stops the investigation
  being repeated.
