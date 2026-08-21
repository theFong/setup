#!/usr/bin/env bash
#
# claude-code-setup.sh — install a localhost model router so Claude Code can
# use its normal Claude models and Brev Webster models from one /model picker.
#
# One-liner (the env prefix belongs on bash, to the right of the pipe):
#   curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/claude-code-setup.sh \
#     | WEBSTER_API_KEY=sk-... bash
#
# The installer:
#   * installs the dependency-free Node.js proxy under ~/.claude/model-proxy
#   * stores the Webster key in ~/.claude/model-proxy/webster.json (mode 0600)
#   * installs a user LaunchAgent (macOS) or systemd user service (Linux)
#   * merge-safely enables Claude Code gateway model discovery
#   * routes normal Claude models to Anthropic with the existing Claude login
#   * translates only claude-webster-* models to Webster Chat Completions
#   * verifies source, login, secret permissions, endpoint, service, and config
#
# Run `claude` and sign in before this installer. Re-running is safe. Start a
# new Claude Code process after setup, then run `/model` to choose Webster.
#
# Usage:
#   ./claude-code-setup.sh                   install, configure, and verify
#   ./claude-code-setup.sh --desktop         also enable Claude Desktop Gateway mode
#   ./claude-code-setup.sh --desktop --anthropic-oauth
#                                              merge Claude models using Claude Code login
#   ./claude-code-setup.sh --check           verify only; change nothing
#   ./claude-code-setup.sh --key-file PATH   read the Webster key from PATH
#   ./claude-code-setup.sh --anthropic-key-file PATH
#                                              read an Anthropic API key from PATH
#
# Env: WEBSTER_API_KEY, ANTHROPIC_API_KEY, CLAUDE_CODE_WEBSTER_BASE_URL,
#      CLAUDE_CODE_MODEL_PROXY_PORT, CLAUDE_CODE_SETUP_REF,
#      CLAUDE_CODE_SETUP_RAW_BASE_URL, CLAUDE_CODE_SETUP_CLAUDE_DIR,
#      CLAUDE_CODE_SETUP_SOURCE_DIR, CLAUDE_CODE_SETUP_SKIP_ENDPOINT_CHECK,
#      CLAUDE_CODE_SETUP_SKIP_AUTH_CHECK, CLAUDE_DESKTOP_SETUP_APP,
#      CLAUDE_DESKTOP_SETUP_SUPPORT_DIR, CLAUDE_DESKTOP_SETUP_SKIP_RELAUNCH

set -euo pipefail

DEFAULT_WEBSTER_BASE_URL="https://webster-models-extnode-3gdrajbr0hiykknxzitck9yaiwo.apps.run.brev.nvidia.com/v1"
WEBSTER_BASE_URL="${CLAUDE_CODE_WEBSTER_BASE_URL:-$DEFAULT_WEBSTER_BASE_URL}"
WEBSTER_BASE_URL="${WEBSTER_BASE_URL%/}"
PROXY_HOST="127.0.0.1"
PROXY_PORT="${CLAUDE_CODE_MODEL_PROXY_PORT:-4816}"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
HEALTH_URL="${PROXY_URL}/healthz"

CLAUDE_DIR="${CLAUDE_CODE_SETUP_CLAUDE_DIR:-$HOME/.claude}"
PROXY_DIR="$CLAUDE_DIR/model-proxy"
WEBSTER_CONFIG="$PROXY_DIR/webster.json"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
GATEWAY_CACHE="$CLAUDE_DIR/cache/gateway-models.json"
CODEX_DIR="${CLAUDE_CODE_SETUP_CODEX_DIR:-${CODEX_HOME:-$HOME/.codex}}"
CODEX_WEBSTER_CONFIG="$CODEX_DIR/model-proxy/webster.json"
CLAUDE_DESKTOP_APP="${CLAUDE_DESKTOP_SETUP_APP:-/Applications/Claude.app}"
CLAUDE_DESKTOP_SUPPORT_DIR="${CLAUDE_DESKTOP_SETUP_SUPPORT_DIR:-$HOME/Library/Application Support/Claude-3p}"

