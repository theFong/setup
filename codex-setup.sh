#!/usr/bin/env bash
#
# codex-setup.sh — install a localhost model router so Codex CLI and Codex
# Desktop can use OpenAI/ChatGPT and another Responses-compatible model API
# from one picker.
#
# One-liner (the env prefix belongs on bash, to the right of the pipe):
#   curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/codex-setup.sh \
#     | CODEX_MODEL_API_BASE_URL=https://models.example.com/v1 \
#       CODEX_MODEL_API_KEY=sk-... CODEX_MODEL_API_NAME=Example bash
#
# The installer:
#   * installs the dependency-free Node.js proxy under ~/.codex/model-proxy
#   * discovers the models accessible to the supplied model API key
#   * stores the key and discovered models in ~/.codex/model-proxy/upstream.json (mode 0600)
#   * installs a user LaunchAgent (macOS) or systemd user service (Linux)
#   * builds a combined OpenAI + custom model catalog from the existing Codex login
#   * merge-safely configures ~/.codex/config.toml for CLI and Desktop
#   * detects a running app-server with stale model settings and prints reload steps
#   * verifies source, secret permissions, endpoint, service, catalog, and config
#
# Run `codex login` before this installer. Re-running is safe. When model
# settings change beneath a running app-server, the installer prints the exact
# restart and Codex Desktop reconnect steps required to load them.
#
# Usage:
#   ./codex-setup.sh                   install, configure, and verify
#   ./codex-setup.sh --check           verify only; change nothing
#   ./codex-setup.sh --restart-app-server  refresh and restart a stale app-server
#   ./codex-setup.sh --key-file PATH   read the model API key from PATH
#
# Env: CODEX_MODEL_API_KEY, CODEX_MODEL_API_BASE_URL, CODEX_MODEL_API_NAME,
#      CODEX_MODEL_PROXY_PORT, CODEX_SETUP_REF, CODEX_SETUP_RAW_BASE_URL,
#      CODEX_SETUP_CODEX_DIR, CODEX_SETUP_SOURCE_DIR,
#      CODEX_SETUP_SKIP_ENDPOINT_CHECK
# Backward-compatible aliases: WEBSTER_API_KEY, CODEX_WEBSTER_BASE_URL

set -euo pipefail

DEFAULT_WEBSTER_BASE_URL="https://webster-models-extnode-3gdrajbr0hiykknxzitck9yaiwo.apps.run.brev.nvidia.com/v1"
PROXY_HOST="127.0.0.1"
PROXY_PORT="${CODEX_MODEL_PROXY_PORT:-4815}"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}/v1"
HEALTH_URL="http://${PROXY_HOST}:${PROXY_PORT}/healthz"

CODEX_DIR="${CODEX_SETUP_CODEX_DIR:-${CODEX_HOME:-$HOME/.codex}}"
PROXY_DIR="$CODEX_DIR/model-proxy"
MODEL_API_CONFIG="$PROXY_DIR/upstream.json"
LEGACY_WEBSTER_CONFIG="$PROXY_DIR/webster.json"
CATALOG_FILE="$CODEX_DIR/openai-custom-models.json"
CODEX_CONFIG="$CODEX_DIR/config.toml"
AUTH_FILE="$CODEX_DIR/auth.json"
RELOAD_MARKER="$CODEX_DIR/app-server-model-reload-required"

SETUP_REF="${CODEX_SETUP_REF:-main}"
RAW_BASE_URL="${CODEX_SETUP_RAW_BASE_URL:-https://raw.githubusercontent.com/theFong/setup/$SETUP_REF}"
LOCAL_SOURCE_DIR="${CODEX_SETUP_SOURCE_DIR:-}"
SOURCE_FILES="proxy.mjs write-model-api-config.mjs write-catalog.mjs"

NODE_MIN_MAJOR=20
OS=""
PM=""
SUDO=""
APT_UPDATED=0
FAILED=""
CHECK_ONLY=0
RESTART_APP_SERVER=0
KEY_FILE=""
API_KEY=""
API_BASE_URL=""
API_NAME=""
GENERIC_INPUT=0
LEGACY_WEBSTER_INPUT=0
INSTALL_CHANGED=0

if [ "${CODEX_MODEL_API_KEY+x}" = x ] ||
   [ "${CODEX_MODEL_API_BASE_URL+x}" = x ] ||
   [ "${CODEX_MODEL_API_NAME+x}" = x ]; then
  GENERIC_INPUT=1
fi
if [ "${WEBSTER_API_KEY+x}" = x ] || [ "${CODEX_WEBSTER_BASE_URL+x}" = x ]; then
  LEGACY_WEBSTER_INPUT=1
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

