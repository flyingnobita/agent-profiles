# OpenCode Integration

Guidance for using OpenCode (`opencode`) inside an agent profile.

## Directory Redirection

- Configuration: Redirected to `.agent-profiles/<name>/.opencode` via `OPENCODE_CONFIG_DIR` and XDG environment variables.
- Server mode: Recommended with `--standalone` to avoid connecting to host daemon instances.
- Shared resources: Host repository files, inherited environment credentials, and mise tool paths are preserved.