SETUP_REF="${CLAUDE_CODE_SETUP_REF:-main}"
RAW_BASE_URL="${CLAUDE_CODE_SETUP_RAW_BASE_URL:-https://raw.githubusercontent.com/theFong/setup/$SETUP_REF}"
LOCAL_SOURCE_DIR="${CLAUDE_CODE_SETUP_SOURCE_DIR:-}"
SOURCE_FILES="proxy.mjs claude-code-oauth.mjs write-webster-config.mjs write-claude-settings.mjs write-gateway-cache.mjs write-claude-desktop-config.mjs"

NODE_MIN_MAJOR=20
CLAUDE_DISCOVERY_MIN_VERSION="2.1.129"
OS=""
PM=""
SUDO=""
APT_UPDATED=0
FAILED=""
CHECK_ONLY=0
DESKTOP=0
KEY_FILE=""
API_KEY="${WEBSTER_API_KEY:-}"
ANTHROPIC_KEY_FILE=""
ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
ANTHROPIC_MODE=""
ANTHROPIC_OAUTH_REQUESTED=0
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
claude-code-setup.sh — add Webster models alongside Claude models in Claude Code.

Usage:
  claude-code-setup.sh [--check] [--desktop] [--key-file PATH]
                       [--anthropic-oauth | --anthropic-key-file PATH]

Options:
  --check, --verify-only  Verify the current setup without changing it.
  --desktop               Also configure Claude Desktop/Cowork in Gateway mode (macOS).
  --key-file PATH         Read the Webster API key from PATH.
  --anthropic-oauth       Reuse and refresh Claude Code OAuth from macOS Keychain.
  --anthropic-key-file PATH
                          Read an Anthropic API key from PATH.
  -h, --help              Show this help.

Env: WEBSTER_API_KEY, ANTHROPIC_API_KEY, CLAUDE_CODE_WEBSTER_BASE_URL,
     CLAUDE_CODE_MODEL_PROXY_PORT, CLAUDE_CODE_SETUP_REF,
     CLAUDE_CODE_SETUP_RAW_BASE_URL, CLAUDE_CODE_SETUP_CLAUDE_DIR,
     CLAUDE_CODE_SETUP_SOURCE_DIR, CLAUDE_CODE_SETUP_SKIP_ENDPOINT_CHECK,
     CLAUDE_CODE_SETUP_SKIP_AUTH_CHECK, CLAUDE_DESKTOP_SETUP_APP,
     CLAUDE_DESKTOP_SETUP_SUPPORT_DIR, CLAUDE_DESKTOP_SETUP_SKIP_RELAUNCH
USAGE
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --check|--verify-only) CHECK_ONLY=1 ;;
      --desktop) DESKTOP=1 ;;
      --anthropic-oauth) ANTHROPIC_OAUTH_REQUESTED=1 ;;
      --key-file)
        shift
        KEY_FILE="${1:-}"
        [ -n "$KEY_FILE" ] || { warn "--key-file needs a path"; return 2; }
        ;;
      --anthropic-key-file)
        shift
        ANTHROPIC_KEY_FILE="${1:-}"
        [ -n "$ANTHROPIC_KEY_FILE" ] || {
          warn "--anthropic-key-file needs a path"
          return 2
        }
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

version_at_least() {
  node -e '
    const parse = (value) => value.split(".").map((part) => Number.parseInt(part, 10) || 0);
    const actual = parse(process.argv[1]);
    const minimum = parse(process.argv[2]);
    for (let i = 0; i < Math.max(actual.length, minimum.length); i++) {
      if ((actual[i] ?? 0) > (minimum[i] ?? 0)) process.exit(0);
      if ((actual[i] ?? 0) < (minimum[i] ?? 0)) process.exit(1);
    }
  ' "$1" "$2"
}

assert_claude_code() {
  have claude || {
    warn "Claude Code is not installed; install it and sign in before running setup"
    return 1
  }
  local version
  version=$(claude --version 2>/dev/null | awk '{print $1}') || return 1
  version_at_least "$version" "$CLAUDE_DISCOVERY_MIN_VERSION" || {
    warn "Claude Code >= $CLAUDE_DISCOVERY_MIN_VERSION is required for gateway model discovery (found $version)"
    return 1
  }
  ok "Claude Code $version supports gateway model discovery"
}

