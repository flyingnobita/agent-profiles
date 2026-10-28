# OpenAI Codex CLI Integration

Guidance for using OpenAI Codex CLI (`codex`) inside an Agent profile.

## Directory Redirection

When launched via `agent-profiles run`, the Agent integration configures dedicated profile storage:

- Configuration: Redirected to `<repo>/.agent-profiles/<profile>/.codex` through the exported `CODEX_HOME` environment variable and an underlying bubblewrap bind mount over `$HOME/.codex`.
- Shared skills: Mounted from `<repo>/.agent-profiles/<profile>/.agents` over `$HOME/.agents`.
- Profile bins: Profile binaries (`npm-global/bin`, `bin`, `cargo-global/bin`, `python-user/bin`) take precedence in `PATH`.
- Host environment: Project repository files, inherited environment credentials, and mise tool paths are preserved. If no profile is named, the Default profile is used.

## Skill Discovery

Codex discovers skills across distinct scopes using its local discovery mechanism:

- User-scope skills: Located in `$HOME/.codex/skills` and `$HOME/.agents/skills`. Because `$HOME/.codex` and `$HOME/.agents` are redirected to the active Agent profile, each profile maintains its own user-scope skills without cross-profile marker leakage.
- Repository-scope skills: Discovered in `<repo>/.agents/skills` and `<repo>/.codex/skills` within the current project checkout.
- Exclusion: Skills defined exclusively in profile A remain invisible to profile B.
- Bundled system skills: The installed Codex build materializes its system skills under `$CODEX_HOME/skills/.system`. They are available in every profile, separately from user and repository markers.
- Admin/managed sources: Managed configuration and admin skill roots supplied by the host remain readable. Record any that appear in the skill-roots table instead of assuming they are absent.
- Verification: The discovery surface can be inspected offline without model calls using `codex debug prompt-input`. Treat skill bodies as model-loaded only when a skill is selected; the prompt input lists metadata and file paths.

## Instruction Discovery

Codex discovers instructions according to repository boundaries:

- Project instructions: `AGENTS.md` files located at the repository root and within subdirectories are discovered and incorporated into session context.
- Repository boundary: Codex traversal respects the Git repository boundary and does not ascend to the filesystem root or parent directories outside the repository.
- Verification: Run `codex debug prompt-input` to confirm that root and subdirectory `AGENTS.md` instructions appear while parent directories outside the repository root are excluded.

## Authentication Diagnostics

Authentication credentials and state are kept strictly isolated from host profiles:

- Fresh profile state: A freshly initialized profile contains no imported host credentials.
- Diagnosis: Running `codex login status` in a fresh profile reports `Not logged in` with exit code 1. This command reports file-based login only.
- Credential isolation: Host authentication tokens in host directories are never copied or symlinked into the profile.
- Inherited environment: If API credentials (such as `OPENAI_API_KEY`) are present in the host environment, they are inherited by the running shell unless explicitly unset. `codex doctor --json` reports this separately as `auth is provided by environment` and lists the variable name, never the value. Profile-based file authentication remains separate from host files.

## Sandbox Execution

Codex provides its own process sandbox for executing commands:

- Read-only sandbox: Executing `codex sandbox -- <command>` applies Codex's default read-only policy, where write attempts are denied.
- Enforced denial: Running `codex sandbox -- sh -c 'echo ok; touch /tmp/denied'` outputs `ok` and reports a read-only filesystem error on the write attempt.
- Background services: Codex may start helper processes or an app-server daemon under `$CODEX_HOME`. Test runners and automations must isolate and terminate these processes using owned process group IDs (PGID) to avoid leaving orphaned background services or disturbing unrelated sessions.

## Troubleshooting & Gaps

Common diagnostic procedures and known boundaries:

- Local health: Run `codex doctor --json` to inspect configuration loading, app-server socket paths, and authentication status. The app server is ephemeral by default and normally reports as not running.
- Profile diagnostics: `agent-profiles doctor --json --agent codex --profile NAME` reports the profile `CODEX_HOME`, initialization, artifact presence, inherited credential variable names, and a login state probed in a disposable snapshot. `login_reported` means the CLI reported a login; it is not authentication, and an auth file's presence alone is never treated as one.
- Verified version: The discovery, login-status, and sandbox behavior above was verified with `codex-cli 0.165.0`. Re-run `codex doctor --json` after upgrades because flags and skill sources can change.
- Credential gaps: Live model turns and authenticated skill execution require valid API credentials; when testing without credentials, model responses remain explicit unverified gaps.
- Process cleanup: Always terminate test app-servers and helper processes using `kill -TERM -$PGID` and `kill -KILL -$PGID` against recorded test markers.
