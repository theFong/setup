#!/usr/bin/env bash
#
# install.sh — bootstrap a new machine with a baseline dev environment.
#
# Installs: Claude Code, Codex CLI, opencode, tmux, git, gh, jq, ripgrep, fzf,
# wget, curl, htop, and the Go toolchain. Then links this repo's Claude
# config (CLAUDE.md + skills) into ~/.claude.
#
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/theFong/setup/main/install.sh | bash
#
# Re-running is safe: anything already present is skipped.
#
# Works on macOS (Homebrew) and Linux (apt / dnf / apk). Everything is
# wrapped in main() and invoked on the last line so a truncated download
# never executes a partial script.

set -euo pipefail

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

OS=""        # darwin | linux
ARCH=""      # x86_64 | arm64 | ...
PM=""        # brew | apt | dnf | apk
SUDO=""      # "" when root, else "sudo"
APT_UPDATED=0
FAILED=""    # space-separated list of things that failed

detect_platform() {
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
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
    if ! have brew; then
      log "installing Homebrew"
      NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    # Make brew available on this shell (Apple Silicon vs Intel paths).
    if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
    PM="brew"
    return
  fi

  # Linux
  if   have apt-get; then PM="apt"
  elif have dnf;     then PM="dnf"
  elif have apk;     then PM="apk"
  else echo "no supported package manager found (need apt, dnf, or apk)" >&2; exit 1; fi
  log "using package manager: $PM"
}

pm_update_once() {
  case "$PM" in
    apt) [ "$APT_UPDATED" = 1 ] || { $SUDO apt-get update -y; APT_UPDATED=1; } ;;
    *)   : ;;  # dnf/apk/brew resolve metadata per-install
  esac
}

pm_install() {
  pm_update_once
  case "$PM" in
    brew) brew install "$@" ;;
    apt)  $SUDO apt-get install -y "$@" ;;
    dnf)  $SUDO dnf install -y "$@" ;;
    apk)  $SUDO apk add "$@" ;;
  esac
}

# add_path DIR — prepend to current PATH and persist to the user's shell rc.
add_path() {
  local dir="$1" profile
  case ":$PATH:" in *":$dir:"*) ;; *) PATH="$dir:$PATH"; export PATH ;; esac
  case "${SHELL:-}" in
    */zsh)  profile="$HOME/.zshrc" ;;
    */bash) profile="$HOME/.bashrc" ;;
    *)      profile="$HOME/.profile" ;;
  esac
  touch "$profile"
  grep -qF "$dir" "$profile" 2>/dev/null || \
    printf '\nexport PATH="%s:$PATH"\n' "$dir" >> "$profile"
}

# ---------------------------------------------------------------------------
# package installs
# ---------------------------------------------------------------------------

# install_one TOOL [BINARY] — install TOOL via the package manager unless its
# BINARY (defaults to TOOL) is already on PATH. Never aborts the script.
install_one() {
  local tool="$1" bin="${2:-$1}"
  if have "$bin"; then log "$tool already present"; return; fi
  log "installing $tool"
  if ! pm_install "$tool"; then warn "failed to install $tool"; FAILED="$FAILED $tool"; fi
}

install_base_tools() {
  install_one git
  install_one jq
  install_one ripgrep rg
  install_one fzf
  install_one wget
  install_one curl
  install_one htop
  install_one tmux
}

# gh isn't in the base repos on every distro, so handle it explicitly.
install_gh() {
  if have gh; then log "gh already present"; return; fi
  log "installing gh (GitHub CLI)"
  case "$PM" in
    brew) brew install gh || { warn "failed to install gh"; FAILED="$FAILED gh"; } ;;
    apt)
      $SUDO install -d -m 0755 /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
      $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
      APT_UPDATED=0; pm_update_once
      $SUDO apt-get install -y gh || { warn "failed to install gh"; FAILED="$FAILED gh"; }
      ;;
    dnf)
      $SUDO dnf install -y gh || {
        $SUDO dnf install -y 'dnf-command(config-manager)' || true
        $SUDO dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo || true
        $SUDO dnf install -y gh || { warn "failed to install gh"; FAILED="$FAILED gh"; }
      }
      ;;
    apk)
      pm_install github-cli || { warn "failed to install gh"; FAILED="$FAILED gh"; }
      ;;
  esac
}

