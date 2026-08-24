#!/usr/bin/env bash
#
# omp-setup.sh — install and configure oh-my-pi (omp) against the Brev-hosted
# "webster" model endpoint.
#
#   * installs omp if it is not already on PATH
#   * registers the webster provider (OpenAI-compatible LiteLLM proxy)
#   * discovers every model accessible to the supplied key
#   * preserves an accessible Webster default, otherwise prefers glm-5.2
#   * turns on "nerd mode": Nerd Font symbols + the nerd status line preset
#     (tok/sec spark, TTFT, context %, cost, cache reads, elapsed time)
#
# Usage:
#   OMP_WEBSTER_API_KEY=sk-... ./omp-setup.sh
#   ./omp-setup.sh                      # prompts for the key
#   ./omp-setup.sh --check              # verify an existing install, change nothing
#   ./omp-setup.sh --no-smoke           # skip the live model round-trip
#
# Env overrides: OMP_WEBSTER_API_KEY / WEBSTER_API_KEY, OMP_BASE_URL,
#                OMP_MODEL, OMP_SKIP_PROFILE
#
# Every run asserts the resulting on-disk state and the live endpoint, per
# STYLE_GUIDE.md. Negative paths are covered in test.sh, which sources this
# file with SETUP_SKIP_MAIN=1.
#
# The API key is written to $AGENT_DIR/models.yml with mode 0600. It is never
# committed to this repo.

set -euo pipefail

BASE_URL="${OMP_BASE_URL:-https://webster-models-extnode-3gdrajbr0hiykknxzitck9yaiwo.apps.run.brev.nvidia.com/v1}"
PROVIDER_ID="webster"
PREFERRED_MODEL_ID="glm-5.2"
REQUESTED_MODEL="${OMP_MODEL:-}"
MODEL_ID=""
MODEL_EXPLICIT=0
[ -n "$REQUESTED_MODEL" ] && MODEL_EXPLICIT=1
DEFAULT_MODEL=""
DISCOVERED_MODEL_IDS=""
DISCOVERY_STATUS=""
NPM_PKG="@oh-my-pi/pi-coding-agent"

MARK_BEGIN="  # >>> theFong/setup: ${PROVIDER_ID} provider (managed) >>>"
MARK_END="  # <<< theFong/setup: ${PROVIDER_ID} provider (managed) <<<"

CHECK_ONLY=0
RUN_SMOKE=1
AGENT_DIR=""
API_KEY=""

# ---------------------------------------------------------------------------
# helpers (mirrors install.sh; see STYLE_GUIDE.md)
# ---------------------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- install omp

# ensure_omp_path — omp lands in a user-local bin depending on how it was
# installed: ~/.bun/bin for `bun install -g`, ~/.local/bin for the omp.sh
# installer. Add both to PATH for this process and persist them, so a new
# shell finds omp too.
ensure_omp_path() {
  local dir profile
  case "${SHELL:-}" in
    */zsh)  profile="$HOME/.zshrc" ;;
    */bash) profile="$HOME/.bashrc" ;;
    *)      profile="$HOME/.profile" ;;
  esac
  for dir in "$HOME/.bun/bin" "$HOME/.local/bin"; do
    [ -d "$dir" ] || continue
    case ":$PATH:" in *":$dir:"*) ;; *) PATH="$dir:$PATH"; export PATH ;; esac
    if [ "${OMP_SKIP_PROFILE:-0}" != "1" ]; then
      touch "$profile"
      grep -qF "$dir" "$profile" 2>/dev/null || \
        printf '\nexport PATH="%s:$PATH"\n' "$dir" >> "$profile"
    fi
  done
}

install_omp() {
  ensure_omp_path
  if have omp; then
    ok "omp already installed ($(omp --version 2>/dev/null || echo unknown))"
    return 0
  fi
  [ "$CHECK_ONLY" = 1 ] && die "omp is not installed (and --check was given)"

  log "installing omp"
  if have bun; then
    bun install -g "$NPM_PKG"
  elif have curl; then
    # Vendor's supported installer: downloads a prebuilt binary to ~/.local/bin
    # and works on macOS and Linux, x86_64 and arm64.
    curl -fsSL https://omp.sh/install | sh
  else
    die "need either bun or curl to install omp"
  fi
  ensure_omp_path

  # `command -v` alone is satisfied by a truncated download or a
  # wrong-architecture binary, so prove it actually runs.
  have omp || die "omp is not on PATH after installation; open a new shell and re-run"
  omp --version >/dev/null 2>&1 || die "omp is on PATH but failed to run"
  ok "installed $(omp --version)"
}

