# System Instructions

## Repository Style and Validation

When working in this setup repository, follow the repository-root
`STYLE_GUIDE.md`. Every behavioral addition must include validation in the same
change, preserve safe re-runs, and maintain equivalent Claude Code and Codex
support unless an exception is explicitly documented.

## Git Commits
- Do NOT add a "Co-Authored-By" line to commit messages.

## Pull Requests
- Do NOT add a "Generated with Claude Code" line (or any similar attribution) to PR descriptions.

## Long-running tasks

If a task is estimated to take longer than 10 minutes (e.g. large downloads, model loading, extensive builds), check if the session is running inside tmux before starting. If not in tmux, ask the user if they'd like to switch to a tmux session first to avoid losing progress on disconnect.

## CLAUDE.md Management

This file is version-controlled in ~/.setup. If you make any changes to this file, commit and push them to the repo.
