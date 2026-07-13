#!/usr/bin/env bash
#
# webshell/install.sh — browser terminal (ttyd + tmux) with persistent sessions.
#
# Installs ttyd (built from source: release/distro builds bundle an xterm.js
# with no OSC 52 handler, so copy-to-clipboard silently fails), links this
# directory's tmux.conf to ~/.tmux.conf, installs the tmux-clip clipboard
# helper, installs tmux plugins (tpm + resurrect + continuum: window/pane
# layout, cwds, and visible text survive reboots — processes do not), and
# sets up a systemd service. Sessions are tmux-backed, so a browser refresh
# (or full disconnect) reattaches to the same shells.
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
# Re-running is safe; the service only restarts if its config changed, and a
# flagless re-run keeps whatever mode/interface/port is already deployed.

set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

WEBSHELL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${WEBSHELL_MODE:-private}"
IFACE="${WEBSHELL_IFACE:-wt0}"
PORT="${WEBSHELL_PORT:-7681}"
# Track which of these the caller chose explicitly (env or flag) so re-runs
# can keep the deployed configuration instead of silently reverting defaults.
MODE_EXPLICIT=0; IFACE_EXPLICIT=0; PORT_EXPLICIT=0
[ -z "${WEBSHELL_MODE:-}" ]  || MODE_EXPLICIT=1
[ -z "${WEBSHELL_IFACE:-}" ] || IFACE_EXPLICIT=1
[ -z "${WEBSHELL_PORT:-}" ]  || PORT_EXPLICIT=1
WSUSER="${WEBSHELL_USER:-$(id -un)}"
PASSWORD="${WEBSHELL_PASSWORD:-}"
SESSION="${WEBSHELL_SESSION:-main}"
FORCE_BUILD=0
VERIFY_ONLY=0
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --private) MODE="private"; MODE_EXPLICIT=1 ;;
      --public)  MODE="public"; MODE_EXPLICIT=1 ;;
      --iface)   IFACE="$2"; IFACE_EXPLICIT=1; shift ;;
      --port)    PORT="$2"; PORT_EXPLICIT=1; shift ;;
      --session) SESSION="$2"; shift ;;
      --force-build) FORCE_BUILD=1 ;;
      --verify-only) VERIFY_ONLY=1 ;;
      -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

# tpm + tmux-resurrect + tmux-continuum give macOS-Terminal-style persistence:
# layout, cwds, and visible pane text are auto-saved and restored whenever the
# tmux server starts again (e.g. first webshell connect after a reboot).
# Processes are not resumed; panes come back as fresh shells.
TPM_DIR="$HOME/.tmux/plugins/tpm"

install_tmux_plugins() {
  have git || { log "installing git (needed for tmux plugins)"; $SUDO apt-get install -y -qq git; }
  if [ -d "$TPM_DIR/.git" ]; then
    log "tpm already present"
  else
    log "installing tpm (tmux plugin manager)"
    git clone -q --depth 1 https://github.com/tmux-plugins/tpm "$TPM_DIR"
  fi
  # tpm's CLI installer only works against a server where tpm has run (it
  # reads TMUX_PLUGIN_MANAGER_PATH from the server environment). Reload the
  # conf into a running server, or boot a throwaway session on a fresh box.
  local started=0
  if tmux has-session 2>/dev/null; then
    tmux source-file "$HOME/.tmux.conf"
  else
    tmux new-session -d -s webshell-plugin-install
    started=1
  fi
  # Installs the plugins declared in tmux.conf; no-op for installed ones.
  "$TPM_DIR/bin/install_plugins" >/dev/null
  if [ "$started" = 1 ]; then
    tmux kill-session -t webshell-plugin-install
  else
    # second reload: the running server now loads the just-installed plugins
    tmux source-file "$HOME/.tmux.conf"
  fi
}

