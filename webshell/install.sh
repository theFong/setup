#!/usr/bin/env bash
#
# webshell/install.sh — browser terminal (ttyd + tmux) with persistent sessions.
#
# Installs ttyd (built from source: release/distro builds bundle an xterm.js
# with no OSC 52 handler, so copy-to-clipboard silently fails), links this
# directory's tmux.conf to ~/.tmux.conf, installs the tmux-clip clipboard
# helper, and sets up a systemd service. Sessions are tmux-backed, so a
# browser refresh (or full disconnect) reattaches to the same shells.
#
# Modes:
#   private (default) — binds 127.0.0.1 with password auth (generated and
#                       printed unless WEBSHELL_PASSWORD is set). Reach it
#                       via an SSH tunnel:  ssh -L 7681:127.0.0.1:7681 <host>
#                       then open http://localhost:7681 (localhost counts as
#                       a secure context, so clipboard works).
#   public            — binds a specific interface (default: wt0 / Netbird)
#                       with NO password: an authenticating HTTPS proxy in
#                       front is assumed. Do not use without one.
#
# Usage:
#   ./install.sh                                # private on 127.0.0.1:7681
#   ./install.sh --public                       # public on wt0:7681
#   ./install.sh --public --iface eth0 --port 8080
#   ./install.sh --force-build                  # rebuild ttyd even if present
#
# Env overrides: WEBSHELL_MODE (private|public), WEBSHELL_IFACE, WEBSHELL_PORT,
#                WEBSHELL_USER, WEBSHELL_PASSWORD, WEBSHELL_SESSION
#
# Re-running is safe; the service only restarts if its config changed.

set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

WEBSHELL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${WEBSHELL_MODE:-private}"
IFACE="${WEBSHELL_IFACE:-wt0}"
PORT="${WEBSHELL_PORT:-7681}"
WSUSER="${WEBSHELL_USER:-$(id -un)}"
PASSWORD="${WEBSHELL_PASSWORD:-}"
SESSION="${WEBSHELL_SESSION:-main}"
FORCE_BUILD=0
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --private) MODE="private" ;;
      --public)  MODE="public" ;;
      --iface)   IFACE="$2"; shift ;;
      --port)    PORT="$2"; shift ;;
      --session) SESSION="$2"; shift ;;
      --force-build) FORCE_BUILD=1 ;;
      -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) warn "unknown argument: $1"; exit 1 ;;
    esac
    shift
  done
  case "$MODE" in private|public) ;; *) warn "invalid mode: $MODE"; exit 1 ;; esac
}

check_platform() {
  if [ "$(uname -s)" != "Linux" ] || ! have systemctl; then
    warn "webshell setup requires Linux with systemd"; exit 1
  fi
  if ! have apt-get; then
    warn "this script installs build deps with apt; on other distros install" \
         "cmake, gcc, json-c and libwebsockets dev headers manually first"
  fi
}

# Release binaries and distro packages of ttyd (<= 1.7.7) ship an xterm.js
# with no OSC 52 clipboard handler — highlight-to-copy silently fails. Only
# builds from main (which bundle @xterm/addon-clipboard) support it, so we
# always build from source. Source builds are identifiable by the git-hash
# suffix in --version (e.g. "1.7.7-647d55a" vs a bare "1.7.7").
install_ttyd() {
  if [ "$FORCE_BUILD" = 0 ] && have ttyd && ttyd --version 2>&1 | grep -qE 'version [0-9.]+-[0-9a-f]+'; then
    log "ttyd already present (source build): $(ttyd --version)"
    return
  fi
  log "building ttyd from source (releases lack OSC52 clipboard support)"
  if have apt-get; then
    $SUDO apt-get update -y -qq
    $SUDO apt-get install -y -qq build-essential cmake libjson-c-dev libwebsockets-dev git
  fi
  local tmpd; tmpd=$(mktemp -d)
  git clone --depth 1 https://github.com/tsl0922/ttyd.git "$tmpd/ttyd"
  (cd "$tmpd/ttyd" && mkdir build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release >/dev/null && make -j"$(nproc)")
  $SUDO install -m 0755 "$tmpd/ttyd/build/ttyd" /usr/local/bin/ttyd
  rm -rf "$tmpd"
  log "installed $(/usr/local/bin/ttyd --version)"
}

install_tmux_config() {
  have tmux || { log "installing tmux"; $SUDO apt-get install -y -qq tmux; }
  # tmux-clip: tmux 3.2a's own set-clipboard/OSC52 emission is unreliable, so
  # copy bindings pipe through this helper, which writes the escape sequence
  # directly to every attached client tty.
  $SUDO install -m 0755 "$WEBSHELL_DIR/tmux-clip" /usr/local/bin/tmux-clip
  # Symlink ~/.tmux.conf into the repo (source of truth), backing up any
  # existing regular file.
  if [ -f "$HOME/.tmux.conf" ] && [ ! -L "$HOME/.tmux.conf" ]; then
    mv "$HOME/.tmux.conf" "$HOME/.tmux.conf.bak"
    warn "existing ~/.tmux.conf moved to ~/.tmux.conf.bak"
  fi
  ln -sfn "$WEBSHELL_DIR/tmux.conf" "$HOME/.tmux.conf"
  log "linked ~/.tmux.conf -> $WEBSHELL_DIR/tmux.conf"
}

