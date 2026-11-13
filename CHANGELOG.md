# Changelog

- Nov-14, 2026 - 06:59 AM +08:00 - On macOS, the OpenCode service-port check no longer risks a spurious "unverified" result from a broken pipe when it confirms `lsof` can see its own process

- Nov-14, 2026 - 06:53 AM +08:00 - `check-install` extracts the source archive from a temporary file instead of a pipe, so macOS CI no longer fails intermittently with exit 141 when `tar` stops reading before `git archive` finishes writing

- Nov-14, 2026 - 01:09 AM +08:00 - `mise run test` runs the Bats suite in parallel through a pinned `rush`, one job per CPU up to 8, so a full run takes about 8 minutes instead of 19 on a 3-job macOS arm64 host; `AP_TEST_JOBS` sets the job count and `AP_TEST_JOBS=1` runs it serially

- Nov-14, 2026 - 12:58 AM +08:00 - `ap doctor` reports the global task as `stale` when the installed skill changed after setup: setup records the installed skill directory in each task, and doctor compares the deployed release with it, reporting `cannot verify` when that record is missing or the skill has moved, as after a plugin update

- Nov-13, 2026 - 11:21 PM +08:00 - Plugin installs copy only `skills/` instead of the whole repository (about 470 KB instead of 1.5 MB): the manifests live in `skills/.claude-plugin/` and `skills/.codex-plugin/`, name the skill directory as their skills path (the only form Codex discovers), and the package check enforces both; the release notes now list plugin install

- Nov-13, 2026 - 11:14 PM +08:00 - On macOS, `reset`, `remove`, `recover` and `migrate` no longer refuse because of a process that exited during the process scan, such as a short-lived Spotlight `mdworker_shared`; a process that is still alive and cannot be inspected still refuses

- Nov-13, 2026 - 10:18 PM +08:00 - The repository is a plugin marketplace: the skill installs as the `agent-profiles` plugin in Claude Code, Codex CLI and Antigravity CLI (from GitHub or a local checkout), the README documents each plugin's install, update, removal and helper path plus a manual copy for OpenCode, and the package check fails when a plugin manifest's version drifts from `VERSION`

- Nov-13, 2026 - 09:57 PM +08:00 - The README presents macOS arm64 as a supported platform: a platform badge and requirements table for both systems, a macOS install section (Xcode command line tools, Homebrew `mise`) with the configuration-only redirection, shared Keychain and Intel limits, and macOS-observed agent versions and evidence links in the compatibility section

- Nov-13, 2026 - 09:10 PM +08:00 - The lock-holder test fixture is the background job itself, so tests that stop it end it at once instead of waiting out its 30-second hold

- Nov-13, 2026 - 09:10 PM +08:00 - Tests that make a tool absent build their restricted `PATH` through one shared helper that forks nothing per executable and runs outside the bats debug trap, so each such setup takes under a second instead of 15-48 seconds on CI

- Nov-13, 2026 - 08:38 PM +08:00 - The `test` task runs the Darwin suite with the stock `/bin/bash` 3.2 path ordering the macOS CI job already uses, so a Homebrew bash earlier in `PATH` no longer fails the platform contract or resolves a Homebrew bash inside the restricted-PATH fixtures

- Nov-13, 2026 - 04:00 PM +08:00 - Qualify real-agent behavior on macOS arm64: version, offline startup, discovery and authentication were observed for Claude Code 2.1.323, Codex CLI 0.168.0, Antigravity CLI 1.5.8 and OpenCode 2.2.7 in disposable profiles under a test-only containment wrapper on a desktop host, with A/B redirection, host preservation, native runtime changes and the shared-host, network, Keychain and read-observability limits recorded in `docs/evidence/macos-2026-11-13-real-agent.md`

- Nov-13, 2026 - 02:16 PM +08:00 - The README install command uses `npx skills add` without a version pin, so users get the current `skills` CLI; the repository's own tests still pin 1.7.4

- Nov-02, 2026 - 09:47 AM +08:00 - Lease contention tests wait for the holder's own start marker and an observed lease instead of a fixed sleep, keep every holder and descendant in an owned-process registry with a bounded lifetime, and close the runner's capture descriptor before a fixture starts, so a slow host no longer fails the macOS suite and an aborted test cannot leave a fixture process behind

- Oct-31, 2026 - 05:07 PM +08:00 - macOS arm64 becomes a qualified platform: environment and configuration redirection only, stock `/bin/bash` 3.2 with no bubblewrap, a portable platform adapter for BSD userland, Darwin process safety that fails closed, a truthful Darwin doctor, an arm64 CI job with a guarded test tier, and release tooling that fingerprints every shipped file