resolve_codex_binary() {
  local candidate
  if [ -n "${CODEX_SETUP_CODEX_BIN:-}" ] && [ -x "$CODEX_SETUP_CODEX_BIN" ]; then
    printf '%s' "$CODEX_SETUP_CODEX_BIN"
    return 0
  fi
  if have codex; then
    command -v codex
    return 0
  fi
  for candidate in \
    "$CODEX_DIR/packages/standalone/current/codex" \
    "/Applications/ChatGPT.app/Contents/Resources/codex"
  do
    if [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

codex_app_server_processes() {
  ps -ax -o pid= -o command= 2>/dev/null | awk '
    /[c]odex/ && /app-server/ && !/app-server proxy/ && !/app-server daemon/ {
      print $1
    }
  '
}

codex_daemon_state() {
  local codex_bin daemon_json state
  codex_bin=$(resolve_codex_binary) || { printf 'unavailable'; return 0; }
  daemon_json=$("$codex_bin" app-server daemon version 2>/dev/null) || {
    if [ -n "$(codex_app_server_processes)" ]; then
      printf 'desktop'
    else
      printf 'stopped'
    fi
    return 0
  }
  state=$(printf '%s' "$daemon_json" | node -e '
    const fs = require("fs");
    try {
      const value = JSON.parse(fs.readFileSync(0, "utf8"));
      if (value.status !== "running") process.stdout.write("stopped");
      else if (value.backend === "pid" || value.managedCodexVersion) process.stdout.write("managed");
      else process.stdout.write("unmanaged");
    } catch {
      process.stdout.write("unavailable");
    }
  ')
  if [ "$state" = stopped ] && [ -n "$(codex_app_server_processes)" ]; then
    printf 'desktop'
  else
    printf '%s' "$state"
  fi
}

process_command() {
  ps -p "$1" -o command= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

process_parent_pid() {
  ps -p "$1" -o ppid= 2>/dev/null | tr -d '[:space:]'
}

process_uid() {
  ps -p "$1" -o uid= 2>/dev/null | tr -d '[:space:]'
}

process_is_active() {
  local state
  state=$(ps -p "$1" -o stat= 2>/dev/null | tr -d '[:space:]')
  case "$state" in ''|Z*) return 1 ;; *) return 0 ;; esac
}

unmanaged_app_server_pids() {
  local socket_file owner_pids pid parent command current_uid candidates
  socket_file="$CODEX_DIR/app-server-control/app-server-control.sock"
  have lsof || { warn "lsof is required to identify the unmanaged app-server safely"; return 1; }
  [ -S "$socket_file" ] || { warn "Codex app-server control socket was not found"; return 1; }
  owner_pids=$(lsof -t "$socket_file" 2>/dev/null | sort -n -u) || true
  [ -n "$owner_pids" ] || { warn "no process owns the Codex app-server control socket"; return 1; }

  current_uid=$(id -u)
  candidates=""
  for pid in $owner_pids; do
    case "$pid" in *[!0-9]*|'') warn "invalid app-server PID: $pid"; return 1 ;; esac
    [ "$(process_uid "$pid")" = "$current_uid" ] || {
      warn "refusing to stop app-server PID $pid owned by another user"
      return 1
    }
    command=$(process_command "$pid")
    case "$command" in
      *codex*app-server*--listen*unix://*) ;;
      *) warn "refusing to stop unexpected control-socket owner: $command"; return 1 ;;
    esac
    candidates="$candidates $pid"

    parent=$(process_parent_pid "$pid")
    case "$parent" in ''|*[!0-9]*|0|1) continue ;; esac
    if [ "$(process_uid "$parent")" = "$current_uid" ]; then
      command=$(process_command "$parent")
      case "$command" in
        *codex*app-server*--listen*unix://*) candidates="$candidates $parent" ;;
      esac
    fi
  done
  printf '%s\n' "$candidates" | awk '{ for (i = 1; i <= NF; i++) print $i }' | sort -n -u
}

terminate_unmanaged_app_server() {
  local pids pid remaining attempt
  if ! have lsof; then
    log "installing lsof to inspect the legacy Codex control socket"
    pm_install lsof || return 1
    hash -r 2>/dev/null || true
  fi
  pids=$(unmanaged_app_server_pids) || return 1
  [ -n "$pids" ] || { warn "no validated unmanaged app-server process was found"; return 1; }

  for pid in $pids; do
    if process_is_active "$pid" && ! kill -TERM "$pid" 2>/dev/null; then
      process_is_active "$pid" || continue
      warn "could not stop app-server PID $pid"
      return 1
    fi
  done
  attempt=0
  while [ "$attempt" -lt 20 ]; do
    remaining=""
    for pid in $pids; do
      process_is_active "$pid" && remaining="$remaining $pid"
    done
    [ -z "$remaining" ] && return 0
    sleep 0.25
    attempt=$((attempt + 1))
  done
  warn "app-server did not stop after SIGTERM (PIDs:${remaining})"
  return 1
}

mark_codex_client_reload() {
  touch "$RELOAD_MARKER"
  chmod 600 "$RELOAD_MARKER"
}

report_new_codex_task() {
  printf 'Start a new Codex task before selecting a custom model. '
  printf 'Existing tasks keep the model provider they started with.\n'
}

restart_codex_app_server() {
  local state codex_bin
  [ -f "$RELOAD_MARKER" ] || { ok "Codex app-server does not need a model reload"; return 0; }
  state=$(codex_daemon_state)
  case "$state" in
    managed)
      codex_bin=$(resolve_codex_binary) || {
        warn "Codex binary was not found; cannot restart the managed app-server"
        return 1
      }
      "$codex_bin" app-server daemon restart || {
        warn "Codex app-server daemon restart failed"
        return 1
      }
      rm -f "$RELOAD_MARKER"
      ok "restarted the managed Codex app-server"
      printf 'Disconnect and reconnect this machine in Codex Desktop if it is already connected.\n'
      report_new_codex_task
      ;;
    unmanaged)
      log "Stopping the validated owner of the legacy Codex control socket"
      terminate_unmanaged_app_server || return 1
      rm -f "$RELOAD_MARKER"
      ok "stopped the unmanaged Codex app-server; Desktop can start a fresh one"
      printf 'Reconnect this machine in Codex Desktop.\n'
      report_new_codex_task
      ;;
    desktop)
      warn "the Codex app-server is owned by the Desktop app and cannot be restarted safely here"
      warn "fully quit and reopen Codex Desktop to load the new models"
      return 1
      ;;
    stopped)
      rm -f "$RELOAD_MARKER"
      ok "Codex app-server is stopped; it will load the new models on its next start"
      report_new_codex_task
      ;;
    *)
      warn "Codex app-server state could not be inspected; refusing to stop an unknown process"
      return 1
      ;;
  esac
}

