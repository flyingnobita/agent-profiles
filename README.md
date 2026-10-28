# flyingnobita-agent-profiles

Named Linux agent profiles for a single Git checkout. Give Claude Code, OpenAI
Codex CLI, Google Antigravity CLI and OpenCode their own settings, credentials
storage and user-installed tools, while the repository, its package managers and
its lockfiles stay shared.

Version 0.1.0, MIT licensed. Linux only; macOS is not qualified.

## What an Agent Profile Is

An agent profile is a named directory, `.agent-profiles/<name>/`, created inside
a Git checkout. It holds that profile's agent configuration, session state,
credentials storage and tool-install roots. Running an agent through the profile
redirects the directories the agent would otherwise read from your home
directory, so two workflows cannot overwrite each other's settings or tools.

- Profile selection is explicit: `--profile NAME`, or `default` when omitted.
- Redirection covers agent configuration, state, credentials storage and
  tool-install roots. It does not withhold inherited environment credentials or
  shared OS services.
- The repository working tree, project package managers and lockfiles are shared
  by every profile in that checkout.
- Host `mise` configuration, installed tools, state and cache directories are
  preserved, not replaced.
- Working directories, Git worktrees and subdirectories keep working; profiles
  live with the checkout they belong to.

Agent profiles are a workflow and dependency separation mechanism. They are
**not a security sandbox** for untrusted code. See
[Security and Shared Host Resources](#security-and-shared-host-resources).

## Requirements

- Linux x86_64 with unprivileged user namespaces enabled
- `bubblewrap` (`bwrap`) for profile directory redirection
- `bash`, `git` and `python3` (standard library only)
- `mise` for the global tasks, versioned deployment and directory preservation
- at least one supported agent CLI; each is optional and diagnosed separately

`agent-profiles setup --preview` reports which prerequisites the detected
distribution can install automatically (Arch-family `pacman`, Debian-family
`apt-get`) and names anything it will not guess at. `mise` itself is never
installed by the helper.

## Install

The skill is installed with the `skills` CLI (npm `skills` package, pinned to
1.7.4 for this release). Explicit selection of the skill is required.

From a local checkout of this repository (verified for v0.1.0):

```bash
# Confirm discovery first: the skill name must be listed.
npx skills add /path/to/flyingnobita-agent-profiles --list

# Install with explicit skill selection. Use -g for user scope, or drop -g for
# project scope. Install into the agents you use.
npx skills add /path/to/flyingnobita-agent-profiles \
  --skill flyingnobita-agent-profiles -g -y \
  --agent claude-code codex antigravity-cli opencode
```

From the repository (proposed, after publication). This release is prepared but
not published: there is no public remote yet, so the repository-source command
below cannot be used in v0.1.0.

```bash
# Proposed, after publication. Requires a published repository and network
# access; not available in this release.
npx skills add flyingnobita/flyingnobita-agent-profiles \
  --skill flyingnobita-agent-profiles -g -y
```

Nothing outside the installed skill directory is required: the helper resolves
its libraries and references relative to its own installation path, so it runs
after the source checkout is gone.

Verify the installation. The installed skill directory is the one reported by
`npx skills list`:

```bash
AP_HELPER="<installed-skill-dir>/scripts/agent-profiles"

bash "$AP_HELPER" --version
bash "$AP_HELPER" doctor
```

## Machine Setup

`setup` is read-only unless `--apply` is given:

```bash
bash "$AP_HELPER" setup --preview
bash "$AP_HELPER" setup --apply
```

`--apply` deploys the helper and its references to a versioned release directory
under `${XDG_DATA_HOME:-$HOME/.local/share}/flyingnobita-agent-profiles/releases/`
and installs exactly two global `mise` file tasks:

```bash
mise run agent-profiles-init -- --profile demo
mise run agent-profiles -- --profile demo claude
```

The tasks forward arguments verbatim and stay pinned to that versioned release.
After a skill update, `doctor` reports the deployment as `stale` and
`setup --apply` refreshes it; if the release directory is removed the tasks exit
78 and name the missing path. Missing
prerequisites and agent CLIs are installed only with `--apply`, only when they
are actually missing, and only through the detected package manager or the
`mise` registry; `--agent claude|codex|agy|opencode` limits which agent is
installed, and `--tasks-only` skips installation entirely. See
[references/machine-setup.md](skills/flyingnobita-agent-profiles/references/machine-setup.md) for conflicts, backups and managed configuration
(for example dotfiles-managed task directories).

## Quick Start

Inside any Git checkout:

```bash
# Create (or re-initialize) a profile. Profiles start empty.
bash "$AP_HELPER" init --profile dev

# Run an agent with that profile's configuration and tools. Inherited environment
# credentials and shared OS services are not withheld; see the security section.
bash "$AP_HELPER" run --profile dev -- claude
bash "$AP_HELPER" run --profile dev -- codex
bash "$AP_HELPER" run --profile dev -- agy
bash "$AP_HELPER" run --profile dev -- opencode

# Inspect profiles and the machine.
bash "$AP_HELPER" list
bash "$AP_HELPER" doctor --json
bash "$AP_HELPER" doctor --agent claude --profile dev
```

Everything after `--` is forwarded unchanged, and the caller's working directory
is preserved. Log in inside the profile normally; the helper never copies, links
or rewrites host credential files.

## Update

```bash
# Refresh an installed global skill (or re-run `npx skills add` from a checkout).
npx skills update flyingnobita-agent-profiles -g -y

# Redeploy the versioned release and refresh the global tasks.
bash "$AP_HELPER" setup --apply

# Confirm the deployment is current.
bash "$AP_HELPER" doctor
```

`doctor` reports the global tasks as `available`, `missing`, `foreign`,
`managed`, `project-shadowed`, `stale` or `broken`, and names the release
directory when it is broken. A previous release is kept until the new one is
verified.

## Remove

Remove profiles and check the machine state first, then uninstall the skill.
`doctor` and the other commands run from the installed helper, so resolve
everything they report before you remove it.

```bash
# 1. Preview, then confirm: removes one profile and its trash copy.
bash "$AP_HELPER" remove --profile dev
bash "$AP_HELPER" remove --profile dev --yes

# 2. Inspect what is left while the helper still exists.
bash "$AP_HELPER" list
bash "$AP_HELPER" doctor

# 3. Uninstall the skill from the agents it was installed into. The installed
#    helper is gone after this step, so no helper command can run below.
npx skills remove -g -y --skill flyingnobita-agent-profiles

# 4. Delete the two global mise task files by absolute path, but only when this
#    tool owns them. Setup resolves the config directory as $MISE_CONFIG_DIR, or
#    from `mise doctor --json` dirs.config, or ${XDG_CONFIG_HOME:-$HOME/.config}/mise.
MISE_CONFIG="${MISE_CONFIG_DIR:-$(mise doctor --json 2>/dev/null |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["dirs"]["config"])' 2>/dev/null)}"
MISE_CONFIG="${MISE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}"
for task in agent-profiles agent-profiles-init; do
  target="$MISE_CONFIG/tasks/$task"
  # Never delete a foreign or dotfiles-managed task: only files carrying this
  # tool's managed-by marker are ours.
  if [ -f "$target" ] && grep -q '^# managed-by: flyingnobita-agent-profiles ' "$target"; then
    rm -f "$target"
  elif [ -e "$target" ]; then
    echo "left $target untouched (not managed by flyingnobita-agent-profiles)"
  fi
done

# 5. Optional: delete the versioned deployment after the task files are gone.
rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/flyingnobita-agent-profiles"
```

Removing a profile never touches other profiles, tracked project files,
`mise.local.toml` or unrelated Git excludes. Migration backups live under
`${XDG_STATE_HOME:-$HOME/.local/state}/flyingnobita-agent-profiles/backups/` and
are kept until you delete them deliberately.

## Maintenance

```bash
bash "$AP_HELPER" doctor                # OS, dependencies, tasks, namespaces, agents
bash "$AP_HELPER" doctor --json         # machine-readable report
bash "$AP_HELPER" list --json           # profiles in this checkout

bash "$AP_HELPER" reset --profile dev   # preview: recreate one profile empty
bash "$AP_HELPER" remove --profile dev  # preview: delete one profile
bash "$AP_HELPER" migrate               # preview: convert legacy storage
bash "$AP_HELPER" recover --yes         # finish an interrupted operation
```

- Mutating operations take the storage lock and exclusive profile locks, and
  scan for live processes first. A profile that is in use exits 75; the helper
  never kills processes. Run lifecycle commands from a host shell, not from
  inside a profile.
- Reset and remove are previews until `--yes`; the preview names the absolute
  profile path and the affected settings, transcripts, credentials and installed
  tools, never their contents.
- `migrate` backs up legacy data to a private directory outside the checkout and
  verifies per-file content hashes before removing originals. Corrupt or changed
  backups are refused with exit 77 instead of being deleted.
- Interrupted operations leave a journal. `recover` finishes or rolls back the
  operation; until then, affected commands exit 77 and point at `recover`.
- `doctor` is read-only. Version probes run in a temporary synthetic environment
  and are informational; they are not readiness evidence.

Exit codes: 64 usage, 65 invalid name/data, 66 not a Git checkout or not
initialized, 69 dependency or namespace unavailable, 73 unsafe layout, 75 busy,
77 refused, 78 broken task or deployment. `run` otherwise returns the child's
status. See [lifecycle.md](skills/flyingnobita-agent-profiles/references/lifecycle.md) and
[troubleshooting.md](skills/flyingnobita-agent-profiles/references/troubleshooting.md).

## Compatibility

Verified 2026-10-28 on Linux x86_64 in disposable profiles with offline startup
and discovery checks. These four are the only supported agent integrations.

| Agent integration | Command | Verified version | Profile redirection |
| --- | --- | --- | --- |
| Claude Code | `claude` | 2.1.312 | `CLAUDE_CONFIG_DIR`, `.claude` mount |
| OpenAI Codex CLI | `codex` | 0.165.0 | `CODEX_HOME`, `.codex`/`.agents` mounts |
| Google Antigravity CLI | `agy` | 1.4.9 | `.gemini`/`.agents` mounts, XDG roots |
| OpenCode | `opencode` | 2.2.0 | `OPENCODE_CONFIG_DIR`, XDG roots |

Other agent tools are not integrated. A delivery or orchestration harness used
while building this release is not a fifth supported integration.

Version probes are informational: a successful `--version` does not show that
startup, discovery, authentication or sandboxing work. See
[the compatibility reference](skills/flyingnobita-agent-profiles/references/compatibility.md) for the per-class results and limits.

## Platforms

| Platform | Status | Notes |
| --- | --- | --- |
| Linux x86_64 | Qualified | Requires bubblewrap and unprivileged user namespaces |
| macOS | Not qualified | Deferred; unverified, no bubblewrap redirection layer |

## Security and Shared Host Resources

Agent profiles redirect directories and set per-profile environment variables.
That is all they do. They are **not a security sandbox**, a virtual machine or a
container boundary: a profile process keeps broad remaining host access.

- The profile keeps the kernel, the filesystem outside the redirected
  directories, network access and the project checkout.
- Inherited environment credentials (API keys exported in your shell) pass into
  profile sessions by design. A profile is not a separate account.
- OS services stay shared. Antigravity CLI authenticates through the session
  D-Bus secret service; that service sits outside profile storage and can
  authenticate a process running inside a profile.
- OpenCode's background service uses a host-wide default port (49374) and a
  shared temporary directory (`/tmp/opencode` in the tested version); neither is
  redirected by a profile.
- Host services started outside the profile namespace (`systemd --user`, D-Bus
  activation) carry no profile marker and cannot be attributed to a profile by
  the process scan.

Do not run untrusted or hostile code inside a profile expecting containment. For
that, use a VM or a container with its own credentials and network policy.

## Evidence

Sanitized Linux evidence for this release is published in
[`docs/evidence/linux-2026-10-28.md`](docs/evidence/linux-2026-10-28.md). It keeps
version, startup, discovery, authentication and sandbox results separate.

- Offline checks enforce write denial for Claude Code and Codex CLI sandbox
  modes, and verify profile-scoped skill discovery for all four CLIs.
- Model responses, model-driven skill invocation and command execution that
  requires an authenticated model turn are **credential-dependent gaps** for this
  release. No credentialed model calls were run and none are claimed.
- Raw QA logs stay private; only the sanitized summary and its generic paths,
  versions and results are published.

## Documentation

| Topic | Reference |
| --- | --- |
| Concepts, credentials, FAQ | [questions.md](skills/flyingnobita-agent-profiles/references/questions.md) |
| Diagnostics and exit codes | [troubleshooting.md](skills/flyingnobita-agent-profiles/references/troubleshooting.md) |
| Profile init, list, run | [repository-operations.md](skills/flyingnobita-agent-profiles/references/repository-operations.md) |
| Prerequisites, doctor, mise tasks | [machine-setup.md](skills/flyingnobita-agent-profiles/references/machine-setup.md) |
| Reset, remove, migrate, recover | [lifecycle.md](skills/flyingnobita-agent-profiles/references/lifecycle.md) |
| Platform and CLI matrix | [compatibility.md](skills/flyingnobita-agent-profiles/references/compatibility.md) |
| Agent guidance | [claude-code.md](skills/flyingnobita-agent-profiles/references/agents/claude-code.md), [codex.md](skills/flyingnobita-agent-profiles/references/agents/codex.md), [antigravity.md](skills/flyingnobita-agent-profiles/references/agents/antigravity.md), [opencode.md](skills/flyingnobita-agent-profiles/references/agents/opencode.md) |

## Development

```bash
MISE_TRUSTED_CONFIG_PATHS="$PWD" mise install
mise run ci                 # lint, tests, clean installation checks
mise run release-artifacts  # release readiness checks, tarball, checksum, notes
```

`mise run release-artifacts` writes build output to `dist/` (ignored by Git) and
does not publish anything. Creating a tag, remote, release or deployment is a
separate, explicit maintainer action. Offline live QA is opt-in and per agent:
`AP_EVIDENCE_DIR=<private-dir> bash tests/live/claude.sh` (also `codex.sh`,
`agy.sh`, `opencode.sh`).

## License

MIT. See [LICENSE](LICENSE).
