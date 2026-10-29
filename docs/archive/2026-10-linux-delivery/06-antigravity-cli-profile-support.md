# 06: Use Google Antigravity CLI with profiles

> Historical specification. The approved Linux delivery is completed and
> integrated. See the [delivery record](../../agents/delivery-progress.md)
> for verification, scope decisions and remaining limitations. The original
> criteria below are preserved as written; unchecked boxes are not open tasks.

**What to build:** Launch Google Antigravity CLI in a selected profile, discover and invoke its profile skill, execute a harmless command and explain which identity or host resources may remain shared.

**Blocked by:** 02: Create and run named Linux profiles.

**Archive status:** Completed for the approved Linux scope; integrated as `e59a7ee`.

**Original intake status:** ready-for-agent

- [ ] The integration targets the agy command. Home-path redirection covers its supported .gemini skill and state locations, with .agents handling verified where applicable. A directory named .gemini is not a claim of Gemini CLI support.
- [ ] Actual CLI checks demonstrate startup and selected-profile skill discovery or invocation with distinct markers in two profiles. Host configuration is not silently assumed absent merely because environment variables were set.
- [ ] Authentication diagnostics and documentation distinguish filesystem state from environment or OS-provided authentication. A successful live response is not described as proof of account separation.
- [ ] Where authorized authentication is available, demonstrate a minimal live response, a profile skill invocation and a harmless terminal command with supported sandbox and permission modes.
- [ ] Agent initialization, caches, plugins and background helpers stay within documented profile locations where supported; report remaining shared processes, sockets and paths.
- [ ] Record tested versions and readiness/onboarding behavior. Clean up only test-owned processes, and keep raw logs private rather than publishing authentication or account metadata.
- [ ] Package the integration and its focused reference so it works after npx installation without author-specific paths, gateways or fleet configuration.