report_codex_client_reload() {
  local state pid_file socket_file
  [ -f "$RELOAD_MARKER" ] || return 0
  state=$(codex_daemon_state)
  pid_file="$CODEX_DIR/app-server-daemon/app-server.pid"
  socket_file="$CODEX_DIR/app-server-control/app-server-control.sock"

  if [ "$state" = managed ] && [ -f "$pid_file" ] && [ "$pid_file" -nt "$RELOAD_MARKER" ]; then
    [ "$CHECK_ONLY" = 1 ] || rm -f "$RELOAD_MARKER"
    printf '\n'
    report_new_codex_task
    return 0
  fi
  if [ "$state" = unmanaged ] && [ -S "$socket_file" ] && [ "$socket_file" -nt "$RELOAD_MARKER" ]; then
    [ "$CHECK_ONLY" = 1 ] || rm -f "$RELOAD_MARKER"
    printf '\n'
    report_new_codex_task
    return 0
  fi
  if [ "$state" = stopped ]; then
    [ "$CHECK_ONLY" = 1 ] || rm -f "$RELOAD_MARKER"
    printf '\nCodex app-server is not running; the new models will load on its next start.\n'
    report_new_codex_task
    return 0
  fi

  printf '\n'
  if [ "$state" = unmanaged ]; then
    warn "a legacy, unmanaged Codex app-server is still using the previous model catalog"
    printf 'On this machine, re-run setup with the explicit restart option:\n\n'
    printf '  curl -fsSL %s/codex-setup.sh | bash -s -- --restart-app-server\n\n' "$RAW_BASE_URL"
    printf 'Then reconnect this machine in Codex Desktop.\n'
  elif [ "$state" = managed ]; then
    warn "the running Codex app-server is still using the previous model catalog"
    printf 'Run on this machine:\n\n'
    printf '  codex app-server daemon restart\n\n'
    printf 'Then disconnect and reconnect this machine in Codex Desktop '
    printf '(or fully quit and reopen Desktop).\n'
  elif [ "$state" = desktop ]; then
    warn "the Codex Desktop app-server is still using the previous model catalog"
    printf 'Fully quit and reopen Codex Desktop to load the new models.\n'
  else
    warn "model settings changed, but the Codex app-server state could not be inspected"
    printf 'Restart the active Codex client before using the new models.\n'
  fi
  report_new_codex_task
}

record_failure() {
  local item="$1"
  case " $FAILED " in
    *" $item "*) ;;
    *) FAILED="$FAILED $item" ;;
  esac
}

usage() {
  cat <<'USAGE'
codex-setup.sh — add OpenAI/ChatGPT and custom API models to Codex CLI + Desktop.

  ./codex-setup.sh                   install, configure, and verify
  ./codex-setup.sh --check           verify only; change nothing
  ./codex-setup.sh --restart-app-server  refresh and restart a stale app-server
  ./codex-setup.sh --key-file PATH   read the model API key from PATH

Generic OpenAI-compatible Responses API (env prefix goes on bash, not curl):
  curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/codex-setup.sh \
    | CODEX_MODEL_API_BASE_URL=https://models.example.com/v1 \
      CODEX_MODEL_API_KEY=sk-... CODEX_MODEL_API_NAME=Example bash

Existing Webster shorthand remains supported:
  curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/codex-setup.sh \
    | WEBSTER_API_KEY=sk-... bash

Run `codex login` first. Setup prints restart/reconnect steps only when needed.

Env: CODEX_MODEL_API_KEY, CODEX_MODEL_API_BASE_URL, CODEX_MODEL_API_NAME,
     CODEX_MODEL_PROXY_PORT, CODEX_SETUP_REF, CODEX_SETUP_RAW_BASE_URL,
     CODEX_SETUP_CODEX_DIR, CODEX_SETUP_SOURCE_DIR,
     CODEX_SETUP_SKIP_ENDPOINT_CHECK
Aliases: WEBSTER_API_KEY, CODEX_WEBSTER_BASE_URL
USAGE
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --check|--verify-only) CHECK_ONLY=1 ;;
      --restart-app-server) RESTART_APP_SERVER=1 ;;
      --key-file)
        shift
        KEY_FILE="${1:-}"
        [ -n "$KEY_FILE" ] || { warn "--key-file needs a path"; return 2; }
        ;;
      -h|--help) usage; return 10 ;;
      *) warn "unknown option: $1"; usage >&2; return 2 ;;
    esac
    shift
  done
  if [ "$CHECK_ONLY" = 1 ] && [ "$RESTART_APP_SERVER" = 1 ]; then
    warn "--check and --restart-app-server cannot be used together"
    return 2
  fi
}

