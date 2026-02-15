# Example: Complex Directory Skill

This is an example of a full directory-based skill structure.

**Location:** `~/.claude/skills/api-client/`

---

## Directory Structure

```
~/.claude/skills/api-client/
├── SKILL.md           # Main entry point
├── examples/
│   ├── crud-workflow.md
│   └── auth-flow.md
├── reference/
│   ├── endpoints.md
│   └── error-codes.md
└── scripts/
    └── setup.sh
```

---

## SKILL.md

```markdown
---
name: api-client
description: Interact with REST APIs. Use when users want to make HTTP requests, test endpoints, debug API responses, or work with JSON data. Trigger keywords - API, REST, HTTP, curl, request, endpoint, JSON.
allowed-tools: Bash, Read, Write, AskUserQuestion
argument-hint: [GET|POST|PUT|DELETE] <url> [--data JSON]
---

# API Client

Make HTTP requests and work with REST APIs from the command line.

## When to Use

Use this skill when users want to:
- Make HTTP requests (GET, POST, PUT, DELETE)
- Test API endpoints
- Debug API responses
- Parse and format JSON data

**Trigger Keywords:** API, REST, HTTP, curl, request, endpoint, JSON, fetch

## Quick Start

```bash
# GET request
curl -s https://api.example.com/users | jq

# POST with JSON
curl -X POST https://api.example.com/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice"}' | jq

# With authentication
curl -s -H "Authorization: Bearer $TOKEN" \
  https://api.example.com/protected | jq
```

## Common Operations

### GET Request
```bash
curl -s "<url>" | jq
```

### POST Request
```bash
curl -X POST "<url>" \
  -H "Content-Type: application/json" \
  -d '<json-body>' | jq
```

### With Headers
```bash
curl -s -H "Header: Value" "<url>" | jq
```

### Save Response
```bash
curl -s "<url>" -o response.json
```

## Best Practices

- Always pipe to `jq` for readable JSON output
- Use `-s` (silent) to suppress progress output
- Store tokens in environment variables, not in commands
- Use `jq` filters to extract specific fields

## Error Handling

| HTTP Code | Meaning | Action |
|-----------|---------|--------|
| 400 | Bad Request | Check request body format |
| 401 | Unauthorized | Verify authentication |
| 403 | Forbidden | Check permissions |
| 404 | Not Found | Verify endpoint URL |
| 500 | Server Error | Retry or report issue |

## Safety Rules

- Never log or display API tokens/secrets
- Don't make destructive requests without confirmation
- Verify URLs before making requests to unknown endpoints

## References

- [Endpoints Reference](reference/endpoints.md)
- [Error Codes](reference/error-codes.md)
- [Examples](examples/)
```

---

## Why This Works

1. **YAML frontmatter** - Metadata for Claude to understand when to use it
2. **Trigger keywords** - Explicit activation conditions
3. **Quick start** - Immediate usable examples
4. **Progressive disclosure** - Details in subdirectories
5. **Error handling** - Common issues and solutions
6. **Safety rules** - Explicit constraints
7. **References** - Links to deeper documentation
