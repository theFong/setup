#!/usr/bin/env bash
#
# pi-setup.sh — install the pi coding agent and point it at the Brev-hosted
# "webster" model endpoint, discovering the models accessible to the supplied
# key and adding a footer status line (tok/s, active model, session id).
#
# The sibling of omp-setup.sh: same endpoint, different agent.
#
# Installs the npm package, writes ~/.pi/agent/models.json (provider + models),
# sets the default provider/model in ~/.pi/agent/settings.json, and drops the
# tokps-session extension into ~/.pi/agent/extensions/.
#
# The API key is never stored in this repo. Supply it one of three ways:
#   WEBSTER_API_KEY=sk-... ./pi-setup.sh  # non-interactive (CI, provisioning)
#   ./pi-setup.sh                         # prompts on the terminal
#   ./pi-setup.sh --key-file ./key.txt    # read from a file (first line)
#
# Usage:
#   ./pi-setup.sh                      # merge config into any existing setup
#   ./pi-setup.sh --exclusive          # make this the ONLY configured provider
#   ./pi-setup.sh --check              # verify an existing install, change nothing
#
# Env overrides: WEBSTER_API_KEY / PI_API_KEY, PI_NO_PROMPT, PI_PROVIDER,
#                PI_BASE_URL, PI_MODEL, PI_CONTEXT_WINDOW, PI_MAX_TOKENS,
#                PI_CODING_AGENT_DIR, PI_NPM_PACKAGE, PI_SKIP_ENDPOINT_CHECK
#
# One-liner (the env prefix must be on bash, not before curl, or it is a plain
# shell variable that never reaches the script):
#   curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/pi-setup.sh \
#     | WEBSTER_API_KEY=sk-... bash
# Without the key it prompts on the terminal, reading /dev/tty because stdin is
# the pipe carrying the script itself.
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
PREFERRED_MODEL="glm-5.2"
MODEL="${PI_MODEL:-}"
MODEL_EXPLICIT=0
[ -n "$MODEL" ] && MODEL_EXPLICIT=1

# Discovery normally supplies each model's context limit. These values are
# only a fallback for an explicit manual model or a cap on advertised output;
# pi reserves maxTokens inside contextWindow, so an endpoint that advertises
# both as the same huge number would otherwise leave no useful prompt space.
DEFAULT_CONTEXT_WINDOW=320000
DEFAULT_MAX_TOKENS=32768
CONTEXT_WINDOW_OVERRIDE="${PI_CONTEXT_WINDOW:-}"
MAX_TOKENS_OVERRIDE="${PI_MAX_TOKENS:-}"
DISCOVERED_MODELS='[]'
DISCOVERY_STATUS=""

# pi reads its config from PI_CODING_AGENT_DIR, defaulting to ~/.pi/agent.
AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
MODELS_JSON="$AGENT_DIR/models.json"
SETTINGS_JSON="$AGENT_DIR/settings.json"
EXTENSION="$AGENT_DIR/extensions/tokps-session.ts"

NPM_PACKAGE="${PI_NPM_PACKAGE:-@earendil-works/pi-coding-agent}"

# WEBSTER_API_KEY is shared with omp-setup.sh: one variable configures either
# agent against the same endpoint.
API_KEY="${PI_API_KEY:-${WEBSTER_API_KEY:-}}"
KEY_FILE=""
EXCLUSIVE=0
VERIFY_ONLY=0

