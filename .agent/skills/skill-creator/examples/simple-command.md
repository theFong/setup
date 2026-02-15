# Example: Simple Command Skill

This is an example of a simple markdown command file.

**Location:** `~/.claude/commands/pr-checklist.md`

---

```markdown
# PR Checklist

Run through a checklist before creating a pull request.

## Instructions

1. **Check for uncommitted changes** - Run `git status` to see pending changes
2. **Review the diff** - Run `git diff` to understand what changed
3. **Run tests** - Execute the test suite to catch regressions
4. **Check for lint errors** - Run the linter if configured
5. **Update documentation** - If behavior changed, update relevant docs

## Checklist

Before creating the PR, verify:

- [ ] All tests pass
- [ ] No lint errors
- [ ] Commit messages are clear and descriptive
- [ ] Branch is up to date with main
- [ ] Documentation updated if needed
- [ ] No secrets or credentials in code

## Safety Rules

- Never force push to shared branches
- Always pull latest main before rebasing
- Don't include `.env` files or credentials

## Workflow

1. Run `git status` to see changes
2. Run the project's test command
3. Run the project's lint command
4. If issues found, fix them before proceeding
5. Summarize readiness to user
```

---

## Why This Works

1. **Clear title** - Describes what it does
2. **Step-by-step instructions** - Claude knows what to do
3. **Checklist** - Concrete items to verify
4. **Safety rules** - Explicit constraints
5. **Workflow** - Ordered actions to take