# Ookla speedtest CLI — for evaluating north/south internet throughput.
# Not in base repos: uses Ookla's packagecloud repo on apt/dnf, the teamookla
# Homebrew tap on macOS, and a static tarball on Alpine.
install_speedtest() {
  if have speedtest; then log "speedtest already present"; return; fi
  log "installing Ookla speedtest CLI"
  case "$PM" in
    brew)
      brew tap teamookla/speedtest >/dev/null 2>&1 || true
      brew install speedtest --force || { warn "failed to install speedtest"; FAILED="$FAILED speedtest"; }
      ;;
    apt)
      curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | $SUDO bash || true
      APT_UPDATED=0; pm_update_once
      $SUDO apt-get install -y speedtest || { warn "failed to install speedtest"; FAILED="$FAILED speedtest"; }
      ;;
    dnf)
      curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | $SUDO bash || true
      $SUDO dnf install -y speedtest || { warn "failed to install speedtest"; FAILED="$FAILED speedtest"; }
      ;;
    apk)
      install_speedtest_tarball
      ;;
  esac
}

# Alpine has no Ookla repo; grab the static binary tarball instead.
install_speedtest_tarball() {
  local sarch ver url tmpd
  case "$ARCH" in
    x86_64|amd64)  sarch="x86_64" ;;
    aarch64|arm64) sarch="aarch64" ;;
    *) warn "no speedtest build for arch $ARCH"; FAILED="$FAILED speedtest"; return ;;
  esac
  ver="1.2.0"
  url="https://install.speedtest.net/app/cli/ookla-speedtest-${ver}-linux-${sarch}.tgz"
  tmpd=$(mktemp -d)
  if curl -fsSL "$url" -o "$tmpd/speedtest.tgz" && tar -C "$tmpd" -xzf "$tmpd/speedtest.tgz" speedtest; then
    $SUDO install -m 0755 "$tmpd/speedtest" /usr/local/bin/speedtest
    add_path /usr/local/bin
  else
    warn "failed to install speedtest from tarball"; FAILED="$FAILED speedtest"
  fi
  rm -rf "$tmpd"
}

# Distro Go packages are often stale; install the current release from go.dev
# on Linux. On macOS, Homebrew's Go is current enough.
install_go() {
  if have go; then log "go already present: $(go version)"; return; fi
  if [ "$OS" = "darwin" ]; then
    install_one go
    return
  fi
  local goarch
  case "$ARCH" in
    x86_64|amd64)  goarch="amd64" ;;
    aarch64|arm64) goarch="arm64" ;;
    *) warn "unknown arch $ARCH; skipping Go"; FAILED="$FAILED go"; return ;;
  esac
  local ver tarball
  ver=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -n1) || true
  if [ -z "${ver:-}" ]; then warn "could not determine latest Go version; skipping"; FAILED="$FAILED go"; return; fi
  tarball="${ver}.linux-${goarch}.tar.gz"
  log "installing Go ${ver}"
  if curl -fsSL "https://go.dev/dl/${tarball}" -o "/tmp/${tarball}"; then
    $SUDO rm -rf /usr/local/go
    $SUDO tar -C /usr/local -xzf "/tmp/${tarball}"
    rm -f "/tmp/${tarball}"
    add_path "/usr/local/go/bin"
  else
    warn "failed to download Go"; FAILED="$FAILED go"
  fi
}

# ---------------------------------------------------------------------------
# agent CLIs
# ---------------------------------------------------------------------------