# -------------------------------------------------------------------- api key

# key_from_models_yml FILE — read the provider's key back out of models.yml so
# re-runs do not re-prompt.
key_from_models_yml() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk -v pid="$PROVIDER_ID" '
    $0 ~ "^[ \t]{2}" pid ":[ \t]*$" { inprov = 1; next }
    inprov && /^[ \t]{0,2}[^ \t#]/  { inprov = 0 }
    inprov && /^[ \t]+apiKey:[ \t]*/ { sub(/^[ \t]+apiKey:[ \t]*/, ""); print; exit }
  ' "$f"
}

resolve_key() {
  API_KEY="${OMP_WEBSTER_API_KEY:-${WEBSTER_API_KEY:-}}"
  if [ -z "$API_KEY" ]; then
    API_KEY="$(key_from_models_yml "$AGENT_DIR/models.yml")"
    [ -n "$API_KEY" ] && ok "reusing the API key already in models.yml"
  fi
  if [ -z "$API_KEY" ]; then
    [ "$CHECK_ONLY" = 1 ] && die "no API key found (set OMP_WEBSTER_API_KEY)"
    [ -t 0 ] || die "no API key: set OMP_WEBSTER_API_KEY (stdin is not a tty, cannot prompt)"
    printf 'webster API key (sk-...): ' >&2
    read -rs API_KEY
    printf '\n' >&2
  fi
  [ -n "$API_KEY" ] || die "empty API key"
}

# ------------------------------------------------------------- model discovery

# normalize_model_ids RESPONSE_FILE — print one sorted model id per line from
# either the OpenAI `.data` shape or LiteLLM's `.models` shape. jq is preferred,
# with python3 as a portability fallback for standalone one-line installs.
normalize_model_ids() {
  local response_file="$1"
  if have jq; then
    jq -r '
      (.data // .models // []) as $models
      | if ($models | type) != "array" then error("model list is not an array") else $models end
      | [
          .[]
          | if type == "string" then .
            elif type == "object" then (.id // .slug // .model // empty)
            else empty
            end
          | select(type == "string" and length > 0)
        ]
      | unique
      | sort
      | .[]
    ' "$response_file"
    return
  fi
  if have python3; then
    python3 - "$response_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
models = payload.get("data", payload.get("models", []))
if not isinstance(models, list):
    raise SystemExit("model list is not an array")
ids = set()
for item in models:
    if isinstance(item, str):
        model_id = item
    elif isinstance(item, dict):
        model_id = item.get("id") or item.get("slug") or item.get("model")
    else:
        continue
    if isinstance(model_id, str) and model_id:
        ids.add(model_id)
print("\n".join(sorted(ids)))
PY
    return
  fi
  warn "need jq or python3 to parse the endpoint's model catalog"
  return 1
}

# fetch_omp_models URL KEY — authenticate to /models and update the discovered
# catalog. The key is supplied to curl over stdin rather than exposed in argv.
fetch_omp_models() {
  local url="$1" key="$2" response_file http_status normalized
  have curl || { DISCOVERY_STATUS="no-curl"; return 1; }
  if ! have jq && ! have python3; then
    DISCOVERY_STATUS="no-parser"
    return 1
  fi
  response_file="$(mktemp)"
  DISCOVERY_STATUS=""
  if ! http_status=$(printf 'Authorization: Bearer %s\n' "$key" \
      | curl -sS -o "$response_file" -w '%{http_code}' --max-time 30 \
          --header @- "$url/models" 2>/dev/null); then
    DISCOVERY_STATUS="unreachable"
    rm -f "$response_file"
    return 1
  fi

  case "$http_status" in
    2*)
      if normalized="$(normalize_model_ids "$response_file" 2>/dev/null)"; then
        if [ -n "$normalized" ]; then
          DISCOVERED_MODEL_IDS="$normalized"
          DISCOVERY_STATUS="ok"
          rm -f "$response_file"
          return 0
        fi
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

model_is_discovered() {
  [ -n "$1" ] && printf '%s\n' "$DISCOVERED_MODEL_IDS" | grep -Fqx -- "$1"
}

discover_models() {
  local count
  if fetch_omp_models "$BASE_URL" "$API_KEY"; then
    count=$(printf '%s\n' "$DISCOVERED_MODEL_IDS" | awk 'NF { n++ } END { print n + 0 }')
    log "discovered $count Webster model(s) accessible to this key"
    return 0
  fi
  case "$DISCOVERY_STATUS" in
    auth-*)  warn "endpoint rejected the configured key (HTTP ${DISCOVERY_STATUS#auth-})" ;;
    empty)   warn "endpoint accepted the key but advertised no accessible models" ;;
    invalid) warn "endpoint returned an invalid model catalog" ;;
    no-curl) warn "curl not found; cannot discover accessible models" ;;
    no-parser) warn "need jq or python3 to parse the endpoint's model catalog" ;;
    http-*)  warn "endpoint returned HTTP ${DISCOVERY_STATUS#http-} while listing models" ;;
    *)       warn "endpoint unreachable while listing models" ;;
  esac
  return 1
}

