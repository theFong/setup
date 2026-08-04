#!/usr/bin/env bash
#
# probe-cluster.sh — read-only inventory sweep across cluster nodes.
#
# Collects the facts a cluster skill needs to be written honestly: identity,
# capacity, GPUs, containers and their restart policies, addresses on every
# plane (LAN / overlay / RDMA fabric), listening ports, and access asymmetry
# (sudo and docker without sudo). Emits one JSON object per host.
#
# READ-ONLY BY CONSTRUCTION. It reads /proc, /sys, /etc/os-release and
# /etc/docker/daemon.json, and runs query-only commands (ip, ss, docker ps,
# nvidia-smi, systemctl list-units). It never writes, installs, restarts, or
# reconfigures anything, and it never runs sudo except `sudo -n true` to
# discover whether passwordless sudo exists.
#
# Usage:
#   probe-cluster.sh [options] HOST [HOST...]
#   probe-cluster.sh [options] --hosts-file FILE
#   probe-cluster.sh [options] --brev
#   probe-cluster.sh --self-test
#
# Options:
#   -o FILE           write JSON here instead of stdout
#   -t SECS           SSH connect timeout (default 10)
#   -T SECS           per-host wall-clock timeout (default 90)
#   -u USER           force this SSH user for every host
#   --hosts-file F    read hosts from F (one per line, # comments allowed)
#   --brev            enumerate physical nodes from `brev ls nodes`
#   --brev-instances  enumerate cloud instances from `brev ls`
#   --include-local   also probe the machine this runs on, as host "local"
#   --self-test       probe the local machine and assert the output is
#                     well-formed; prints nothing but a verdict
#   -h, --help        this text
#
# Sources combine, so `--brev --brev-instances extra-host` sweeps the whole
# fleet plus anything the control plane does not know about.
#
# Exit status: 0 if every host was probed, 1 if any host failed (the JSON
# still contains an entry for it, with an "error" field).
#
# Hosts are whatever `ssh <name>` already resolves — an ~/.ssh/config alias, a
# hostname, or user@host. Brev node and instance names double as SSH aliases
# because `brev refresh` writes them into ~/.brev/ssh_config, which
# ~/.ssh/config Includes. If a host stops resolving, run `brev refresh` — this
# script will not, because it stays read-only. Fix SSH first; this script does
# not manage keys.

set -uo pipefail

CONNECT_TIMEOUT=10
HOST_TIMEOUT=90
OUT=""
FORCE_USER=""
INCLUDE_LOCAL=0
SELF_TEST=0
BREV_NODES=0
BREV_INSTANCES=0
# Newline-delimited rather than an array: macOS ships bash 3.2, where expanding
# an empty array under `set -u` is an unbound-variable error.
HOSTS=""
add_host() { HOSTS="${HOSTS}$1
"; }

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 2; }
# Print the header comment block. Derived from the file rather than a fixed
# line range so editing the header cannot silently truncate --help.
usage() { awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$0"; }

# ---------------------------------------------------------------------------
# The collector. Runs on each target under `bash -s`. Single-quoted heredoc:
# nothing here is expanded locally. Deliberately does not `set -e` — a missing
# tool must yield an empty field, not a dead probe.
# ---------------------------------------------------------------------------
read -r -d '' COLLECTOR <<'COLLECTOR_EOF'
set -u

# JSON-escape stdin. Drops control characters that have no JSON short escape,
# then escapes the ones that do and folds newlines into \n.
esc() {
  tr -d '\000-\010\013\014\016-\037' 2>/dev/null \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' \
    | awk 'BEGIN{ORS=""} NR>1{printf "\\n"} {print}'
}

first=1
sep() { if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi; }
kv()  { sep; printf '    "%s": "%s"' "$1" "$(printf '%s' "${2-}" | esc)"; }
# karr KEY < lines — emit a JSON array of strings, skipping blank lines.
karr() {
  sep; printf '    "%s": [' "$1"
  local n=0 line
  while IFS= read -r line; do
    case "$line" in ''|' ') continue ;; esac
    [ "$n" = 0 ] || printf ', '
    printf '"%s"' "$(printf '%s' "$line" | esc)"
    n=1
  done
  printf ']'
}
has() { command -v "$1" >/dev/null 2>&1; }

printf '  {\n'

# --- identity -------------------------------------------------------------
kv hostname "$(hostname 2>/dev/null)"
if [ -r /etc/os-release ]; then
  kv os "$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-$NAME}")"
