# 07: Use OpenCode with profiles

> Historical specification. The approved Linux delivery is completed and
> integrated. See the [delivery record](../../agents/delivery-progress.md)
> for verification, scope decisions and remaining limitations. The original
> criteria below are preserved as written; unchecked boxes are not open tasks.

**What to build:** Launch OpenCode through a selected profile, verify its effective configuration and state locations, invoke a profile skill and execute a harmless command with clear authentication diagnostics.

**Blocked by:** 02: Create and run named Linux profiles.

**Archive status:** Completed for the approved Linux scope; integrated as `bea878c`.

**Original intake status:** ready-for-agent

- [ ] The integration targets opencode and redirects profile configuration, data, state and caches. Determine effective behavior from the installed version rather than assuming OPENCODE_CONFIG_DIR is additive or replacing.
- [ ] Use actual path/configuration diagnostics and distinguishable synthetic sources to verify which configuration is loaded. Diagnostics do not expose secrets from real user settings.
- [ ] Distinct skills in two profiles are discovered or invoked only from the selected profile. Record additional managed or bundled sources separately.
- [ ] Authentication diagnostics distinguish profile-stored credentials from inherited environment credentials, without printing their values. Host authentication is not imported by copying configuration.
- [ ] Where authorized test credentials are available, demonstrate a minimal response, profile-skill invocation and a harmless shell command.
- [ ] Use a private or standalone server for verification where supported so an existing host service cannot invalidate the isolation test. Report shared sockets or services as limitations.
- [ ] Package focused version-aware usage and troubleshooting guidance, and record checks that remain unverified rather than generalizing one version's behavior.
