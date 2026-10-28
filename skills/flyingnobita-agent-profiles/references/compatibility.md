# Compatibility Matrix

Platform compatibility, qualified agent CLIs, and feature boundaries.

## Platform Support

| Operating System | Status | Verification Notes |
| --- | --- | --- |
| Linux (x86_64) | Qualified | Tested with bubblewrap and unprivileged userns |
| macOS (Darwin) | Not Qualified | Unverified; no bubblewrap redirection layer |

## Agent CLI Integration Matrix

| Agent CLI | Command | Storage Redirection | Environment Variables |
| --- | --- | --- | --- |
| Claude Code | `claude` | `.claude` | `CLAUDE_CONFIG_DIR` |
| OpenAI Codex CLI | `codex` | `.codex`, `.agents` | `CODEX_HOME` |
| Google Antigravity CLI | `agy` | `.gemini`, `.agents` | Standard redirection |
| OpenCode | `opencode` | `.opencode` | `OPENCODE_CONFIG_DIR` |
