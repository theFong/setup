#!/usr/bin/env bash
#
# codex-setup.sh — install a localhost model router so Codex CLI and Codex
# Desktop can use OpenAI/ChatGPT and Brev Webster models from one picker.
#
# One-liner (the env prefix belongs on bash, to the right of the pipe):
#   curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/codex-setup.sh \
#     | WEBSTER_API_KEY=sk-... bash
#
# The installer:
#   * installs the dependency-free Node.js proxy under ~/.codex/model-proxy
#   * discovers the models accessible to the supplied Webster key
#   * stores the key and discovered models in ~/.codex/model-proxy/webster.json (mode 0600)
#   * installs a user LaunchAgent (macOS) or systemd user service (Linux)
#   * builds a combined OpenAI + Webster model catalog from the existing Codex login
#   * merge-safely configures ~/.codex/config.toml for CLI and Desktop
#   * verifies source, secret permissions, endpoint, service, catalog, and config
#
# Run `codex login` before this installer. Re-running is safe. Codex Desktop
# must be fully quit and reopened after a successful install because the model
# catalog is loaded at app-server startup.
#
# Usage:
#   ./codex-setup.sh                   install, configure, and verify
#   ./codex-setup.sh --check           verify only; change nothing
#   ./codex-setup.sh --key-file PATH   read the Webster key from PATH
#
# Env: WEBSTER_API_KEY, CODEX_WEBSTER_BASE_URL, CODEX_MODEL_PROXY_PORT,
#      CODEX_SETUP_REF, CODEX_SETUP_RAW_BASE_URL, CODEX_SETUP_CODEX_DIR,
#      CODEX_SETUP_SOURCE_DIR, CODEX_SETUP_SKIP_ENDPOINT_CHECK

set -euo pipefail

DEFAULT_WEBSTER_BASE_URL="https://webster-models-extnode-3gdrajbr0hiykknxzitck9yaiwo.apps.run.brev.nvidia.com/v1"
WEBSTER_BASE_URL="${CODEX_WEBSTER_BASE_URL:-$DEFAULT_WEBSTER_BASE_URL}"
WEBSTER_BASE_URL="${WEBSTER_BASE_URL%/}"
PROXY_HOST="127.0.0.1"
PROXY_PORT="${CODEX_MODEL_PROXY_PORT:-4815}"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}/v1"
HEALTH_URL="http://${PROXY_HOST}:${PROXY_PORT}/healthz"

CODEX_DIR="${CODEX_SETUP_CODEX_DIR:-${CODEX_HOME:-$HOME/.codex}}"
PROXY_DIR="$CODEX_DIR/model-proxy"
WEBSTER_CONFIG="$PROXY_DIR/webster.json"
CATALOG_FILE="$CODEX_DIR/openai-webster-models.json"
CODEX_CONFIG="$CODEX_DIR/config.toml"
AUTH_FILE="$CODEX_DIR/auth.json"

SETUP_REF="${CODEX_SETUP_REF:-main}"
RAW_BASE_URL="${CODEX_SETUP_RAW_BASE_URL:-https://raw.githubusercontent.com/theFong/setup/$SETUP_REF}"
LOCAL_SOURCE_DIR="${CODEX_SETUP_SOURCE_DIR:-}"
SOURCE_FILES="proxy.mjs write-webster-config.mjs write-catalog.mjs"

NODE_MIN_MAJOR=20
OS=""
PM=""
SUDO=""
APT_UPDATED=0
FAILED=""
CHECK_ONLY=0
KEY_FILE=""
API_KEY="${WEBSTER_API_KEY:-}"
INSTALL_CHANGED=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

record_failure() {
  local item="$1"
  case " $FAILED " in
    *" $item "*) ;;
    *) FAILED="$FAILED $item" ;;
  esac
}

usage() {
  cat <<'USAGE'
codex-setup.sh — add OpenAI/ChatGPT and Webster models to Codex CLI + Desktop.

  ./codex-setup.sh                   install, configure, and verify
  ./codex-setup.sh --check           verify only; change nothing
  ./codex-setup.sh --key-file PATH   read the Webster key from PATH

One-liner (env prefix goes on bash, not curl):
  curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/codex-setup.sh \
    | WEBSTER_API_KEY=sk-... bash

Run `codex login` first. After setup, fully quit and reopen Codex Desktop.

Env: WEBSTER_API_KEY, CODEX_WEBSTER_BASE_URL, CODEX_MODEL_PROXY_PORT,
     CODEX_SETUP_REF, CODEX_SETUP_RAW_BASE_URL, CODEX_SETUP_CODEX_DIR,
     CODEX_SETUP_SOURCE_DIR, CODEX_SETUP_SKIP_ENDPOINT_CHECK
USAGE
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --check|--verify-only) CHECK_ONLY=1 ;;
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

