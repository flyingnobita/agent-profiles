# Google Antigravity CLI Integration

Guidance for using Google Antigravity CLI (`agy`) inside an Agent profile. This
integration targets the `agy` command, not the Gemini CLI. The `.gemini`
directory name is shared history, not a claim of Gemini CLI support: the two
tools are configured and verified separately.

An Agent profile separates configuration and installed tools. It is not a
security boundary. The Host environment remains shared, including inherited
environment credentials and OS services.

## Directory Redirection

`agent-profiles run` starts `agy` with the normal profile environment and
bubblewrap bind mounts:

- Configuration and state: `$HOME/.gemini` is bound to
  `<repo>/.agent-profiles/<profile>/.gemini`, which holds both the global
  customization root (`config/`) and the CLI state directory
  (`antigravity-cli/`).
- Shared agent directory: `$HOME/.agents` is bound to
  `<repo>/.agent-profiles/<profile>/.agents`. This is required for the other
  agents in the same profile; `agy` does not read it (see below).
- XDG roots: `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME` and
  `XDG_CACHE_HOME` point into the profile. `agy` keeps plugin secrets in
  `$XDG_CONFIG_HOME/antigravity/plugin-secrets.json`, so that path stays inside
  the profile.
- Tool paths: profile binaries take precedence in `PATH`; mise's own
  configuration, data, state and cache directories are preserved.
- No configuration-directory environment variable is required or set: in the
  tested version the CLI resolves everything from `HOME` plus the XDG roots.
  Redirection therefore comes from the mount and the XDG variables, and setting
  an environment variable alone would not isolate anything.

## Skill and Customization Discovery

Skill locations are verified by observing which `SKILL.md` files the real CLI
opens during startup (offline, no model call, in a disposable profile with a
marker skill in every candidate directory):

| Location | Read by `agy` |
| --- | --- |
| `~/.gemini/config/skills/<name>/SKILL.md` | yes - global customization root |
| `~/.gemini/skills/<name>/SKILL.md` | yes - legacy user skill root, still scanned |
| `~/.gemini/antigravity-cli/skills/<name>/SKILL.md` | yes - per-app skill root |
| `~/.gemini/antigravity/skills/<name>/SKILL.md` | no - not scanned |
| `~/.agents/skills/<name>/SKILL.md` in the profile home | no - not scanned |
| built-in skills under `.gemini/antigravity-cli/builtin/skills/` | yes - materialized per profile |

Consequences:

- Because the whole `.gemini` tree is profile storage, every global skill root
  above is per profile. A skill written to profile A's
  `.gemini/config/skills` is read when `agy` runs in profile A and is not
  visible in profile B.
- `.agents` at the home level is not an Antigravity skill root. Do not promise
  `.agents` skills to `agy`; only the shared mount exists so the directory is
  consistent for other agents.
- The documented workspace root `.agents/` (and `.agents/skills/`) at the
  project root is a project customization source. Its runtime read is
  not verified offline: it is exercised when a conversation starts, which
  requires an authenticated model turn. This is recorded as a gap, not assumed.
- Plugins are read from `~/.gemini/config/plugins/<name>/` and are the
  non-credential discovery surface that names skills directly:
  `agy plugin list --json` reports each plugin path and its skill names, so two
  profiles can be compared without a model call.
- Skill activation is progressive: only names and descriptions are injected.
  Treat startup file reads and plugin listings as discovery evidence, not as
  proof that a model loaded a skill body.

## Authentication Diagnostics

Antigravity CLI authentication can come from three separate sources. They must
be reported separately, and presence in any of them is not proof of account separation:

1. **Profile credential files.** Candidate paths, reported by name only:
   `.gemini/antigravity-cli/oauth_creds.json`,
   `.gemini/antigravity-cli/credentials.json`, and
   `$XDG_CONFIG_HOME/antigravity/plugin-secrets.json` (file-based plugin secret
   storage). In the tested version a fresh profile creates no profile credential file.
2. **Environment variable names.** `GEMINI_API_KEY`, `GOOGLE_API_KEY`,
   `GOOGLE_APPLICATION_CREDENTIALS` and `GOOGLE_CLOUD_PROJECT` are inherited by
   the running shell. Each environment variable name is reported as set or
   unset; a value is never printed or copied.
