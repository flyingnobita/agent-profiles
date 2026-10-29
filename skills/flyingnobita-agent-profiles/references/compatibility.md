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
| macOS (Darwin) | Not Qualified | Deferred and unverified; there is no Darwin redirection layer |

Linux is the only implementation. Running on any other OS reports that the
platform is not qualified (exit 69) instead of attempting a fallback. Linux
results are not evidence for macOS behavior.

Default Docker containers usually restrict unprivileged user namespaces. There,
prerequisite installation, versioned deployment, the two global tasks and
`doctor` are qualified, but the namespace probe reports the restriction and
profile `run` exits 69 with the cause. Full profile execution inside such a
container is not claimed and no bypass is attempted.

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
| Claude Code 2.1.312 | ready (init event, TUI banner offline) | profile-scoped skills and MCP; host markers absent | fresh profile logged out; environment key classified by name | enforced and independently reproduced in final QA: outside write denied, inside write allowed |
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
  (`49374` in the tested version); QA used private `--standalone` servers and
  never connected to a host service. The shared temporary directory
  (`/tmp/opencode`) is not redirected by a profile.
- **Host services.** Services started by the host outside a profile namespace
  (`systemd --user`, D-Bus activation) carry no profile marker and cannot be
  attributed to a profile by the process scan.
- **Network and repository.** Network access and the project checkout are shared
  by every profile in that checkout.
- **Host configuration preservation.** A fresh controlled audit compared 211
  selected persistent settings, configuration, credential and mise paths by
  content hash and stat metadata around a Codex QA run and found them equal,
  without reading credential values. An earlier unattributed Codex setting
  change during a paused QA interval was accepted by the user as-is; equality
  across that original interval is not claimed and no host configuration was
  restored or written.
