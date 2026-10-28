# OpenAI Codex CLI Integration

Guidance for using OpenAI Codex CLI (`codex`) inside an agent profile.

## Directory Redirection

- Configuration: Redirected to `.agent-profiles/<name>/.codex` via `CODEX_HOME` and bubblewrap mount.
- Shared skills: Stored under `.agent-profiles/<name>/.agents`.
- Shared resources: Host repository files, inherited environment credentials, and mise tool paths are preserved.