install_service() {
  local bind_args="" extra_unit=""
  local unit="/etc/systemd/system/ttyd.service"
  if [ "$MODE" = "private" ]; then
    # Re-runs stay idempotent: reuse the credential already in the unit
    # rather than rotating the password on every install.
    if [ -z "$PASSWORD" ] && [ -f "$unit" ]; then
      local existing
      existing=$($SUDO sed -n 's/.*--credential \([^ ]*\).*/\1/p' "$unit" 2>/dev/null | head -1)
      if [ -n "$existing" ]; then
        WSUSER="${existing%%:*}"
        PASSWORD="${existing#*:}"
        log "reusing existing credential for user $WSUSER"
      fi
    fi
    if [ -z "$PASSWORD" ]; then
      PASSWORD=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)
      GENERATED_PASSWORD=1
    fi
    bind_args="--interface 127.0.0.1 --credential $WSUSER:$PASSWORD"
    extra_unit='After=network.target'
  else
    bind_args="--interface $IFACE"
    # Netbird's wt0 comes up via netbird.service; order after it when used.
    case "$IFACE" in
      wt0) extra_unit=$'After=network.target netbird.service\nWants=netbird.service' ;;
      *)   extra_unit='After=network.target' ;;
    esac
  fi

  local tmp; tmp=$(mktemp)
  cat > "$tmp" <<EOF
[Unit]
Description=ttyd browser terminal (tmux-backed, session-persistent)
$extra_unit

[Service]
Type=simple
User=$WSUSER
# tmux "new -A" attaches if the session exists, else creates it ->
# refreshing the browser preserves your shells.
ExecStart=/usr/local/bin/ttyd $bind_args --port $PORT --writable tmux new -A -s $SESSION
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  if [ -f "$unit" ] && $SUDO cmp -s "$tmp" "$unit"; then
    log "ttyd.service unchanged"
    rm -f "$tmp"
  else
    $SUDO install -m 0600 "$tmp" "$unit"   # 0600: may contain the password
    rm -f "$tmp"
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now ttyd
    $SUDO systemctl restart ttyd
    log "ttyd.service installed and (re)started"
  fi
}

# Fail loudly (nonzero) if the webshell isn't actually up and guarded:
# service active, port serving HTTP, and in private mode unauthenticated
# requests must be rejected while the credential must be accepted.
verify() {
  local addr fails=0
  case "$MODE" in
    private) addr="127.0.0.1" ;;
    *)       addr=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')
             [ -n "$addr" ] || { warn "verify: interface $IFACE has no IPv4 address"; return 1; } ;;
  esac
  # the service may need a moment (or, for wt0, the mesh) to come up
  local code="" i
  for i in 1 2 3 4 5; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$addr:$PORT/" || true)
    [ "$code" != "000" ] && break
    sleep 2
  done
  systemctl is-active --quiet ttyd || { warn "verify: ttyd.service is not active"; fails=$((fails+1)); }
  if [ "$MODE" = "private" ]; then
    [ "$code" = "401" ] || { warn "verify: expected HTTP 401 without credentials, got '$code'"; fails=$((fails+1)); }
    local auth_code
    auth_code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -u "$WSUSER:$PASSWORD" "http://$addr:$PORT/" || true)
    [ "$auth_code" = "200" ] || { warn "verify: expected HTTP 200 with credentials, got '$auth_code'"; fails=$((fails+1)); }
  else
    [ "$code" = "200" ] || { warn "verify: expected HTTP 200 on $addr:$PORT, got '$code'"; fails=$((fails+1)); }
  fi
  [ "$fails" -eq 0 ] || return 1
  log "verified: service active and serving on $addr:$PORT ($MODE mode)"
}

summary() {
  echo
  log "webshell ready (mode: $MODE)"
  if [ "$MODE" = "private" ]; then
    echo "  Bound to 127.0.0.1:$PORT — reach it via an SSH tunnel:"
    echo "    ssh -L $PORT:127.0.0.1:$PORT <this-host>"
    echo "  then open http://localhost:$PORT"
    echo "  login: $WSUSER"
    if [ "${GENERATED_PASSWORD:-0}" = 1 ]; then
      echo "  password (generated — save it now, not stored elsewhere): $PASSWORD"
    else
      echo "  password: (from WEBSHELL_PASSWORD)"
    fi
  else
    echo "  Bound to $IFACE:$PORT with NO password."
    echo "  Ensure an authenticating HTTPS proxy fronts it and the port is"
    echo "  not otherwise reachable."
  fi
  echo "  Sessions persist across refresh/disconnect (tmux session: $SESSION)."
}

main() {
  parse_args "$@"
  check_platform
  install_ttyd
  install_tmux_config
  install_service
  verify
  summary
}

main "$@"