detect_platform() {
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$OS" in
    darwin|linux) ;;
    *) warn "unsupported OS: $OS"; return 1 ;;
  esac
  if [ "$(id -u)" -ne 0 ]; then
    if have sudo; then SUDO="sudo"; else SUDO=""; fi
  fi
}

ensure_package_manager() {
  if [ "$OS" = "darwin" ]; then
    if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
    have brew && PM="brew"
    return 0
  fi
  if have apt-get; then PM="apt"
  elif have dnf; then PM="dnf"
  elif have apk; then PM="apk"
  fi
}

pm_install() {
  [ -n "$PM" ] || { warn "no supported package manager found; cannot install $*"; return 1; }
  if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ] && [ "$PM" != "brew" ]; then
    warn "installing $* needs root, but sudo is unavailable"
    return 1
  fi
  case "$PM" in
    brew) brew install "$@" ;;
    apt)
      [ "$APT_UPDATED" = 1 ] || { $SUDO apt-get update -y && APT_UPDATED=1; }
      $SUDO apt-get install -y "$@"
      ;;
    dnf) $SUDO dnf install -y "$@" ;;
    apk) $SUDO apk add "$@" ;;
  esac
}

node_major() {
  local version
  have node || return 1
  version=$(node --version 2>/dev/null) || return 1
  version=${version#v}
  version=${version%%.*}
  case "$version" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s' "$version" ;;
  esac
}

node_is_current() {
  local major
  major=$(node_major) || return 1
  [ "$major" -ge "$NODE_MIN_MAJOR" ]
}

install_node() {
  local setup_url
  case "$PM" in
    brew) pm_install node ;;
    apt)
      setup_url="https://deb.nodesource.com/setup_${NODE_MIN_MAJOR}.x"
      if [ -n "$SUDO" ]; then curl -fsSL "$setup_url" | $SUDO -E bash -
      else curl -fsSL "$setup_url" | bash -; fi
      $SUDO apt-get install -y nodejs
      ;;
    dnf)
      setup_url="https://rpm.nodesource.com/setup_${NODE_MIN_MAJOR}.x"
      if [ -n "$SUDO" ]; then curl -fsSL "$setup_url" | $SUDO bash -
      else curl -fsSL "$setup_url" | bash -; fi
      $SUDO dnf install -y nodejs
      ;;
    apk) pm_install nodejs npm ;;
    *) warn "no supported package manager for Node.js"; return 1 ;;
  esac
}

ensure_node() {
  if node_is_current; then
    ok "node $(node --version)"
    return 0
  fi
  [ "$CHECK_ONLY" = 1 ] && { warn "Node.js >= $NODE_MIN_MAJOR is required"; return 1; }
  log "installing Node.js >= $NODE_MIN_MAJOR"
  install_node || return 1
  hash -r 2>/dev/null || true
  node_is_current || { warn "Node.js >= $NODE_MIN_MAJOR is unavailable after installation"; return 1; }
  ok "node $(node --version)"
}

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

installed_model_api_config() {
  if [ -f "$MODEL_API_CONFIG" ]; then
    printf '%s' "$MODEL_API_CONFIG"
  elif [ -f "$LEGACY_WEBSTER_CONFIG" ]; then
    printf '%s' "$LEGACY_WEBSTER_CONFIG"
  fi
}

config_value() {
  local config="$1" field="$2"
  [ -f "$config" ] || return 0
  node -e '
    const fs = require("fs");
    try {
      const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const provider = config?.providers?.modelApi ?? config?.providers?.webster ?? config;
      const value = provider?.[process.argv[2]];
      if (typeof value === "string") process.stdout.write(value);
    } catch {}
  ' "$config" "$field"
}

resolve_api_config() {
  local installed="" installed_key="" installed_base_url="" installed_name=""
  installed=$(installed_model_api_config)
  if [ -n "$installed" ]; then
    installed_key=$(config_value "$installed" apiKey)
    installed_base_url=$(config_value "$installed" baseUrl)
    installed_name=$(config_value "$installed" name)
    [ -n "$installed_name" ] || installed_name="Webster"
  fi

  if [ "$GENERIC_INPUT" = 1 ]; then
    API_BASE_URL="${CODEX_MODEL_API_BASE_URL:-$installed_base_url}"
    if [ -n "${CODEX_MODEL_API_NAME:-}" ]; then
      API_NAME="$CODEX_MODEL_API_NAME"
    elif [ -n "$installed_name" ] &&
         [ "${installed_base_url%/}" = "${API_BASE_URL%/}" ]; then
      API_NAME="$installed_name"
    else
      API_NAME="Custom"
    fi
    API_KEY="${CODEX_MODEL_API_KEY:-}"
    if [ -z "$API_KEY" ] && [ -n "$installed_key" ] &&
       [ "${installed_base_url%/}" = "${API_BASE_URL%/}" ]; then
      API_KEY="$installed_key"
    fi
    [ -n "$API_BASE_URL" ] || {
      warn "CODEX_MODEL_API_BASE_URL is required for a custom model API"
      return 1
    }
  elif [ "$LEGACY_WEBSTER_INPUT" = 1 ]; then
    API_BASE_URL="${CODEX_WEBSTER_BASE_URL:-$DEFAULT_WEBSTER_BASE_URL}"
    API_NAME="Webster"
    API_KEY="${WEBSTER_API_KEY:-}"
  elif [ -n "$installed" ]; then
    API_BASE_URL="$installed_base_url"
    API_NAME="$installed_name"
    API_KEY="$installed_key"
  else
    API_BASE_URL="$DEFAULT_WEBSTER_BASE_URL"
    API_NAME="Webster"
  fi

  [ -n "$API_NAME" ] || { warn "model API name must not be empty"; return 1; }
  case "$API_NAME" in
    *$'\n'*|*$'\r'*) warn "model API name must fit on one line"; return 1 ;;
  esac
  API_BASE_URL="${API_BASE_URL%/}"
  case "$API_BASE_URL" in
    http://*|https://*) ;;
    *) warn "model API base URL must start with http:// or https://"; return 1 ;;
  esac
  if [ -n "$KEY_FILE" ]; then
    [ -r "$KEY_FILE" ] || { warn "cannot read key file: $KEY_FILE"; return 1; }
    IFS= read -r API_KEY < "$KEY_FILE" || true
  fi
  [ -n "$API_KEY" ] && [ -n "$installed_key" ] && [ "$API_KEY" = "$installed_key" ] &&
    ok "reusing the installed $API_NAME key"
  if [ -z "$API_KEY" ]; then
    [ "$CHECK_ONLY" = 1 ] && { warn "no installed $API_NAME key"; return 1; }
    if [ -r /dev/tty ]; then
      printf '%s API key: ' "$API_NAME" >/dev/tty
      IFS= read -rs API_KEY </dev/tty || true
      printf '\n' >/dev/tty
    fi
  fi
  [ -n "$API_KEY" ] || {
    warn "no model API key; set CODEX_MODEL_API_KEY or use --key-file"
    return 1
  }
}

