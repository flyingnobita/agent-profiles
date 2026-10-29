# 05: Use OpenAI Codex CLI with profiles

> Historical specification. The approved Linux delivery is completed and
> integrated. See the [delivery record](../../agents/delivery-progress.md)
> for verification, scope decisions and remaining limitations. The original
> criteria below are preserved as written; unchecked boxes are not open tasks.

**What to build:** Launch Codex through a selected profile, discover the intended instructions and skills, diagnose authentication and execute a harmless command under its own sandbox.

**Blocked by:** 02: Create and run named Linux profiles.

**Archive status:** Completed for the approved Linux scope; integrated as `5eed95d`.

**Original intake status:** ready-for-agent

- [ ] The integration supports codex, CODEX_HOME and home-based .agents skill discovery without breaking mise-backed launchers.
- [ ] Use Codex's actual discovery surface to verify distinct user-scope marker skills in two profiles, repository-scope skills and exclusion of the other profile's marker. Record admin and bundled sources that remain available.
- [ ] Verify instruction discovery according to the installed Codex version, including repository boundaries; do not assume traversal to the filesystem root.
- [ ] A fresh profile reports its actual login state. Host authentication and user configuration are not imported automatically. Explain inherited environment credentials and separately authorized sharing.
- [ ] Where authorized test credentials are available, verify a minimal live response and explicit profile-skill invocation. Skill invocation may read the skill instructions; it must not be tested with a contradictory prohibition on all file reads.
- [ ] Execute a harmless shell command using Codex's read-only sandbox inside the Linux wrapper and verify its output. Stop test app servers and helper processes without touching unrelated sessions.
- [ ] Record versions, credential prerequisites and genuine failures separately. Include focused usage and troubleshooting guidance reachable through progressive disclosure.
