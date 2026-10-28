# Lifecycle Operations

Reset, remove, migrate, and recover change profile storage for one checkout. Run them from a host shell, never from inside a profile: the helper refuses with exit 75 and tells you to leave the profile first.

Every mutating operation takes the storage lock, then exclusive locks for each affected profile in name order, and scans for live processes before it changes anything. Locks are non-blocking: a profile that is in use makes the command exit 75 instead of waiting.

## Preview and Confirmation

`reset` and `remove` are previews until you pass `--yes`:

```bash
agent-profiles reset --profile my-worker
agent-profiles remove --profile my-worker
agent-profiles reset --profile my-worker --yes
agent-profiles remove --profile my-worker --yes
```

The preview prints the exact absolute profile path and counts and sizes for these categories:

- Settings
- Transcripts
- Credentials
- Installed tools

The preview never prints file contents, never changes the profile, and exits 0. Omitting `--profile`, an invalid name, an uninitialized profile, and a symlinked profile root exit 64, 65, 66, and 73 respectively.

## Resetting a Profile

Reset returns one profile to its empty initial structure while other profiles keep their bytes. The old profile directory is renamed into `.agent-profiles/.trash/` first, so a crash cannot leave a half-deleted profile. Reset then re-creates the empty profile directories and deletes the trash copy.

## Removing a Profile

Remove deletes one profile directory and its trash copy. Other profiles, tracked project files, `mise.local.toml`, and unrelated Git excludes stay unchanged.

## Process Refusals

Before mutating, the helper scans processes owned by your user for evidence that the profile is in use: `AGENT_PROFILES_DIR` or the legacy `AGENT_SANDBOX_DIR` pointing at the profile, an open link, working directory, executable, or mount source under the profile path. A hit exits 75 and prints only PID and `comm`; command lines and environment values stay hidden.

Processes whose `/proc` entries cannot be read are *relevant-unknown* when an orphaned process started during a recorded run, or when an uninspectable ancestor chain reaches `bwrap` or the helper. Vouch for a specific one only when you know it is unrelated:

```bash
agent-profiles reset --profile my-worker --assume-unrelated 12345,12346 --yes
agent-profiles remove --profile my-worker --assume-unrelated 12345 --yes
```

The assertion is recorded in the operation journal. Inspectable processes that actually reference the profile cannot be vouched for. The helper never kills a process. Services started by the host outside the profile namespace (`systemd --user`, D-Bus activation) carry no marker and cannot be attributed; check them yourself with `systemctl --user` or `lsof` before forcing an operation.

## Migrating Legacy Storage

`agent-profiles migrate` converts earlier storage layouts into the current named profile format. It detects:

- `.agent-sandbox` with unnamed agent directories directly inside it.
- `.agent-sandbox/<name>` named profiles.
- Unnamed agent directories directly under `.agent-profiles`.
- Mixed layouts where current named profiles coexist with legacy data.

Run the preview first, then confirm:

```bash
agent-profiles migrate
agent-profiles migrate --yes
```

The preview prints the detected layout, the backup destination, and the profiles that would be created. It changes nothing.

Migration refuses instead of merging when:

- Both unnamed layouts would become the default profile, or `.agent-profiles/default` already exists.
- A named legacy profile collides with an existing profile.
- `.agent-sandbox` mixes unnamed agent directories and named profiles.
- A legacy root or named entry is a symlink, or the contents are unrecognized.
- Legacy data contains sockets, device nodes, or FIFOs.

Already-working named profiles are preserved byte-for-byte. Each migrated profile is initialized empty after its legacy data reaches the backup; nothing is copied back into the new profile.

### Private Backups

The default backup root is `${XDG_STATE_HOME:-$HOME/.local/state}/flyingnobita-agent-profiles/backups/`. Override it with an absolute path:

```bash
agent-profiles migrate --yes --backup-root /path/outside/the/checkout
```

The backup root and the per-run directory `<repo>-<sha8>-<UTC>` must be outside the checkout, owned by you, and not group or world writable. A per-run directory is created once with mode 0700 and is never reused. Before the verified checkpoint the helper writes `content-manifest.json` (mode 0600), a durable per-source list of every path, type, mode, size, symlink target, and SHA-256 digest. The finished backup also contains a `manifest.json` and a copy of the operation journal. Contents are never printed.

On the same filesystem the legacy tree is renamed into the backup, which is atomic. Across filesystems the tree is copied with `cp -a --no-dereference`, compared file-by-file and symlink-by-symlink against the source, flushed to disk, and only then are the originals removed. A mismatch aborts the migration with exit 77 and leaves the originals intact.

Because shims, tool installs, caches, and symlinks embed absolute paths, reinstalling tools inside the migrated profiles is expected: rerun the installers (`npm install -g`, `uv tool install`, `cargo install`, and so on) and relink anything that pointed into the legacy directories.

## Interrupted Operation Recovery

Each mutating operation writes a journal under `.agent-profiles/.journal/`. The journal records the operation, profile or checkout target, state, absolute paths, boot ID, and any vouched-for PIDs. A journal is stale when no process holds its lock.

While a stale journal exists:

- `init` and `run` on that profile exit 77 and name the interrupted operation.
- A stale migrate journal blocks every mutating command in the checkout.
- `doctor` and `list` report it without failing.
- `migrate`, `reset`, and `remove` refuse until it is resolved.

List and run recovery from a host shell:

```bash
agent-profiles recover
agent-profiles recover --yes
```

Recovery takes the same locks, re-validates every recorded path (profile path, trash path, backup directory, staging and legacy directories, and every legacy source), and refuses traversal, symlinked components, and paths outside their expected base. Then it completes the recorded state machine:

- Reset: `planned -> trashed -> rebuilt -> trash-deleted`. Remove: `planned -> trashed -> trash-deleted`. A `planned` operation with the profile still intact is aborted and cleared; later states roll forward.
- Migrate: `planned -> staged -> verified -> originals-removed -> rebuilt`. Below `verified`, staging is deleted and originals stay intact. From `verified`, recovery completes moves, removes copied originals, writes the manifest, and initializes the target profiles.

Recovery never treats the journal state as proof of integrity. Before it moves anything or deletes a remaining original, it revalidates every staged copy, every existing legacy destination, and every original that will be removed against the durable content manifest. A corrupt or mismatched copy, a missing or partial backup, an original changed since verification, or both source and destination present exits 77 and preserves the original data plus the journal for manual recovery.

## Locks and Concurrency

Persistent lock files live under `.agent-profiles/.locks/` and stay in place across operations so a lock inode is never unlinked underneath a holder. `run` holds a shared profile lease for the command lifetime, including descendants that keep inherited file descriptors; reset, remove, migrate, and recover need exclusive locks, so they exit 75 while any run is active. Unaffected profiles stay usable.

## Internal Test Hooks

These environment variables exist only for the automated lifecycle tests. They are not supported user options and may change without notice:

- `AP_FAULT_AFTER=<state>` exits 137 after recording a journal state, simulating a crash.
- `AP_PROC_ROOT=<dir>` substitutes a fixture for `/proc` in the process scan.
- `AP_FORCE_COPY=1` forces the cross-device copy and verification path.
- `AP_CORRUPT_STAGED=1` corrupts staged data to prove mismatch handling.

## Related Guidance

- Exit codes and diagnostic messages: [troubleshooting.md](troubleshooting.md)
- Creating and running profiles: [repository-operations.md](repository-operations.md)
