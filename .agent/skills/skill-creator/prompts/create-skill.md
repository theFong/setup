# Create Directory Skill Workflow

Step-by-step workflow for creating a full directory-based skill.

## Step 1: Gather Basic Info

Use AskUserQuestion:
```
question: "What should this skill do?"
header: "Purpose"
options:
  - label: "Tool Integration"
    description: "Wrap a CLI tool or external service"
  - label: "Complex Workflow"
    description: "Multi-step process with branching logic"
  - label: "Domain Operations"
    description: "Manage a specific domain (email, calendar, etc.)"
  - label: "Other"
    description: "Something else"
```

Then ask for a one-sentence description.

## Step 2: Get the Name

Use AskUserQuestion:
```
question: "What should we name this skill?"
header: "Name"
```

Validate the name:
- Lowercase with hyphens (e.g., `api-client`, `docker-helper`)
- No spaces or special characters
- Descriptive and concise

## Step 3: Identify Triggers

Ask: "What words or phrases should activate this skill?"

Capture:
- 5-10 trigger keywords
- 3-5 use case descriptions ("Use when users want to...")

## Step 4: Define Operations

Ask: "What are the main operations/commands?"

For each operation:
- Operation name
- Example command (if CLI-based)
- Brief description

## Step 5: External Dependencies

Ask: "Does this skill use any external tools or CLIs?"

If yes:
- Tool name
- Installation method
- How to verify it's installed

## Step 6: Safety Rules

Ask: "What dangerous actions could this skill take?"

Map to safety rules:
- Data deletion → "Never delete without confirmation"
- External requests → "Never send data to unknown endpoints"
- System changes → "Never modify system files"
- Credentials → "Never log or display secrets"

## Step 7: Generate Directory Structure

```bash
mkdir -p ~/.claude/skills/<name>/{prompts,examples,reference}
```

## Step 8: Generate SKILL.md

Create `~/.claude/skills/<name>/SKILL.md`:

```markdown
---
name: <name>
description: <Description>. Use when users want to <use-case-1>, <use-case-2>, or <use-case-3>. Trigger keywords - <kw1>, <kw2>, <kw3>.
allowed-tools: <tools>
argument-hint: <hint>
---
<!--
Token Budget:
- Level 1 (YAML): ~100 tokens
- Level 2 (This file): ~XXXX tokens
- Level 3 (prompts/, examples/): On demand
-->

# <Title>

<Brief description>

## When to Use

Use this skill when users want to:
- <Use case 1>
- <Use case 2>
- <Use case 3>

**Trigger Keywords:** <keywords>

## Quick Start

```bash
# <Example description>
<example-command>
```

## Operations

### <Operation 1>
```bash
<command-1>
```

### <Operation 2>
```bash
<command-2>
```

## Best Practices

- <Practice 1>
- <Practice 2>

## Safety Rules - CRITICAL

**NEVER do these without explicit user confirmation:**
- <Dangerous action 1>
- <Dangerous action 2>

## Troubleshooting

**<Issue 1>:**
- <Solution>

**<Issue 2>:**
- <Solution>

## References

- [Examples](examples/)
- [Detailed Reference](reference/)
```

## Step 9: Generate Sub-files (Optional)

If the skill has multiple workflows, create prompts:
- `prompts/<workflow-1>.md`
- `prompts/<workflow-2>.md`

If external tool, create reference:
- `reference/commands.md` - Full command reference
- `reference/installation.md` - Setup instructions

## Step 10: Verify

1. List created files: `ls -laR ~/.claude/skills/<name>/`
2. Show the main SKILL.md contents
3. Explain: "Restart Claude Code or start a new conversation to use `/<name>`"