assert_model_api_endpoint() {
  if [ "${CODEX_SETUP_SKIP_ENDPOINT_CHECK:-0}" = 1 ]; then
    ok "skipping $API_NAME endpoint check (CODEX_SETUP_SKIP_ENDPOINT_CHECK=1)"
    return 0
  fi
  CODEX_MODEL_API_KEY="$API_KEY" CODEX_MODEL_API_BASE_URL="$API_BASE_URL" \
  CODEX_MODEL_API_NAME="$API_NAME" \
    node "$PROXY_DIR/write-model-api-config.mjs" --check "$MODEL_API_CONFIG" || {
      warn "$API_NAME access changed or the endpoint rejected the key; re-run setup to refresh"
      return 1
    }
  ok "$API_NAME endpoint access matches the installed model list"
}

install_one_source() {
  local name="$1" source temporary target
  target="$PROXY_DIR/$name"
  temporary=$(mktemp)
  if [ -n "$LOCAL_SOURCE_DIR" ]; then
    source="$LOCAL_SOURCE_DIR/$name"
    [ -f "$source" ] || { rm -f "$temporary"; warn "missing source file: $source"; return 1; }
    cp "$source" "$temporary"
  else
    source="$RAW_BASE_URL/codex-model-proxy/$name"
    curl -fsSL "$source" -o "$temporary" || {
      rm -f "$temporary"
      warn "failed to download $source"
      return 1
    }
  fi
  chmod 755 "$temporary"
  if ! node --input-type=module --check < "$temporary" >/dev/null 2>&1; then
    rm -f "$temporary"
    warn "downloaded $name failed Node.js syntax validation"
    return 1
  fi
  if [ -f "$target" ] && cmp -s "$temporary" "$target"; then
    rm -f "$temporary"
    ok "$name unchanged"
    return 0
  fi
  mv "$temporary" "$target"
  INSTALL_CHANGED=1
  ok "installed $target"
}

install_proxy_sources() {
  local name
  mkdir -p "$PROXY_DIR" "$CODEX_DIR/log"
  for name in $SOURCE_FILES; do
    install_one_source "$name" || return 1
  done
}

assert_proxy_sources() {
  local name
  for name in $SOURCE_FILES; do
    [ -s "$PROXY_DIR/$name" ] || { warn "missing $PROXY_DIR/$name"; return 1; }
    node --check "$PROXY_DIR/$name" >/dev/null || {
      warn "$PROXY_DIR/$name failed Node.js syntax validation"
      return 1
    }
  done
  ok "proxy source files pass Node.js syntax validation"
}

write_model_api_config() {
  local next="$MODEL_API_CONFIG.next-$$" models_file=""
  if [ "${CODEX_SETUP_SKIP_ENDPOINT_CHECK:-0}" = 1 ]; then
    models_file=$(installed_model_api_config)
    [ -n "$models_file" ] || {
      warn "cannot skip model discovery on a fresh install"
      return 1
    }
  fi
  if ! CODEX_MODEL_API_KEY="$API_KEY" CODEX_MODEL_API_BASE_URL="$API_BASE_URL" \
    CODEX_MODEL_API_NAME="$API_NAME" CODEX_MODEL_API_MODELS_FILE="$models_file" \
    node "$PROXY_DIR/write-model-api-config.mjs" "$next"; then
    rm -f "$next"
    return 1
  fi
  if [ -f "$MODEL_API_CONFIG" ] && cmp -s "$next" "$MODEL_API_CONFIG"; then
    rm -f "$next"
    ok "$API_NAME credential config unchanged"
    return 0
  fi
  mv "$next" "$MODEL_API_CONFIG"
  chmod 600 "$MODEL_API_CONFIG"
  INSTALL_CHANGED=1
  ok "wrote $MODEL_API_CONFIG (mode 600)"
}

