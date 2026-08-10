#!/usr/bin/env bash
#
# pi/install.sh — install the pi coding agent and point it at an
# OpenAI-compatible inference endpoint, with a default model and a footer
# status line (tok/s, active model, session id).
#
# Installs the npm package, writes ~/.pi/agent/models.json (provider + models),
# sets the default provider/model in ~/.pi/agent/settings.json, and drops the
# tokps-session extension into ~/.pi/agent/extensions/.
#
# The API key is never stored in this repo. Supply it one of three ways:
#   PI_API_KEY=sk-... ./install.sh     # non-interactive (CI, provisioning)
#   ./install.sh                       # prompts on the terminal
#   ./install.sh --key-file ./key.txt  # read from a file (first line)
#
# Usage:
#   ./install.sh                       # merge config into any existing setup
#   ./install.sh --exclusive           # make this the ONLY configured provider
#   ./install.sh --verify-only         # check an existing install, install nothing
#
# Env overrides: PI_API_KEY, PI_NO_PROMPT, PI_PROVIDER, PI_BASE_URL, PI_MODEL,
#                PI_CONTEXT_WINDOW, PI_MAX_TOKENS, PI_CODING_AGENT_DIR,
#                PI_NPM_PACKAGE, PI_SKIP_ENDPOINT_CHECK
#
# Re-running is safe: an existing pi is left alone, config is merged rather
# than clobbered, and the extension is only rewritten when its content differs.
#
# Everything is wrapped in main() and invoked on the last line so a truncated
# download never executes a partial script.

set -euo pipefail

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

OS=""        # darwin | linux
PM=""        # brew | apt | dnf | apk
SUDO=""      # "" when root, else "sudo"
APT_UPDATED=0
FAILED=""    # space-separated list of things that failed

record_failure() {
  local item="$1"
  case " $FAILED " in
    *" $item "*) ;;
    *) FAILED="$FAILED $item" ;;
  esac
}

# assert_installed LABEL BINARY [FAILURE_NAME] — verify an install produced an
# executable on PATH and record a failure if it did not.
assert_installed() {
  local label="$1" bin="$2" failure_name="${3:-$2}"
  if have "$bin"; then
    log "verified $label: $(command -v "$bin")"
    return 0
  fi
  warn "$label is not available on PATH after installation"
  record_failure "$failure_name"
  return 1
}

# assert_runs LABEL FAILURE_NAME CMD... — verify an installed binary actually
# executes, not just that it resolves on PATH. A truncated npm install or a
# wrong-architecture native dependency still satisfies `command -v`.
assert_runs() {
  local label="$1" failure_name="$2"; shift 2
  if "$@" >/dev/null 2>&1; then
    log "verified $label runs"
    return 0
  fi
  warn "$label is on PATH but failed to run: $*"
  record_failure "$failure_name"
  return 1
}

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------

DEFAULT_BASE_URL="https://webster-models-extnode-3gdrajbr0hiykknxzitck9yaiwo.apps.run.brev.nvidia.com/v1"

PROVIDER="${PI_PROVIDER:-webster}"
BASE_URL="${PI_BASE_URL:-$DEFAULT_BASE_URL}"
MODEL="${PI_MODEL:-glm-5.2}"
# The endpoint's real limits: vLLM rejects max_tokens beyond max_model_len,
# and pi reserves output tokens against the context window, so these must
# match the backend rather than the proxy's advertised metadata.
CONTEXT_WINDOW="${PI_CONTEXT_WINDOW:-320000}"
MAX_TOKENS="${PI_MAX_TOKENS:-32768}"

# pi reads its config from PI_CODING_AGENT_DIR, defaulting to ~/.pi/agent.
AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
MODELS_JSON="$AGENT_DIR/models.json"
SETTINGS_JSON="$AGENT_DIR/settings.json"
EXTENSION="$AGENT_DIR/extensions/tokps-session.ts"

NPM_PACKAGE="${PI_NPM_PACKAGE:-@earendil-works/pi-coding-agent}"

