# Repository Operations

Guidance for managing agent profiles within a Git repository checkout.

## Initializing Profiles

To initialize the default profile in the current checkout:

```bash
agent-profiles init
```

To initialize a custom named profile:

```bash
agent-profiles init --profile my-worker
# or
agent-profiles init --profile=my-worker
```

### Profile Storage and Naming

- **Storage Layout**: Storage is created at `<git-toplevel>/.agent-profiles/<name>/` with private permissions (`0700`, `umask 077`). Initialized profiles contain subdirectories for `.claude`, `.codex`, `.gemini`, `.agents`, `.opencode`, `home`, `bin`, `npm-global`, `uv-tools`, `cargo-global`, `python-user`, `.config`, `.local/share`, `.local/state`, `.cache`, and an `.agent-profile` format marker.
- **Naming Rule**: Names accept 1 to 32 characters matching `^[a-z][a-z0-9_-]{0,31}$` (lowercase letters, digits, underscores, or hyphens, starting with a letter). Invalid names exit 65 (`EX_DATAERR`). Omitting `--profile` defaults to `default`.
- **Subdirectory and Worktree Resolution**: Running from any repository subdirectory creates storage at the Git toplevel. Separate Git worktrees maintain distinct, independent profile storage.
- **Git Metadata Exclude**: An anchored `/.agent-profiles/` entry is added to `git rev-parse --git-path info/exclude` under lock, ensuring profile storage is untracked locally without modifying project files or `.gitignore`.
- **Idempotency**: Running `init` on an existing profile is safe and idempotent, preserving existing contents.

## Listing Profiles

To list all initialized profiles configured in the current checkout:

```bash
agent-profiles list
```

Add `--json` for structured JSON output:

```bash
agent-profiles list --json
```

Output includes initialized profiles (directories containing `home/`) and excludes reserved dot directories (`.locks`, `.journal`, `.trash`).

## Executing Commands Inside a Profile

Run any command within a named profile:

```bash
agent-profiles run --profile my-worker -- command arg1 arg2
```

If `--profile` is omitted, the `default` profile is used. Leading options are consumed only before the child command; all arguments following the command are forwarded unchanged.

### Environment and Package Managers

When executing commands, the helper resets managed environment variables (`AGENT_PROFILES_*`, legacy `AGENT_SANDBOX_*`, `XDG_*`, package manager roots, agent-specific directories) and exports:

- `AGENT_PROFILES_NAME`, `AGENT_PROFILES_DIR`, `AGENT_PROFILES_ROOT`, `AGENT_PROFILES_BASE_PATH`
- Legacy output-only aliases `AGENT_SANDBOX_PROFILE` and `AGENT_SANDBOX_DIR`
- Isolated XDG roots (`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`) pointing inside `<profile>`
- Isolated package managers: `NPM_CONFIG_PREFIX`, `NPM_CONFIG_CACHE`, `UV_TOOL_DIR`, `UV_TOOL_BIN_DIR`, `UV_CACHE_DIR`, `CARGO_INSTALL_ROOT`, `GOBIN`, `PYTHONUSERBASE`
- `PATH`: Profile binaries (`npm-global/bin`, `bin`, `cargo-global/bin`, `python-user/bin`) are prepended first, followed by cleaned host PATH (stale `*/.agent-profiles/*/` entries are purged).

Project package managers and lockfiles remain unchanged.

### Bubblewrap Redirection and Host Boundaries

- **Directory Redirection**: Bubblewrap (`bwrap`) bind-mounts `<profile>/{.claude,.codex,.gemini,.agents}` over corresponding host directories in `$HOME`. Writes inside the profile land in profile storage and do not touch host configuration.
- **Host Symlinks**: If a host mount target is a valid directory symlink, bubblewrap binds over its physical destination (`readlink -f`). Dangling symlinks, non-directories, root (`/`), or targets overlapping profile storage are rejected with exit 73 (`EX_LAYOUT`).
- **Empty Host Mountpoints**: If a mount target does not exist on the host, an empty directory is created on the host to serve as a bind mountpoint, accompanied by an explicit notice on stderr.
- **Shared Host Access**: Agent profiles provide workflow separation, not a security sandbox for untrusted code. Host network, devices, project files, and system processes remain accessible.
- **Capability Failure**: Missing `bwrap` or failure of unprivileged user namespaces exits 69 (`EX_UNAVAILABLE`) with an actionable hint.

### Host Mise Preservation

Before environment variables are reset, `mise doctor --json` captures the host's effective config, data, state, and cache directories. These are preserved and exported as `MISE_CONFIG_DIR`, `MISE_DATA_DIR`, `MISE_STATE_DIR`, and `MISE_CACHE_DIR`. Custom user overrides and inherited `MISE_*` variables pass through, allowing host-managed runtimes and tools to resolve inside the profile.

### Nested Invocations and Concurrency

- **Nested Execution**: Nested detection inspects `/proc/self/mountinfo` for active profile binds. Nested execution within the same profile does not re-wrap with `bwrap`, rebuilds a deduplicated environment from `AGENT_PROFILES_BASE_PATH`, and succeeds. Attempting to switch to a different profile while nested inside another profile is refused with exit 75 (`EX_BUSY`). Inherited variables without live mountinfo evidence are treated as spurious and reset.
- **Concurrent Profiles**: Multiple profiles in the same repository can run concurrently without interference. Profile directories must be distinct real directories; aliasing or sharing inodes across profiles is rejected with exit 73.
- **Lease API**: Every run holds a persistent shared lease (`.agent-profiles/.locks/<name>.lock`) inherited by child processes across command execution. Lock ordering requires acquiring storage locks before profile leases. Runs record `<boot_id> <start_ticks>` in `.agent-profiles/.locks/<name>.runs`.
- **Preflight Hooks**: Extensible preflight scripts in `lib/preflight.d/*.sh` execute before commands and can reject invalid or corrupted states.