install_claude_code() {
  if have claude; then log "claude already present"; return; fi
  log "installing Claude Code"
  curl -fsSL https://claude.ai/install.sh | bash || { warn "failed to install Claude Code"; FAILED="$FAILED claude-code"; }
  add_path "$HOME/.local/bin"
}

install_codex() {
  if have codex; then log "codex already present"; return; fi
  log "installing Codex CLI"
  curl -fsSL https://chatgpt.com/codex/install.sh | sh || { warn "failed to install Codex CLI"; FAILED="$FAILED codex"; }
  add_path "$HOME/.local/bin"
}

install_opencode() {
  if have opencode; then log "opencode already present"; return; fi
  log "installing opencode"
  curl -fsSL https://opencode.ai/install | bash || { warn "failed to install opencode"; FAILED="$FAILED opencode"; }
  add_path "$HOME/.local/bin"
}

# Default Claude Code to "auto mode" (auto-accept edits) on this machine by
# writing defaultMode into ~/.claude/settings.json. Merges into any existing
# settings (via jq) rather than overwriting. Change "acceptEdits" to
# "bypassPermissions" for full skip-all-prompts mode, or "default" to undo.
configure_claude() {
  local settings="$HOME/.claude/settings.json"
  local mode="acceptEdits"
  mkdir -p "$HOME/.claude"
  if [ ! -f "$settings" ]; then
    printf '{\n  "defaultMode": "%s"\n}\n' "$mode" > "$settings"
    log "set Claude default mode to $mode"
    return
  fi
  if have jq; then
    local tmp; tmp=$(mktemp)
    if jq --arg m "$mode" '.defaultMode = $m' "$settings" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$settings"
      log "set Claude default mode to $mode"
    else
      rm -f "$tmp"; warn "could not update $settings (invalid JSON?); leaving it unchanged"
    fi
  else
    warn "jq unavailable; not modifying existing $settings"
  fi
}

# ---------------------------------------------------------------------------
# dotfiles / Claude config
# ---------------------------------------------------------------------------

# Clone this repo to ~/.setup (if absent) and symlink CLAUDE.md + skills into
# ~/.claude, matching README.md. Won't clobber existing files.
link_dotfiles() {
  local setup_dir="$HOME/.setup"
  if [ ! -d "$setup_dir/.git" ]; then
    log "cloning setup repo to $setup_dir"
    git clone https://github.com/theFong/setup "$setup_dir" || { warn "failed to clone setup repo"; return; }
  fi
  mkdir -p "$HOME/.claude"
  [ -e "$HOME/.claude/CLAUDE.md" ] || ln -s "$setup_dir/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  [ -e "$HOME/.claude/skills" ]    || ln -s "$setup_dir/.agent/skills" "$HOME/.claude/skills"
  log "linked Claude config into ~/.claude"
}

# ---------------------------------------------------------------------------

summary() {
  echo
  log "done."
  if [ -n "${FAILED# }" ]; then
    warn "the following did not install cleanly:${FAILED}"
    warn "re-run after resolving, or install them manually."
  fi
  echo "Open a new shell (or 'source' your rc) so PATH changes take effect."
  echo "Then run 'claude' or 'codex' to log in."
}

main() {
  # These two must succeed; everything after is best-effort so a single
  # failed package never blocks the rest of the bootstrap.
  detect_platform
  ensure_package_manager

  install_base_tools     || warn "some base tools failed"
  install_gh             || warn "gh install failed"
  install_speedtest      || warn "speedtest install failed"
  install_go             || warn "go install failed"
  install_claude_code    || warn "Claude Code install failed"
  install_codex          || warn "Codex CLI install failed"
  install_opencode       || warn "opencode install failed"
  configure_claude       || warn "configuring Claude default mode failed"
  link_dotfiles          || warn "linking dotfiles failed"
  summary
}

main "$@"
