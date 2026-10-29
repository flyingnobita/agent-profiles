# 09: Prepare the public Linux release

> Historical specification. The approved Linux delivery is completed and
> integrated. See the [delivery record](../../agents/delivery-progress.md)
> for verification, scope decisions and remaining limitations. The original
> criteria below are preserved as written; unchecked boxes are not open tasks.

**What to build:** Prepare a public, installable Linux release of flyingnobita-agent-profiles, with truthful support claims, end-to-end validation and usable installation and maintenance instructions.

**Blocked by:** 03: Set up a Linux machine and integrate mise tasks; 04: Use Claude Code with profiles; 05: Use OpenAI Codex CLI with profiles; 06: Use Google Antigravity CLI with profiles; 07: Use OpenCode with profiles; 08: Reset, remove, and migrate profiles safely.

**Archive status:** Completed for the approved Linux scope; integrated as `3503944`.

**Original intake status:** ready-for-agent

- [ ] Provide a public README, maintainer-confirmed license, installation/update/removal instructions and a dated compatibility matrix naming exactly Claude Code, OpenAI Codex CLI, Google Antigravity CLI and OpenCode as the supported agent integrations.
- [ ] The repository layout is discoverable through npx skills add with explicit selection of flyingnobita-agent-profiles. Verify a clean local-source installation before publication and a repository-source installation once publication is separately authorized.
- [ ] The installed copy includes its helper and references, executes from an installation path different from the source checkout and works when the author's dotfiles checkout is unavailable.
- [ ] Run automated checks for profile selection, concurrent execution, mise preservation, task integration, lifecycle operations and supported-agent discovery. Record actual live CLI evidence and credential-dependent gaps separately.
- [ ] Validate progressive disclosure using representative machine-setup, repository-operation, question and troubleshooting requests. Keep the entry point small, avoid duplicated implementations and load only references needed by each task.
- [ ] Remove author-specific home paths, hostnames, gateways, credentials and mandatory dependencies on personal fleet skills. Keep the public brand name and agreed user-facing task/storage contracts.
- [ ] Describe the workflow as agent profiles with broad remaining host access, not a security sandbox for untrusted code. Publish only sanitized test evidence.
- [ ] macOS qualification remains deferred at the user's request and does not block this Linux release. Any retained macOS implementation is clearly unverified or experimental; do not claim it passed Linux-only tests.
- [ ] Prepare versioned release artifacts and notes. Creating a public remote, pushing commits, publishing a release, or deploying to real machines requires a separate explicit user instruction and is not authorized by these tickets.
