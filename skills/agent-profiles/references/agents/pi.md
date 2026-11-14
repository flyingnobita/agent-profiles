# Pi Integration

Guidance for running Pi (`pi`) inside an Agent profile. Details were verified
against the installed CLI and its shipped documentation; re-check them after
upgrades because configuration roots and skill sources change between versions.

## Directory Redirection

Pi keeps its user state in an agent directory that defaults to `~/.pi/agent`.
Both platforms keep that directory inside the profile:

- Linux: the Agent integration adds a bubblewrap bind mount for `$HOME/.pi`,
  so `<repo>/.agent-profiles/<profile>/.pi` replaces it for the profile process.
  The profile also owns `<profile>/.agents`, the agent home skill root.
- macOS arm64: nothing is mounted. The profile `HOME` is the profile directory,
  so `$HOME/.pi` and `$HOME/.agents` resolve to profile storage by environment
  alone.

The agent directory holds `settings.json`, `keybindings.json`, `mcp.json`,
`models.json`, `auth.json`, `AGENTS.md`, `SYSTEM.md`, `extensions/`, `skills/`,
`prompts/`, `themes/` and `sessions/`. `doctor --json --agent pi --profile
<name>` reports the directory and the artifacts that are present.

Pi reads `PI_CODING_AGENT_DIR` as an override for the agent directory and
`PI_CODING_AGENT_SESSION_DIR` for session storage. A profile clears both before
the agent starts instead of exporting them, because oh-my-pi reads the same
`PI_CODING_AGENT_DIR` variable for its own `~/.omp/agent` directory; one shared
value cannot point at two different roots. Nothing is exported, so the
HOME-relative defaults and the platform redirect decide the location.

Project configuration is separate: an untrusted checkout's `.pi/settings.json`,
`.pi/mcp.json`, extensions, skills and prompt templates load only after project
trust is granted (`--approve` or an interactive decision). A project `.pi`
directory is shared with the repository by design.

## macOS arm64 (Darwin)

macOS arm64 is qualified for profile mechanics, configuration redirection and
diagnostics only. Observed on a macOS arm64 desktop host on 2026-11-14 with Pi
1.5.2 (`tests/10-pi/darwin-env.bats`, synthetic executable):

- a profile run wrote `.pi/agent/settings.json`, `auth.json`, `trust.json`,
  `models-store.json` and `sessions/` under the profile, not the host `~/.pi`;
- the profile `HOME` covers the `$HOME/.agents` skill root;
- the platform adapter needs no bubblewrap and no mount table.

Observed limits:

- A build that resolves the account home through `getpwuid` instead of `HOME`
  would see host paths. That was not observed in 1.5.2.
- Network access is not blocked on Darwin.
- The macOS Keychain is shared with the host. Whether Pi uses it for any
  credential class was not inspected; `auth.json` is the profile file the
  integration reports.

## Skill and Customization Discovery

Pi follows the Agent Skills specification. Its documented sources are:

- the agent directory (`<profile>/.pi/agent/skills`), the user skill location;
- project `.pi/skills` in the checkout, after project trust;
- `~/.agents/skills` and project `.agents/skills`, which both map to the
  profile on Linux (mount) and macOS (profile `HOME`);
- extensions, prompt templates and themes configured in settings.

Project `.agents/skills` discovery walks up from the working directory and
stops at the repository root when one exists. An ancestor directory outside the
repository, including a real home reached through a walk-up, is unverified; the
same class of gap is tracked for OpenCode in #54. The host `~/.pi` and
`~/.agents` markers were not read in the profile probes.

The `skills` CLI installs a Pi skill to `~/.agents/skills` with `--agent pi`.
That root is also read by oh-my-pi, Codex CLI and Antigravity CLI, so one
install serves all of them in the profile.

## Authentication Diagnostics

Credential sources are reported separately, never as one "authenticated" flag:

- Profile-stored credentials: `auth.json` in the profile agent directory, or
  provider keys saved through `/login`. Doctor reports the file path when it is
  present and never reads its contents.
- Inherited environment credentials: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  `GEMINI_API_KEY`, `OPENROUTER_API_KEY`, `ZAI_API_KEY` and `OPENCODE_API_KEY`
  are reported by environment variable name only.
- Model access: a successful model response is separate evidence and is not
  claimed by the integration tests.

A fresh profile stays logged out even when the invoking shell exports a key.
The profile file, the inherited variable name and a model response are
different evidence; presence is not proof of account separation.

## Shared Host Resources

- **Tool installation.** The `pi` binary and its mise-managed runtime are
  shared; a profile changes state, not the installed tool.
- **Project checkout and network.** The working tree, its project `.pi`
  configuration, network access and OS trust stores are shared.
- **OS credential services.** Any credential service the CLI reaches outside
  profile storage is shared with the host. Not inspected for this integration.
- **Host environment.** The invoking shell's environment credentials are
  inherited; doctor reports names only.

## Sandbox and Permission Modes

Pi asks for project trust before it loads project extensions, skills or
templates. `--approve` trusts project-local files for one run, `--no-approve`
ignores them, and `--no-skills`, `--no-extensions`, `--no-context-files` and
`--no-tools` disable whole surfaces.

Agent profiles are not a security boundary. Pi does not claim an enforced
filesystem sandbox in the tested version, and no enforced write denial was
tested; Linux bubblewrap mounts redirect known paths, not arbitrary host access.

## Versions and Onboarding

Tested version: Pi 1.5.2. The Linux observation was made on 2026-11-15 in
disposable profiles on x86_64 (`tests/live/pi.sh`); the macOS arm64 observation
was made on 2026-11-14. These are dated observations, not a supported version
range.

Onboarding is interactive (`pi` then `/login`, or `pi auth login`). An
unauthenticated non-interactive run exits with "No API key found for the
selected model" and still creates `auth.json`, `models-store.json` and a
session directory under the profile, which is enough to verify redirection
without credentials.

## Troubleshooting and Gaps

- A `PI_CODING_AGENT_DIR` inherited from the shell is cleared by the profile.
  If a run still points somewhere unexpected, check for a wrapper that sets it
  after `agent-profiles run` prepared the environment.
- `doctor --agent pi --profile <name>` reports `auth_json` only when
  `auth.json` exists. A reported `profile_credential_files` status means "a file
  is present", not "signed in".
- Empty profile `.pi/agent/skills` and `.agents/skills` are normal until a
  skill is installed.
- Unverified: model-driven skill invocation, enforced sandbox denial,
  ancestor-directory skill discovery outside the repository, and any macOS
  Keychain use. Model calls and other behavior that is credential-dependent
  remain a gap, not a pass.