API_KEY="${PI_API_KEY:-}"
KEY_FILE=""
EXCLUSIVE=0
VERIFY_ONLY=0

usage() {
  sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --exclusive)   EXCLUSIVE=1 ;;
      --verify-only) VERIFY_ONLY=1 ;;
      --key-file)    shift; KEY_FILE="${1:-}"; [ -n "$KEY_FILE" ] || { echo "--key-file needs a path" >&2; exit 1; } ;;
      -h|--help)     usage; exit 0 ;;
      *)             echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
  done
}

detect_platform() {
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$OS" in
    darwin|linux) ;;
    *) echo "unsupported OS: $OS" >&2; exit 1 ;;
  esac
  if [ "$(id -u)" -ne 0 ]; then
    if have sudo; then SUDO="sudo"; else warn "not root and no sudo; package installs may fail"; fi
  fi
}

ensure_package_manager() {
  if [ "$OS" = "darwin" ]; then
    if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
    have brew && PM="brew"
    return 0
  fi
  if   have apt-get; then PM="apt"
  elif have dnf;     then PM="dnf"
  elif have apk;     then PM="apk"
  fi
  return 0
}

pm_install() {
  [ -n "$PM" ] || { warn "no supported package manager found; cannot install $*"; return 1; }
  case "$PM" in
    brew) brew install "$@" ;;
    apt)  [ "$APT_UPDATED" = 1 ] || { $SUDO apt-get update -y && APT_UPDATED=1; }
          $SUDO apt-get install -y "$@" ;;
    dnf)  $SUDO dnf install -y "$@" ;;
    apk)  $SUDO apk add "$@" ;;
  esac
}

# ---------------------------------------------------------------------------
# prerequisites
# ---------------------------------------------------------------------------

# jq does the config merging. Hand-rolled JSON editing is how bootstrap
# scripts silently corrupt a user's existing configuration.
ensure_jq() {
  if have jq; then log "jq already present"; return 0; fi
  log "installing jq"
  pm_install jq || { warn "failed to install jq"; record_failure jq; }
  assert_installed "jq" jq
}

ensure_node() {
  if have npm; then log "npm already present"; return 0; fi
  log "installing Node.js"
  case "$PM" in
    brew) pm_install node ;;
    apt)  pm_install nodejs npm ;;
    dnf)  pm_install nodejs npm ;;
    apk)  pm_install nodejs npm ;;
    *)    warn "no package manager for Node.js; install Node 20+ manually" ;;
  esac || warn "failed to install Node.js"
  assert_installed "npm" npm nodejs
}

# npm's global prefix is root-owned on most distro packages but user-owned
# under nvm/Homebrew. Try unprivileged first so we never gratuitously sudo.
npm_install_global() {
  local pkg="$1"
  if npm install -g "$pkg" >/dev/null 2>&1; then return 0; fi
  if [ -n "$SUDO" ]; then
    warn "unprivileged 'npm install -g' failed; retrying with sudo"
    $SUDO npm install -g "$pkg" >/dev/null 2>&1 && return 0
  fi
  return 1
}

install_pi() {
  if have pi; then
    log "pi already present: $(pi --version 2>/dev/null || echo unknown)"
  else
    have npm || { warn "npm unavailable; cannot install pi"; record_failure pi; return 1; }
    log "installing pi ($NPM_PACKAGE)"
    npm_install_global "$NPM_PACKAGE" || { warn "failed to install $NPM_PACKAGE"; record_failure pi; }
  fi
  assert_installed "pi" pi || return 1
  assert_runs "pi" pi pi --version
}

# ---------------------------------------------------------------------------
# API key
# ---------------------------------------------------------------------------