key_from_config() {
  [ -f "$WEBSTER_CONFIG" ] || return 0
  node -e '
    const fs = require("fs");
    try {
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).apiKey;
      if (typeof value === "string") process.stdout.write(value);
    } catch {}
  ' "$WEBSTER_CONFIG"
}

resolve_api_key() {
  if [ -n "$KEY_FILE" ]; then
    [ -r "$KEY_FILE" ] || { warn "cannot read key file: $KEY_FILE"; return 1; }
    IFS= read -r API_KEY < "$KEY_FILE" || true
  fi
  if [ -z "$API_KEY" ]; then
    API_KEY=$(key_from_config)
    [ -n "$API_KEY" ] && ok "reusing the installed Webster key"
  fi
  if [ -z "$API_KEY" ]; then
    [ "$CHECK_ONLY" = 1 ] && { warn "no installed Webster key"; return 1; }
    if [ -r /dev/tty ]; then
      printf 'Webster API key (sk-...): ' >/dev/tty
      IFS= read -rs API_KEY </dev/tty || true
      printf '\n' >/dev/tty
    fi
  fi
  [ -n "$API_KEY" ] || {
    warn "no Webster key; set WEBSTER_API_KEY or use --key-file"
    return 1
  }
}

assert_webster_endpoint() {
  if [ "${CODEX_SETUP_SKIP_ENDPOINT_CHECK:-0}" = 1 ]; then
    ok "skipping Webster endpoint check (CODEX_SETUP_SKIP_ENDPOINT_CHECK=1)"
    return 0
  fi
  WEBSTER_API_KEY="$API_KEY" WEBSTER_BASE_URL="$WEBSTER_BASE_URL" \
    node "$PROXY_DIR/write-webster-config.mjs" --check "$WEBSTER_CONFIG" || {
      warn "Webster access changed or the endpoint rejected the key; re-run setup to refresh"
      return 1
    }
  ok "Webster endpoint access matches the installed model list"
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

write_webster_config() {
  local next="$WEBSTER_CONFIG.next-$$" models_file=""
  if [ "${CODEX_SETUP_SKIP_ENDPOINT_CHECK:-0}" = 1 ]; then
    [ -f "$WEBSTER_CONFIG" ] || {
      warn "cannot skip model discovery on a fresh install"
      return 1
    }
    models_file="$WEBSTER_CONFIG"
  fi
  WEBSTER_API_KEY="$API_KEY" WEBSTER_BASE_URL="$WEBSTER_BASE_URL" \
  WEBSTER_MODELS_FILE="$models_file" \
    node "$PROXY_DIR/write-webster-config.mjs" "$next"
  if [ -f "$WEBSTER_CONFIG" ] && cmp -s "$next" "$WEBSTER_CONFIG"; then
    rm -f "$next"
    ok "Webster credential config unchanged"
    return 0
  fi
  mv "$next" "$WEBSTER_CONFIG"
  chmod 600 "$WEBSTER_CONFIG"
  INSTALL_CHANGED=1
  ok "wrote $WEBSTER_CONFIG (mode 600)"
}

assert_webster_config() {
  [ -f "$WEBSTER_CONFIG" ] || { warn "missing $WEBSTER_CONFIG"; return 1; }
  [ "$(mode_of "$WEBSTER_CONFIG")" = 600 ] || {
    warn "$WEBSTER_CONFIG must have mode 600"
    return 1
  }
  WEBSTER_API_KEY="$API_KEY" WEBSTER_BASE_URL="$WEBSTER_BASE_URL" node -e '
    const fs = require("fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (value.apiKey !== process.env.WEBSTER_API_KEY) process.exit(1);
    if (value.baseUrl.replace(/\/+$/, "") !== process.env.WEBSTER_BASE_URL.replace(/\/+$/, "")) process.exit(1);
    if (!Array.isArray(value.models) || value.models.length === 0) process.exit(1);
    const ids = new Set();
    for (const model of value.models) {
      if (!model || typeof model.id !== "string" || model.id.length === 0 || ids.has(model.id)) process.exit(1);
      if (typeof model.displayName !== "string" || typeof model.description !== "string") process.exit(1);
      if (model.contextWindow !== undefined && (!Number.isSafeInteger(model.contextWindow) || model.contextWindow <= 0)) process.exit(1);
      ids.add(model.id);
    }
  ' "$WEBSTER_CONFIG" || { warn "Webster credential config does not match"; return 1; }
  ok "Webster credential and discovered model config is valid and private"
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
  config_xml=$(printf '%s' "$WEBSTER_CONFIG" | xml_escape)
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
    <key>WEBSTER_MODELS_CONFIG</key><string>$config_xml</string>
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
  config_unit=$(printf '%s' "$WEBSTER_CONFIG" | systemd_escape)
  mkdir -p "$units"
  temporary=$(mktemp)
  cat > "$temporary" <<EOF
[Unit]
Description=Codex OpenAI and Webster model proxy
After=network-online.target

[Service]
Type=simple
ExecStart="$node_unit" "$proxy_unit"
Environment="WEBSTER_MODELS_CONFIG=$config_unit"
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
  [ -f "$AUTH_FILE" ] || {
    warn "Codex login not found at $AUTH_FILE; run 'codex login' and re-run setup"
    return 1
  }
  CODEX_MODEL_PROXY_CODEX_DIR="$CODEX_DIR" \
  CODEX_AUTH_FILE="$AUTH_FILE" \
  CODEX_MODEL_CATALOG_FILE="$CATALOG_FILE" \
  CODEX_MODEL_PROXY_URL="$PROXY_URL" \
    node "$PROXY_DIR/write-catalog.mjs"
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
    const websterIds = new Set(config.models.map((model) => model.id));
    if (required.size || !models.some((model) => !websterIds.has(model.slug))) process.exit(1);
  ' "$CATALOG_FILE" "$WEBSTER_CONFIG" || {
    warn "combined catalog is invalid or missing OpenAI/Webster models"
    return 1
  }
  ok "combined catalog has OpenAI and every discovered Webster model"
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
        if ($0 == "[model_providers.openai_webster]") {
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
    printf 'model_provider = "openai_webster"\n'
    printf 'model_catalog_json = "%s"\n\n' "$catalog_toml"
    cat "$cleaned"
    printf '\n# Managed by https://github.com/theFong/setup/blob/main/codex-setup.sh\n'
    printf '[model_providers.openai_webster]\n'
    printf 'name = "OpenAI + Webster"\n'
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
  [ "$top_values" = "model_provider=\"openai_webster\"|\"$CATALOG_FILE\"" ] || {
    warn "Codex top-level provider/catalog settings are missing or incorrect"
    return 1
  }
  section_count=$(grep -c '^\[model_providers\.openai_webster\]$' "$CODEX_CONFIG" || true)
  [ "$section_count" = 1 ] || { warn "Codex provider section count is $section_count, expected 1"; return 1; }
  awk -v url="$PROXY_URL" '
    $0 == "[model_providers.openai_webster]" { in_provider = 1; next }
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
  assert_webster_config || record_failure webster-config
  assert_webster_endpoint || record_failure webster-endpoint
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
  log "Codex OpenAI + Webster setup is healthy"
  printf '\nFully quit and reopen Codex Desktop, then choose a Webster or OpenAI model.\n'
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
  resolve_api_key || { record_failure webster-key; summary || true; return 1; }

  if [ "$CHECK_ONLY" = 1 ]; then
    verify_all
    summary
    return
  fi

  install_proxy_sources || { record_failure proxy-source; summary || true; return 1; }
  assert_proxy_sources || { record_failure proxy-source; summary || true; return 1; }
  write_webster_config || { record_failure webster-config; summary || true; return 1; }
  assert_webster_config || { record_failure webster-config; summary || true; return 1; }
  assert_webster_endpoint || { record_failure webster-endpoint; summary || true; return 1; }
  install_service || { record_failure proxy-service; summary || true; return 1; }
  assert_service || { record_failure proxy-service; summary || true; return 1; }
  generate_catalog || { record_failure model-catalog; summary || true; return 1; }
  assert_catalog || { record_failure model-catalog; summary || true; return 1; }
  merge_codex_config "$CODEX_CONFIG" || { record_failure codex-config; summary || true; return 1; }
  assert_codex_config || record_failure codex-config
  summary
}

if [ "${SETUP_SKIP_MAIN:-0}" != 1 ]; then
  main "$@"
fi