assert_model_api_config() {
  [ -f "$MODEL_API_CONFIG" ] || { warn "missing $MODEL_API_CONFIG"; return 1; }
  [ "$(mode_of "$MODEL_API_CONFIG")" = 600 ] || {
    warn "$MODEL_API_CONFIG must have mode 600"
    return 1
  }
  CODEX_MODEL_API_KEY="$API_KEY" CODEX_MODEL_API_BASE_URL="$API_BASE_URL" \
  CODEX_MODEL_API_NAME="$API_NAME" node -e '
    const fs = require("fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (value.name !== process.env.CODEX_MODEL_API_NAME) process.exit(1);
    if (value.apiKey !== process.env.CODEX_MODEL_API_KEY) process.exit(1);
    if (value.baseUrl.replace(/\/+$/, "") !== process.env.CODEX_MODEL_API_BASE_URL.replace(/\/+$/, "")) process.exit(1);
    if (!Array.isArray(value.models) || value.models.length === 0) process.exit(1);
    const ids = new Set();
    for (const model of value.models) {
      if (!model || typeof model.id !== "string" || model.id.length === 0 || ids.has(model.id)) process.exit(1);
      if (typeof model.displayName !== "string" || typeof model.description !== "string") process.exit(1);
      if (model.contextWindow !== undefined && (!Number.isSafeInteger(model.contextWindow) || model.contextWindow <= 0)) process.exit(1);
      ids.add(model.id);
    }
  ' "$MODEL_API_CONFIG" || { warn "$API_NAME credential config does not match"; return 1; }
  ok "$API_NAME credential and discovered model config is valid and private"
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

install_launch_agent() {
  local label="com.thefong.codex-model-proxy" legacy_label="com.alecf.codex-model-proxy"
  local agents="$HOME/Library/LaunchAgents"
  local plist="$agents/$label.plist"
  local legacy="$agents/$legacy_label.plist"
  local domain node_path temporary
  local node_xml proxy_xml config_xml stdout_xml stderr_xml
  domain="gui/$(id -u)"
  node_path=$(command -v node)
  mkdir -p "$agents"

  # Migrate the development-only launch agent used before this installer was
  # published. Move its file aside so the operation remains recoverable.
  if launchctl print "$domain/$legacy_label" >/dev/null 2>&1; then
    launchctl bootout "$domain/$legacy_label" >/dev/null 2>&1 || true
  fi
  if [ -f "$legacy" ]; then
    local disabled="$legacy.disabled-by-codex-setup"
    [ -e "$disabled" ] && disabled="$disabled.$$"
    mv "$legacy" "$disabled"
    log "disabled legacy $legacy_label launch agent"
  fi

  node_xml=$(printf '%s' "$node_path" | xml_escape)
  proxy_xml=$(printf '%s' "$PROXY_DIR/proxy.mjs" | xml_escape)
  config_xml=$(printf '%s' "$MODEL_API_CONFIG" | xml_escape)
  stdout_xml=$(printf '%s' "$CODEX_DIR/log/model-proxy.log" | xml_escape)
  stderr_xml=$(printf '%s' "$CODEX_DIR/log/model-proxy.error.log" | xml_escape)
  temporary=$(mktemp)
  cat > "$temporary" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$node_xml</string><string>$proxy_xml</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CODEX_MODEL_API_CONFIG</key><string>$config_xml</string>
    <key>CODEX_MODEL_PROXY_HOST</key><string>$PROXY_HOST</string>
    <key>CODEX_MODEL_PROXY_PORT</key><string>$PROXY_PORT</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$stdout_xml</string>
  <key>StandardErrorPath</key><string>$stderr_xml</string>
</dict>
</plist>
EOF
  if [ ! -f "$plist" ] || ! cmp -s "$temporary" "$plist"; then
    mv "$temporary" "$plist"
    chmod 644 "$plist"
    INSTALL_CHANGED=1
    ok "installed $plist"
  else
    rm -f "$temporary"
    ok "launch agent unchanged"
  fi

  if launchctl print "$domain/$label" >/dev/null 2>&1; then
    if [ "$INSTALL_CHANGED" = 1 ]; then
      launchctl kickstart -k "$domain/$label"
    fi
  else
    launchctl bootstrap "$domain" "$plist"
  fi
}

systemd_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g'
}

install_systemd_service() {
  local units="$HOME/.config/systemd/user"
  local unit="$units/codex-model-proxy.service"
  local node_path temporary node_unit proxy_unit config_unit
  have systemctl || { warn "systemctl is required on Linux"; return 1; }
  systemctl --user show-environment >/dev/null 2>&1 || {
    warn "the systemd user service manager is unavailable"
    return 1
  }
  node_path=$(command -v node)
  node_unit=$(printf '%s' "$node_path" | systemd_escape)
  proxy_unit=$(printf '%s' "$PROXY_DIR/proxy.mjs" | systemd_escape)
  config_unit=$(printf '%s' "$MODEL_API_CONFIG" | systemd_escape)
  mkdir -p "$units"
  temporary=$(mktemp)
  cat > "$temporary" <<EOF
[Unit]
Description=Codex OpenAI and custom model API proxy
After=network-online.target

[Service]
Type=simple
ExecStart="$node_unit" "$proxy_unit"
Environment="CODEX_MODEL_API_CONFIG=$config_unit"
Environment="CODEX_MODEL_PROXY_HOST=$PROXY_HOST"
Environment="CODEX_MODEL_PROXY_PORT=$PROXY_PORT"
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
  if [ ! -f "$unit" ] || ! cmp -s "$temporary" "$unit"; then
    mv "$temporary" "$unit"
    chmod 644 "$unit"
    INSTALL_CHANGED=1
    ok "installed $unit"
  else
    rm -f "$temporary"
    ok "systemd user service unchanged"
  fi
  systemctl --user daemon-reload
  systemctl --user enable codex-model-proxy.service >/dev/null
  if systemctl --user is-active codex-model-proxy.service >/dev/null 2>&1; then
    if [ "$INSTALL_CHANGED" = 1 ]; then
      systemctl --user restart codex-model-proxy.service
    fi
  else
    systemctl --user start codex-model-proxy.service
  fi
}

install_service() {
  case "$OS" in
    darwin) install_launch_agent ;;
    linux) install_systemd_service ;;
  esac
}