# Resolve the key from --key-file, $PI_API_KEY, or an interactive prompt, in
# that order. Reads the prompt from /dev/tty so `curl ... | bash` still works:
# stdin is the pipe carrying the script itself.
resolve_api_key() {
  if [ -n "$KEY_FILE" ]; then
    [ -r "$KEY_FILE" ] || { warn "key file not readable: $KEY_FILE"; record_failure api-key; return 1; }
    API_KEY=$(head -n 1 "$KEY_FILE" | tr -d '\r\n')
  fi

  if [ -z "$API_KEY" ] && [ "${PI_NO_PROMPT:-0}" != 1 ] && [ -r /dev/tty ]; then
    printf 'API key for %s (%s)\n' "$PROVIDER" "$BASE_URL" > /dev/tty
    printf 'Paste key (input hidden), or Ctrl-C to abort: ' > /dev/tty
    IFS= read -rs API_KEY < /dev/tty || true
    printf '\n' > /dev/tty
  fi

  if [ -z "$API_KEY" ]; then
    warn "no API key: set PI_API_KEY, pass --key-file, or run with a terminal attached"
    record_failure api-key
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# configuration files
# ---------------------------------------------------------------------------

# jq_edit FILE FALLBACK_JSON FILTER ARGS... — apply FILTER to FILE, writing the
# result back only if jq succeeds. A file that fails to parse is left exactly
# as it was: clobbering a user's hand-edited config is worse than not
# configuring anything.
jq_edit() {
  local file="$1" fallback="$2" filter="$3"; shift 3
  local tmp
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || printf '%s\n' "$fallback" > "$file"
  tmp=$(mktemp)
  if jq "$@" "$filter" "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
    return 0
  fi
  rm -f "$tmp"
  warn "could not update $file (invalid JSON?); leaving it unchanged"
  return 1
}

# The provider entry plus the model definitions pi needs. pi has no endpoint
# discovery, so every model has to be declared with its real limits.
configure_models() {
  log "configuring provider '$PROVIDER' in $MODELS_JSON"
  # The key goes through the environment, not argv: anyone on the box can read
  # a command line out of `ps`.
  local filter='
    (if $exclusive == 1 then {providers: {}} else . end)
    | .providers[$p] = {
        name: ($p | ascii_upcase[0:1] + $p[1:]),
        baseUrl: $url,
        api: "openai-completions",
        apiKey: $ENV.PI_INSTALL_API_KEY,
        authHeader: true,
        compat: { supportsDeveloperRole: false, supportsReasoningEffort: true },
        models: [ {
          id: $model,
          name: $model,
          reasoning: true,
          input: ["text"],
          contextWindow: ($ctx | tonumber),
          maxTokens: ($max | tonumber)
        } ]
      }'
  PI_INSTALL_API_KEY="$API_KEY" jq_edit "$MODELS_JSON" '{"providers":{}}' "$filter" \
    --arg p "$PROVIDER" --arg url "$BASE_URL" --arg model "$MODEL" \
    --arg ctx "$CONTEXT_WINDOW" --arg max "$MAX_TOKENS" \
    --argjson exclusive "$EXCLUSIVE" \
    || { record_failure pi-models; return 1; }
  # The file holds a live credential.
  chmod 600 "$MODELS_JSON" 2>/dev/null || warn "could not chmod 600 $MODELS_JSON"
}

configure_settings() {
  log "setting default model to $PROVIDER/$MODEL in $SETTINGS_JSON"
  jq_edit "$SETTINGS_JSON" '{}' \
    '.defaultProvider = $p | .defaultModel = $model' \
    --arg p "$PROVIDER" --arg model "$MODEL" \
    || { record_failure pi-settings; return 1; }
}

# Footer status line: generation speed, active model, session id. Written from
# a heredoc so this script stays usable as a standalone curl one-liner.
install_extension() {
  local tmp
  mkdir -p "$(dirname "$EXTENSION")"
  tmp=$(mktemp)
  cat > "$tmp" <<'TOKPS_EOF'
/**
 * tokps-session — adds a footer status line with generation speed, active model,
 * and session ID. Installed by theFong/setup pi/install.sh.
 *
 * Renders e.g.  73.4 tok/s • webster/glm-5.2 • 019feddc-fb49-729f-87ea-2401481cdb25
 *
 * tok/s is decode speed: output tokens of the last assistant message divided by
 * the time from first streamed content to end of generation. Tool-execution time
 * is excluded, so a turn that runs a slow bash command doesn't dilute the rate.
 *
 * Note: providers report usage only on the final stream event, so the rate lands
 * at the end of each turn rather than ticking up live.
 */

import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	let sessionId = "";
	let modelLabel = "";
	let rate: number | null = null;

	// Per-turn generation timing
	let turnStart = 0;
	let firstContentAt = 0;
	let genEndAt = 0;
	let genTokens = 0;

	const paint = (ctx: ExtensionContext) => {
		const parts: string[] = [];
		if (rate !== null) parts.push(`${rate.toFixed(1)} tok/s`);
		if (modelLabel) parts.push(modelLabel);
		if (sessionId) parts.push(sessionId);
		ctx.ui.setStatus("tokps-session", parts.length > 0 ? parts.join(" • ") : undefined);
	};

	const labelFor = (model: ExtensionContext["model"]): string => (model ? `${model.provider}/${model.id}` : "");

	const outputTokens = (message: unknown): number => {
		const usage = (message as { usage?: { output?: number } } | undefined)?.usage;
		return typeof usage?.output === "number" ? usage.output : 0;
	};

	/** True once the assistant message has produced any text or thinking content. */
	const hasContent = (message: unknown): boolean => {
		const content = (message as { content?: unknown } | undefined)?.content;
		if (typeof content === "string") return content.length > 0;
		return Array.isArray(content) && content.length > 0;
	};

	pi.on("session_start", async (_event, ctx) => {
		sessionId = ctx.sessionManager.getSessionId();
		modelLabel = labelFor(ctx.model);
		rate = null;
		paint(ctx);
	});

	pi.on("model_select", async (event, ctx) => {
		modelLabel = labelFor(event.model);
		paint(ctx);
	});

	pi.on("turn_start", async (event) => {
		turnStart = event.timestamp || Date.now();
		firstContentAt = 0;
		genEndAt = 0;
		genTokens = 0;
	});

	pi.on("message_update", async (event) => {
		const now = Date.now();
		if (firstContentAt === 0 && hasContent(event.message)) firstContentAt = now;

		// Usage arrives on the last stream event; treat that as end of generation.
		const output = outputTokens(event.message);
		if (output > 0) {
			genTokens = output;
			genEndAt = now;
		}
	});

	pi.on("turn_end", async (event, ctx) => {
		const tokens = genTokens || outputTokens(event.message);
		const from = firstContentAt || turnStart;
		const to = genEndAt || Date.now();
		const elapsed = (to - from) / 1000;

		// Leave the previous rate in place for turns with no generation (e.g. tool-only).
		if (tokens > 0 && elapsed > 0) rate = tokens / elapsed;

		turnStart = 0;
		paint(ctx);
	});
}
TOKPS_EOF

  if [ -f "$EXTENSION" ] && cmp -s "$tmp" "$EXTENSION"; then
    rm -f "$tmp"
    log "tokps-session extension unchanged"
    return 0
  fi
  mv "$tmp" "$EXTENSION"
  log "installed tokps-session extension to $EXTENSION"
}

# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

# assert_pi_provider — verify the provider actually landed on disk with a
# usable key. A models.json whose apiKey is empty (or still the literal env
# var name) makes pi fail at request time, long after this script exits.
assert_pi_provider() {
  if have jq && jq -e --arg p "$PROVIDER" --arg url "$BASE_URL" --arg model "$MODEL" '
        .providers[$p].baseUrl == $url
        and (.providers[$p].apiKey | type == "string" and length > 0)
        and (.providers[$p].models | map(.id) | index($model) != null)
      ' "$MODELS_JSON" >/dev/null 2>&1; then
    log "verified provider $PROVIDER serves $MODEL in $MODELS_JSON"
    return 0
  fi
  warn "provider $PROVIDER is not configured for $MODEL in $MODELS_JSON"
  record_failure pi-models
  return 1
}

assert_pi_default_model() {
  if have jq && jq -e --arg p "$PROVIDER" --arg model "$MODEL" \
      '.defaultProvider == $p and .defaultModel == $model' \
      "$SETTINGS_JSON" >/dev/null 2>&1; then
    log "verified default model $PROVIDER/$MODEL in $SETTINGS_JSON"
    return 0
  fi
  warn "default model is not $PROVIDER/$MODEL in $SETTINGS_JSON"
  record_failure pi-settings
  return 1
}

