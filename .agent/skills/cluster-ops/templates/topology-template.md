# {{CLUSTER_TITLE}} Topology (detail)

Verified {{YYYY-MM-DD}}.

Everything here is loaded on demand, so it can be long. What it must not be is
*unverified* — a detail table is exactly what gets trusted without checking.

## {{OVERLAY}} overlay

{{WHICH_NODES_RUN_IT, interface name, CIDR, how peer count was verified}}

| Node | {{OVERLAY_IF}} | site |
|---|---|---|
| `{{NODE}}` | `{{IP}}` | {{SITE}} |

{{WHAT_IS_REACHABLE_FROM_WHERE — state it as tested directions, not as a
policy claim. "head → node:22 OPEN, verified {{DATE}}" beats "the mesh is open".}}

<!-- DELETE IF ONLY ONE OVERLAY IS INSTALLED -->
### Second overlay: {{NAME}}

{{RANGE}}, on {{WHICH_NODES}}. **{{HOW_TO_TELL_THE_TWO_APART}}** — e.g. a
`{{PREFIX}}` address is {{OVERLAY_A}}, any other `100.x` is {{OVERLAY_B}}.

Two overlays allocating from CGNAT `100.64.0.0/10` can silently drop each
other's traffic: cluster-ops `reference/diagnostics.md` §1.1.

### Measured latency ({{DATE}}, from {{NODE}})

| Target | ICMP avg | note |
|---|---|---|
| {{TARGET}} | {{MS}} | {{WHY_IT_IS_WHAT_IT_IS}} |

Overlay RTT is not fabric RTT. Never put collectives on it (diagnostics §1.3).

## Physical LAN

{{HOW_MANY_SITES, subnets, gateways, DHCP or static}}

| Node | LAN | iface | route metric |
|---|---|---|---|
| `{{NODE}}` | `{{IP}}` | `{{IFACE}}` | {{METRIC}} |

{{DUAL_HOMED_NODES — list every node holding more than one address on a subnet,
and say which one services are pinned to.}}

{{BMC_ADDRESSES_IF_ANY}}

<!-- DELETE IF NO CLOUD NODES -->
### Cloud nodes are not on the LAN

{{WHICH}}, {{REGION}}, {{CIDR}}. They reach on-prem **only** over the overlay,
which is why {{e.g. central Prometheus scrapes by overlay IP, not LAN IP}}.

### Config that depends on physical placement

Upstreams that deliberately bypass the overlay and would break if a node moved:

| Consumer | Target | Plane |
|---|---|---|
| {{CONSUMER}} | `{{ADDR}}` | {{PLANE}} |

<!-- DELETE IF NO RDMA FABRIC -->
## {{FABRIC_NAME}} ({{NODE_A}} / {{NODE_B}})

- NIC: **{{MODEL}}**, {{PCIE_TOPOLOGY — note multihost/dual-view NICs}}
- Cables: **{{N}}** — derived as ACTIVE devices ÷ PCIe views (diagnostics §3.1)
- Cabled {{back-to-back | through switch {{NAME}}}}

| HCA | netdev | state | phys_state | rate | IP |
|---|---|---|---|---|---|
| `{{HCA}}` | `{{NETDEV}}` | {{STATE}} | {{PHYS}} | {{RATE}} | `{{IP}}` |

{{UNADDRESSED_PORTS — ACTIVE but no IP is spare capacity NCCL cannot use until
addressed (diagnostics §3.2).}}

{{MTU_STATE}}. {{HOW_ADDRESSES_PERSIST — NetworkManager profile name; manually
added IPs do not survive (diagnostics §3.3).}}

{{MEASURED_BANDWIDTH, and how — `ib_write_bw`, SSH throughput, cipher used.}}

## SSH access

{{HOW_HOSTS_RESOLVE — generated config, Include line, any flag that must NOT be
passed and why}}

{{WHAT_TO_DO_WHEN_A_HOST_STOPS_RESOLVING}}

## Port map

| Node | Port | Service |
|---|---|---|
| `{{NODE}}` | {{PORT}} | {{SERVICE}} — {{BIND_ADDRESS_AND_WHY}} |

<!-- Record the bind address, not just the port. "loopback only" and "bound to
     the overlay IP only" are deliberate policy; without the note someone
     rebinds to 0.0.0.0 to "fix" a scrape. -->

## Known gaps

<!-- The section operators read first. Be specific and dated. An honest gap list
     is worth more than a clean-looking skill. -->

- **{{GAP}}** ({{DATE}}): {{WHAT_IS_BROKEN_OR_UNMONITORED, and what it means —
  e.g. "nothing scrapes these nodes, so a failure there is invisible"}}
- **{{UNVERIFIED_CLAIM}}**: reported by {{WHO}} on {{DATE}}, **not verified**.
- **{{KNOWN_WRONG_NUMBER}}**: {{which figure must not be quoted, and why}}
