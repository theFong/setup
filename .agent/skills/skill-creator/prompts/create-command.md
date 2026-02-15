# Create Command Workflow

Step-by-step workflow for creating a simple markdown command.

## Step 1: Gather Basic Info

Use AskUserQuestion:
```
question: "What should this command do?"
header: "Purpose"
options:
  - label: "Workflow/Checklist"
    description: "Step-by-step process to follow"
  - label: "Code Generation"
    description: "Generate boilerplate or templates"
  - label: "Automation"
    description: "Automate a repetitive task"
  - label: "Other"
    description: "Something else"
```

Then ask for a one-sentence description.

## Step 2: Get the Name

Use AskUserQuestion:
```
question: "What should we name this command?"
header: "Name"
```

Validate the name:
- Lowercase with hyphens (e.g., `pr-checklist`, `quick-test`)
- No spaces or special characters
- Descriptive and concise

## Step 3: Gather Steps

Ask: "What are the main steps? (List 3-7 steps)"

For each step, capture:
- Step title (brief)
- Step description (what to do)

## Step 4: Safety Rules

Ask: "Are there any dangerous actions this command might take?"

Common patterns:
- File deletion → "Never delete without confirmation"
- Git operations → "Never force push or reset --hard"
- External APIs → "Never send data without user approval"
- Credentials → "Never log or display secrets"

## Step 5: Generate

Create file at `~/.claude/commands/<name>.md`:

```markdown
# <Title>

<One-line description>

## Instructions

1. **<Step 1 Title>** - <Description>
2. **<Step 2 Title>** - <Description>
3. **<Step 3 Title>** - <Description>

## Safety Rules

- <Rule 1>
- <Rule 2>

## Workflow

1. <Action 1>
2. <Action 2>
3. Verify success and report to user
```

## Step 6: Verify

1. Confirm file was created: `ls -la ~/.claude/commands/<name>.md`
2. Show the user the contents
3. Explain: "Restart Claude Code or start a new conversation to use `/<name>`"
