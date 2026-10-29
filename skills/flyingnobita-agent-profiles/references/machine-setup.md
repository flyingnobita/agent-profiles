# Machine Setup and Mise Tasks

Focused guidance for preparing a Linux machine, configuring the global
`mise ap` task, and diagnosing the resulting deployment. Read this reference only
for host setup, task integration, or setup troubleshooting requests.

## System Prerequisites

Agent profiles require:

- Linux with unprivileged user namespaces enabled
- `bubblewrap` (`bwrap`) for profile directory redirection
- `git` and `python3` (standard library only)
- `mise` for environment preservation and global task integration
- `bash` to run the bundled helper

The helper supports Arch-family (`pacman`) and Debian-family (`apt-get`)
distributions for automatic prerequisite installation. Other distributions are
reported as an unsupported automatic path rather than guessed at.

## Detection and Preview

`setup` is read-only unless `--apply` is given:

```bash
agent-profiles setup --preview
```

The preview reports:

- OS identity (`ID`, `ID_LIKE`, pretty name) from `/etc/os-release`
- the detected package manager and distribution family
- each dependency with its resolved path, or the detected install command
- agent CLIs resolved from `PATH`
- mise registry membership for each optional agent
- the effective global task directory and whether each task exists

A missing dependency that has no authorized automatic path is named as an
`unsupported automatic path`. This includes `mise` itself: it is never installed
with `curl`. Install `mise` manually through its documented package or installer
before configuring tasks.

Tests may point detection at a fixture with the documented `AP_OS_RELEASE`
environment variable. It is a test input, not a user-facing override.

## Global Mise Task Integration

`setup --apply` deploys the versioned helper release and installs one global
file task, `agent-profiles`, aliased `ap`. It runs the helper's `ap` command,
a profile-first grammar over the long commands:

- `mise ap NAME [COMMAND...]` runs `COMMAND` (default: your shell) in profile
  `NAME`; a missing profile is offered for creation in a terminal, and
  `--create` (`mise ap --create NAME ...`) creates it without asking
- `mise ap new NAME`, `mise ap ls`, `mise ap rm NAME [--yes]`,
  `mise ap reset NAME [--yes]`, `mise ap doctor`, `mise ap migrate`,
  `mise ap recover` and `mise ap --version` map to `init`, `list`, `remove`,
  `reset`, `doctor`, `migrate`, `recover` and `--version`
- `mise ap --profile NAME COMMAND...` keeps the previous task's `run` form

Earlier versions installed a second task, `agent-profiles-init`. Setup copies a
managed copy of it to the backups directory and removes it; a foreign file with
that name is left untouched, and `doctor` reports a managed leftover as stale.

Tasks live in `$MISE_CONFIG_DIR/tasks/` and are never added to `config.toml`.
Each file task carries `#MISE dir="{{cwd}}"`, `#MISE alias="ap"`,
`#MISE quiet=true` (mise does not echo the command), a `managed-by` marker naming the
skill version and manifest digest, and an explicit released-helper path. If that
helper is missing the task exits 78 and tells you to rerun
`agent-profiles setup`.

Command arguments are forwarded verbatim; mise needs neither `run` nor `--`:

```bash
mise ap new demo
mise ap demo sh -c 'printf "%s\n" "$AGENT_PROFILES_NAME"'
mise ap NAME claude --resume
```

`--tasks-only` configures the tasks without installing prerequisites or agents.
`--agent claude|codex|agy|opencode` installs only the named agent, and only when
it is missing and available through the mise registry. The other agents remain
optional and untouched. Task deployment never edits `config.toml`; a requested
agent install does add its tool entry to the global mise configuration, and the
previous configuration is copied to the backups directory first. A managed
configuration (symlink, chezmoi, read-only, or a symlinked config directory) is
never rewritten: with `--prepare-dir` setup writes
`mise/config.toml.fragment` and `INSTRUCTIONS.md` there for you to commit, and
without it the install is skipped with a message. The versioned helper release
is always deployed to XDG data on `--apply`, managed configuration or not, so
task shims copied from a prepared directory point at a real helper.

## Task Conflicts and Backups

Before writing a task, setup checks for conflicts:

- an existing task file without the managed marker is a foreign task
- an inline `[tasks.agent-profiles]` entry in
  the global configuration is an inline conflict
- `mise tasks ls --global` catches global tasks from other sources

Conflicting tasks are reported and left untouched; unrelated settings are never
rewritten. When a managed task file differs from the current release, the old
file is copied to
`${XDG_STATE_HOME:-$HOME/.local/state}/flyingnobita-agent-profiles/backups/<timestamp>/tasks/`
before it is replaced. Repeated setup is idempotent: identical task files are not
rewritten and no extra backup is created.

## Managed Configuration

If the tasks directory or a task file is a symlink, read-only, or reported by
`chezmoi source-path`, the target is treated as managed configuration and is
left untouched. Instead, setup prints instructions. Prepare source changes with:

```bash
agent-profiles setup --apply --prepare-dir /path/to/prepared
```

The prepared directory contains `tasks/agent-profiles` and `INSTRUCTIONS.md`
naming the real target. Copy the task into your managed source, delete a
prepared `agent-profiles-init` from an earlier release there, and commit, then rerun setup so the versioned
release matches the prepared task files.

## Versioned Deployment

The installed skill's `scripts/`, `VERSION`, and a sha256 manifest are copied to:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/flyingnobita-agent-profiles/releases/<version>-<sha8>/
```

Task files point at that release instead of the installed skill path, so a moved
or updated installation cannot silently run stale code. A valid release is
reused, a previous release is kept until the new one is verified, and the
manifest is checked after copying.

## Doctor Checks

`agent-profiles doctor` reports the `tasks` and `namespaces` checks:

- `tasks` distinguishes available, missing, foreign, managed-configuration,
  project-shadowed, `stale`, and `broken` deployments, and names the release
  directory when it is broken
- `namespaces` runs an actual `bwrap --dev-bind / / true` probe and reports
  whether profile namespaces work

A failed namespace probe names the usual causes: the kernel
`unprivileged_userns_clone` setting, AppArmor
`apparmor_restrict_unprivileged_userns`, and container `seccomp` restrictions.
`agent-profiles run` exits 69 in that case rather than falling back silently.
Doctor is read-only and does not install or deploy anything.

## Troubleshooting

- `setup` exits 64: check the option spelling; `--preview` and `--apply` are
  mutually exclusive.
- A task reports a missing helper or exit 78: the release moved or was removed.
  Rerun `agent-profiles setup --apply` from the installed skill.
- Doctor reports `stale`: the installed skill changed after setup. Rerun setup.
- Doctor reports `broken`: inspect the named release path and manifest, then
  rerun setup to redeploy.
- Doctor reports a foreign task: rename or remove the conflicting task, then
  rerun setup. Unrelated tasks are preserved.
- A managed configuration was detected: prepare the files with `--prepare-dir`
  and commit them through your configuration manager instead of editing the
  target directly.
- `mise` is missing: install it manually. Setup never uses `curl` to install
  `mise`, and it reports that path as unsupported.
