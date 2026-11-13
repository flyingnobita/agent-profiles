# macOS arm64 real-agent evidence, 2026-11-13

Sanitized summary of an opt-in real-agent qualification run on a macOS arm64
desktop. All four supported agent CLIs were installed on this host, which is the
gap that
[the 2026-10-31 snapshot](macos-2026-10-31.md) records as not observed. That page
stays a historical snapshot of its own host and is not updated by this one.

Raw logs and the disposable trees stay private. This page is the sanitized
summary: no account names, no host paths, no credential values.

## What was run

| Item | Value |
| --- | --- |
| Host | macOS 27.2.1 arm64 desktop, stock `/bin/bash` 3.2.57, mise-managed tools, real user session |
| Isolated host | disposable synthetic `HOME` with its own XDG roots and mise state, plus a disposable Git checkout for the profiles |
| Profiles | two named profiles for the A/B check and one fresh profile per agent for the startup check |
| Containment | each CLI launch ran under a test-owned `sandbox-exec` profile, kept outside this repository, that denies non-loopback egress and allows loopback |
| Not performed | no login, no account sign-in, no completed provider request, no model turn, no tool installation, and no `security` command; whether a CLI queried the Keychain was not observed |

The containment profile is a property of this run, not of the product. It exists
so the startup class can be called offline; the platform limit it does not remove
is in the limits section. Its policy is a test artifact: outbound network denied
except loopback, inherited environment, and read access to the system tool paths
the CLIs need. It is not committed here, and `sandbox-exec` is the deprecated API
that [ADR 0001](../adr/0001-darwin-environment-only-redirection.md) rejects as a
product mechanism. Nothing in this page is product behaviour or a supported
containment guarantee.

## Version class

Informational. The version probe is separate from startup, discovery and
authentication, and `doctor` marked the probe verified for all four.

| Integration | Command | Observed |
| --- | --- | --- |
| Claude Code | `claude --version` | 2.1.323 |
| Codex CLI | `codex --version` | codex-cli 0.168.0 |
| Antigravity CLI | `agy --version` | 1.5.8 |
| OpenCode | `opencode --version` | 2.2.7 |

## Startup class

Each CLI was launched in a fresh profile through `agent-profiles run`, on a
recorded pseudo-terminal, with no credentials, and was stopped by the harness
timeout. Output markers are quoted from the sanitized capture.

| Integration | Offline result | What it proves |
| --- | --- | --- |
| Claude Code | banner `Welcome to Claude Code v2.1.323`, then `Unable to connect to Anthropic services` and `api.anthropic.com: ECONNREFUSED`, exit 1 | the entry point renders with profile storage and no credentials supplied, stops at its own connectivity check when egress is denied, and does **not** reach a ready state; host credential reads were not observed |
| Codex CLI | sign-in screen: `Choose how you want to use Codex`, `1. Sign in with ChatGPT`, reached with `--no-daemon` | the entry point reaches its authentication surface offline in a profile, but only with `--no-daemon` |
| Antigravity CLI | `Welcome to the Antigravity CLI. You are currently not signed in.` with `Select login method: 1. Google OAuth, 2. Use a Google Cloud project` | the entry point reaches its sign-in surface offline in a profile, with no extra flag |
| OpenCode | TUI composer `Ask anything...`, version `2.2.7`, workspace path inside the disposable checkout | the TUI reaches its composer offline in a profile, with no extra flag |

Read this table as three different outcomes, not one: Antigravity CLI and
OpenCode reached their own ready or composer surface; Codex CLI reached its
authentication surface only with `--no-daemon`; Claude Code rendered its entry
point and then stopped at its own connectivity check without reaching ready.

Codex's default mode, which starts a pid-managed background app-server, does not
start under the test-owned containment profile: it reports `failed to invoke ps
... Operation not permitted`. The run therefore qualified Codex startup with
`--no-daemon`. This is a limit of the containment wrapper, recorded below; Codex's
default mode outside the wrapper was not observed in this run.

