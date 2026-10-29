# 04: Use Claude Code with profiles

> Historical specification. The approved Linux delivery is completed and
> integrated. See the [delivery record](../../agents/delivery-progress.md)
> for verification, scope decisions and remaining limitations. The original
> criteria below are preserved as written; unchecked boxes are not open tasks.

**What to build:** Launch Claude Code through a selected profile, discover that profile's skills and settings, diagnose its authentication state and execute a harmless command without inheriting unrelated host agent configuration.

**Blocked by:** 02: Create and run named Linux profiles.

**Archive status:** Completed for the approved Linux scope; integrated as `376201d`.

**Original intake status:** ready-for-agent

- [ ] The integration supports the claude command, CLAUDE_CONFIG_DIR and home-based Claude paths while preserving the base runtime's mise behavior.
- [ ] Distinct marker skills and settings in two profiles are discovered only by the selected profile. Record bundled or managed sources that remain applicable, and check that host MCP configuration is not silently imported.
- [ ] A fresh profile reports its actual authentication state. No host credential files are copied, linked or made writable by default; inherited credentials and OS credential services are explained.
- [ ] Where authorized test credentials are available, verify a minimal live response and skill invocation. Any explicit credential-sharing test is separate from default behavior, and host credential files remain unchanged.
- [ ] Execute a harmless Bash command with Claude's sandbox enabled inside the Linux wrapper and verify enforcement by denying a write to a controlled test file. Failures and unavailable prerequisites are reported accurately.
- [ ] Validate actual CLI startup, discovery and authentication diagnostics, recording versions and any checks blocked by missing credentials. Do not equate --version success with authenticated or sandboxed operation.
- [ ] Package focused Claude setup and troubleshooting guidance with the installed skill. Normal use does not need to load other agent integrations or a full test transcript.