else
  kv os "$(uname -s 2>/dev/null) $(uname -r 2>/dev/null)"
fi
kv kernel "$(uname -r 2>/dev/null)"
kv arch "$(uname -m 2>/dev/null)"
kv uptime "$(uptime -p 2>/dev/null || uptime 2>/dev/null)"
kv probed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
kv ssh_user "$(id -un 2>/dev/null)"

# --- capacity -------------------------------------------------------------
kv cpus "$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
if [ -r /proc/meminfo ]; then
  kv mem_total "$(awk '/^MemTotal:/{printf "%.0f GB", $2/1048576}' /proc/meminfo 2>/dev/null)"
else
  kv mem_total "$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f GB", $1/1073741824}')"
fi
kv root_fs "$(df -h / 2>/dev/null | awk 'NR==2{print $2" total, "$4" avail"}')"

# --- GPUs -----------------------------------------------------------------
if has nvidia-smi; then
  nvidia-smi --query-gpu=index,name,memory.total,driver_version \
             --format=csv,noheader 2>/dev/null | karr gpus
  # Module-level power meter, where it exists. Its ABSENCE is the finding:
  # without it nvidia-smi reports die-only watts and must not be used for
  # power or cost figures. See cluster-ops reference/diagnostics.md.
  mpr=$(nvidia-smi -q 2>/dev/null \
        | awk -F': ' '/Module Power Readings/{f=1;next} f&&/Power Draw/{gsub(/^ +| +$/,"",$2); print $2; exit}')
  kv gpu_module_power "${mpr:-absent}"
  nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv,noheader 2>/dev/null \
    | sort -u | karr gpu_throttle_reasons
else
  printf '' | karr gpus
  kv gpu_module_power "no-nvidia-smi"
fi

# --- container runtime ----------------------------------------------------
if has docker; then
  if docker info >/dev/null 2>&1; then
    kv docker "yes"; kv docker_needs_sudo "no"
    docker ps -aq 2>/dev/null | xargs -r docker inspect \
      --format '{{.Name}}|{{.Config.Image}}|{{.State.Status}}|restart={{.HostConfig.RestartPolicy.Name}}|net={{.HostConfig.NetworkMode}}' \
      2>/dev/null | sed 's|^/||' | karr containers
  else
    kv docker "yes"; kv docker_needs_sudo "yes"
    printf '' | karr containers
  fi
  kv docker_default_runtime "$(sed -n 's/.*"default-runtime"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/docker/daemon.json 2>/dev/null)"
  ls /etc/cdi 2>/dev/null | karr cdi_specs
else
  kv docker "no"; kv docker_needs_sudo ""
  printf '' | karr containers
  kv docker_default_runtime ""
  printf '' | karr cdi_specs
fi

# --- access ---------------------------------------------------------------
if [ "$(id -u)" = 0 ]; then kv sudo_nopasswd "root"
elif sudo -n true 2>/dev/null; then kv sudo_nopasswd "yes"
else kv sudo_nopasswd "no"; fi

# --- network --------------------------------------------------------------
if has ip; then
  # name|state|mtu|comma-separated IPv4 CIDRs
  ip -o link show 2>/dev/null | awk -F': ' '{split($3,a," "); print $2}' \
    | while IFS= read -r n; do
        st=$(cat "/sys/class/net/$n/operstate" 2>/dev/null)
        mtu=$(cat "/sys/class/net/$n/mtu" 2>/dev/null)
        v4=$(ip -o -4 addr show dev "$n" 2>/dev/null | awk '{printf "%s%s", sep, $4; sep=","}')
        printf '%s|%s|mtu=%s|%s\n' "$n" "${st:-?}" "${mtu:-?}" "${v4:-none}"
      done | karr interfaces
  ip route show default 2>/dev/null | karr default_routes
else
  ifconfig -a 2>/dev/null | karr interfaces
  printf '' | karr default_routes
fi

# --- overlay networks -----------------------------------------------------
# Two overlays that both allocate from CGNAT 100.64.0.0/10 can silently fight;
# record every one present so the conflict is visible when the skill is written.
{ has netbird && netbird status 2>/dev/null \
    | grep -E 'Peers count|Management|Signal|Connection type' | head -5; } | karr netbird
{ has tailscale && { tailscale ip -4 2>/dev/null; tailscale status 2>&1 | head -2; }; } | karr tailscale
# The netfilter chain behind the CGNAT collision. Only visible to root.
if [ "$(id -u)" = 0 ] || sudo -n true 2>/dev/null; then
  if [ "$(id -u)" = 0 ]; then IPT="iptables"; else IPT="sudo -n iptables"; fi
  if $IPT -L ts-input -n 2>/dev/null | head -20 | grep -q .; then
    $IPT -L ts-input -n -v 2>/dev/null | grep -i 'DROP' | head -5 | karr ts_input_drops
  else
    printf '' | karr ts_input_drops
  fi