assert_service() {
  case "$OS" in
    darwin)
      launchctl print "gui/$(id -u)/com.thefong.codex-model-proxy" >/dev/null 2>&1 || {
        warn "Codex model proxy launch agent is not loaded"
        return 1
      }
      ;;
    linux)
      systemctl --user is-active codex-model-proxy.service >/dev/null 2>&1 || {
        warn "Codex model proxy systemd user service is not active"
        return 1
      }
      ;;
  esac

  local attempt=0
  while [ "$attempt" -lt 10 ]; do
    attempt=$((attempt + 1))
    if curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
      ok "proxy service is healthy at $HEALTH_URL"
      return 0
    fi
    sleep 0.5
  done
  warn "proxy service did not become healthy at $HEALTH_URL"
  return 1
}

generate_catalog() {
  local candidate
  [ -f "$AUTH_FILE" ] || {
    warn "Codex login not found at $AUTH_FILE; run 'codex login' and re-run setup"
    return 1
  }
  candidate=$(mktemp "$CODEX_DIR/.openai-custom-models.XXXXXX")
  CODEX_MODEL_PROXY_CODEX_DIR="$CODEX_DIR" \
  CODEX_AUTH_FILE="$AUTH_FILE" \
  CODEX_MODEL_CATALOG_FILE="$candidate" \
  CODEX_MODEL_PROXY_URL="$PROXY_URL" \
    node "$PROXY_DIR/write-catalog.mjs" >/dev/null || {
      rm -f "$candidate"
      return 1
    }
  install_catalog_candidate "$candidate"
}

install_catalog_candidate() {
  local candidate="$1"
  [ -s "$candidate" ] || { warn "generated model catalog is empty"; return 1; }
  if [ -f "$CATALOG_FILE" ] && cmp -s "$candidate" "$CATALOG_FILE"; then
    rm -f "$candidate"
    chmod 600 "$CATALOG_FILE"
    ok "combined model catalog unchanged"
    return 0
  fi
  mv "$candidate" "$CATALOG_FILE"
  chmod 600 "$CATALOG_FILE"
  mark_codex_client_reload
  ok "wrote combined model catalog to $CATALOG_FILE"
}

assert_catalog() {
  [ -f "$CATALOG_FILE" ] || { warn "missing combined catalog: $CATALOG_FILE"; return 1; }
  [ "$(mode_of "$CATALOG_FILE")" = 600 ] || {
    warn "$CATALOG_FILE must have mode 600"
    return 1
  }
  node -e '
    const fs = require("fs");
    const catalog = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const required = new Set(config.models.map((model) => model.id));
    const models = Array.isArray(catalog.models) ? catalog.models : [];
    for (const model of models) {
      if (!required.has(model.slug)) continue;
      if (model.visibility !== "list" || typeof model.supports_reasoning_summaries !== "boolean") process.exit(1);
      required.delete(model.slug);
    }
    const modelApiIds = new Set(config.models.map((model) => model.id));
    if (required.size || !models.some((model) => !modelApiIds.has(model.slug))) process.exit(1);
  ' "$CATALOG_FILE" "$MODEL_API_CONFIG" || {
    warn "combined catalog is invalid or missing OpenAI/custom API models"
    return 1
  }
  ok "combined catalog has OpenAI and every discovered $API_NAME model"
}

toml_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

