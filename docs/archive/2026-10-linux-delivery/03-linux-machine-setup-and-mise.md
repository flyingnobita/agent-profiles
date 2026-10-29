# 03: Set up a Linux machine and integrate mise tasks

> Historical specification. The approved Linux delivery is completed and
> integrated. See the [delivery record](../../agents/delivery-progress.md)
> for verification, scope decisions and remaining limitations. The original
> criteria below are preserved as written; unchecked boxes are not open tasks.

**What to build:** Prepare a supported Linux machine for profiles and make the agreed global mise tasks work, while preserving existing package installations, configuration and the user's configuration-management workflow.

**Blocked by:** 02: Create and run named Linux profiles.

**Archive status:** Completed for the approved Linux scope; integrated as `1fbd78f`.

**Original intake status:** ready-for-agent

- [ ] Detect the Linux environment, available package manager, existing dependencies and agent installation sources. Clearly identify unsupported automatic setup paths instead of guessing.
- [ ] Provide a read-only setup preview naming required changes. Install only missing prerequisites and specifically requested agent CLIs through supported, authorized package-management operations; the other three agents remain optional.
- [ ] Respect configuration managed by dotfiles or another system by preparing its source changes. The public skill works without any author-specific provisioning or deployment skill.
- [ ] Integrate global tasks named agent-profiles-init and agent-profiles with named-profile argument forwarding, using the bundled helper as the single executable source of truth.
- [ ] Detect existing task-name conflicts, preserve unrelated settings and create backups before modifying important configuration. Repeated setup does not duplicate tasks or reinstall working tools.
- [ ] Task integration uses durable installed resources or a deliberately versioned deployment strategy, and reports broken resource locations after installation moves or updates instead of silently using stale code.
- [ ] Verify setup preview, conflict handling, repeated setup and setup of the installed package in a temporary configuration environment, then demonstrate initialization and a harmless command through both agreed mise tasks.
- [ ] After setup, doctor reports effective task configuration and actual bubblewrap namespace readiness. Machine setup and troubleshooting guidance are loaded only for the relevant request.