else
  printf 'unknown (needs root)\n' | karr ts_input_drops
fi

# --- listening ports ------------------------------------------------------
if has ss; then
  ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | sort -u | karr listeners
elif has netstat; then
  netstat -an 2>/dev/null | awk '/LISTEN/{print $4}' | sort -u | karr listeners
else
  printf '' | karr listeners
fi

# --- RDMA fabric ----------------------------------------------------------
# hca|port|state|phys_state|rate|netdev. Count of ACTIVE devices divided by the
# number of PCIe views is the cable count; the lane-encoding string is not.
{
  for d in /sys/class/infiniband/*; do
    [ -d "$d" ] || continue
    hca=$(basename "$d")
    nd=$(ls "$d/device/net" 2>/dev/null | head -1)
    for p in "$d"/ports/*; do
      [ -d "$p" ] || continue
      printf '%s|port%s|%s|%s|%s|%s\n' "$hca" "$(basename "$p")" \
        "$(cat "$p/state" 2>/dev/null)" "$(cat "$p/phys_state" 2>/dev/null)" \
        "$(cat "$p/rate" 2>/dev/null)" "${nd:-none}"
    done
  done
} 2>/dev/null | karr rdma_ports

# --- service health -------------------------------------------------------
{ has systemctl && systemctl list-units --failed --no-legend --plain 2>/dev/null \
    | awk '{print $1}'; } | karr failed_units

printf '\n  }'
COLLECTOR_EOF

# ---------------------------------------------------------------------------
# local driver
# ---------------------------------------------------------------------------

probe_local() { printf '%s' "$COLLECTOR" | bash -s 2>/dev/null; }

probe_remote() {
  local host="$1" runner=""
  # Unquoted on purpose: "timeout 90" must split into two words, and macOS has
  # no `timeout` at all, in which case the prefix is empty.
  command -v timeout >/dev/null 2>&1 && runner="timeout $HOST_TIMEOUT"
  local ssh_target="$host"
  [ -n "$FORCE_USER" ] && ssh_target="${FORCE_USER}@${host#*@}"
  # shellcheck disable=SC2086
  printf '%s' "$COLLECTOR" | $runner ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="$CONNECT_TIMEOUT" \
    -o LogLevel=ERROR \
    "$ssh_target" bash -s 2>/dev/null
}

# error_entry HOST REASON — a JSON object standing in for a host that failed,
# so a broken node is recorded rather than silently missing from the sweep.
error_entry() {
  printf '  {\n    "host": "%s",\n    "error": "%s"\n  }' "$1" "$2"
}

# enumerate_brev nodes|instances — take the host list from the brev control
# plane. Node and instance names double as SSH aliases, so what this returns is
# directly probe-able. Read-only: it lists, it does not refresh or mutate.
enumerate_brev() {
  local kind="$1" json filter names down
  command -v brev >/dev/null 2>&1 || die "--brev needs the brev CLI on PATH (see the brev-cli skill)"
  command -v jq   >/dev/null 2>&1 || die "--brev needs jq on PATH"

  if [ "$kind" = nodes ]; then
    json=$(brev ls nodes --json 2>/dev/null)
    # `brev ls nodes --json` is a BARE ARRAY, while `brev ls --json` wraps its
    # rows under .workspaces. Using either filter on the other output fails with
    # 'Cannot index array with string "name"'.
    filter='.[]'
  else
    json=$(brev ls --json 2>/dev/null)
    filter='.workspaces[]'
  fi

  printf '%s' "$json" | jq -e . >/dev/null 2>&1 \
    || die "brev ls $kind did not return JSON — is 'brev login' done?"

  if [ "$kind" = nodes ]; then
    # `Connected` is control-plane registration, not reachability. Probe the
    # disconnected ones anyway: a node that cannot be reached belongs in the
    # inventory as unverified, not omitted. Naming them now saves waiting out
    # a timeout to discover which they were.
    down=$(printf '%s' "$json" | jq -r '.[] | select(.status != "Connected") | "\(.name)=\(.status)"')
    [ -n "$down" ] && warn "not Connected per brev: $(printf '%s' "$down" | tr '\n' ' ')"
  fi

  names=$(printf '%s' "$json" | jq -r "$filter | .name" 2>/dev/null)
  if [ -z "$names" ]; then
    warn "brev returned no $kind"
    return 0
  fi
  while IFS= read -r nm; do
    [ -n "$nm" ] && add_host "$nm"
  done <<EOF
$names
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="${2-}"; shift 2 ;;
    -t) CONNECT_TIMEOUT="${2-}"; shift 2 ;;
    -T) HOST_TIMEOUT="${2-}"; shift 2 ;;
    -u) FORCE_USER="${2-}"; shift 2 ;;
    --hosts-file)
      [ -r "${2-}" ] || die "cannot read hosts file: ${2-}"
      while IFS= read -r line; do
        line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [ -n "$line" ] && add_host "$line"
      done < "$2"
      shift 2 ;;
    --brev) BREV_NODES=1; shift ;;
    --brev-instances) BREV_INSTANCES=1; shift ;;
    --include-local) INCLUDE_LOCAL=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) add_host "$1"; shift ;;
  esac
done

# --- self-test -------------------------------------------------------------
# The in-script validation required by STYLE_GUIDE.md: run the collector for
# real on this machine and prove the output is a well-formed object carrying
# the keys every downstream step reads. Catches a collector broken by a quoting
# or portability mistake on the actual machine, not only in CI.
if [ "$SELF_TEST" = 1 ]; then
  out=$(probe_local) || { warn "collector exited nonzero"; exit 1; }
  status=0
  case "$out" in
    *'{'*'}'*) ;;
    *) warn "collector did not emit a JSON object"; status=1 ;;
  esac
  for key in hostname os kernel arch cpus mem_total gpus containers \
             sudo_nopasswd interfaces listeners rdma_ports; do
    case "$out" in
      *"\"$key\":"*) ;;
      *) warn "collector output is missing required key: $key"; status=1 ;;
    esac
  done
  # A stray unescaped quote or a trailing comma would break every consumer, so
  # check balance rather than trusting that the fields merely appear.
  opens=$(printf '%s' "$out" | tr -cd '{' | wc -c | tr -d ' ')
  closes=$(printf '%s' "$out" | tr -cd '}' | wc -c | tr -d ' ')
  [ "$opens" = "$closes" ] || { warn "unbalanced braces ($opens open, $closes close)"; status=1; }
  case "$out" in *',
  }'*|*', }'*) warn "trailing comma before object close"; status=1 ;; esac
  if command -v python3 >/dev/null 2>&1; then
    printf '[%s]' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
      || { warn "output does not parse as JSON"; status=1; }
  fi
  if [ "$status" = 0 ]; then
    log "self-test passed: collector produced valid, complete JSON for $(hostname)"
  else
    warn "self-test FAILED"
  fi
  exit "$status"
fi

[ "$BREV_NODES" = 1 ] && enumerate_brev nodes
[ "$BREV_INSTANCES" = 1 ] && enumerate_brev instances
[ "$INCLUDE_LOCAL" = 1 ] && add_host "local"
[ -n "$HOSTS" ] || { usage; die "no hosts given"; }

failed=0
buf="["
n=0
while IFS= read -r h; do
  [ -n "$h" ] || continue
  log "probing $h"
  if [ "$h" = "local" ]; then
    entry=$(probe_local)
  else
    entry=$(probe_remote "$h")
  fi
  if [ -z "$entry" ]; then
    warn "$h: probe returned nothing (unreachable, no bash, or timed out)"
    entry=$(error_entry "$h" "unreachable or probe timed out")
    failed=1
  else
    # Tag the entry with the name the operator used, which is what the skill's
    # inventory table must key on — it is frequently not the hostname.
    entry=$(printf '%s' "$entry" | sed "1s|^  {|  {\n    \"host\": \"$h\",|")
  fi
  [ "$n" = 0 ] || buf="$buf,"
  buf="$buf
$entry"
  n=$((n + 1))
done <<EOF
$HOSTS
EOF
buf="$buf
]"

if [ -n "$OUT" ]; then
  printf '%s\n' "$buf" > "$OUT" || die "could not write $OUT"
  log "wrote $n host record(s) to $OUT"
else
  printf '%s\n' "$buf"
fi

if [ "$failed" != 0 ]; then
  warn "one or more hosts failed to probe; see \"error\" entries"
  warn "if a host that should exist stopped resolving, run 'brev refresh' (gateway"
  warn "ports rotate) and re-probe. Record anything still unreachable as unverified."
fi
exit "$failed"