select_default_model() {
  local installed_default installed_selector installed_id
  if [ "$MODEL_EXPLICIT" = 1 ]; then
    if model_is_discovered "$REQUESTED_MODEL"; then
      MODEL_ID="$REQUESTED_MODEL"
    else
      MODEL_ID="${REQUESTED_MODEL%:*}"
      if [ "$MODEL_ID" = "$REQUESTED_MODEL" ] || ! model_is_discovered "$MODEL_ID"; then
        warn "OMP_MODEL=$REQUESTED_MODEL is not accessible to this key"
        return 1
      fi
    fi
    DEFAULT_MODEL="${PROVIDER_ID}/${REQUESTED_MODEL}"
  else
    installed_default="$(role_default)"
    case "$installed_default" in
      "$PROVIDER_ID"/*) installed_selector="${installed_default#"$PROVIDER_ID"/}" ;;
      *) installed_selector="" ;;
    esac
    if [ -n "$installed_selector" ] && model_is_discovered "$installed_selector"; then
      MODEL_ID="$installed_selector"
      DEFAULT_MODEL="$installed_default"
    else
      installed_id="${installed_selector%:*}"
    fi
    if [ -z "$MODEL_ID" ]; then
      if [ -n "$installed_id" ] && [ "$installed_id" != "$installed_selector" ] \
          && model_is_discovered "$installed_id"; then
        MODEL_ID="$installed_id"
        DEFAULT_MODEL="$installed_default"
      elif model_is_discovered "$PREFERRED_MODEL_ID"; then
        MODEL_ID="$PREFERRED_MODEL_ID"
      else
        MODEL_ID="$(printf '%s\n' "$DISCOVERED_MODEL_IDS" | sed -n '1p')"
      fi
    fi
  fi
  [ -n "$MODEL_ID" ] || { warn "could not select a default Webster model"; return 1; }
  [ -n "$DEFAULT_MODEL" ] || DEFAULT_MODEL="${PROVIDER_ID}/${MODEL_ID}"
  log "selected default model $DEFAULT_MODEL"
}

# ------------------------------------------------------------------ models.yml

# merge_models_yml FILE KEY — splice the managed provider block into FILE,
# preserving every other provider. Idempotent: re-running produces a
# byte-identical file. Prints nothing; writes FILE in place.
merge_models_yml() {
  local f="$1" key="$2"
  local block stripped merged
  block="$(mktemp)"; stripped="$(mktemp)"; merged="$(mktemp)"

  cat >"$block" <<-YAML
	$MARK_BEGIN
	  # Brev-hosted LiteLLM proxy (OpenAI-compatible). OMP discovers every model
	  # accessible to this key and exposes it as ${PROVIDER_ID}/<model-id>.
	  ${PROVIDER_ID}:
	    baseUrl: ${BASE_URL}
	    apiKey: ${key}
	    api: openai-completions
	    authHeader: true
	    discovery:
	      type: litellm
	$MARK_END
	YAML

  if [ -f "$f" ]; then
    # Drop a previous managed block, and any hand-written provider entry with
    # the same id — a duplicate YAML key would silently shadow ours.
    awk -v mb="$MARK_BEGIN" -v me="$MARK_END" -v pid="$PROVIDER_ID" '
      {
        if ($0 == mb) { skip = 1; next }
        if ($0 == me) { skip = 0; next }
        if (skip) next
        if (drop) {
          if ($0 ~ /^[ \t]{3,}/ || $0 ~ /^[ \t]*$/) next
          drop = 0
        }
        if ($0 ~ "^[ \t]{2}" pid ":[ \t]*$") { drop = 1; next }
        print
      }
    ' "$f" >"$stripped"
  else
    : >"$stripped"
  fi

  # Splice the block under the existing top-level `providers:` key, or create it.
  awk -v blockfile="$block" '
    function emit(  line) { while ((getline line < blockfile) > 0) print line; close(blockfile) }
    !ins && /^providers:[ \t]*(\{\}[ \t]*)?$/ { print "providers:"; emit(); ins = 1; next }
    { print }
    END { if (!ins) { print "providers:"; emit() } }
  ' "$stripped" >"$merged"

  if [ -f "$f" ] && cmp -s "$f" "$merged"; then
    rm -f "$block" "$stripped" "$merged"
    return 1   # already up to date
  fi
  [ -f "$f" ] && cp "$f" "$f.bak"
  mkdir -p "$(dirname "$f")"
  cat "$merged" >"$f"
  chmod 600 "$f"
  rm -f "$block" "$stripped" "$merged"
  return 0
}

write_models_yml() {
  local f="$AGENT_DIR/models.yml"
  if merge_models_yml "$f" "$API_KEY"; then
    [ -f "$f.bak" ] && warn "previous models.yml backed up to $f.bak"
    ok "wrote $f (mode 600)"
  else
    ok "models.yml already up to date"
  fi
}

# ------------------------------------------------------------------ config.yml

set_cfg() {
  local key="$1" val="$2" cur
  cur="$(omp config get "$key" 2>/dev/null || true)"
  if [ "$cur" = "$val" ]; then
    ok "$key = $val"
    return 0
  fi
  omp config set "$key" "$val" >/dev/null
  ok "$key = $val (was: ${cur:-unset})"
}

# `modelRoles` is a record, not a dotted settings key — read, merge, write the
# whole map so sibling roles (advisor, smol, slow, tiny) survive.
role_default() {
  omp config get modelRoles --json 2>/dev/null \
    | awk -F'"' '/"default"[ \t]*:/ { print $4; exit }'
}

set_default_model() {
  local cur merged
  cur="$(role_default)"
  if [ "$cur" = "$DEFAULT_MODEL" ]; then
    ok "modelRoles.default = $DEFAULT_MODEL"
    return 0
  fi
  if have jq; then
    merged="$(omp config get modelRoles --json | jq -c --arg m "$DEFAULT_MODEL" '(.value // {}) | .default = $m')"
  elif have python3; then
    merged="$(omp config get modelRoles --json | M="$DEFAULT_MODEL" python3 -c \
      'import json,os,sys; d=json.load(sys.stdin).get("value") or {}; d["default"]=os.environ["M"]; print(json.dumps(d))')"
  else
    merged="{\"default\":\"$DEFAULT_MODEL\"}"
    warn "neither jq nor python3 found — replacing modelRoles wholesale"
  fi
  omp config set modelRoles "$merged" >/dev/null
  ok "modelRoles.default = $DEFAULT_MODEL (was: ${cur:-unset})"
}

# ------------------------------------------------------------------ assertions

# assert_omp_config — the configuration this script exists to produce must be
# readable back out of omp itself, not merely written to a file.
assert_omp_config() {
  local key cur
  for key in symbolPreset statusLine.preset; do
    cur="$(omp config get "$key" 2>/dev/null || true)"
    [ "$cur" = "nerd" ] || { warn "$key is '${cur:-unset}', expected 'nerd'"; return 1; }
    ok "$key = $cur"
  done
  cur="$(role_default)"
  [ "$cur" = "$DEFAULT_MODEL" ] || { warn "modelRoles.default is '${cur:-unset}', expected '$DEFAULT_MODEL'"; return 1; }
  ok "modelRoles.default = $cur"
  grep -q "^    baseUrl: $BASE_URL$" "$AGENT_DIR/models.yml" 2>/dev/null \
    || { warn "baseUrl is not set to $BASE_URL in models.yml"; return 1; }
  ok "baseUrl = $BASE_URL"
  grep -A8 "^  ${PROVIDER_ID}:$" "$AGENT_DIR/models.yml" 2>/dev/null \
    | grep -q '^      type: litellm$' \
    || { warn "LiteLLM discovery is not enabled for $PROVIDER_ID in models.yml"; return 1; }
  ok "LiteLLM model discovery is enabled"
}

# assert_omp_endpoint URL KEY — the base URL and key must actually serve the
# model we just made the default. A config pointing at a dead or wrong endpoint
# looks fine on disk and fails on first use.
assert_omp_endpoint() {
  local url="$1" key="$2" count
  if ! fetch_omp_models "$url" "$key"; then
    warn "could not refresh endpoint model catalog ($DISCOVERY_STATUS)"
    return 1
  fi
  model_is_discovered "$MODEL_ID" || {
    warn "endpoint is reachable but no longer serves the configured default '$MODEL_ID'"
    return 1
  }
  count=$(printf '%s\n' "$DISCOVERED_MODEL_IDS" | awk 'NF { n++ } END { print n + 0 }')
  ok "endpoint serves $count accessible model(s), including $MODEL_ID"
}

# assert_omp_smoke — one real round-trip. No --model flag: this exercises the
# configured default, which is the thing being claimed.
assert_omp_smoke() {
  local out
  log "smoke test: one-shot prompt through the default model"
  if ! out="$(cd "$(mktemp -d)" && omp -p --no-session --no-tools --no-skills \
      "Reply with exactly: OMP_OK" 2>&1)"; then
    warn "omp failed to run: $out"
    return 1
  fi
  case "$out" in
    *OMP_OK*) ok "model replied: $(printf '%s' "$out" | tr -d '\n' | cut -c1-60)"; return 0 ;;
    *) warn "unexpected reply from $DEFAULT_MODEL: $out"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------- main

# Piped to bash (curl | bash) there is no script file to read the header
# comment back out of, so fall back to an inline summary.
usage() {
  local src="${BASH_SOURCE[0]:-$0}"
  if [ -r "$src" ] && head -1 "$src" | grep -q '^#!'; then
    grep '^#' "$src" | cut -c 3-
    return 0
  fi
  cat <<EOF
omp-setup.sh — install omp and point it at the Brev-hosted $PROVIDER_ID endpoint,
discovering accessible models and enabling nerd mode.

  WEBSTER_API_KEY=sk-... omp-setup.sh              install and verify
  omp-setup.sh --check                             verify only, change nothing
  omp-setup.sh --no-smoke                          skip the live model round-trip

The key comes from OMP_WEBSTER_API_KEY or WEBSTER_API_KEY; OMP_MODEL optionally
selects an accessible default. When run from a terminal, the script prompts for
the key if neither key variable is set.
EOF
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --check)    CHECK_ONLY=1 ;;
      --no-smoke) RUN_SMOKE=0 ;;
      -h|--help)  usage; return 0 ;;
      *) printf 'unknown flag: %s (try --help)\n' "$arg" >&2; return 2 ;;
    esac
  done

  install_omp
  AGENT_DIR="$(omp config path 2>/dev/null || true)"
  [ -n "$AGENT_DIR" ] || AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
  log "agent dir: $AGENT_DIR"
  mkdir -p "$AGENT_DIR"

  resolve_key
  discover_models || die "model discovery failed"
  select_default_model || die "default model selection failed"

  if [ "$CHECK_ONLY" = 0 ]; then
    log "registering the $PROVIDER_ID provider"
    write_models_yml

    log "configuring nerd mode and the default model"
    set_cfg symbolPreset nerd
    set_cfg statusLine.preset nerd
    set_default_model
  fi

  log "verifying"
  assert_omp_config   || die "configuration did not land as expected"
  assert_omp_endpoint "$BASE_URL" "$API_KEY" || die "endpoint verification failed"
  if [ "$RUN_SMOKE" = 1 ]; then
    assert_omp_smoke || die "smoke test failed"
  else
    warn "skipping the live smoke test (--no-smoke)"
  fi

  if [ "$CHECK_ONLY" = 1 ]; then
    log "all checks passed"
    return 0
  fi

  cat <<EOF

$(printf '\033[1;32mdone\033[0m') — omp is configured.

  provider   $PROVIDER_ID -> $BASE_URL
  model      $DEFAULT_MODEL (default)
  status     nerd preset: tok/sec spark, TTFT, context %, cost, cache, elapsed
  symbols    nerd (needs a Nerd Font in your terminal: https://nerdfonts.com)

Run 'omp' to start. Re-run this script any time; it is idempotent.
Verify without changing anything: ./omp-setup.sh --check
EOF
}

if [ "${SETUP_SKIP_MAIN:-0}" != "1" ]; then
  main "$@"
fi
