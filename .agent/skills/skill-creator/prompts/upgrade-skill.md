# Upgrade Skill Workflow

Analyze an existing skill and upgrade it to gold standard.

## Step 1: Read the Skill

```bash
# For commands
cat ~/.claude/commands/<name>.md

# For skills
cat ~/.claude/skills/<name>/SKILL.md
ls -laR ~/.claude/skills/<name>/
```

## Step 2: Run Gold Standard Checklist

Evaluate against these criteria:

| Criteria | Required | Check |
|----------|----------|-------|
| YAML frontmatter | Skills only | Has name, description, allowed-tools |
| Trigger keywords | Yes | In description or explicit section |
| Token budget comment | Skills only | `<!-- Token Budget: ... -->` |
| Quick Start | Yes | Runnable examples at top |
| When to Use | Yes | Clear activation conditions |
| Safety Rules | Yes | Explicit CRITICAL section |
| Troubleshooting | Yes | Common issues + solutions |
| Error handling | If applicable | Exit codes or error table |
| Prompts directory | Complex skills | Sub-workflows |
| Examples directory | Skills only | Working examples |

## Step 3: Identify Gaps

Report findings:
```
## Gold Standard Analysis: <skill-name>

**Score: X/10**

### Present
- ✓ <What it has>

### Missing
- ✗ <What it needs>

### Recommendations
1. <Specific improvement>
2. <Specific improvement>
```

## Step 4: Confirm Upgrades

Use AskUserQuestion:
```
question: "Which improvements should I make?"
header: "Upgrades"
multiSelect: true
options:
  - label: "Add token budget"
  - label: "Add troubleshooting"
  - label: "Add safety rules"
  - label: "Add prompts directory"
  - label: "All of the above"
```

## Step 5: Apply Upgrades

For each selected improvement:

**Token budget:**
Add after YAML frontmatter:
```markdown
<!--
Token Budget:
- Level 1 (YAML): ~100 tokens
- Level 2 (This file): ~XXXX tokens
- Level 3 (prompts/, examples/): On demand
-->
```

**Troubleshooting:**
Add section:
```markdown
## Troubleshooting

**<Common Issue 1>:**
- <Solution>

**<Common Issue 2>:**
- <Solution>
```

**Safety Rules:**
Add section:
```markdown
## Safety Rules - CRITICAL

**NEVER do these without explicit user confirmation:**
- <Action 1>
- <Action 2>
```

**Prompts directory:**
```bash
mkdir -p ~/.claude/skills/<name>/prompts
```
Create workflow files for each major operation.

## Step 6: Verify

1. Re-run checklist
2. Show updated score
3. Confirm all gaps addressed