assert_claude_login() {
  if [ "${CLAUDE_CODE_SETUP_SKIP_AUTH_CHECK:-0}" = 1 ]; then
    ok "skipping Claude login check (CLAUDE_CODE_SETUP_SKIP_AUTH_CHECK=1)"
    return 0
  fi
  if ! claude auth status >/dev/null 2>&1; then
    warn "Claude Code is not signed in; run 'claude' and sign in, then re-run setup"
    return 1
  fi
  ok "Claude Code login is available"
}

assert_claude_desktop_supported() {
  [ "$DESKTOP" = 1 ] || return 0
  [ "$OS" = "darwin" ] || {
    warn "--desktop is supported only on macOS"
    return 1
  }
  [ -d "$CLAUDE_DESKTOP_APP" ] || {
    warn "Claude Desktop is not installed at $CLAUDE_DESKTOP_APP"
    return 1
  }
  local asar="$CLAUDE_DESKTOP_APP/Contents/Resources/app.asar"
  [ -r "$asar" ] || {
    warn "Claude Desktop resources are missing at $asar"
    return 1
  }
  LC_ALL=C grep -aq 'inferenceGatewayBaseUrl' "$asar" || {
    warn "this Claude Desktop build does not expose third-party Gateway configuration"
    return 1
  }
  ok "Claude Desktop supports third-party Gateway mode"
}

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

key_from_config() {
  local config="$1"
  [ -f "$config" ] || return 0
  node -e '
    const fs = require("fs");
    try {
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).apiKey;
      if (typeof value === "string") process.stdout.write(value);
    } catch {}
  ' "$config"
}

anthropic_mode_from_config() {
  local config="$1"
  [ -f "$config" ] || return 0
  node -e '
    const fs = require("fs");
    try {
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).anthropic?.mode;
      if (typeof value === "string") process.stdout.write(value);
    } catch {}
  ' "$config"
}

anthropic_key_from_config() {
  local config="$1"
  [ -f "$config" ] || return 0
  node -e '
    const fs = require("fs");
    try {
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).anthropic?.apiKey;
      if (typeof value === "string") process.stdout.write(value);
    } catch {}
  ' "$config"
}