# pi reports a load error and exits nonzero for a broken extension, so a clean
# --version run with the extension in place proves it parses and registers.
assert_pi_extension() {
  if [ ! -s "$EXTENSION" ]; then
    warn "tokps-session extension missing at $EXTENSION"
    record_failure pi-extension
    return 1
  fi
  if have pi && pi --version >/dev/null 2>&1; then
    log "verified pi loads with the tokps-session extension"
    return 0
  fi
  warn "pi failed to run with the tokps-session extension installed"
  record_failure pi-extension
  return 1
}

# assert_pi_endpoint — prove the key is actually accepted. This is the only
# check that catches a typo'd paste, which otherwise surfaces as a 401 on the
# user's first prompt. Network problems are a warning; an explicit auth
# rejection is a failure.
assert_pi_endpoint() {
  if [ "${PI_SKIP_ENDPOINT_CHECK:-0}" = 1 ]; then
    log "skipping endpoint check (PI_SKIP_ENDPOINT_CHECK=1)"
    return 0
  fi
  have curl || { warn "curl unavailable; skipping endpoint check"; return 0; }

  local key http_status
  key=$(jq -r --arg p "$PROVIDER" '.providers[$p].apiKey // ""' "$MODELS_JSON" 2>/dev/null || echo "")
  [ -n "$key" ] || { warn "no API key on disk; skipping endpoint check"; return 0; }

  http_status=$(curl -s -o /dev/null -w '%{http_code}' -m 20 \
    -H "Authorization: Bearer $key" "$BASE_URL/models" 2>/dev/null || echo "000")

  case "$http_status" in
    2*)   log "verified $BASE_URL accepts the configured key (HTTP $http_status)"; return 0 ;;
    401|403)
          warn "endpoint rejected the configured key (HTTP $http_status) — check the key and re-run"
          record_failure pi-api-key
          return 1 ;;
    000)  warn "could not reach $BASE_URL; skipping endpoint check"; return 0 ;;
    *)    warn "unexpected response from $BASE_URL (HTTP $http_status); skipping endpoint check"; return 0 ;;
  esac
}

verify() {
  assert_pi_provider      || true
  assert_pi_default_model || true
  assert_pi_extension     || true
  assert_pi_endpoint      || true
  [ -z "${FAILED# }" ]
}

summary() {
  local exit_code=0
  echo
  log "done."
  if [ -n "${FAILED# }" ]; then
    warn "the following did not complete cleanly:${FAILED}"
    warn "re-run after resolving, or fix them manually."
    exit_code=1
  else
    echo "Run 'pi' to start. The footer shows tok/s, the active model, and the session id."
    echo "Resume a session with 'pi --session <partial-uuid>' (or '--fork' to branch it)."
  fi
  return "$exit_code"
}

main() {
  parse_args "$@"
  detect_platform
  ensure_package_manager

  if [ "$VERIFY_ONLY" = 1 ]; then
    # Standalone health check of an existing install: same assertions as a
    # fresh run, exits nonzero on any failure, changes nothing.
    verify || true
    summary
    return
  fi

  ensure_jq   || warn "jq install failed"
  ensure_node || warn "Node.js install failed"
  install_pi  || warn "pi install failed"

  resolve_api_key   || { summary; return; }
  configure_models  || warn "writing models.json failed"
  configure_settings || warn "writing settings.json failed"
  install_extension || warn "installing the tokps-session extension failed"

  verify || true
  summary
}

# SETUP_SKIP_MAIN=1 lets tests source individual functions without running the
# installer.
[ "${SETUP_SKIP_MAIN:-0}" = 1 ] || main "$@"
