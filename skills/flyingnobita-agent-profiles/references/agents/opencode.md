# OpenCode Integration

Guidance for using OpenCode (`opencode`) inside an Agent profile. The behavior
below was verified against the installed CLI; re-check it after upgrades because
path resolution, skill sources and server modes change between versions.

## Directory and Path Redirection

When launched through `agent-profiles run`, the Agent integration configures
dedicated profile storage:

- Configuration: `OPENCODE_CONFIG_DIR` is exported as `<repo>/.agent-profiles/<profile>/.opencode`. In the tested version this variable **replaces** the configuration root instead of adding a source: the XDG configuration directory is not read while it is set.
- Data, state and cache: `XDG_DATA_HOME`, `XDG_STATE_HOME` and `XDG_CACHE_HOME` are profile directories, so OpenCode keeps its database, logs, repositories, sessions and installed helper binaries under `.local/share/opencode`, `.local/state/opencode` and `.cache/opencode`.
- Shared skill mounts: `$HOME/.claude` and `$HOME/.agents` are bind-mounted from the profile, because OpenCode resolves Claude-compatible and `.agents` skill roots from the account home directory rather than from `$HOME`.
- Profile bins: profile binaries (`npm-global/bin`, `bin`, `cargo-global/bin`, `python-user/bin`) take precedence in `PATH`. The host mise tool path and project files are preserved. If no profile is named, the Default profile is used.
- Shared temporary path: the CLI reports a host-wide temporary directory (`/tmp/opencode` in the tested version) that is not redirected by a profile. Treat it as a shared Host environment resource, not profile storage.

## Configuration Diagnostics

Two read-only commands classify what a profile actually loads. Always run them
through the profile wrapper and prefer `--standalone` (see Server Isolation):

```bash
agent-profiles run --profile <name> -- opencode --standalone debug paths
agent-profiles run --profile <name> -- opencode --standalone debug config
```

- `debug paths` prints the effective `home`, `data`, `cache`, `config`, `state`, `tmp`, `bin`, `log`, `repos` and `db` locations. Verify that `config` is the profile `.opencode` directory and that `data`, `state` and `cache` are under the profile before trusting any other observation.
- `debug config` lists the configuration sources that were loaded. A profile run normally lists the profile configuration directory and the repository `.opencode` directory, which is the project-scope source.

To classify additive versus replacing for a given version, use three
distinguishable synthetic sources: a synthetic host configuration root
(`XDG_CONFIG_HOME`), the profile configuration root, and `OPENCODE_CONFIG_DIR`,
each carrying a different marker. In the tested version only the
`OPENCODE_CONFIG_DIR` document appears, so the behavior is replacing, not
additive. Do not assume the other order without repeating the marker test.

Diagnostics must never print configuration file contents or secret values:
report marker names, source paths and presence only.

## Skill Discovery

The tested version discovers skills from these sources, and each behaves
differently:

- Profile configuration: `$OPENCODE_CONFIG_DIR/skill` and `$OPENCODE_CONFIG_DIR/skills`, i.e. `.agent-profiles/<profile>/.opencode/skill` and `.opencode/skills`.
- Claude-compatible and `.agents` roots: `$HOME/.claude/skills` and `$HOME/.agents/skills`, which resolve to profile storage through the bind mounts.
- Project scope: `<repo>/.opencode/skills` (and `skill`) in the current checkout.
- Bundled skills: shipped inside the binary and reported from `/builtin/`, available to every profile separately from profile, project and host markers.

Surfaces that show discovery without a model call:

- `opencode --standalone api GET /api/skill` against a private server lists ids and paths. The first request can return an empty list while the asynchronous scan is still running; read the second request before drawing conclusions.
- `opencode --standalone debug agents` lists agents (not skills) and is useful for confirming that the private server started with the profile configuration.
- The interactive composer lists skills in its `@` mention completion, alongside agents and file references. A marker skill that appears there is loaded by the terminal UI itself, not by a model.
- Skill bodies are only sent to a model when a skill is invoked. Activation can be requested against a private server without credentials and records the skill content in the session message list; that proves which profile supplied the skill, not that a model implemented it.

Distinct markers in two profiles must stay separate: a skill defined only in
profile A is absent from profile B's list, and activation of A's skill in B
fails because that id is unknown there. Record bundled and project sources
separately instead of counting them as profile isolation evidence.

## Authentication Diagnostics

Credential sources are reported separately, and presence is not proof of account separation:

- Profile-stored credentials: in the tested version credentials live in the profile database (`credential` table) after the one-time import of a legacy `.local/share/opencode/auth.json`. `agent-profiles doctor --json --agent opencode --profile <name>` reports the legacy file by path and the stored provider identifiers only, never key material.
- Inherited environment credentials: `opencode --standalone auth list` classifies provider credentials provided by the shell as `environment` and prints the environment variable name only. The doctor report lists the same variable names and drops their values.
- Shared host services: a background service on the shared default port is reported as a limitation because it runs outside any profile and may hold its own authentication state.

Host authentication must not be copied into a profile. A profile with no stored
credentials stays logged out even when the invoking shell exports a key, and the
diagnostic still reports the inherited variable name so the difference is
visible.

## Server Isolation

The client has two modes, and only one is safe for verification:

- `--standalone` runs a private server for the lifetime of the command. Use it for every probe and for QA.
- Without it, the CLI connects to (or tries to start) the background service. The default port is fixed at `49374`, so a host-wide service can answer the request with host configuration and invalidate an isolation test. On a host where that service is already running, a profile command fails with "port ... is already in use" instead of silently reusing it.

Read-only checks:

```bash
agent-profiles run --profile <name> -- opencode service status
agent-profiles run --profile <name> -- opencode --standalone api GET /api/info
```

`service status` and `service get` read the profile service configuration; they
do not start a service. `api GET /api/info` against a standalone server reports
the version, the private URL and the temporary path. Report a listener on the
shared default port, and any server a test starts, as limitations: stop only
test-owned servers, by recorded process group after confirming the QA profile
marker.

## Versions and Troubleshooting

Tested version: OpenCode `2.2.0` (Linux, disposable synthetic home, offline
`bwrap --unshare-net`), covering path redirection, configuration-source
classification, skill discovery, authentication classification, TUI startup to
the composer and a credential-free shell command. The offline shell command
works through a session on a private server (`session` shell request) and does
not require a model turn.

Known gaps and checks that are not verified remain listed here:

- A minimal model response and a model-driven skill invocation require authorized credentials: credential-dependent gap. Offline evidence establishes routing and discovery, not model behavior.
- The profile markers described here were verified for `2.2.0` only. Re-run `debug paths`, `debug config` and the three-source marker test after upgrading.
- The interactive startup marker is the composer prompt of the normal entry point; `--help` and `--version` are never startup evidence.
- Watch for new configuration sources: this version also watches the account-home `.claude` and `.agents` skill roots, which are only profile-local because the profile bind mounts cover them.
- Test hooks: `AP_OPENCODE_SERVICE_PORT` lets the test suite point the doctor's shared-port classification at a test-owned socket. It is not a user option.

Troubleshooting:

- `port 49374 ... already in use`: a host background service holds the shared port. Use `--standalone` rather than stopping a service you do not own.
- Empty `/api/skill` list: query again after the asynchronous scan, and confirm `debug config` shows the expected configuration sources.
- Skill not found in a profile: check that the skill sits in `.opencode/skills/<name>/SKILL.md` (or the `skill` directory) of that profile or the repository, not in the XDG configuration root, which is replaced while `OPENCODE_CONFIG_DIR` is set.
