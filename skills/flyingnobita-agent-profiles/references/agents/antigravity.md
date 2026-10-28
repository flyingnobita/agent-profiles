# Google Antigravity CLI Integration

Guidance for using Google Antigravity CLI (`agy`) inside an agent profile.

## Directory Redirection

- Configuration: Redirected to `.agent-profiles/<name>/.gemini` via bubblewrap mount.
- Shared skills: Stored under `.agent-profiles/<name>/.agents`.
- Shared resources: Host repository files, inherited environment credentials, and mise tool paths are preserved.