# Printed from a heredoc rather than read back out of the file: under
# `curl ... | bash` there is no script on disk to read.
usage() {
  cat <<'USAGE'
pi-setup.sh — install pi and discover models from the Brev-hosted webster endpoint.

  ./pi-setup.sh                    configure, merging into any existing setup
  ./pi-setup.sh --exclusive        make webster the ONLY configured provider
  ./pi-setup.sh --check            verify an existing install, change nothing
  ./pi-setup.sh --key-file PATH    read the API key from a file's first line

One-liner (env prefix goes on bash, not curl):
  curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/pi-setup.sh \
    | WEBSTER_API_KEY=sk-... bash

Env: WEBSTER_API_KEY / PI_API_KEY, PI_NO_PROMPT, PI_PROVIDER, PI_BASE_URL,
     PI_MODEL, PI_CONTEXT_WINDOW, PI_MAX_TOKENS, PI_CODING_AGENT_DIR,
     PI_NPM_PACKAGE, PI_SKIP_ENDPOINT_CHECK
USAGE
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --exclusive)            EXCLUSIVE=1 ;;
      --check|--verify-only)  VERIFY_ONLY=1 ;;
      --key-file)             shift; KEY_FILE="${1:-}"; [ -n "$KEY_FILE" ] || { echo "--key-file needs a path" >&2; exit 1; } ;;
      -h|--help)              usage; exit 0 ;;
      *)                      echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
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

# pi ships ESM using import attributes (`with { type: "json" }`). Node 18 does
# not merely lack the feature — it fails to *parse* the module, so the package
# installs cleanly and then dies on startup with
# `SyntaxError: Unexpected token 'with'`. Its engines field says >=22.19.0, and
# the distro nodejs on Ubuntu 22.04/24.04 is 18.x, so "npm exists" is not a
# sufficient check.
NODE_MIN_MAJOR=22

# node_major — major version of the node on PATH, or nonzero if there is none.
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

# NodeSource is the vendor-supported way to get a current Node on a distro
# whose packaged one is too old; brew's node is already current.
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
    *)   warn "no supported package manager for Node.js"; return 1 ;;
  esac
}

# assert_node_version — turn pi's cryptic startup SyntaxError into an
# actionable message here, before anything else is configured.
assert_node_version() {
  local major
  if major=$(node_major) && [ "$major" -ge "$NODE_MIN_MAJOR" ]; then
    log "verified node $(node --version) (>= v$NODE_MIN_MAJOR)"
    return 0
  fi
  warn "node $(node --version 2>/dev/null || echo 'is missing') is too old for pi (needs >= v$NODE_MIN_MAJOR)"
  record_failure nodejs
  return 1
}

