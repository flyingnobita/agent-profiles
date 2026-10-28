# Claude Code Integration

Guidance for using Claude Code (`claude`) inside an agent profile.

## Directory Redirection

- Configuration: Redirected to `.agent-profiles/<name>/.claude` via `CLAUDE_CONFIG_DIR` and bubblewrap mount.
- State & settings: Written inside the active profile directory.
- Shared resources: Host repository files, inherited environment credentials, and mise tool paths are preserved.
