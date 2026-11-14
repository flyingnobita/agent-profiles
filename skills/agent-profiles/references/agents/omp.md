# oh-my-pi Integration

Guidance for running oh-my-pi (`omp`) inside an Agent profile. Details were
verified against the installed CLI; re-check them after upgrades because the
state roots and helper daemons change between versions.

## Directory Redirection

oh-my-pi keeps its agent directory in `~/.omp/agent` and writes sibling
directories (`logs`, `natives`, `run`) under `~/.omp`. Both platforms keep the
whole `~/.omp` tree inside the profile:

- Linux: the Agent integration adds a bubblewrap bind mount for `$HOME/.omp`,
  so `<repo>/.agent-profiles/<profile>/.omp` replaces it for the profile
  process. The profile also owns `<profile>/.agents`, the agent home skill root.
- macOS arm64: nothing is mounted. The profile `HOME` is the profile directory,
  so `$HOME/.omp` and `$HOME/.agents` resolve to profile storage by environment
  alone.

The agent directory holds `agent.db` (state and stored logins), `models.db`,
`skill-descriptions.db`, `sessions/`, `skills/` and `AGENTS.md`.
`doctor --json --agent omp --profile <name>` reports the directory and the
artifacts that are present.

oh-my-pi reads `PI_CODING_AGENT_DIR` as an override for its agent directory,
the same variable Pi reads for `~/.pi/agent`. A profile clears it before the
agent starts instead of exporting it, because one shared value cannot point at
two different roots. The HOME-relative default and the platform redirect decide
the location.

oh-my-pi also offers native named profiles (`OMP_PROFILE` or `--profile`). The
integration does not use them: a native profile isolates auth, sessions and
settings, but `logs`, `natives` and `run` stay under the shared `~/.omp`, and a
native profile name would duplicate the Agent profile name without adding
storage isolation. The mount or `HOME` redirect covers the whole tree instead.

## macOS arm64 (Darwin)

macOS arm64 is qualified for profile mechanics, configuration redirection and
diagnostics only. The Darwin contract is covered with a synthetic executable in
`tests/11-omp/darwin-env.bats`:

- the profile `HOME` puts `$HOME/.omp/agent`, `logs`, `natives` and the
  `$HOME/.agents` skill root inside the profile;
- an inherited `PI_CODING_AGENT_DIR` is cleared;
- no bubblewrap and no mount table are needed.

Observed limits:

- A build that resolves the account home through `getpwuid` instead of `HOME`
  would see host paths. That was not observed with `omp` 18.20.0 on Linux; the
  macOS run of a real `omp` profile was not recorded for this release.
- Network access is not blocked on Darwin.
- The macOS Keychain is shared with the host; whether oh-my-pi uses it for any
  credential class was not inspected.

## Skill and Customization Discovery

oh-my-pi reads the shared Agent Skills roots:

- `~/.agents/skills` and project `.agents/skills` (home and project walk-up),
  which map to the profile on Linux (mount) and macOS (profile `HOME`);
- skills in its agent directory (`<profile>/.omp/agent/skills`) and generated
  managed skills under the same directory;
- project configuration and plugin roots in the checkout.

Project `.agents/skills` discovery walks up from the working directory. An
ancestor directory outside the repository, including a real home reached
through a walk-up, is unverified; the same class of gap is tracked for OpenCode
in #54. Host `~/.omp` and `~/.agents` markers were not read in the profile
probes.

The `skills` CLI does not list oh-my-pi as a separate agent, but it installs to
`~/.agents/skills` for Pi, Codex CLI and Antigravity CLI, and oh-my-pi reads
that root. One install serves every profile on the machine; use `--agent pi`
(or `--agent universal`) when oh-my-pi is the intended consumer.

## Authentication Diagnostics

Credential sources are reported separately, never as one "authenticated" flag:

- Profile-stored credentials: the profile `agent.db` stores logins beside other
  agent state. Doctor reports the database path when it is present and never
  opens it or reads values.
- Inherited environment credentials: `ANTHROPIC_API_KEY`,
  `ANTHROPIC_OAUTH_TOKEN`, `OPENAI_API_KEY`, `GEMINI_API_KEY`,
  `OPENROUTER_API_KEY`, `COPILOT_GITHUB_TOKEN`, `ZAI_API_KEY` and
  `OPENCODE_API_KEY` are reported by variable name only.
- External credential brokers: `OMP_AUTH_BROKER_URL` and `OMP_AUTH_BROKER_TOKEN`
  can point at a service outside the profile. That is a shared source and was
  not inspected.
- Model access: a successful model response is separate evidence and is not
  claimed by the integration tests.

A fresh profile stays logged out even when the invoking shell exports a key.
The profile database, the inherited variable name and a model response are
different evidence; presence is not proof of account separation.

## Shared Host Resources

- **Tool installation.** The `omp` binary, its mise-managed runtime and the
  native `.node` module under `~/.omp/natives` are shared as installed files;
  the profile gets its own copy of the downloaded natives directory inside
  `.omp`, not a separate installation.
- **Helper daemons.** Background daemons write sockets and state under
  `<profile>/.omp/run`, so they are profile-local on both platforms. A daemon
  started from the host is not attributable to a profile.
- **Project checkout and network.** The working tree, network access and OS
  trust stores are shared.
- **Host environment.** The invoking shell's environment credentials are
  inherited; doctor reports environment variable names only.

## Sandbox and Permission Modes

oh-my-pi exposes approval modes (`--approval-mode always-ask|always-ask-cached|write|yolo`
and `--auto-approve`) and tool filters (`--tools`, `--no-tools`, `--no-pty`).
`--no-skills`, `--no-rules` and `--no-context-files` disable whole discovery
surfaces.

Agent profiles are not a security boundary. No enforced filesystem sandbox or
write denial was tested; Linux bubblewrap mounts redirect known paths, not
arbitrary host access. Approval modes control tool use, not host visibility.

## Versions and Onboarding

Tested version: oh-my-pi 18.20.0 (`omp/18.20.0`) on Linux x86_64, 2026-11-15, in
disposable profiles (`tests/live/omp.sh`). The macOS arm64 observation was the
installed 18.20.0 binary; a real macOS profile run was not recorded for this
release. These are dated observations, not a supported version range.

Onboarding is interactive (`omp` then `/login`). An unauthenticated
non-interactive run waits for a model turn and is not a readiness marker; it
still creates `agent.db`, `models.db`, a session file, logs and the profile
`run` directory, which is enough to verify redirection without credentials.

## Troubleshooting and Gaps

- A `PI_CODING_AGENT_DIR` inherited from the shell is cleared by the profile.
  If a run still points somewhere unexpected, check for a wrapper that sets it
  after `agent-profiles run` prepared the environment.
- `doctor --agent omp --profile <name>` reports `agent_db` only when the file
  exists. A reported `profile_credential_store` status means "the database is
  present", not "signed in".
- A profile that was used and then removed can leave a daemon socket under
  `.omp/run`; lifecycle commands scan the profile and refuse or clean up as for
  the other agents.
- Unverified: model-driven skill invocation, enforced sandbox denial,
  ancestor-directory skill discovery outside the repository, external
  auth-broker behavior, and any macOS Keychain use. Behavior that is
  credential-dependent remains a gap, not a pass.