resolve_api_key() {
  if [ -n "$KEY_FILE" ]; then
    [ -r "$KEY_FILE" ] || { warn "cannot read key file: $KEY_FILE"; return 1; }
    IFS= read -r API_KEY < "$KEY_FILE" || true
  fi
  if [ -z "$API_KEY" ]; then
    API_KEY=$(key_from_config "$WEBSTER_CONFIG")
    [ -n "$API_KEY" ] && ok "reusing the installed Claude Code Webster key"
  fi
  if [ -z "$API_KEY" ]; then
    API_KEY=$(key_from_config "$CODEX_WEBSTER_CONFIG")
    [ -n "$API_KEY" ] && ok "reusing the Codex Webster key"
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

assert_claude_code_oauth_credential() {
  [ "$ANTHROPIC_MODE" = "claude-code-oauth" ] || return 0
  [ "$OS" = "darwin" ] || {
    warn "Claude Code OAuth reuse is supported only on macOS"
    return 1
  }
  have security || {
    warn "macOS security command is required for Claude Code OAuth reuse"
    return 1
  }
  if ! security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null |
      node -e '
        let input = "";
        process.stdin.on("data", (chunk) => input += chunk);
        process.stdin.on("end", () => {
          try {
            const oauth = JSON.parse(input).claudeAiOauth;
            if (typeof oauth?.accessToken !== "string" || !oauth.accessToken) process.exit(1);
            if (typeof oauth?.refreshToken !== "string" || !oauth.refreshToken) process.exit(1);
            if (Number.isFinite(oauth?.refreshTokenExpiresAt) && oauth.refreshTokenExpiresAt <= Date.now()) process.exit(1);
          } catch {
            process.exit(1);
          }
        });
      '; then
    warn "Claude Code OAuth credential is missing or expired; run 'claude auth login'"
    return 1
  fi
  ok "Claude Code OAuth credential is available in macOS Keychain"
}

resolve_anthropic_auth() {
  local installed_mode=""
  if [ "$ANTHROPIC_OAUTH_REQUESTED" = 1 ] && [ -n "$ANTHROPIC_KEY" ]; then
    warn "--anthropic-oauth and ANTHROPIC_API_KEY are mutually exclusive"
    return 1
  fi
  if [ "$ANTHROPIC_OAUTH_REQUESTED" = 1 ] && [ -n "$ANTHROPIC_KEY_FILE" ]; then
    warn "--anthropic-oauth and --anthropic-key-file are mutually exclusive"
    return 1
  fi

  if [ "$ANTHROPIC_OAUTH_REQUESTED" = 1 ]; then
    ANTHROPIC_MODE="claude-code-oauth"
  elif [ -n "$ANTHROPIC_KEY_FILE" ]; then
    [ -r "$ANTHROPIC_KEY_FILE" ] || {
      warn "cannot read Anthropic key file: $ANTHROPIC_KEY_FILE"
      return 1
    }
    IFS= read -r ANTHROPIC_KEY < "$ANTHROPIC_KEY_FILE" || true
    [ -n "$ANTHROPIC_KEY" ] || {
      warn "Anthropic key file is empty: $ANTHROPIC_KEY_FILE"
      return 1
    }
    ANTHROPIC_MODE="api-key"
  elif [ -n "$ANTHROPIC_KEY" ]; then
    ANTHROPIC_MODE="api-key"
  else
    installed_mode=$(anthropic_mode_from_config "$WEBSTER_CONFIG")
    case "$installed_mode" in
      api-key)
        ANTHROPIC_KEY=$(anthropic_key_from_config "$WEBSTER_CONFIG")
        [ -n "$ANTHROPIC_KEY" ] || {
          warn "installed Anthropic API-key mode has no key"
          return 1
        }
        ANTHROPIC_MODE="api-key"
        ok "reusing the installed Anthropic API key"
        ;;
      claude-code-oauth)
        ANTHROPIC_MODE="claude-code-oauth"
        ok "reusing installed Claude Code OAuth mode"
        ;;
      "") ANTHROPIC_MODE="none" ;;
      *)
        warn "unsupported installed Anthropic credential mode: $installed_mode"
        return 1
        ;;
    esac
  fi

  case "$ANTHROPIC_MODE" in
    api-key) ok "Anthropic Desktop routing will use an API key" ;;
    claude-code-oauth) assert_claude_code_oauth_credential ;;
    none) ok "Anthropic Desktop routing is not enabled" ;;
    *) warn "unsupported Anthropic credential mode: $ANTHROPIC_MODE"; return 1 ;;
  esac
}

