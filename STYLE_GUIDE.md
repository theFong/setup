# Setup Repository Style Guide

This repository bootstraps real machines. Every behavioral addition must include
validation in the same change. A change is not complete when it only adds an
installer, configuration path, or workflow without proving that it works.

## Required for Every Addition

1. Add a validation that would fail if the new behavior were broken. Put it
   inside the script itself so it runs on every real machine, not only in CI
   (see Installer Conventions).
2. Test the relevant success path and, when failure handling changes, a negative
   path that proves the script returns nonzero.
3. Preserve safe re-runs. A second bootstrap run must skip or harmlessly repeat
   completed work.
4. Update user-facing documentation when commands, installed tools, paths, or
   post-install steps change.
5. Keep Claude Code and Codex support equivalent unless the change is explicitly
   agent-specific.

## Installer Conventions

- Keep `install.sh` compatible with Bash and `set -euo pipefail`.
- Detect existing commands with `have` before installing them.
- Prefer the vendor's supported installer or package-manager path.
- Add user-local binary directories to both the current `PATH` and the user's
  shell profile with `add_path`.
- Call `assert_installed` after every install attempt with the expected command.
- Validate configuration changes the same way: assert the resulting on-disk
  state from inside the script (an `assert_*` helper following the
  `assert_installed` pattern, e.g. `assert_claude_mode`) and call
  `record_failure` on mismatch. Do not add success-path assertions as CI
  workflow steps; reserve workflow steps for running the script and for what a
  passing run cannot prove — isolated negative tests and re-run safety checks.
- Record failures with `record_failure`; do not silently turn a failed install
  into a successful bootstrap.
- Continue best-effort installation of independent tools, then return nonzero
  from `summary` if anything remains missing.
- Do not overwrite existing user configuration or skill installations.

## Platform Support

Installer changes must account for:

- Ubuntu latest and Ubuntu 22.04 on x86_64.
- Ubuntu 24.04 and Ubuntu 22.04 on ARM64.
- macOS on Apple Silicon and Intel.

Use `OS`, `ARCH`, and `PM` instead of assuming one operating system, processor,
package manager, Homebrew prefix, or binary archive name.

## Claude Code and Codex Compatibility

- Repository instructions must remain available through both `CLAUDE.md` and
  `AGENTS.md`.
- Shared rules belong in this file; agent-specific instruction files should
  reference it instead of copying rules that can drift.
- Agent skills should support both `~/.claude/skills` and `~/.codex/skills`.
- When adding or changing a shared skill, validate both agent paths.
- Do not add instructions that only one agent can follow unless they are clearly
  labeled and an equivalent workflow is documented for the other agent.

## Validation Checklist

Run the checks relevant to the change before pushing:

```bash
bash -n install.sh
git diff --check
actionlint .github/workflows/bootstrap.yml
```

For behavioral bootstrap changes, the GitHub Actions matrix must pass on every
supported platform. New failure behavior must also include an isolated negative
test, using `SETUP_SKIP_MAIN=1` when individual shell functions need to be
sourced without running the full bootstrap.

## Definition of Done

A change is ready only when its implementation, automated validation,
documentation, and Claude Code/Codex compatibility are included together and
all required CI jobs pass.