# Re-runs must not change a deployed webshell's exposure: unless the caller
# explicitly chose a mode (flag or WEBSHELL_MODE), adopt the mode, interface,
# and port of the already-installed unit. A flagless re-run once flipped a
# public (proxy-fronted) webshell to private and locked every client out.
adopt_installed_mode() {
  local unit="/etc/systemd/system/ttyd.service" exec_line="" val=""
  if [ "$MODE_EXPLICIT" = 1 ] || [ ! -f "$unit" ]; then return 0; fi
  exec_line=$($SUDO sed -n 's/^ExecStart=//p' "$unit" 2>/dev/null | head -1)
  if [ -z "$exec_line" ]; then return 0; fi
  case "$exec_line" in
    *--credential*) MODE="private" ;;
    *--interface*)
      MODE="public"
      if [ "$IFACE_EXPLICIT" = 0 ]; then
        val=$(printf '%s\n' "$exec_line" | sed -n 's/.*--interface \([^ ]*\).*/\1/p')
        [ -z "$val" ] || IFACE="$val"
      fi ;;
  esac
  if [ "$PORT_EXPLICIT" = 0 ]; then
    val=$(printf '%s\n' "$exec_line" | sed -n 's/.*--port \([^ ]*\).*/\1/p')
    [ -z "$val" ] || PORT="$val"
  fi
  log "re-run: keeping installed ttyd mode ($MODE)"
}

# Populate WSUSER/PASSWORD from the credential in the installed unit, if any.
# Returns nonzero when no credential is found.
load_existing_credential() {
  local unit="/etc/systemd/system/ttyd.service" existing=""
  [ -f "$unit" ] && existing=$($SUDO sed -n 's/.*--credential \([^ ]*\).*/\1/p' "$unit" 2>/dev/null | head -1)
  [ -n "$existing" ] || return 1
  WSUSER="${existing%%:*}"
  PASSWORD="${existing#*:}"
}

# Compute BIND_ARGS / EXTRA_UNIT for the current mode (may generate or reuse
# the private-mode credential), then render the unit. Split from
# install_service so tests can render the expected unit without installing.
compute_service_args() {
  if [ "$MODE" = "private" ]; then
    # Re-runs stay idempotent: reuse the credential already in the unit
    # rather than rotating the password on every install.
    if [ -z "$PASSWORD" ] && load_existing_credential; then
      log "reusing existing credential for user $WSUSER"
    fi
    if [ -z "$PASSWORD" ]; then
      PASSWORD=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)
      GENERATED_PASSWORD=1
    fi
    BIND_ARGS="--interface 127.0.0.1 --credential $WSUSER:$PASSWORD"
    EXTRA_UNIT='After=network.target'
  else
    BIND_ARGS="--interface $IFACE"
    # Netbird's wt0 comes up via netbird.service; order after it when used.
    case "$IFACE" in
      wt0) EXTRA_UNIT=$'After=network.target netbird.service\nWants=netbird.service' ;;
      *)   EXTRA_UNIT='After=network.target' ;;
    esac
  fi
}

render_unit() {
  cat <<EOF
[Unit]
Description=ttyd browser terminal (tmux-backed, session-persistent)
$EXTRA_UNIT

[Service]
Type=simple
User=$WSUSER
# tmux "new -A" attaches if the session exists, else creates it ->
# refreshing the browser preserves your shells.
ExecStart=/usr/local/bin/ttyd $BIND_ARGS --port $PORT --writable tmux new -A -s $SESSION
Restart=always
RestartSec=2
# The tmux server is a child in this unit's cgroup; the default cgroup kill
# would take every shell down with a ttyd restart. Kill only ttyd itself:
# sessions survive service restarts, and reboots are covered by the
# resurrect/continuum session restore.
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
}

install_service() {
  local unit="/etc/systemd/system/ttyd.service"
  compute_service_args
  local tmp; tmp=$(mktemp)
  render_unit > "$tmp"

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
  # a ttyd restart must never take the tmux server (all shells) down with it
  if ! $SUDO grep -q '^KillMode=process' /etc/systemd/system/ttyd.service 2>/dev/null; then
    warn "verify: ttyd.service missing KillMode=process (a restart would kill all shells)"
    fails=$((fails+1))
  fi
  verify_session_restore || fails=$((fails+1))
  [ "$fails" -eq 0 ] || return 1
  log "verified: service active and serving on $addr:$PORT ($MODE mode)"
}