assert_webster_endpoint() {
  if [ "${CLAUDE_CODE_SETUP_SKIP_ENDPOINT_CHECK:-0}" = 1 ]; then
    ok "skipping Webster endpoint check (CLAUDE_CODE_SETUP_SKIP_ENDPOINT_CHECK=1)"
    return 0
  fi
  local response_file
  response_file=$(mktemp)
  if ! curl -fsS --max-time 20 -H "Authorization: Bearer $API_KEY" \
      "$WEBSTER_BASE_URL/models" -o "$response_file"; then
    rm -f "$response_file"
    warn "Webster endpoint rejected the key or could not be reached"
    return 1
  fi
  if ! node -e '
      const fs = require("fs");
      const body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const models = body.data ?? body.models ?? [];
      if (!models.some((model) => (model.id ?? model.slug) === "glm-5.2")) process.exit(1);
    ' "$response_file"; then
    rm -f "$response_file"
    warn "Webster endpoint does not advertise glm-5.2"
    return 1
  fi
  rm -f "$response_file"
  ok "Webster endpoint accepts the key and serves glm-5.2"
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
    source="$RAW_BASE_URL/claude-code-model-proxy/$name"
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
  mkdir -p "$PROXY_DIR" "$CLAUDE_DIR/log"
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
  local next="$WEBSTER_CONFIG.next-$$"
  WEBSTER_API_KEY="$API_KEY" WEBSTER_BASE_URL="$WEBSTER_BASE_URL" \
    ANTHROPIC_CREDENTIAL_MODE="$ANTHROPIC_MODE" ANTHROPIC_API_KEY="$ANTHROPIC_KEY" \
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
  WEBSTER_API_KEY="$API_KEY" WEBSTER_BASE_URL="$WEBSTER_BASE_URL" \
    ANTHROPIC_CREDENTIAL_MODE="$ANTHROPIC_MODE" ANTHROPIC_API_KEY="$ANTHROPIC_KEY" node -e '
    const fs = require("fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (value.apiKey !== process.env.WEBSTER_API_KEY) process.exit(1);
    if (value.baseUrl.replace(/\/+$/, "") !== process.env.WEBSTER_BASE_URL.replace(/\/+$/, "")) process.exit(1);
    const mode = process.env.ANTHROPIC_CREDENTIAL_MODE;
    if (mode === "none") {
      if (value.anthropic !== undefined) process.exit(1);
    } else {
      if (value.anthropic?.mode !== mode) process.exit(1);
      if (mode === "api-key" && value.anthropic?.apiKey !== process.env.ANTHROPIC_API_KEY) process.exit(1);
      if (mode === "claude-code-oauth" && value.anthropic?.apiKey !== undefined) process.exit(1);
    }
  ' "$WEBSTER_CONFIG" || { warn "Webster credential config does not match"; return 1; }
  ok "proxy credential config is valid and private"
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

install_launch_agent() {
  local label="com.thefong.claude-code-model-proxy"
  local agents="$HOME/Library/LaunchAgents"
  local plist="$agents/$label.plist"
  local domain node_path temporary
  local node_xml proxy_xml config_xml stdout_xml stderr_xml
  domain="gui/$(id -u)"
  node_path=$(command -v node)
  mkdir -p "$agents"

  node_xml=$(printf '%s' "$node_path" | xml_escape)
  proxy_xml=$(printf '%s' "$PROXY_DIR/proxy.mjs" | xml_escape)
  config_xml=$(printf '%s' "$WEBSTER_CONFIG" | xml_escape)
  stdout_xml=$(printf '%s' "$CLAUDE_DIR/log/model-proxy.log" | xml_escape)
  stderr_xml=$(printf '%s' "$CLAUDE_DIR/log/model-proxy.error.log" | xml_escape)
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
    <key>CLAUDE_CODE_MODEL_PROXY_HOST</key><string>$PROXY_HOST</string>
    <key>CLAUDE_CODE_MODEL_PROXY_PORT</key><string>$PROXY_PORT</string>
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
    if [ "$INSTALL_CHANGED" = 1 ]; then launchctl kickstart -k "$domain/$label"; fi
  else
    launchctl bootstrap "$domain" "$plist"
  fi
}

systemd_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g'
}

install_systemd_service() {
  local units="$HOME/.config/systemd/user"
  local unit="$units/claude-code-model-proxy.service"
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
Description=Claude Code and Webster model proxy
After=network-online.target

[Service]
Type=simple
ExecStart="$node_unit" "$proxy_unit"
Environment="WEBSTER_MODELS_CONFIG=$config_unit"
Environment="CLAUDE_CODE_MODEL_PROXY_HOST=$PROXY_HOST"
Environment="CLAUDE_CODE_MODEL_PROXY_PORT=$PROXY_PORT"
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
  systemctl --user enable claude-code-model-proxy.service >/dev/null
  if systemctl --user is-active claude-code-model-proxy.service >/dev/null 2>&1; then
    if [ "$INSTALL_CHANGED" = 1 ]; then systemctl --user restart claude-code-model-proxy.service; fi
  else
    systemctl --user start claude-code-model-proxy.service
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
      launchctl print "gui/$(id -u)/com.thefong.claude-code-model-proxy" >/dev/null 2>&1 || {
        warn "Claude Code model proxy launch agent is not loaded"
        return 1
      }
      ;;
    linux)
      systemctl --user is-active claude-code-model-proxy.service >/dev/null 2>&1 || {
        warn "Claude Code model proxy systemd user service is not active"
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

assert_gateway_catalog() {
  local response_file
  response_file=$(mktemp)
  if ! curl -fsS --max-time 5 "$PROXY_URL/v1/models" -o "$response_file"; then
    rm -f "$response_file"
    warn "Claude Code gateway model discovery endpoint is unavailable"
    return 1
  fi
  if ! ANTHROPIC_CREDENTIAL_MODE="$ANTHROPIC_MODE" node -e '
      const fs = require("fs");
      const body = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const required = new Set([
        "claude-sonnet-4-5-webster",
        "claude-sonnet-4-5-webster-flash",
        "claude-sonnet-4-5-webster-h200",
        "claude-sonnet-4-5-webster-flash-h100",
      ]);
      for (const model of body.data ?? []) {
        if (model.anthropic_family_tier !== "sonnet") continue;
        required.delete(model.id);
      }
      if (required.size) process.exit(1);
      if (process.env.ANTHROPIC_CREDENTIAL_MODE !== "none") {
        const official = (body.data ?? []).filter(
          (model) => model.id?.startsWith("claude-") &&
            !model.display_name?.endsWith("(Webster)"),
        );
        if (official.length === 0) process.exit(1);
      }
    ' "$response_file"; then
    rm -f "$response_file"
    warn "gateway catalog is missing required Webster or Anthropic models"
    return 1
  fi
  rm -f "$response_file"
  if [ "$ANTHROPIC_MODE" = "none" ]; then
    ok "gateway advertises all Claude Desktop-compatible Webster models"
  else
    ok "gateway advertises Webster and Anthropic models together"
  fi
}

write_gateway_cache() {
  local next="$GATEWAY_CACHE.next-$$"
  CLAUDE_CODE_MODEL_PROXY_URL="$PROXY_URL" \
    node "$PROXY_DIR/write-gateway-cache.mjs" "$GATEWAY_CACHE" "$next" || {
      rm -f "$next"
      return 1
    }
  if [ -f "$GATEWAY_CACHE" ] && cmp -s "$next" "$GATEWAY_CACHE"; then
    rm -f "$next"
    ok "Claude Code gateway model cache unchanged"
    return 0
  fi
  mv "$next" "$GATEWAY_CACHE"
  chmod 600 "$GATEWAY_CACHE"
  ok "seeded Webster models into $GATEWAY_CACHE"
}

assert_gateway_cache() {
  [ -f "$GATEWAY_CACHE" ] || { warn "missing $GATEWAY_CACHE"; return 1; }
  CLAUDE_CODE_MODEL_PROXY_URL="$PROXY_URL" node -e '
    const fs = require("fs");
    const cache = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const expectedUrl = process.env.CLAUDE_CODE_MODEL_PROXY_URL.replace(/\/+$/, "");
    const required = new Set([
      "claude-webster-glm-5-2",
      "claude-webster-deepseek-v4-flash",
      "claude-webster-glm-5-2-h200",
      "claude-webster-deepseek-v4-flash-h100",
    ]);
    if (cache.baseUrl?.replace(/\/+$/, "") !== expectedUrl) process.exit(1);
    for (const model of cache.models ?? []) required.delete(model.id);
    if (required.size) process.exit(1);
  ' "$GATEWAY_CACHE" || {
    warn "Claude Code gateway model cache is missing or incorrect"
    return 1
  }
  ok "Claude Code picker cache includes all Webster models"
}

merge_claude_settings() {
  local next="$CLAUDE_SETTINGS.next-$$"
  CLAUDE_CODE_MODEL_PROXY_URL="$PROXY_URL" \
    node "$PROXY_DIR/write-claude-settings.mjs" "$CLAUDE_SETTINGS" "$next" || {
      rm -f "$next"
      return 1
    }
  if [ -f "$CLAUDE_SETTINGS" ] && cmp -s "$next" "$CLAUDE_SETTINGS"; then
    rm -f "$next"
    ok "Claude Code settings unchanged"
    return 0
  fi
  [ -f "$CLAUDE_SETTINGS" ] && cp -p "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak-claude-code-setup"
  mv "$next" "$CLAUDE_SETTINGS"
  chmod 600 "$CLAUDE_SETTINGS"
  ok "merged gateway settings into $CLAUDE_SETTINGS"
}

assert_claude_settings() {
  [ -f "$CLAUDE_SETTINGS" ] || { warn "missing $CLAUDE_SETTINGS"; return 1; }
  CLAUDE_CODE_MODEL_PROXY_URL="$PROXY_URL" node -e '
    const fs = require("fs");
    const settings = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const expected = process.env.CLAUDE_CODE_MODEL_PROXY_URL.replace(/\/+$/, "");
    if (settings?.env?.ANTHROPIC_BASE_URL?.replace(/\/+$/, "") !== expected) process.exit(1);
    if (settings?.env?.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY !== "1") process.exit(1);
    if (settings?.env?.ENABLE_TOOL_SEARCH !== "true") process.exit(1);
  ' "$CLAUDE_SETTINGS" || {
    warn "Claude Code gateway settings are missing or incorrect"
    return 1
  }
  ok "Claude Code user settings point at the combined provider"
}