ensure_node() {
  if node_is_current; then
    log "node $(node --version) already present"
    return 0
  fi
  if have node; then
    log "node $(node --version) is older than v$NODE_MIN_MAJOR; upgrading"
  else
    log "installing Node.js $NODE_MIN_MAJOR"
  fi
  install_node || warn "failed to install Node.js $NODE_MIN_MAJOR"
  hash -r 2>/dev/null || true
  assert_node_version
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
  node_is_current || {
    warn "skipping pi install until Node.js >= v$NODE_MIN_MAJOR is available"
    record_failure pi
    return 1
  }
  # "Already present" is not enough: a pi installed against an older Node is
  # on PATH but cannot start, and skipping the install would make a re-run
  # after upgrading Node fail exactly as the first one did.
  if have pi && pi --version >/dev/null 2>&1; then
    log "pi already present: $(pi --version 2>/dev/null)"
  else
    have npm || { warn "npm unavailable; cannot install pi"; record_failure pi; return 1; }
    if have pi; then log "pi is present but does not run; reinstalling"; fi
    log "installing pi ($NPM_PACKAGE)"
    npm_install_global "$NPM_PACKAGE" || { warn "failed to install $NPM_PACKAGE"; record_failure pi; }
    hash -r 2>/dev/null || true
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
    warn "no API key: set WEBSTER_API_KEY, pass --key-file, or run with a terminal attached"
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

# normalize_models_response RESPONSE_FILE — convert the OpenAI-compatible
# /models response into the model definitions pi requires. The API supplies a
# context limit per model. Output is capped unless PI_MAX_TOKENS explicitly
# overrides it because pi reserves maxTokens inside contextWindow.
normalize_models_response() {
  local response_file="$1"
  jq -ce \
    --arg context_override "$CONTEXT_WINDOW_OVERRIDE" \
    --arg max_override "$MAX_TOKENS_OVERRIDE" \
    --argjson fallback_context "$DEFAULT_CONTEXT_WINDOW" \
    --argjson fallback_max "$DEFAULT_MAX_TOKENS" '
    def positive_number($value; $fallback):
      (try ($value | tonumber) catch $fallback)
      | if type == "number" and . > 0 then . else $fallback end;
    [
      (.data // .models // [])[]?
      | if type == "string" then {id: .} elif type == "object" then . else empty end
      | (.id // .slug // .model // "") as $id
      | select(($id | type) == "string" and ($id | length) > 0)
      | (if $context_override != ""
          then positive_number($context_override; 0)
          else positive_number((.max_input_tokens // .context_window // .contextWindow // .context_length); $fallback_context)
        end) as $context
      | select($context > 0)
      | (if $max_override != ""
          then positive_number($max_override; 0)
          else ([positive_number((.max_output_tokens // .maxOutputTokens); $fallback_max), $fallback_max] | min)
        end) as $output
      | ((.display_name // .displayName // .name // $id)
          | if type == "string" and length > 0 then . else $id end) as $name
      | {
          id: $id,
          name: (if ($name | endswith("(Webster)")) then $name else ($name + " (Webster)") end),
          reasoning: (if (.reasoning | type) == "boolean" then .reasoning else true end),
          input: ["text"],
          contextWindow: $context,
          maxTokens: ([$output, $context] | min)
        }
    ]
    | unique_by(.id)
    | sort_by(.id)
    | if length > 0 then . else error("no usable models in endpoint response") end
  ' "$response_file"
}

# fetch_webster_models KEY — update DISCOVERED_MODELS from the live endpoint.
# DISCOVERY_STATUS distinguishes authentication and empty-access failures from
# transient/unparseable responses that may safely reuse an installed catalog.
fetch_webster_models() {
  local key="$1" response_file http_status normalized
  response_file=$(mktemp)
  DISCOVERY_STATUS=""
  if ! http_status=$(printf 'Authorization: Bearer %s\n' "$key" \
      | curl -sS -o "$response_file" -w '%{http_code}' -m 20 \
          --header @- "$BASE_URL/models" 2>/dev/null); then
    DISCOVERY_STATUS="unreachable"
    rm -f "$response_file"
    return 1
  fi

  case "$http_status" in
    2*)
      if normalized=$(normalize_models_response "$response_file" 2>/dev/null); then
        DISCOVERED_MODELS="$normalized"
        DISCOVERY_STATUS="ok"
        rm -f "$response_file"
        return 0
      fi
      if jq -e '((.data // .models // []) | type == "array" and length == 0)' \
          "$response_file" >/dev/null 2>&1; then
        DISCOVERY_STATUS="empty"
      else
        DISCOVERY_STATUS="invalid"
      fi
      ;;
    401|403) DISCOVERY_STATUS="auth-$http_status" ;;
    *)       DISCOVERY_STATUS="http-$http_status" ;;
  esac
  rm -f "$response_file"
  return 1
}

reuse_installed_models() {
  local installed
  [ -f "$MODELS_JSON" ] || return 1
  installed=$(jq -ce --arg p "$PROVIDER" '
    [.providers[$p].models[]?
      | select(
          (.id | type) == "string" and (.id | length) > 0
          and (.contextWindow | type) == "number" and .contextWindow > 0
          and (.maxTokens | type) == "number" and .maxTokens > 0
        )]
    | unique_by(.id)
    | sort_by(.id)
    | if length > 0 then . else error("no installed models") end
  ' "$MODELS_JSON" 2>/dev/null) || return 1
  DISCOVERED_MODELS="$installed"
}

configure_explicit_model_without_discovery() {
  [ "$MODEL_EXPLICIT" = 1 ] || return 1
  local context max
  context="${CONTEXT_WINDOW_OVERRIDE:-$DEFAULT_CONTEXT_WINDOW}"
  max="${MAX_TOKENS_OVERRIDE:-$DEFAULT_MAX_TOKENS}"
  DISCOVERED_MODELS=$(jq -cne \
    --arg id "$MODEL" --arg ctx "$context" --arg max "$max" '
      ($ctx | tonumber) as $context
      | ($max | tonumber) as $output
      | select($context > 0 and $output > 0)
      | [{
          id: $id,
          name: ($id + " (Webster)"),
          reasoning: true,
          input: ["text"],
          contextWindow: $context,
          maxTokens: ([$output, $context] | min)
        }]
    ') || return 1
}

discover_models() {
  if [ "${PI_SKIP_ENDPOINT_CHECK:-0}" = 1 ]; then
    if reuse_installed_models; then
      log "reusing installed Webster models (PI_SKIP_ENDPOINT_CHECK=1)"
      return 0
    fi
    if configure_explicit_model_without_discovery; then
      warn "model discovery skipped; configuring only explicit PI_MODEL=$MODEL"
      return 0
    fi
    warn "cannot skip model discovery on a fresh install without PI_MODEL"
    record_failure pi-models
    return 1
  fi

  if fetch_webster_models "$API_KEY"; then
    log "discovered $(printf '%s' "$DISCOVERED_MODELS" | jq 'length') model(s) accessible to this key"
    return 0
  fi

  case "$DISCOVERY_STATUS" in
    auth-*)
      warn "endpoint rejected the configured key (HTTP ${DISCOVERY_STATUS#auth-}) — check the key and re-run"
      record_failure pi-api-key
      return 1
      ;;
    empty)
      warn "endpoint accepted the key but advertised no accessible models"
      record_failure pi-models
      return 1
      ;;
  esac

  if reuse_installed_models; then
    warn "model discovery failed ($DISCOVERY_STATUS); reusing the installed model list"
    return 0
  fi
  if configure_explicit_model_without_discovery; then
    warn "model discovery failed ($DISCOVERY_STATUS); configuring only explicit PI_MODEL=$MODEL"
    return 0
  fi
  warn "model discovery failed ($DISCOVERY_STATUS) and there is no installed model list to reuse"
  record_failure pi-models
  return 1
}

model_is_discovered() {
  printf '%s' "$DISCOVERED_MODELS" | jq -e --arg model "$1" \
    'map(.id) | index($model) != null' >/dev/null 2>&1
}

select_default_model() {
  local installed_default=""
  if [ "$MODEL_EXPLICIT" = 1 ]; then
    model_is_discovered "$MODEL" || {
      warn "PI_MODEL=$MODEL is not accessible to this key"
      record_failure pi-settings
      return 1
    }
  else
    if [ -f "$SETTINGS_JSON" ]; then
      installed_default=$(jq -r '.defaultModel // empty' "$SETTINGS_JSON" 2>/dev/null || true)
    fi
    if [ -n "$installed_default" ] && model_is_discovered "$installed_default"; then
      MODEL="$installed_default"
    elif model_is_discovered "$PREFERRED_MODEL"; then
      MODEL="$PREFERRED_MODEL"
    else
      MODEL=$(printf '%s' "$DISCOVERED_MODELS" | jq -r '.[0].id')
    fi
  fi
  [ -n "$MODEL" ] || {
    warn "could not select a default Webster model"
    record_failure pi-settings
    return 1
  }
  log "selected default model $PROVIDER/$MODEL"
}

# Pi does not perform provider discovery itself, so the installer writes every
# model returned for this key into models.json with endpoint-derived limits.
configure_models() {
  log "configuring provider '$PROVIDER' with discovered models in $MODELS_JSON"
  printf '%s' "$DISCOVERED_MODELS" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || {
    warn "no discovered models are available to configure"
    record_failure pi-models
    return 1
  }
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
        models: $models
      }'
  PI_INSTALL_API_KEY="$API_KEY" jq_edit "$MODELS_JSON" '{"providers":{}}' "$filter" \
    --arg p "$PROVIDER" --arg url "$BASE_URL" \
    --argjson models "$DISCOVERED_MODELS" --argjson exclusive "$EXCLUSIVE" \
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
  local count
  if have jq && jq -e --arg p "$PROVIDER" --arg url "$BASE_URL" '
        .providers[$p].baseUrl == $url
        and (.providers[$p].apiKey | type == "string" and length > 0)
        and (.providers[$p].models | type == "array" and length > 0)
        and (.providers[$p].models
          | (map(.id) | length) == (map(.id) | unique | length))
        and all(.providers[$p].models[];
          (.id | type) == "string" and (.id | length) > 0
          and (.contextWindow | type) == "number" and .contextWindow > 0
          and (.maxTokens | type) == "number" and .maxTokens > 0
          and .maxTokens <= .contextWindow)
      ' "$MODELS_JSON" >/dev/null 2>&1; then
    count=$(jq -r --arg p "$PROVIDER" '.providers[$p].models | length' "$MODELS_JSON")
    log "verified provider $PROVIDER has $count discovered model(s) in $MODELS_JSON"
    return 0
  fi
  warn "provider $PROVIDER has no valid discovered model list in $MODELS_JSON"
  record_failure pi-models
  return 1
}

assert_pi_default_model() {
  local default_model
  default_model=$(jq -r '.defaultModel // empty' "$SETTINGS_JSON" 2>/dev/null || true)
  if have jq && [ -n "$default_model" ] && \
      jq -e --arg p "$PROVIDER" --arg model "$default_model" \
        '.providers[$p].models | map(.id) | index($model) != null' \
        "$MODELS_JSON" >/dev/null 2>&1 && \
      jq -e --arg p "$PROVIDER" '.defaultProvider == $p' \
        "$SETTINGS_JSON" >/dev/null 2>&1; then
    log "verified default model $PROVIDER/$default_model is in the discovered model list"
    return 0
  fi
  warn "default model is not an installed $PROVIDER model in $SETTINGS_JSON"
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

# assert_pi_endpoint — prove the key is accepted and its live model list still
# matches models.json. Network problems preserve installed state as a warning;
# authentication, empty access, and confirmed catalog drift are failures.
assert_pi_endpoint() {
  if [ "${PI_SKIP_ENDPOINT_CHECK:-0}" = 1 ]; then
    log "skipping endpoint check (PI_SKIP_ENDPOINT_CHECK=1)"
    return 0
  fi
  have curl || { warn "curl unavailable; skipping endpoint check"; return 0; }

  local key installed live
  key=$(jq -r --arg p "$PROVIDER" '.providers[$p].apiKey // ""' "$MODELS_JSON" 2>/dev/null || echo "")
  [ -n "$key" ] || { warn "no API key on disk; skipping endpoint check"; return 0; }

  if fetch_webster_models "$key"; then
    installed=$(jq -cS --arg p "$PROVIDER" '.providers[$p].models | sort_by(.id)' \
      "$MODELS_JSON" 2>/dev/null || echo "")
    live=$(printf '%s' "$DISCOVERED_MODELS" | jq -cS 'sort_by(.id)')
    if [ "$installed" = "$live" ]; then
      log "verified installed models match current endpoint access"
      return 0
    fi
    warn "installed Webster models differ from current endpoint access; re-run pi-setup.sh"
    record_failure pi-models
    return 1
  fi

  case "$DISCOVERY_STATUS" in
    auth-*)
          warn "endpoint rejected the configured key (HTTP ${DISCOVERY_STATUS#auth-}) — check the key and re-run"
          record_failure pi-api-key
          return 1 ;;
    empty)
          warn "endpoint accepts the configured key but advertises no accessible models"
          record_failure pi-models
          return 1 ;;
    *)    warn "could not validate live model access ($DISCOVERY_STATUS); keeping installed models"; return 0 ;;
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

  resolve_api_key      || { summary; return; }
  discover_models      || { summary; return; }
  select_default_model || { summary; return; }
  configure_models     || warn "writing models.json failed"
  configure_settings || warn "writing settings.json failed"
  install_extension || warn "installing the tokps-session extension failed"

  verify || true
  summary
}

# SETUP_SKIP_MAIN=1 lets tests source individual functions without running the
# installer.
[ "${SETUP_SKIP_MAIN:-0}" = 1 ] || main "$@"