- Oct-30, 2026 - 12:55 AM +08:00 - The README and setup reference use `ap migrate`, `ap recover` and `ap --version`

- Oct-30, 2026 - 12:55 AM +08:00 - `mise ap` also forwards `migrate`, `recover` and `--version` to the helper, so only machine setup still needs the helper's installed path

- Oct-30, 2026 - 12:53 AM +08:00 - The README introduces the `ap` alias right after setup, in both Quick start and Install, and uses `ap` in the usage table and everything after it

- Oct-30, 2026 - 12:51 AM +08:00 - The README uses the short `ap` alias after introducing it, keeping the installed helper only for first-time setup, redeploying after an update, `migrate` and `recover`

- Oct-30, 2026 - 12:08 AM +08:00 - Announce in the README that the skill will be renamed to `agent-profiles`, dropping the `flyingnobita-` prefix, before it is published to the public registry

- Oct-29, 2026 - 11:42 PM +08:00 - Rewrite the README around what a profile isolates and the `mise ap` workflow, with quick start, usage, skill and tool scopes, prompt setup and condensed install, maintenance and security sections

- Oct-29, 2026 - 11:42 PM +08:00 - Release checks no longer treat bracket syntax inside README code blocks as links, so the Starship prompt example no longer fails `check-release`

- Oct-29, 2026 - 11:16 PM +08:00 - Document showing the active profile in the shell prompt (`ap: NAME`) for Starship, zsh and bash, so a shell opened with `mise ap NAME` is not mistaken for a normal one

- Oct-29, 2026 - 10:55 PM +08:00 - Replace the two global mise tasks with one `agent-profiles` task aliased `ap`: `mise ap NAME [COMMAND]` runs a profile and offers to create a missing one (`--create` in scripts), with `new`, `ls`, `rm`, `reset` and `doctor` shortcuts; setup removes the retired `agent-profiles-init` task after a backup

- Oct-29, 2026 - 10:24 PM +08:00 - Run OpenCode in profiles with a private `--standalone` server wherever the command accepts it, so a profile session no longer leaves a background service on the shared port that blocks the host's own OpenCode

- Oct-29, 2026 - 03:50 PM +08:00 - Preserve the nine completed Linux delivery specifications in a tracked archive with integration references and remove their untracked scratch copies

- Oct-29, 2026 - 03:38 PM +08:00 - Configure GitHub Issues as the canonical tracker, migrate six remaining follow-ups, and add agent, triage and domain guidance

- Oct-29, 2026 - 02:46 PM +08:00 - Record independent seven-host verification of the published Deliver and Retro skills and close fleet follow-up F2

- Oct-29, 2026 - 02:21 PM +08:00 - Refresh verified publication, hosted CI and cleanup status, and consolidate remaining deployment, validation and optional-scope follow-ups

- Oct-29, 2026 - 01:50 PM +08:00 - Make setup package-manager and Codex mise-launcher tests independent of runner-installed tools using explicit disposable fixtures

- Oct-29, 2026 - 01:32 PM +08:00 - Install Linux runtime prerequisites in CI and probe bubblewrap on the Ubuntu 22.04 runner before running clean-install and test checks

- Oct-29, 2026 - 12:30 PM +08:00 - Refresh installation guidance for the published source repository, record verified copy-mode source installation and distinguish source publication from an unpublished tagged release and pending hosted CI

- Oct-29, 2026 - 12:16 PM +08:00 - Add GitHub Actions checks for main pushes and pull requests using pinned project tools, full CI verification and release artifact validation