configure_claude_desktop() {
  [ "$DESKTOP" = 1 ] || return 0
  CLAUDE_CODE_MODEL_PROXY_URL="$PROXY_URL" \
    node "$PROXY_DIR/write-claude-desktop-config.mjs" \
      "$CLAUDE_DESKTOP_SUPPORT_DIR" "$PROXY_URL" >/dev/null
  ok "configured Claude Desktop Webster Gateway profile"
}

assert_claude_desktop_config() {
  [ "$DESKTOP" = 1 ] || return 0
  CLAUDE_CODE_MODEL_PROXY_URL="$PROXY_URL" node -e '
    const fs = require("fs");
    const path = require("path");
    const support = process.argv[1];
    const expected = process.env.CLAUDE_CODE_MODEL_PROXY_URL.replace(/\/+$/, "");
    const read = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
    const desktop = read(path.join(support, "claude_desktop_config.json"));
    const meta = read(path.join(support, "configLibrary", "_meta.json"));
    if (desktop.deploymentMode !== "3p") process.exit(1);
    if (!/^[0-9a-f-]{36}$/i.test(meta.appliedId ?? "")) process.exit(1);
    const profile = read(path.join(support, "configLibrary", `${meta.appliedId}.json`));
    if (profile.inferenceProvider !== "gateway") process.exit(1);
    if (profile.inferenceCredentialKind !== "static") process.exit(1);
    if (profile.inferenceGatewayBaseUrl?.replace(/\/+$/, "") !== expected) process.exit(1);
    if (profile.inferenceGatewayApiKey !== "claude-desktop-local") process.exit(1);
    if (profile.inferenceGatewayAuthScheme !== "bearer") process.exit(1);
    if (profile.modelDiscoveryEnabled !== true) process.exit(1);
  ' "$CLAUDE_DESKTOP_SUPPORT_DIR" || {
    warn "Claude Desktop Gateway profile is missing or incorrect"
    return 1
  }

  local desktop_config="$CLAUDE_DESKTOP_SUPPORT_DIR/claude_desktop_config.json"
  local meta="$CLAUDE_DESKTOP_SUPPORT_DIR/configLibrary/_meta.json"
  local profile_id profile
  profile_id=$(node -e '
    const fs = require("fs");
    process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).appliedId ?? "");
  ' "$meta") || return 1
  profile="$CLAUDE_DESKTOP_SUPPORT_DIR/configLibrary/$profile_id.json"
  [ "$(mode_of "$desktop_config")" = 600 ] &&
    [ "$(mode_of "$meta")" = 600 ] &&
    [ "$(mode_of "$profile")" = 600 ] || {
      warn "Claude Desktop Gateway configuration must use mode 600"
      return 1
    }
  ok "Claude Desktop is persisted in private Gateway/3P configuration"
}