# Session restore must actually work, not just be configured. Everything runs
# on a scratch socket with its own @resurrect-dir, so the real webshell server
# and any real saves are untouched:
#   1. a fresh server on the linked conf must load the plugins (the reboot
#      path — tmux-resurrect's bindings appear only when tpm ran);
#   2. continuum's save hook must be armed where real saves happen: on the
#      live server when one exists, else on the scratch server (continuum
#      only arms itself on a machine's sole tmux server);
#   3. a full save -> kill server -> fresh server -> restore cycle must bring
#      a window layout back. resurrect's save/restore scripts are driven
#      directly because continuum's auto-trigger depends on that machine-wide
#      sole-server condition, which CI runners and live boxes both violate.
# The scratch conf turns @continuum-restore off after sourcing the real one
# (tpm's `run` executes after config parsing) so nothing is ever replayed
# into the scratch servers from real saves.
verify_session_restore() {
  # The "rebooted" server gets its own socket: reusing the first socket races
  # the dying server's cleanup (it unlinks the socket path from under the new
  # server -> "server exited unexpectedly"). Restore state lives in files,
  # so a fresh socket restores identically — race-free by construction.
  local sock="webshell-verify-$$" sock2="webshell-verify2-$$"
  local keys="" sright="" restored="" i fails=0
  local vdir; vdir=$(mktemp -d)
  printf 'source-file %s\nset -g @continuum-restore "off"\nset -g @resurrect-dir "%s"\n' \
    "$HOME/.tmux.conf" "$vdir" > "$vdir/conf"

  if tmux -L "$sock" -f "$vdir/conf" new-session -d -s main 2>/dev/null; then
    for i in 1 2 3 4 5 6 7 8 9 10; do
      keys=$(tmux -L "$sock" list-keys 2>/dev/null || true)
      case "$keys" in *tmux-resurrect/scripts/save.sh*) break ;; esac
      sleep 1
    done
    if tmux has-session 2>/dev/null; then
      sright=$(tmux show-option -gv status-right 2>/dev/null || true)
    else
      for i in 1 2 3 4 5 6 7 8 9 10; do
        sright=$(tmux -L "$sock" show-option -gv status-right 2>/dev/null || true)
        case "$sright" in *continuum_save*) break ;; esac
        sleep 1
      done
    fi
    # save -> kill -> fresh server -> restore: the layout must come back
    tmux -L "$sock" new-window -t main -n restoreme 2>/dev/null || true
    tmux -L "$sock" split-window -t main:restoreme 2>/dev/null || true
    tmux -L "$sock" run-shell "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" >/dev/null 2>&1 || true
    tmux -L "$sock" kill-server 2>/dev/null || true
    if tmux -L "$sock2" -f "$vdir/conf" new-session -d -s main 2>/dev/null; then
      tmux -L "$sock2" run-shell "$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh" >/dev/null 2>&1 || true
      restored=$(tmux -L "$sock2" list-windows -t main -F '#{window_name}:#{window_panes}' 2>/dev/null || true)
      tmux -L "$sock2" kill-server 2>/dev/null || true
    fi
  fi
  rm -rf "$vdir"

  case "$keys" in *tmux-resurrect/scripts/save.sh*) ;; *)
    warn "verify: tmux-resurrect did not load in a fresh tmux server"; fails=$((fails+1)) ;; esac
  case "$sright" in *continuum_save*) ;; *)
    warn "verify: continuum auto-save hook missing from status-right"; fails=$((fails+1)) ;; esac
  [ -f "$HOME/.tmux/plugins/tmux-continuum/scripts/continuum_save.sh" ] || {
    warn "verify: tmux-continuum save script is missing"; fails=$((fails+1)); }
  case "$restored" in *"restoreme:2"*) ;; *)
    warn "verify: save/restore cycle did not bring the window layout back"; fails=$((fails+1)) ;; esac
  [ "$fails" -eq 0 ] || return 1
  log "verified: session-restore plugins load, auto-save armed, save/restore cycle works"
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
  echo "  Sessions persist across refresh/disconnect (tmux session: $SESSION),"
  echo "  and window/pane layout is restored after a reboot (processes are not)."
}

main() {
  parse_args "$@"
  check_platform
  adopt_installed_mode
  if [ "$VERIFY_ONLY" = 1 ]; then
    # Standalone health check of an existing install (e.g. from CI or cron):
    # same assertions as a fresh install, exits nonzero on any failure.
    if [ "$MODE" = "private" ] && [ -z "$PASSWORD" ]; then
      load_existing_credential || { warn "verify: no credential found in ttyd.service"; exit 1; }
    fi
    verify
    return
  fi
  install_ttyd
  install_tmux_config
  install_tmux_plugins
  install_service
  verify
  summary
}

# SETUP_SKIP_MAIN=1 lets tests source individual functions (e.g. render_unit)
# without running the bootstrap.
[ "${SETUP_SKIP_MAIN:-0}" = 1 ] || main "$@"
