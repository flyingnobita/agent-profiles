---
name: flyingnobita-agent-profiles
description: Named Linux agent profiles for Claude Code, Codex CLI, Antigravity CLI, and OpenCode with separate settings and tools while preserving shared host checkouts. Routes setup, repository operations, lifecycle, and Q&A to focused references.
license: MIT
compatibility: Linux (bash, git, python3, mise, bubblewrap); macOS not qualified
metadata:
  version: 0.1.0
---

# Agent Profiles

Agent profiles separate agent configuration, credentials storage, and user-installed tools into named profiles (`.agent-profiles/<name>/`) within a Git checkout. Host repository files, package managers, and lockfiles remain shared. Agent profiles provide workflow separation, not a security boundary for untrusted code.

## Reference Routing

Consult only the reference document relevant to the user's specific request:

| Request Topic | Target Reference |
| ------------- | ---------------- |
| General concepts, architecture, credentials, FAQ | [questions.md](references/questions.md) |
| Diagnostic errors, exit codes, recover procedures | [troubleshooting.md](references/troubleshooting.md) |
| Profile initialization, listing, command execution | [repository-operations.md](references/repository-operations.md) |
| Host prerequisites, doctor checks, mise tasks | [machine-setup.md](references/machine-setup.md) |
| Reset, remove, migration from legacy layouts | [lifecycle.md](references/lifecycle.md) |
| Supported platforms and qualified CLI matrix | [compatibility.md](references/compatibility.md) |
| Claude Code configuration and execution | [claude-code.md](references/agents/claude-code.md) |
| OpenAI Codex CLI configuration and execution | [codex.md](references/agents/codex.md) |
| Google Antigravity CLI configuration and execution | [antigravity.md](references/agents/antigravity.md) |
| OpenCode configuration and execution | [opencode.md](references/agents/opencode.md) |

## Command Summary

Execute profile operations using the bundled helper script:

```bash
# Health check and environment diagnosis
bash scripts/agent-profiles doctor [--json]

# Initialize or list profiles in the current checkout
bash scripts/agent-profiles init [--profile NAME]
bash scripts/agent-profiles list [--json]

# Execute commands within a profile (defaults to "default")
bash scripts/agent-profiles run [--profile NAME] -- COMMAND [ARGS...]

# Machine setup and global mise task configuration
bash scripts/agent-profiles setup [--preview | --apply]

# Profile lifecycle management
bash scripts/agent-profiles reset --profile NAME [--yes]
bash scripts/agent-profiles remove --profile NAME [--yes]
bash scripts/agent-profiles migrate [--yes]
bash scripts/agent-profiles recover [--yes]
```
