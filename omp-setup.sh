#!/usr/bin/env bash
#
# omp-setup.sh — install and configure oh-my-pi (omp) against the Brev-hosted
# "webster" model endpoint.
#
#   * installs omp if it is not already on PATH
#   * registers the webster provider (OpenAI-compatible LiteLLM proxy)
#   * defaults the agent to glm-5.2
#   * turns on "nerd mode": Nerd Font symbols + the nerd status line preset
#     (tok/sec spark, TTFT, context %, cost, cache reads, elapsed time)
#
# Usage:
#   OMP_WEBSTER_API_KEY=sk-... ./omp-setup.sh
#   ./omp-setup.sh                      # prompts for the key
#   ./omp-setup.sh --check              # verify an existing install, change nothing
#   ./omp-setup.sh --no-smoke           # skip the live model round-trip
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
MODEL_ID="glm-5.2"
DEFAULT_MODEL="${PROVIDER_ID}/${MODEL_ID}"
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
	  # Brev-hosted LiteLLM proxy (OpenAI-compatible). Models are discovered from
	  # the proxy and selectable as ${PROVIDER_ID}/<model-id>, e.g. ${DEFAULT_MODEL}.
	  ${PROVIDER_ID}:
	    baseUrl: ${BASE_URL}
	    apiKey: ${key}
	    api: openai-completions
	    authHeader: true
	    discovery:
	      type: litellm
	    modelOverrides:
	      ${MODEL_ID}:
	        contextWindow: 350000
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
}

# assert_omp_endpoint URL KEY — the base URL and key must actually serve the
# model we just made the default. A config pointing at a dead or wrong endpoint
# looks fine on disk and fails on first use.
assert_omp_endpoint() {
  local url="$1" key="$2" out
  have curl || { warn "curl not found; cannot verify the endpoint"; return 1; }
  if ! out="$(curl -fsS --max-time 30 -H "Authorization: Bearer $key" "$url/models" 2>&1)"; then
    warn "endpoint unreachable or key rejected: $out"
    return 1
  fi
  case "$out" in
    *"\"$MODEL_ID\""*) ok "endpoint reachable, $MODEL_ID is served"; return 0 ;;
    *) warn "endpoint reachable but does not serve '$MODEL_ID'"; return 1 ;;
  esac
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
defaulting to $MODEL_ID with nerd mode enabled.

  WEBSTER_API_KEY=sk-... omp-setup.sh              install and verify
  omp-setup.sh --check                             verify only, change nothing
  omp-setup.sh --no-smoke                          skip the live model round-trip

The key comes from OMP_WEBSTER_API_KEY or WEBSTER_API_KEY; when the script is
run from a terminal (not piped) it prompts instead.
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