relaunch_claude_desktop() {
  [ "$DESKTOP" = 1 ] || return 0
  if [ "${CLAUDE_DESKTOP_SETUP_SKIP_RELAUNCH:-0}" = 1 ]; then
    ok "skipping Claude Desktop relaunch (CLAUDE_DESKTOP_SETUP_SKIP_RELAUNCH=1)"
    return 0
  fi
  if pgrep -x Claude >/dev/null 2>&1; then
    osascript -e 'tell application id "com.anthropic.claudefordesktop" to quit' || return 1
    local stop_attempt=0
    while pgrep -x Claude >/dev/null 2>&1 && [ "$stop_attempt" -lt 30 ]; do
      stop_attempt=$((stop_attempt + 1))
      sleep 0.5
    done
    pgrep -x Claude >/dev/null 2>&1 && {
      warn "Claude Desktop did not quit for the Gateway-mode relaunch"
      return 1
    }
  fi
  open "$CLAUDE_DESKTOP_APP" || return 1
  local start_attempt=0
  while [ "$start_attempt" -lt 30 ]; do
    start_attempt=$((start_attempt + 1))
    if ps ax -o command= | grep -F '"deploymentMode":"3p"' | grep -v grep >/dev/null 2>&1; then
      ok "Claude Desktop relaunched in Gateway/3P mode"
      return 0
    fi
    sleep 0.5
  done
  warn "Claude Desktop did not relaunch in Gateway/3P mode"
  return 1
}

