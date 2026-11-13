# flyingnobita-agent-profiles v0.3.0

Named agent profiles now run on macOS arm64 as well as Linux. The same four
integrations are supported: Claude Code, OpenAI Codex CLI, Google Antigravity
CLI and OpenCode. MIT licensed.

On Linux a profile is redirected with a bubblewrap mount layer. macOS has no
namespace to mount into, so there a profile is redirected through the agents'
own configuration variables and a profile `HOME`, and nothing is mounted.
Neither platform is a security sandbox for untrusted code, and the macOS layer is
the weaker of the two because a process that ignores those variables still sees
host paths. Inherited environment credentials and shared host resources,
including the macOS Keychain, stay shared.

Both platforms are verified differently. Linux is qualified by the 2026-10-29
host QA plus the offline evidence summary. macOS arm64 profile mechanics,
configuration redirection and diagnostics are qualified by the 2026-10-31
real-machine run recorded in `docs/evidence/macos-2026-10-31.md` and by the
arm64 job in CI. A 2026-11-13 macOS arm64 desktop run observed version, startup,
discovery and authentication for the four real agent CLIs in disposable profiles
(`docs/evidence/macos-2026-11-13-real-agent.md`); it claims no enforcement and no
network containment. Credential-dependent model behavior remains a
credential-dependent gap on both platforms and is not claimed.

The source is available at <https://github.com/flyingnobita/agent-profiles>, and
repository-source installation in copy mode is verified in a disposable home.
A tagged GitHub Release is **not published**. The artifact set is built and
verified locally; tagging, publishing a release or deploying to real machines
requires a separate explicit maintainer action.

## Highlights

- macOS arm64 support: environment and configuration redirection, stock
  `/bin/bash` 3.2, and no bubblewrap prerequisite
- A portable platform adapter replaces `flock`, GNU `readlink`, `realpath`,
  `stat`, `sha256sum`, `timeout`, `cp --no-dereference` and `mapfile` so the same
  helper and test suite run on BSD userland
- Darwin process safety: lifecycle mutations fail closed when process inspection
  is unavailable, and live harness cleanup proves UID, profile, process group and
  start identity before any signal
- `doctor` reports Darwin honestly: arm64 qualified, bubblewrap and namespace
  checks not applicable, Antigravity's shared Keychain and OpenCode's listener
  classified without procfs
- An arm64 macOS CI job plus a guarded test tier with two named, reasoned
  Linux-only skips
- Release tooling builds a reproducible artifact with the Python standard library
  and fingerprints every shipped file, rejecting stale or tampered content

## Compatibility

See the compatibility reference for the per-agent matrix, the tested versions and
the evidence classes. Linux results are not evidence for macOS behavior and the
reverse also holds.

## Earlier release: flyingnobita-agent-profiles v0.1.0

First local Linux release of named agent profiles for Claude Code, OpenAI Codex
CLI, Google Antigravity CLI and OpenCode. MIT licensed.

The source is available at <https://github.com/flyingnobita/agent-profiles>, and
repository-source installation in copy mode is verified in a disposable home.
A tagged GitHub Release is **not published**. The artifact set is built and
verified locally; tagging, publishing a release or deploying to real machines
requires a separate explicit maintainer action.

### Highlights of v0.1.0

- Installable skill (`npx skills add ... --skill flyingnobita-agent-profiles`)
  that resolves its helper and references from its own installation path.
- Named profiles at `.agent-profiles/<name>/` with bubblewrap redirection for
  `.claude`, `.codex`, `.gemini` and `.agents`, plus per-profile XDG, npm, uv,
  Cargo, Go and Python user roots. Host mise configuration and directories are
  preserved.
- `init`, `list`, `run` and read-only `doctor` diagnostics (text and `--json`)
  covering OS, dependencies, global tasks, user-namespace readiness and the four
  agent integrations.
- `setup` with a read-only preview, versioned helper deployment under
  `${XDG_DATA_HOME:-$HOME/.local/share}/flyingnobita-agent-profiles/releases/`,
  and exactly two global mise file tasks that forward arguments verbatim.
- Safe lifecycle: previewed `reset` and `remove`, `migrate` from legacy
  `.agent-sandbox` storage with private outside-checkout backups and per-file
  SHA-256 verification, and journaled `recover` for interrupted operations.
- Agent integrations for Claude Code 2.1.312, Codex CLI 0.165.0, Antigravity CLI
  1.4.9 and OpenCode 2.2.0, each with profile diagnostics and offline QA.

### Platforms

Linux x86_64 with bubblewrap and unprivileged user namespaces is qualified.
macOS is not qualified: it is deferred and unverified, and this release makes no
macOS claim.

### Security Boundary

Agent profiles are not a security sandbox and not a container or VM boundary.
Profile processes keep broad remaining host access: the kernel, the filesystem
outside the redirected directories, network access and the project checkout.
Inherited environment credentials and shared OS services (for example the session
D-Bus secret service used by Antigravity CLI, and the host-wide OpenCode service
on its default port) remain shared. Do not run untrusted code in a profile
expecting containment.

### Evidence

Sanitized Linux evidence is published in `docs/evidence/linux-2026-10-29.md`
(final QA) and `docs/evidence/linux-2026-10-28.md` (historical offline evidence),
with version, startup, discovery, authentication and sandbox results kept
separate. Raw QA logs stay private.

Final QA installed genuinely missing prerequisites with `setup --apply` in
`archlinux:latest` and `ubuntu:24.04`, verified idempotent deployment and both
task shims, ran the `agent-profiles-init` task, and confirmed that the
`agent-profiles` run task delegates to the helper and truthfully returns the
exit-69 namespace refusal under default Docker restrictions. Full profile
execution inside default Docker, and equality across the original paused QA
interval, are not claimed.

Claude Code write denial was verified for a background-session shell-mode `!`
command with strict sandbox settings; foreground or manual shell-mode was not
qualified.

Credential-dependent gaps are recorded, not claimed: live model responses,
model-driven skill invocation, and command execution or sandbox denials that
require an authenticated model turn (including the Antigravity CLI sandbox and
OpenCode model commands).

### Known Limits

- Hosted CI passed at `dea1c24`: 332 tests, lint, both clean-install modes and
  release artifact checks. See [the verified run](https://github.com/flyingnobita/agent-profiles/actions/runs/40825706875).
  Current follow-ups are listed in [outstanding.md](docs/agents/outstanding.md).
- The Antigravity CLI read of the repository/workspace `.agents` customization
  root is unqualified because it happens in an authenticated conversation.
- OpenCode's background service uses a host-wide default port (49374) and a
  shared temporary directory (`/tmp/opencode`); profiles do not redirect either.
- macOS support is deferred and this release contains no Darwin implementation.
- Default Docker containers usually restrict unprivileged user namespaces; there
  `run` exits 69 with the cause instead of falling back, so full profile
  execution inside such a container is not qualified.
- A fresh controlled audit found 211 selected persistent host configuration paths
  equal around a Codex QA run. An earlier unattributed configuration-file content
  change in the Codex config was accepted as-is by the user: the current file is
  preserved with no restore, and no whole-interval equality is claimed.

### Artifact Contents

- `flyingnobita-agent-profiles-0.1.0.tar.gz` - the installable skill bundle
  (`SKILL.md`, `VERSION`, `LICENSE`, `scripts/`, `references/`).
- `flyingnobita-agent-profiles-0.1.0.tar.gz.sha256` - SHA-256 checksum.
- `RELEASE_NOTES.md` - this file.

Verify a downloaded artifact set with `sha256sum -c`, or rebuild and verify it
with `mise run release-artifacts`.