3. **OS credential service.** The tested version authenticates through the
   host session D-Bus and its secret service
   (`org.freedesktop.secrets`). That service is outside profile storage, so a
   profile is not a separate account and a hosted token can authenticate an
   `agy` process that runs inside a profile. Offline QA hides the session bus
   so no host credential can be used; a session-bus-masked run reaches the
   sign-in screen instead of the composer.

`agent-profiles doctor --json --agent agy --profile NAME` reports the profile
directory, artifact presence, candidate credential files, environment variable
names, and the OS credential service status in `auth`, with
`auth.authenticated` always `null`. There is no login-status subcommand in the
tested version, so doctor never reports a signed-in state. A successful model
response would not be proof of account separation either.

## Shared Host Resources

These remain shared and must be reported, not hidden:

- Session D-Bus and its secret service, described above.
- The remote-control daemon: `agy remote-control` manages a user-scope
  background service (`antigravity-cli-daemon.service` when installed) that
  lives outside any profile. QA only queries its status from inside the profile
  and never starts it.
- `mise` tool paths, because the CLI binary itself is usually mise-managed.
- Network access and the project checkout.

Initialization that stays inside profile storage in the tested version:
`.gemini/config/{mcp_config.json,projects,.migrated}`,
`.gemini/antigravity-cli/{settings.json,cache,conversations,log,crashes,updater,bin,builtin}`
and `$XDG_CONFIG_HOME/antigravity/plugin-secrets.json`. The cli state also
contains per-profile logs and crash reports, so keep raw QA logs private.

## Sandbox and Permission Modes

- `agy --sandbox` runs the session with terminal restrictions enabled.
- `--mode` selects `accept-edits`, `auto` or `plan`; permission prompts can be
  auto-approved with `--dangerously-skip-permissions`, which should never be
  used merely to demonstrate a sandbox.
- Command execution, including a harmless terminal command, happens inside a
  model turn. An enforced denial therefore requires an authenticated model
  turn: this is a credential-dependent gap in offline QA, not a claimed result.
  The flag set above is verified from `agy --help` for the tested version, and
  the profile's own bubblewrap mount is verified separately by marker writes.

## Versions and Onboarding

Tested version: Antigravity CLI `1.4.9` (mise-managed; `agy --version` prints
the version, and `--version` is informational, not readiness evidence).

Onboarding is a sequence of screens; a first-run home that has no profile state
reaches them offline:

1. `Welcome to Antigravity CLI!` with a color-scheme list (`[Next]`).
2. `Terms of Service & Data Use` with a data-collection consent toggle and
   `[Done]`.
3. `Do you trust the contents of this project?` for the workspace.
4. With no usable credential source, the sign-in screen:
   `You are currently not signed in.` with a login-method choice.

A freshly initialized profile in the offline QA run reached the sign-in screen
directly, because the CLI treats that profile state as already onboarded. The
QA script waits for either screen, drives the onboarding screens when they
appear, and records the sign-in screen as the ready marker. A profile is ready
when startup reaches one of them. Before an authenticated composer exists,
slash-command and skill completion cannot be exercised; do not press through
the sign-in screen in automated QA, because it starts an OAuth flow. The
composer header shows the account that the OS credential service supplied, so
raw screens are kept private and only the absence of account identifiers is
recorded.

## Troubleshooting and Gaps

- **Skills not visible:** confirm the marker lives in
  `.gemini/config/skills`, `.gemini/skills` or
  `.gemini/antigravity-cli/skills` inside the selected profile. A marker in
  `.gemini/antigravity/skills` or profile `.agents/skills` is never read.
- **Stale skills:** the CLI watches customization directories; restart the
  session after writing a skill.
- **Signed in unexpectedly:** a profile does not isolate the OS credential
  service. Check `agent-profiles doctor --json --agent agy --profile NAME`
  output for `os_credential_service` before assuming a fresh account.
- **Sign-in screen in offline QA:** expected when the session bus is hidden; it
  proves no host credential was used.
- **Credential-dependent gap:** live model responses, explicit profile-skill
  invocation and sandboxed command denials require authorized credentials and
  are recorded as unverified unless separately authorized.
- **Process cleanup:** launch QA sessions in their own process group, record the
  PGID with the harness, and terminate only that group after confirming the
  QA profile marker in the process environment.