verify_all() {
  assert_claude_code     || record_failure claude-code
  assert_claude_login    || record_failure claude-login
  assert_proxy_sources   || record_failure proxy-source
  assert_webster_config  || record_failure webster-config
  assert_webster_endpoint || record_failure webster-endpoint
  assert_claude_code_oauth_credential || record_failure anthropic-oauth
  assert_service         || record_failure proxy-service
  assert_gateway_catalog || record_failure model-catalog
  assert_gateway_cache   || record_failure model-cache
  assert_claude_settings || record_failure claude-settings
  if [ "$DESKTOP" = 1 ]; then
    assert_claude_desktop_supported || record_failure claude-desktop
    assert_claude_desktop_config || record_failure claude-desktop-config
  fi
}

summary() {
  echo
  if [ -n "${FAILED# }" ]; then
    warn "setup is incomplete:${FAILED}"
    warn "fix the reported issue and re-run claude-code-setup.sh"
    return 1
  fi
  if [ "$DESKTOP" = 1 ]; then
    if [ "$ANTHROPIC_MODE" = "none" ]; then
      log "Claude Code + Claude Desktop + Webster setup is healthy"
    else
      log "Claude Code + Claude Desktop mixed Anthropic/Webster setup is healthy"
    fi
  else
    log "Claude Code + Webster setup is healthy"
  fi
  printf '\nStart a new Claude Code process, run /model, and choose a Webster or Claude model.\n'
  printf 'Direct launch example: claude --model claude-webster-glm-5-2\n'
  if [ "$DESKTOP" = 1 ]; then
    if [ "$ANTHROPIC_MODE" = "none" ]; then
      printf 'Claude Desktop is using the Webster-only Gateway/3P profile.\n'
    else
      printf 'Claude Desktop now shows Anthropic and Webster models in one Gateway picker.\n'
    fi
  fi
  printf 'Re-run this installer to update the proxy; use --check for a read-only health check.\n'
}

main() {
  local parse_status=0
  parse_args "$@" || parse_status=$?
  [ "$parse_status" = 10 ] && return 0
  [ "$parse_status" = 0 ] || return "$parse_status"

  detect_platform || { record_failure platform; summary || true; return 1; }
  ensure_package_manager
  ensure_node || { record_failure node; summary || true; return 1; }
  assert_claude_code || { record_failure claude-code; summary || true; return 1; }
  assert_claude_login || { record_failure claude-login; summary || true; return 1; }
  assert_claude_desktop_supported || { record_failure claude-desktop; summary || true; return 1; }
  resolve_api_key || { record_failure webster-key; summary || true; return 1; }
  resolve_anthropic_auth || { record_failure anthropic-auth; summary || true; return 1; }

  if [ "$CHECK_ONLY" = 1 ]; then
    verify_all
    summary
    return
  fi

  assert_webster_endpoint || { record_failure webster-endpoint; summary || true; return 1; }
  install_proxy_sources || { record_failure proxy-source; summary || true; return 1; }
  assert_proxy_sources || { record_failure proxy-source; summary || true; return 1; }
  write_webster_config || { record_failure webster-config; summary || true; return 1; }
  assert_webster_config || { record_failure webster-config; summary || true; return 1; }
  install_service || { record_failure proxy-service; summary || true; return 1; }
  assert_service || { record_failure proxy-service; summary || true; return 1; }
  assert_gateway_catalog || { record_failure model-catalog; summary || true; return 1; }
  merge_claude_settings || { record_failure claude-settings; summary || true; return 1; }
  write_gateway_cache || { record_failure model-cache; summary || true; return 1; }
  assert_gateway_cache || record_failure model-cache
  assert_claude_settings || record_failure claude-settings
  if [ "$DESKTOP" = 1 ]; then
    configure_claude_desktop || { record_failure claude-desktop-config; summary || true; return 1; }
    assert_claude_desktop_config || { record_failure claude-desktop-config; summary || true; return 1; }
    relaunch_claude_desktop || record_failure claude-desktop-runtime
  fi
  summary
}

if [ "${SETUP_SKIP_MAIN:-0}" != 1 ]; then
  main "$@"
fi