- Oct-29, 2026 - 11:04 AM +08:00 - Record final Linux QA evidence for v0.1.0: Docker prerequisite installation with idempotent deployment and truthful namespace refusal, final offline startup/discovery/auth results for the four integrations with an independently reproduced background-session Claude shell-mode write denial and a Codex read-only denial, twenty-command public workflow, and the fresh 211-path host configuration preservation audit
- Oct-29, 2026 - 07:55 AM +08:00 - Repair round-2 review: deploy the versioned release even when the mise configuration is managed so prepared tasks run, deduplicate prepared instructions independently of the prepare directory, label prepared and untouched managed targets instead of applied writes, keep the managed preview truthful for installed agents, re-run lifecycle preflight under storage and profile locks, hold the storage lock while clearing incomplete journals, write journals through private unique temporary files, and report incomplete journals without a traceback
- Oct-29, 2026 - 07:14 AM +08:00 - Repair release readiness review: keep agent-named profiles usable by classifying named profiles structurally, refuse migrate and recovery while any legacy source or trash path is in use, classify real conversation stores in destructive previews, preserve managed mise configuration and back up the original before requested agent installs with a matching tasks-only and managed preview, lock lifecycle operations before profile checks and create journals atomically, refuse unsafe journal sidecar locks, classify apiKeyHelper and ANTHROPIC_AUTH_TOKEN in Claude diagnostics, mark probes unverified when no temporary directory exists, and use standard dashes in shipped content
- Oct-29, 2026 - 06:11 AM +08:00 - Deliver ticket 09: publish the Linux release README, MIT license copy, dated four-integration compatibility matrix and sanitized evidence summary, list every implemented command in the helper help and router, and add release readiness checks with a verified v0.1.0 tarball, checksum and notes
- Oct-29, 2026 - 03:53 AM +08:00 - Deliver ticket 07: integrate OpenCode profiles with OPENCODE_CONFIG_DIR replacing the configuration root, profile XDG data/state/cache, doctor profile artifacts with separate profile and environment credential diagnostics, shared background-service port classification, version-aware usage guidance, and offline live QA with private servers and owned-process cleanup
- Oct-29, 2026 - 03:38 AM +08:00 - Deliver ticket 03: add Linux machine detection and read-only setup preview, versioned helper deployment with sha256 manifests, two global mise file tasks with argument forwarding, conflict preservation and backups, managed-configuration prepare-dir support, opt-in missing prerequisite and mise-registry agent installation, and doctor task/namespace readiness checks
- Oct-29, 2026 - 02:59 AM +08:00 - Deliver ticket 04: add Claude Code profile integration with CLAUDE_CONFIG_DIR redirection, profile-scoped discovery and doctor auth classification, offline startup/auth/sandbox QA with ownership-aware process cleanup, and focused Claude setup and troubleshooting guidance
- Oct-29, 2026 - 02:57 AM +08:00 - Deliver ticket 06: add Google Antigravity CLI (agy) profile diagnostics for .gemini artifacts, candidate credential files, environment variable names and the shared OS credential service, and offline live QA proving startup, per-profile .gemini and plugin skill discovery, resource audit and owned cleanup
- Oct-29, 2026 - 02:05 AM +08:00 - Repair ticket 08: require durable per-source content manifests and two-phase integrity validation before recovery moves data or deletes originals, refusing corrupt, missing, partial, or changed verified backups with exit 77 while preserving original data and journals
- Oct-29, 2026 - 01:56 AM +08:00 - Repair ticket 05: harden shared live cleanup with per-process UID, profile-marker and PID-reuse checks, and add Codex profile diagnostics for CODEX_HOME, artifacts, environment credential names and reported login state
- Oct-29, 2026 - 01:35 AM +08:00 - Deliver ticket 08: add safe profile lifecycle with targeted reset/remove previews, exclusive profile locks and process-scan refusals, journaled recovery, legacy .agent-sandbox and unnamed .agent-profiles migration with private outside-checkout backups, per-file SHA-256 verification, and lifecycle reference guidance
- Oct-29, 2026 - 01:35 AM +08:00 - Deliver ticket 05: add Codex CLI profile support with CODEX_HOME and home .agents skill discovery, mise-backed launcher resolution in doctor, offline live QA for startup/discovery/auth/sandbox, and verified Codex reference guidance
- Oct-28, 2026 - 10:28 PM +08:00 - Repair ticket 02: bind nested container detection to canonical checkout and profile storage identity, reject symlinks in profile internals and lock files, enforce two-pass mount validation preventing host fixture modification and rejecting ancestor/descendant overlaps, source shipped agent modules, run preflight across all profile commands, configure uv tool bin destination, sanitize profile listing, and harden live test harness with isolated process cleanup
- Oct-28, 2026 - 09:50 PM +08:00 - Deliver ticket 02: implement named Linux profile runtime with bubblewrap home directory redirection, profile naming and private storage layout, local git exclusion, isolated XDG and package manager roots, host mise directory preservation, shared lease API, and live test harness
- Oct-28, 2026 - 09:12 PM +08:00 - Repair ticket 01: bootstrap python check, validate agent and profile CLI options, enforce probe secret safety and unverified status classification, modularize per-agent probes and dynamic doctor section registration, clarify skill-relative helper paths, and isolate installer environments while verifying all four agent registrations in check-install
- Oct-28, 2026 - 08:15 PM +08:00 - Deliver ticket 01: installable skill, router, doctor diagnostics, Q&A, and clean skills installation
