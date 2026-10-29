# 02: Create and run named Linux profiles

> Historical specification. The approved Linux delivery is completed and
> integrated. See the [delivery record](../../agents/delivery-progress.md)
> for verification, scope decisions and remaining limitations. The original
> criteria below are preserved as written; unchecked boxes are not open tasks.

**What to build:** From an installed skill, initialize and list named profiles for a Git checkout and run a harmless command in the selected Linux profile, with separate configuration and tool-install destinations and a working host mise installation.

**Blocked by:** 01: Installable skill with readiness checks and Q&A.

**Archive status:** Completed for the approved Linux scope; integrated as `c6817cb`.

**Original intake status:** ready-for-agent

- [ ] The bundled helper can initialize, list and run profiles directly, before global mise integration is installed.
- [ ] Profiles use the agreed .agent-profiles storage with named subdirectories. Omitting --profile selects default; new names start empty. Names accept 1-32 lowercase letters, digits, underscores or hyphens, starting with a letter.
- [ ] Reject empty or invalid names, path traversal, missing commands and uninitialized profiles with clear errors. Consume profile options only before the child command and forward its remaining arguments unchanged.
- [ ] Resolve the Git checkout root from subdirectories, preserve the calling directory for execution, support separate Git worktrees and add only local Git exclusions through Git's metadata lookup.
- [ ] The selected profile has separate XDG directories, npm global prefix and cache, uv tools and cache, Cargo installation root, Go binaries and Python user-install root, with its own binaries selected first. Project package managers and lockfiles are preserved.
- [ ] Preserve mise's effective configuration, installed-tool, state and cache directories before redirects, including existing custom overrides. Generic commands and mise-backed executables continue to resolve.
- [ ] Linux uses bubblewrap directory redirection and fails clearly if namespace capabilities are unavailable. Support valid host directory symlinks; reject dangling, overlapping, root and profile-hiding mount targets. Explain any empty host directories created for mountpoints.
- [ ] Profile roots do not silently alias one another. Define and test nested invocation behavior so changing profiles cannot accidentally retain another profile's tool paths or overrides.
- [ ] Verify repeat initialization, concurrent profile namespaces, inherited selection variables, argument quoting, separate install/configuration roots and worktree separation in disposable repositories. Create new profile storage with private permissions.
- [ ] The skill can carry out an initialization-and-run request by executing the helper, without reconstructing scripts in the model context. Document shared project files, host access and mise caches.
