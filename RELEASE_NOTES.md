# flyingnobita-agent-profiles v0.1.0

First local Linux release of named agent profiles for Claude Code, OpenAI Codex
CLI, Google Antigravity CLI and OpenCode. MIT licensed.

This release is **not published**. The artifact set is built and verified
locally; creating a public remote, pushing commits, tagging, publishing a
release or deploying to real machines requires a separate explicit maintainer
action.

## Highlights

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

## Platforms

Linux x86_64 with bubblewrap and unprivileged user namespaces is qualified.
macOS is not qualified: it is deferred and unverified, and this release makes no
macOS claim.

## Security Boundary

Agent profiles are not a security sandbox and not a container or VM boundary.
Profile processes keep broad remaining host access: the kernel, the filesystem
outside the redirected directories, network access and the project checkout.
Inherited environment credentials and shared OS services (for example the session
D-Bus secret service used by Antigravity CLI, and the host-wide OpenCode service
on its default port) remain shared. Do not run untrusted code in a profile
expecting containment.

## Evidence

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

## Known Limits

- Repository-source installation is proposed, after publication; only
  local-source installation is verified for this release.
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

## Artifact Contents

- `flyingnobita-agent-profiles-0.1.0.tar.gz` - the installable skill bundle
  (`SKILL.md`, `VERSION`, `LICENSE`, `scripts/`, `references/`).
- `flyingnobita-agent-profiles-0.1.0.tar.gz.sha256` - SHA-256 checksum.
- `RELEASE_NOTES.md` - this file.

Verify a downloaded artifact set with `sha256sum -c`, or rebuild and verify it
with `mise run release-artifacts`.
