---
name: brev-cli
description: Manage GPU cloud instances and external nodes with the Brev CLI. Use when users want to create GPU instances, search for GPUs, list instances or on-prem nodes, SSH into machines, open editors, copy files, port forward, manage organizations, or work with cloud compute. Trigger keywords - brev, gpu, instance, create instance, brev ls, brev ls nodes, external node, on-prem node, ssh, vram, A100, H100, cloud gpu, remote machine.
allowed-tools: Bash, Read, AskUserQuestion
argument-hint: [create|search|shell|open|ls|ls nodes|delete] [instance-name]
---
<!--
Token Budget:
- Level 1 (YAML): ~100 tokens
- Level 2 (This file): ~1900 tokens (target <2000)
- Level 3 (prompts/, reference/): Loaded on demand
-->

# Brev CLI

Manage GPU cloud instances from the command line. Create, search, connect, and manage remote GPU machines.

## When to Use

Use this skill when users want to:
- Create GPU instances (with smart defaults or specific types)
- Search for available GPU types (A100, H100, L40S, etc.)
- SSH into instances or run commands remotely
- Open editors (VS Code, Cursor, Windsurf) on remote instances
- Copy files to/from instances
- Port forward from remote to local
- Manage organizations and instances

**Trigger Keywords:** brev, gpu, instance, create instance, ssh, vram, A100, H100, cloud gpu, remote machine, shell

## Quick Start

```bash
# Search for GPUs (sorted by price)
brev search

# Create an instance with smart defaults
brev create my-instance

# Create with specific GPU
brev create my-instance --type g5.xlarge

# List your cloud instances
brev ls

# List external/on-prem nodes -- a SEPARATE list that `brev ls` never shows
brev ls nodes

# SSH into an instance
brev shell my-instance

# Open in VS Code/Cursor
brev open my-instance code
brev open my-instance cursor
```

## Core Commands

### Search GPUs
```bash
# All available GPUs
brev search

# Filter by GPU name
brev search --gpu-name A100
brev search --gpu-name H100

# Filter by VRAM, sort by price
brev search --min-vram 40 --sort price

# Filter by boot time
brev search --max-boot-time 5 --sort price
```

### Create Instances
```bash
# Smart defaults (cheapest matching GPU)
brev create my-instance

# Specific type
brev create my-instance --type g5.xlarge

# Multiple types (fallback chain)
brev create my-instance --type g5.xlarge,g5.2xlarge

# Pipe from search
brev search --gpu-name A100 | brev create my-instance

# Multiple instances
brev create my-cluster --count 3

# With startup script
brev create my-instance --startup-script @setup.sh
brev create my-instance --startup-script 'pip install torch'
```

### Instance Access
```bash
# SSH into instance
brev shell my-instance

# Run command remotely
brev shell my-instance -c "nvidia-smi"
brev shell my-instance -c "python train.py"

# Run a local script on the instance (use @filepath)
brev shell my-instance -c @setup.sh
brev shell my-instance -c @/path/to/script.sh

# Open in editor
brev open my-instance           # default editor
brev open my-instance code      # VS Code
brev open my-instance cursor    # Cursor
brev open my-instance windsurf  # Windsurf
brev open my-instance terminal  # Terminal window
brev open my-instance tmux      # Terminal + tmux

# Copy files
brev copy ./local-file my-instance:/remote/path/
brev copy my-instance:/remote/file ./local-path/

# Port forward
brev port-forward my-instance -p 8080:8080
```

### Listing: instances vs. nodes

`brev ls` has two namespaces and they do **not** overlap. If you are looking for a
machine and `brev ls` doesn't show it, check `brev ls nodes` before concluding it
doesn't exist.

```bash
brev ls              # cloud instances (VMs Brev provisioned)
brev ls instances    # same as above, explicit
brev ls nodes        # external nodes only -- physical/on-prem machines
brev ls orgs         # organizations
brev ls nodes --json # machine-readable: name, org_id, status
```

|  | `brev ls` | `brev ls nodes` |
|---|---|---|
| Status values | `RUNNING` / `STOPPED` | `Connected` / `Disconnected` |
| Columns | NAME, STATUS, BUILD, SHELL, ID, MACHINE, GPU | NAME, STATUS only |
| `stop`/`start`/`delete` | yes | **no** — Brev doesn't own their lifecycle |

