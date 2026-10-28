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

For questions, conceptual guidance, or documentation requests, read only the single focused reference document without mutating the repository, environment, or profile configurations:

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

Run the helper by resolving it relative to this installed skill directory (for
example `$SKILL_DIR/scripts/agent-profiles`), while keeping the working directory
in the target Git repository:

```bash
AP_HELPER="<skill-directory>/scripts/agent-profiles"

# Diagnose the machine, global tasks, namespaces and agent integrations
bash "$AP_HELPER" doctor [--json] [--agent claude|codex|agy|opencode] [--profile NAME]

# Create, inspect and use named profiles
bash "$AP_HELPER" init [--profile NAME]
bash "$AP_HELPER" list [--json]
bash "$AP_HELPER" run [--profile NAME] -- COMMAND [ARGS...]

# Deploy the versioned helper and the two global mise tasks (preview is default)
bash "$AP_HELPER" setup [--preview | --apply] [--agent ID]... [--tasks-only] [--prepare-dir DIR]

# Lifecycle: previews until --yes; run from a host shell, never inside a profile
bash "$AP_HELPER" reset --profile NAME [--assume-unrelated PID,...] [--yes]
bash "$AP_HELPER" remove --profile NAME [--assume-unrelated PID,...] [--yes]
bash "$AP_HELPER" migrate [--backup-root DIR] [--assume-unrelated PID,...] [--yes]
bash "$AP_HELPER" recover [--yes]
```

All commands are implemented; `--help` lists the same set. Profile options are
consumed before `COMMAND`, and everything after `--` is forwarded unchanged.
Load `references/repository-operations.md`, `references/machine-setup.md` or
`references/lifecycle.md` only for the task at hand.
