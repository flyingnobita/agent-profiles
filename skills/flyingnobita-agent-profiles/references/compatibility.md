# Compatibility Matrix

Platform compatibility, qualified agent CLIs, verified versions and feature
boundaries. Initial offline evidence was collected 2026-10-28; final
qualification, Docker prerequisite installation and the host preservation audit
ran 2026-10-29 on Linux x86_64 in disposable profiles and test-owned containers.

Agent profiles provide workflow and dependency separation. They are not a security sandbox
for untrusted code: host access, inherited environment credentials and shared OS
services remain.

## Platform Support

| Operating System | Status | Verification Notes |
| --- | --- | --- |
| Linux (x86_64) | Qualified | bubblewrap and unprivileged user namespaces required; host final QA 2026-10-29 |
| macOS (arm64) | Qualified for profile mechanics, redirection and diagnostics | configuration redirection only (no mounts); stock `/bin/bash` 3.2, mise, git and python3; macOS 27.2 arm64 mechanics run in `docs/evidence/macos-2026-10-31.md`. Version, startup, discovery and authentication of the four real agent CLIs were observed on a later macOS arm64 desktop run in `docs/evidence/macos-2026-11-13-real-agent.md`; enforcement, offline containment and credentialed model runs remain unverified |

Linux redirects with a bubblewrap mount layer. On macOS there is no namespace
to mount into, so a profile is redirected by pointing the agent CLIs and
toolchains at profile storage through their own environment and configuration
variables plus a profile `HOME`. Both platforms separate settings and tools;
neither is a security boundary, and the macOS layer is the weaker of the two
because a process that ignores those variables still sees host paths. Linux
results are not evidence for macOS behavior and the reverse also holds.

Unsupported operating systems report the platform as not qualified instead of
attempting a fallback. Darwin is decided per architecture by `doctor` only: a
Darwin build that is not arm64 is reported there as unqualified (a warning, not
a refusal), and profile execution on such a build is unvalidated because only
macOS arm64 was tested. `run` and `setup` do not refuse a non-arm64 Darwin host.

Default Docker containers usually restrict unprivileged user namespaces. There,
prerequisite installation, versioned deployment, the task shims, profile
creation through the earlier `agent-profiles-init` task and `doctor` are
qualified (its replacement, `mise ap new`, runs the same `init` and is not
re-qualified there); running a profile delegates to the helper and returns the
namespace refusal (exit 69), and
`doctor` reports the restriction. Full profile execution inside such a container
is not claimed and no bypass is attempted.

## Agent CLI Integration Matrix

| Agent CLI | Command | Verified Version | Configuration Redirection |
| --- | --- | --- | --- |
| Claude Code | `claude` | 2.1.312 | `CLAUDE_CONFIG_DIR` plus `.claude` mount |
| OpenAI Codex CLI | `codex` | 0.165.0 | `CODEX_HOME` plus `.codex` and `.agents` mounts |
| Google Antigravity CLI | `agy` | 1.4.9 | `.gemini` and `.agents` mounts plus XDG roots |
| OpenCode | `opencode` | 2.2.0 | `OPENCODE_CONFIG_DIR` plus XDG roots |

Exactly these four agent CLIs are integrated. Gemini CLI is a different tool and
is not supported; `.gemini` is Antigravity CLI storage. A delivery or
orchestration harness used to build this release is not a supported agent
integration.

Version numbers come from the informational version probe and are recorded per
release. A successful `--version` does not demonstrate startup, discovery,
authentication or sandbox behavior; those are separate evidence classes.

## Verified Evidence Classes

Each integration was checked offline in disposable profiles with a synthetic
home. The sanitized results are published in
`docs/evidence/linux-2026-10-28.md`; raw logs stay private.

| Class | What it establishes |
| --- | --- |
| Version | The resolved CLI and version, informational only |
| Startup | The normal entry point reached a recorded ready marker offline |
| Discovery | Profile A/B skills, repository and bundled sources stay separate; synthetic host markers are not read |
| Auth | Status commands classified without printing values; no host credential copy |
| Sandbox | An enforced write denial, where the CLI exposes a credential-free surface |

| Integration | Startup | Discovery | Auth | Sandbox |
| --- | --- | --- | --- | --- |
| Claude Code 2.1.312 | ready (init event, TUI banner offline) | profile-scoped skills and MCP; host markers absent | fresh profile logged out; environment key classified by name | background-session shell-mode `!` command with strict sandbox settings: outside write denied, inside write allowed (foreground or manual shell-mode not qualified) |
| Codex CLI 0.165.0 | ready (sign-in screen offline) | profile, repository and bundled skill roots; parent directory outside the repo excluded | fresh profile reports not logged in; environment key reported by name | enforced: read-only sandbox denies a controlled write (final QA) |
| Antigravity CLI 1.4.9 | ready (sign-in screen offline, session bus masked) | three `.gemini` skill roots and per-profile plugins; profile `.agents` not read | no profile credential file; environment names only; OS credential service shared | credential-dependent: denial needs a model turn |
| OpenCode 2.2.0 | ready (TUI composer offline) | profile, repository and bundled skills; private `--standalone` server | profile and environment sources separated by name; no values printed | not claimed: no enforced denial surface; shell command works without a model turn |

## Credential-Dependent Gaps

These remain unverified for this release and are not claimed:

- live model responses for any integration;
- model-driven skill invocation;
- command execution and enforced sandbox denial that require an authenticated
  model turn, including the Antigravity CLI sandbox and OpenCode model commands.

An Antigravity CLI read of the repository/workspace `.agents` customization root
is unqualified: it happens during an authenticated conversation. It is recorded
as unverified, not assumed to work.

## Shared Host Resources and Limits

- **OS credential services.** Antigravity CLI authenticates through the session
  D-Bus secret service (`org.freedesktop.secrets`). That service is outside
  profile storage, so a profile is not a separate account and a hosted token can
  authenticate a process running inside a profile.
- **Inherited credentials.** Environment credentials exported by the invoking
  shell are inherited. Doctor reports variable names only, never values.
- **OpenCode background service.** The default service port is host-wide
  (`49374` in the tested version). Profile runs add `--standalone` to every
  command that accepts it, so they use a private server instead; commands
  without the flag, such as `service`, still manage a background service on
  that port. The shared temporary directory (`/tmp/opencode`) is not
  redirected by a profile.
- **Host services.** Services started by the host outside a profile namespace
  (`systemd --user`, D-Bus activation) carry no profile marker and cannot be
  attributed to a profile by the process scan.
- **Network and repository.** Network access and the project checkout are shared
  by every profile in that checkout.
- **Host configuration preservation.** A fresh controlled audit compared 211
  selected persistent settings, configuration, credential and mise paths by
  content hash and stat metadata around a Codex QA run and found them equal,
  without reading credential values. An earlier unattributed configuration-file
  content change in the Codex config during a paused QA interval has an unknown
  actor; the current file is preserved as-is with no restore, and equality across
  that original interval is not claimed.