**Two gotchas, both verified on v0.6.329:**
- `brev ls --all` does *not* merge the lists despite its help text promising
  "all instances and external nodes". It returns the same rows as `brev ls`.
  Run both commands; don't rely on `--all`.
- Piped output is *not* names-only despite the help text. You still get the full
  table, which is why the pipelines below all use `awk '{print $1}'`.

Node names are also SSH host aliases — `brev refresh` writes them into
`~/.brev/ssh_config`, so `ssh spark-1` works without `brev shell`.

```bash
# Names of every node that is currently connected
brev ls nodes --json | jq -r '.[] | select(.status=="Connected") | .name'
```

### Instance Management
```bash
# List instances
brev ls

# Delete instance
brev delete my-instance

# Stop/start (if supported)
brev stop my-instance
brev start my-instance

# Reset (recover from errors)
brev reset my-instance
```

### Pipeable Workflows
```bash
# Stop all running instances
brev ls | awk '/RUNNING/ {print $1}' | brev stop

# Delete all stopped instances
brev ls | awk '/STOPPED/ {print $1}' | brev delete

# Start all stopped instances
brev ls | awk '/STOPPED/ {print $1}' | brev start

# Stop instances matching pattern
brev ls | grep "test-" | awk '{print $1}' | brev stop

# Run command on all running instances
brev ls | awk '/RUNNING/ {print $1}' | brev shell -c "nvidia-smi"

# Create and open in one command
brev search --gpu-name A100 | brev create my-box | brev open cursor
```

### Organizations
```bash
# List orgs
brev org ls

# Set active org
brev org set my-org
brev set my-org  # alias

# Generate invite link
brev invite
```

## Common Workflows

1. **Quick GPU Session** ([prompts/quick-session.md](prompts/quick-session.md))
   - Search → Create → Open editor

2. **ML Training Setup** ([prompts/ml-training.md](prompts/ml-training.md))
   - Find high-VRAM GPU → Create with startup script → Copy data → Run training

3. **Instance Cleanup** ([prompts/cleanup.md](prompts/cleanup.md))
   - List instances → Identify unused → Delete

## Safety Rules - CRITICAL

**NEVER do these without explicit user confirmation:**
- Delete instances (`brev delete`)
- Stop running instances (`brev stop`)
- Create multiple instances (`--count > 1`)
- Create expensive instances (H100, multi-GPU)

**ALWAYS do these:**
- Show instance cost/type before creating
- Confirm instance name before deletion
- Check `brev ls` **and `brev ls nodes`** before assuming a machine doesn't exist —
  they are separate lists

**External nodes are not disposable.** Nodes in `brev ls nodes` are real hardware
someone registered to the org, not Brev-provisioned VMs. Never try to `delete` or
`stop` one, and treat anything running on them as production unless told otherwise.

## Troubleshooting

**"Instance not found":**
- Run `brev ls` to see available instances
- **Run `brev ls nodes` too** — external nodes never appear in `brev ls`, and
  `brev ls --all` does not include them either
- Check if you're in the correct org: `brev org ls`

**Node shows `Connected` but SSH hangs:**
- `Connected` means registered with the control plane, not reachable. The usual
  cause is a stale gateway port mapping.
- `brev refresh` first — gateway ports rotate and `~/.brev/ssh_config` goes stale.
- If it still hangs, the node's mesh agent needs to re-register (on the node:
  `systemctl restart netbird`, or the equivalent for your overlay).

**"Failed to create instance":**
- Try a different instance type: `brev search --sort price`
- Check quota/credits with org admin

**SSH connection fails:**
- Run `brev refresh` to update SSH config
- Ensure instance is running: `brev ls`

**Editor won't open:**
- Verify editor is in PATH: `which code` / `which cursor`
- Set default: `brev open --set-default code`

## References

- **[reference/commands.md](reference/commands.md)** - Full command reference
- **[reference/search-filters.md](reference/search-filters.md)** - GPU search options
- **[prompts/](prompts/)** - Workflow guides
- **[examples/](examples/)** - Common patterns
