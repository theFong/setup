---
name: skill-creator
description: Create new Claude Code skills and commands. Use when users want to create a skill, make a command, add a workflow, automate a task, build a Claude Code extension, or upgrade an existing skill. Trigger keywords - create skill, new skill, make command, add workflow, skill template, automate, upgrade skill.
allowed-tools: Bash, Read, Write, AskUserQuestion, Glob
argument-hint: [name] [--type command|skill] [--upgrade]
---
<!--
Token Budget:
- Level 1 (YAML): ~100 tokens
- Level 2 (This file): ~1800 tokens (target <2000)
- Level 3 (prompts/, examples/, templates/): Loaded on demand
-->

# Skill Creator

Create well-structured Claude Code skills and commands following gold standard best practices.

## When to Use

Use this skill when users want to:
- Create a new skill or command
- Automate a repetitive workflow
- Add a custom Claude Code extension
- Upgrade an existing skill to gold standard

**Trigger Keywords:** create skill, new skill, make command, add workflow, skill template, automate, upgrade skill

## Quick Start

```bash
# List existing skills
ls ~/.claude/skills/

# List existing commands
ls ~/.claude/commands/

# Check a skill's structure
ls -laR ~/.claude/skills/<name>/

# View a command
cat ~/.claude/commands/<name>.md
```

**Interactive creation:**
1. User says "create a new skill" or `/skill-creator`
2. Claude asks what it should do
3. Claude asks for skill type (command vs skill)
4. Claude gathers details and generates files
5. User restarts Claude Code to load it

## Skill Types

| Type | Location | Best For |
|------|----------|----------|
| **Command** | `~/.claude/commands/<name>.md` | Simple workflows, checklists, procedures |
| **Skill** | `~/.claude/skills/<name>/` | Complex integrations, external tools, multi-file docs |

## Workflows

This skill supports three workflows:

1. **Create Command** ([prompts/create-command.md](prompts/create-command.md))
   - Gather purpose and name
   - Define steps and safety rules
   - Generate single markdown file

2. **Create Skill** ([prompts/create-skill.md](prompts/create-skill.md))
   - Gather purpose, name, triggers
   - Define operations and dependencies
   - Generate directory structure with SKILL.md

3. **Upgrade Skill** ([prompts/upgrade-skill.md](prompts/upgrade-skill.md))
   - Analyze existing skill against gold standard
   - Identify gaps (troubleshooting, safety, etc.)
   - Apply targeted improvements

## Gold Standard Checklist

Before finalizing any skill, verify:

| Criteria | Command | Skill |
|----------|---------|-------|
| Clear title & description | Required | Required |
| YAML frontmatter | N/A | Required |
| Trigger keywords | In title | In description |
| Token budget comment | N/A | Required |
| Quick Start examples | Required | Required |
| Safety Rules section | Required | Required |
| Troubleshooting | Recommended | Required |
| Prompts directory | N/A | If complex |
| Examples directory | N/A | Required |

## Safety Rules - CRITICAL

**NEVER do these without explicit user confirmation:**
- Overwrite an existing skill or command
- Delete any skill files
- Modify skills outside `~/.claude/`
- Create skills with overly broad tool permissions

**ALWAYS do these:**
- Check if skill/command name already exists before creating
- Use minimal `allowed-tools` (only what's needed)
- Include safety rules in generated skills
- Verify file creation succeeded

## Naming Conventions

| Pattern | Example | Use For |
|---------|---------|---------|
| `verb-noun` | `commit-smart` | Action-oriented commands |
| `noun-verb` | `email-triage` | Domain-specific operations |
| `tool-action` | `git-fixup` | Tool wrappers |
| `workflow-name` | `pr-review` | Multi-step workflows |

## Troubleshooting

**Skill not appearing after creation:**
- Restart Claude Code or start a new conversation
- Verify file exists: `ls ~/.claude/skills/<name>/SKILL.md`
- Check YAML frontmatter syntax (no tabs, proper indentation)

**Skill not triggering on keywords:**
- Ensure trigger keywords are in the `description` field
- Keywords must be comma-separated in description
- Try invoking directly with `/<skill-name>`

**Permission errors:**
- Check directory permissions: `ls -la ~/.claude/`
- Ensure ~/.claude/skills/ and ~/.claude/commands/ exist

**YAML parsing errors:**
- No tabs in frontmatter (use spaces)
- Ensure `---` delimiters are on their own lines
- Quote descriptions containing colons

## References

- **[prompts/](prompts/)** - Detailed workflows for each operation
- **[templates/](templates/)** - Starter templates to copy
- **[examples/](examples/)** - Complete working examples