merge_codex_config() {
  local file="$1" stripped cleaned merged catalog_toml
  stripped=$(mktemp)
  cleaned=$(mktemp)
  merged=$(mktemp)
  catalog_toml=$(printf '%s' "$CATALOG_FILE" | toml_escape)

  if [ -f "$file" ]; then
    awk '
      BEGIN { top = 1; skip_provider = 0 }
      /^\[\[?[^]]+/ {
        if ($0 == "[model_providers.openai_custom]" ||
            $0 == "[model_providers.openai_webster]") {
          skip_provider = 1
          top = 0
          next
        }
        if (skip_provider) skip_provider = 0
        top = 0
      }
      skip_provider { next }
      $0 == "# Managed by https://github.com/theFong/setup/blob/main/codex-setup.sh" { next }
      top && /^[[:space:]]*model_provider[[:space:]]*=/ { next }
      top && /^[[:space:]]*model_catalog_json[[:space:]]*=/ { next }
      { print }
    ' "$file" > "$stripped"
  else
    : > "$stripped"
  fi

  # Removing the managed top-level keys and provider block can expose blank
  # lines at either edge. Trim only those edges so re-runs are byte-identical
  # while spacing and comments inside the user's config remain untouched.
  awk '
    /^[[:space:]]*$/ { if (started) pending++; next }
    {
      while (pending > 0) { print ""; pending-- }
      print
      started = 1
    }
  ' "$stripped" > "$cleaned"

  {
    printf 'model_provider = "openai_custom"\n'
    printf 'model_catalog_json = "%s"\n\n' "$catalog_toml"
    cat "$cleaned"
    printf '\n# Managed by https://github.com/theFong/setup/blob/main/codex-setup.sh\n'
    printf '[model_providers.openai_custom]\n'
    printf 'name = "OpenAI + %s"\n' "$(printf '%s' "$API_NAME" | toml_escape)"
    printf 'base_url = "%s"\n' "$PROXY_URL"
    printf 'wire_api = "responses"\n'
    printf 'requires_openai_auth = true\n'
    printf 'supports_websockets = false\n'
  } > "$merged"
  rm -f "$stripped" "$cleaned"

  if [ -f "$file" ] && cmp -s "$merged" "$file"; then
    rm -f "$merged"
    ok "Codex config unchanged"
    return 0
  fi
  [ -f "$file" ] && cp -p "$file" "$file.bak"
  mv "$merged" "$file"
  chmod 600 "$file"
  mark_codex_client_reload
  ok "merged provider settings into $file"
}

assert_codex_config() {
  [ -f "$CODEX_CONFIG" ] || { warn "missing $CODEX_CONFIG"; return 1; }
  local top_values section_count
  top_values=$(awk '
    /^\[\[?[^]]+/ { exit }
    /^[[:space:]]*model_provider[[:space:]]*=/ { gsub(/[[:space:]]/, ""); provider=$0 }
    /^[[:space:]]*model_catalog_json[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); catalog=$0 }
    END { print provider "|" catalog }
  ' "$CODEX_CONFIG")
  [ "$top_values" = "model_provider=\"openai_custom\"|\"$CATALOG_FILE\"" ] || {
    warn "Codex top-level provider/catalog settings are missing or incorrect"
    return 1
  }
  section_count=$(grep -c '^\[model_providers\.openai_custom\]$' "$CODEX_CONFIG" || true)
  [ "$section_count" = 1 ] || { warn "Codex provider section count is $section_count, expected 1"; return 1; }
  awk -v url="$PROXY_URL" '
    $0 == "[model_providers.openai_custom]" { in_provider = 1; next }
    in_provider && /^\[/ { exit }
    in_provider && $0 == "base_url = \"" url "\"" { base = 1 }
    in_provider && $0 == "wire_api = \"responses\"" { api = 1 }
    in_provider && $0 == "requires_openai_auth = true" { auth = 1 }
    END { exit !(base && api && auth) }
  ' "$CODEX_CONFIG" || { warn "Codex provider block is incomplete"; return 1; }
  ok "Codex user configuration points at the combined provider and catalog"
}

verify_all() {
  assert_proxy_sources  || record_failure proxy-source
  assert_model_api_config || record_failure model-api-config
  assert_model_api_endpoint || record_failure model-api-endpoint
  assert_service        || record_failure proxy-service
  assert_catalog        || record_failure model-catalog
  assert_codex_config   || record_failure codex-config
}

summary() {
  echo
  if [ -n "${FAILED# }" ]; then
    warn "setup is incomplete:${FAILED}"
    warn "fix the reported issue and re-run codex-setup.sh"
    return 1
  fi
  log "Codex OpenAI + $API_NAME setup is healthy"
  report_codex_client_reload
  printf 'Re-run this installer to refresh the model catalog; use --check for a read-only health check.\n'
}

main() {
  local parse_status=0
  parse_args "$@" || parse_status=$?
  [ "$parse_status" = 10 ] && return 0
  [ "$parse_status" = 0 ] || return "$parse_status"

  detect_platform || { record_failure platform; summary || true; return 1; }
  ensure_package_manager
  ensure_node || { record_failure node; summary || true; return 1; }
  resolve_api_config || { record_failure model-api-key; summary || true; return 1; }

  if [ "$CHECK_ONLY" = 1 ]; then
    verify_all
    summary
    return
  fi

  install_proxy_sources || { record_failure proxy-source; summary || true; return 1; }
  assert_proxy_sources || { record_failure proxy-source; summary || true; return 1; }
  write_model_api_config || { record_failure model-api-config; summary || true; return 1; }
  assert_model_api_config || { record_failure model-api-config; summary || true; return 1; }
  assert_model_api_endpoint || { record_failure model-api-endpoint; summary || true; return 1; }
  install_service || { record_failure proxy-service; summary || true; return 1; }
  assert_service || { record_failure proxy-service; summary || true; return 1; }
  generate_catalog || { record_failure model-catalog; summary || true; return 1; }
  assert_catalog || { record_failure model-catalog; summary || true; return 1; }
  merge_codex_config "$CODEX_CONFIG" || { record_failure codex-config; summary || true; return 1; }
  assert_codex_config || record_failure codex-config
  if [ "$RESTART_APP_SERVER" = 1 ]; then
    restart_codex_app_server || record_failure app-server-restart
  fi
  summary
}

if [ "${SETUP_SKIP_MAIN:-0}" != 1 ]; then
  main "$@"
fi