## Discovery class

A profile redirects configuration. The discovery question is which storage the
real CLI reads and writes, observed through each CLI's own reporting surface and
through the files it created.

| Integration | Where the real CLI resolved its state | A/B check with a distinguishable marker |
| --- | --- | --- |
| Claude Code | `claude mcp add` reported `File modified: <profile a>/.claude/.claude.json`; the new profile gained `.claude/.claude.json` and one `.claude/backups` entry | `claude mcp list` in profile A listed only the A marker, in profile B only the B marker |
| Codex CLI | `codex doctor` reported `CODEX_HOME ~/.codex`, resolving inside the profile, and `config.toml ~/.codex/config.toml` parsed ok | `codex doctor` reported model `ap-qa-marker-a` in profile A and `ap-qa-marker-b` in profile B |
| Antigravity CLI | `agy mcp add` and `agy mcp list` acted on the profile `.gemini` tree, whose `config/` and `antigravity-cli/` appeared inside the profile | `agy mcp list` showed the A marker in profile A and the B marker in profile B |
| OpenCode | `opencode debug config` reported the profile `.opencode` directory; state landed in the profile `.local/share` and `.local/state` | `opencode debug config` reported the profile A directory in A and the profile B directory in B |

No read-back in one profile listed the other profile's marker, and nothing a
profile run wrote appeared in the synthetic host home. That is a statement about
what each CLI reported and wrote, not proof that a read was impossible: the read
boundary is covered in the limits section.

## Authentication class

Diagnostics only. `doctor --json` was run per profile; no credential value was
read or printed, and no sign-in was attempted.

| Integration | Fresh profile | Environment credentials |
| --- | --- | --- |
| Claude Code | `logged_out`, method `none`, `Fresh profile, not signed in (OS keyring not inspected)` | a synthetic `ANTHROPIC_API_KEY` was classified `env_inherited` / `environment` by name and explicitly not stored in the profile |
| Codex CLI | `logged_out`, `codex login status reports no login` | a synthetic `OPENAI_API_KEY` was listed by name in `env_credentials` and the profile still reported `logged_out` |
| Antigravity CLI | `no_profile_credentials`, `authenticated: null`, `profile_files: []` | none reported; the OS credential service is reported as available outside profile isolation |
| OpenCode | `no_profile_credentials`, `profile_files: []` | inherited variable names listed by name only; a shared background service port was reported listening outside the profile |

The inherited-variable names are reported, never their values, and an inherited
key is not profile storage: the same profile reports `logged_out` for Codex with
the key present.

## Shared host, network, Keychain and read-observability limits

These are the limits this run observed, stated as observed:

- Network is not blocked by the product. Darwin has no network namespace, so a
  profile session shares the host network. The offline startup class above is a
  result of the test-owned `sandbox-exec` containment, and the denial it produced
  is visible in the captures (`ECONNREFUSED`, and Codex `doctor` reporting the
  update and runtime CDN unreachable). No offline containment is claimed for
  macOS arm64 outside such a wrapper.
- The containment wrapper has its own limit: `/bin/ps` does not execute inside
  it, so any agent surface that inspects processes (Codex's pid-managed
  background app-server) cannot start there.
- Redirection is not a read boundary. From inside profile A, the host
  `.claude/settings.json`, `.codex/config.toml`, `.gemini/settings.json` and
  `.config/opencode/opencode.json` were all readable, and so were the host
  credential files `.claude/.credentials.json`, `.codex/auth.json` and
  `.local/share/opencode/auth.json`. This run tested readability only and read no
  content.
- The macOS Keychain is one per user session and stays shared. No `security`
  command was run, and whether a CLI queried the Keychain was not observed.
  Antigravity reports the shared OS credential service; OpenCode reports the
  shared background service port.
