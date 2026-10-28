# Machine Setup and Mise Tasks

Guidance for configuring host prerequisites and global `mise` tasks.

## System Prerequisites

Agent profiles require:

- Linux kernel with unprivileged user namespaces enabled
- `bubblewrap` (`bwrap`)
- `git`
- `python3` (for JSON serialization and directory resolution)
- `mise` (for environment and global task integration)

## Diagnostic Health Check

Run the built-in doctor:

```bash
agent-profiles doctor
```

## Global Mise Task Integration

To preview task setup without modifying the host:

```bash
agent-profiles setup --preview
```

To apply tasks to `$MISE_CONFIG_DIR/tasks`:

```bash
agent-profiles setup --apply
```

This registers `agent-profiles-init` and `agent-profiles` global mise tasks.