- Host services outside the profile keep running as the user and stay visible to
  a profile session, exactly as [compatibility.md](../../skills/flyingnobita-agent-profiles/references/compatibility.md)
  states. A profile is not a security boundary.

## Preservation and cleanup

Observation is only useful if the host is unchanged afterwards.

| Check | Observed |
| --- | --- |
| Host configuration | `sha256` unchanged before and after for exactly four files: host `.claude/settings.json`, `.codex/config.toml`, `.gemini/settings.json` and `.config/opencode/opencode.json`. The compared set is those four; no other host path was hashed |
| Host credentials | size and modification time unchanged for host `.claude/.credentials.json`, `.codex/auth.json` and `.local/share/opencode/auth.json`; no value read. Byte-for-byte content equality is not claimed |
| Credential use | no login, no sign-in flow completed, no provider request completed, no `security` command |
| Disposable trees | synthetic home, disposable checkout and all profiles removed; no temporary profile directory left behind |
| Processes | one leftover process whose environment still carried the disposable profile path was terminated during cleanup; a scan afterwards found none |
| Private evidence | one stray private evidence directory written by an early aborted harness invocation was removed; raw logs remain private and outside Git |

## Native runtime changes, classified honestly

The real CLIs do change state, and the profile moves that state rather than
removing it. Per agent, in the fresh profile it ran in:

| Integration | State written inside the profile | Class |
| --- | --- | --- |
| Claude Code | `.claude/.claude.json` and one `.claude/backups` entry | session and configuration state, redirected |
| Codex CLI | 68 files: `.codex` sqlite state, logs and queue databases, installation id, a plugin sync lock, and 49 bundled system skills under `.codex/skills` | configuration state plus materialized bundled content, redirected |
| Antigravity CLI | 55 files: `.gemini/antigravity-cli` state database, log, bundled plugin payload, `bin/webm_encoder`, updater state including an update check timestamp and lock, plus `.gemini/config` | configuration state plus materialized bundled content; an update check ran and wrote updater state, the wrapper denied its egress, and no downloaded payload was observed |
| OpenCode | `.local/share/opencode` database and log, `.local/state/opencode` TUI state, npm cache directories | session, state and cache data, redirected |

Two things follow, and neither is a claim of containment:

- these runtime changes are the CLIs' own behaviour under a profile, not a
  product feature that suppresses them;
- an update check can still be attempted. Disabling updates is not claimed.

## Separation from credentialed model execution

This page records diagnostics and offline startup only. Every launch stopped at a
sign-in, connectivity or composer surface, and no prompt was sent.

Still unverified, and unchanged by this run:

- model responses for any integration, which need credentials;
- model-driven skill invocation;
- command execution and enforced write denial that require an authenticated model
  turn, including the Antigravity CLI sandbox and OpenCode model commands;
- an Antigravity CLI read of the workspace `.agents` customization root, which
  happens during an authenticated conversation.

Credentialed model runs remain a credential-dependent gap on every platform and
are not claimed here.

## Reproduction

Version, discovery and authentication are the repository's own surfaces, run
inside a disposable synthetic home and a disposable checkout:
`agent-profiles doctor --json --profile <name>`, `agent-profiles run --profile
<name> -- <cli>`, and each CLI's own read-back (`claude mcp list`, `codex
doctor`, `agy mcp list`, `opencode debug config`).

The A/B markers were written with the CLIs' own commands: `claude mcp add` in
each profile, `agy mcp add` in each profile, and a distinct marker model in each
profile's own `config.toml` for `codex doctor` to report. Read-back then listed
only that profile's marker.

The startup class is not reproducible from this repository alone. It used the
private `sandbox-exec` wrapper described above, plus the repository PTY driver
with a recorded timeout. A Linux result is not evidence for macOS behavior, and
the reverse also holds. The 2026-10-31 page remains the earlier host's historical
snapshot and is not updated by this one.
