# Agent Profiles

**Separate logins, settings, skills and tools for your coding agents, per project.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: Linux](https://img.shields.io/badge/platform-Linux%20x86__64-informational)
![Agents](https://img.shields.io/badge/agents-Claude%20Code%20%7C%20Codex%20%7C%20Antigravity%20%7C%20OpenCode-8A2BE2)

[What a profile isolates](#what-a-profile-isolates) •
[Quick start](#quick-start) •
[Usage](#usage) •
[Install](#install) •
[Security](#security-and-shared-host-resources)

Coding agents keep everything in your home directory: one login, one set of
settings, plugins and MCP servers, one session history, one set of globally
installed tools. Agent profiles give a Git checkout any number of named,
side-by-side setups for **Claude Code**, **OpenAI Codex CLI**,
**Google Antigravity CLI** and **OpenCode**, while the repository itself stays
shared.

```bash
mise ap work claude      # Claude with your work account and settings
mise ap personal claude  # same checkout, different account, settings and history
```

## What a profile isolates

A profile is a directory, `.agent-profiles/<name>/`, inside the checkout. When
an agent runs through it, the directories it would read from your home
directory are redirected there:

| Isolated per profile | What that means |
| --- | --- |
| **Logins and accounts** | Each profile has its own credential storage, so `work` and `personal` can be logged into different accounts or plans. |
| **Settings, plugins, MCP servers and hooks** | The user-level ones, which mostly have no project-scope equivalent, or have one you would not want to commit. |
| **Session history and state** | Transcripts, memory and caches stay with the profile. |
| **User-installed tools** | `npm -g`, `cargo install`, `go install`, `uv tool` and `pip --user` install into the profile and come first on its `PATH`, so tool versions never collide with each other or with your host. |
| **User-level skills** | Skills installed with `-g` inside a profile are visible only there. |

What stays **shared** by every profile in the checkout:

- the repository working tree, its project-scope config (`.claude/`, `.agents/`,
  `.opencode/`) and project skills
- project package managers, lockfiles and your host `mise` configuration and tools
- network access, OS services and environment variables exported by your shell

> [!WARNING]
> Profiles separate workflows. They are **not a security sandbox**: a profile
> process keeps broad host access and inherits your environment. See
> [Security and shared host resources](#security-and-shared-host-resources).

## Quick start

> [!NOTE]
> Linux x86_64 only, with `bubblewrap`, `git`, `python3` and `mise` installed.
> See [Install](#install) for details.

```bash
# 1. Install the skill into your agents
npx skills@1.7.4 add flyingnobita/agent-profiles \
  --skill flyingnobita-agent-profiles --copy -g -y \
  --agent claude-code codex antigravity-cli opencode

# 2. Install the global `mise ap` task (preview first, then apply)
AP_HELPER="$HOME/.agents/skills/flyingnobita-agent-profiles/scripts/agent-profiles"
bash "$AP_HELPER" setup --preview
bash "$AP_HELPER" setup --apply

# 3. In any Git checkout, run an agent in a profile
cd my-project
mise ap demo claude      # asks to create "demo" the first time, then starts Claude
```

Log in inside the profile as you normally would; the helper never copies, links
or rewrites your host credential files.

## Usage

| Command | Does |
| --- | --- |
| `mise ap NAME AGENT [ARGS...]` | Run an agent (`claude`, `codex`, `agy`, `opencode`) or any command in profile `NAME` |
| `mise ap NAME` | Open your shell inside the profile; `exit` to leave |
| `mise ap new NAME` | Create a profile without running anything |
| `mise ap ls` | List the profiles in this checkout |
| `mise ap rm NAME [--yes]` | Remove a profile (preview until `--yes`) |
| `mise ap reset NAME [--yes]` | Recreate a profile empty (preview until `--yes`) |
| `mise ap doctor` | Check the machine, the task and the agent integrations |

Everything after the agent name is forwarded unchanged
(`mise ap demo claude --resume`). A missing profile is offered for creation in a
terminal; scripts pass `--create` (`mise ap --create demo codex`) so a typo
never creates a stray profile.

> [!TIP]
> Add `alias ap='mise ap'` to your shell to type `ap demo claude`.

### Skills and tools inside a profile

Install them the usual way, but from inside the profile:

```bash
mise ap demo npx skills add owner/repo --skill NAME -g -y --agent claude-code codex
mise ap demo npm install -g some-cli
```

| Install | Lands in | Seen by |
| --- | --- | --- |
| `-g` / global, run inside a profile | `.agent-profiles/<name>/` | that profile only; never committed |
| `-g` / global, run in a normal shell | your home directory | your normal agents only |
| project scope (no `-g`) | the repository (`.claude/skills/`, `.agents/skills/`) | the host and every profile in the checkout; commit it to share |

Use project scope for what the project needs and profile scope for personal,
experimental or account-specific setup.

### Show the active profile in your prompt

`mise ap NAME` without a command leaves you in a profile shell, where even a
plain `claude` runs in the profile. Every profile process exports
`AGENT_PROFILES_NAME`, so your prompt can say so:

```text
ap: demo > _
```

[Starship](https://starship.rs): put `${env_var.AGENT_PROFILES_NAME}` in your
`format` where the tag belongs, and add:

```toml
[env_var.AGENT_PROFILES_NAME]
format = '[ap: $env_value]($style) '
style = 'bold purple'
```

Plain zsh or bash, after any other prompt setup:

```bash
# zsh (~/.zshrc)
setopt PROMPT_SUBST
PROMPT='${AGENT_PROFILES_NAME:+ap: $AGENT_PROFILES_NAME }'"$PROMPT"

# bash (~/.bashrc)
PS1='${AGENT_PROFILES_NAME:+ap: $AGENT_PROFILES_NAME }'"$PS1"
```

## Install

### Requirements

- Linux x86_64 with unprivileged user namespaces enabled
- `bubblewrap` (`bwrap`) for the directory redirection
- `bash`, `git` and `python3` (standard library only)
- `mise` for the global task and versioned deployment
- at least one supported agent CLI; each is optional and diagnosed separately

`setup --preview` reports which missing prerequisites the detected distribution
can install (Arch-family `pacman`, Debian-family `apt-get`). `mise` itself is
never installed by the helper.

### Install the skill

The skill is installed with the `skills` CLI (npm `skills` package, pinned to
1.7.4). Select the skill explicitly, and drop `-g` for project scope.

> [!NOTE]
> Before the skill is published to the public registry it will be renamed
> without the `flyingnobita-` prefix, to `agent-profiles`. Commands that name
> `flyingnobita-agent-profiles` will change accordingly.

From the [published repository](https://github.com/flyingnobita/agent-profiles):

```bash
npx skills@1.7.4 add flyingnobita/agent-profiles \
  --skill flyingnobita-agent-profiles --copy -g -y \
  --agent claude-code codex antigravity-cli opencode
```

From a local checkout:

```bash
npx skills add /path/to/flyingnobita-agent-profiles --list   # confirm discovery
npx skills add /path/to/flyingnobita-agent-profiles \
  --skill flyingnobita-agent-profiles -g -y \
  --agent claude-code codex antigravity-cli opencode
```

The installed helper needs nothing outside its own directory, so it keeps
working after the source checkout is gone. `npx skills list` shows where it was
installed; the examples here use that path as `$AP_HELPER`:

```bash
AP_HELPER="<installed-skill-dir>/scripts/agent-profiles"
bash "$AP_HELPER" --version
bash "$AP_HELPER" doctor
```

### Set up the machine

```bash
bash "$AP_HELPER" setup --preview   # read-only plan
bash "$AP_HELPER" setup --apply     # deploy
```

`--apply` copies the helper to a versioned release under
`${XDG_DATA_HOME:-$HOME/.local/share}/flyingnobita-agent-profiles/releases/`
and installs one global mise file task, `agent-profiles`, aliased `ap` and
pinned to that release.

- Missing prerequisites and agent CLIs are installed only with `--apply`, only
  when actually missing, and only through the detected package manager or the
  mise registry. `--agent claude|codex|agy|opencode` limits which agent is
  installed; `--tasks-only` installs nothing.
- Existing tasks you own are never overwritten, and a dotfiles-managed task
  directory gets prepared files instead (`--prepare-dir DIR`).
- Setup removes the `agent-profiles-init` task of earlier versions after a
  backup.

Details: [machine-setup.md](skills/flyingnobita-agent-profiles/references/machine-setup.md).

## Update

```bash
npx skills update flyingnobita-agent-profiles -g -y   # refresh the installed skill
bash "$AP_HELPER" setup --apply                       # redeploy the release and task
bash "$AP_HELPER" doctor                              # confirm it is current
```

After a skill update `doctor` reports the task as `stale` until setup runs
again. A previous release is kept until the new one is verified.

## Remove

Remove profiles first, while the helper still exists, then uninstall:

```bash
# 1. Remove each profile (preview, then confirm) and check what is left.
mise ap rm demo
mise ap rm demo --yes
bash "$AP_HELPER" doctor

# 2. Uninstall the skill. The helper is gone after this step.
npx skills remove -g -y --skill flyingnobita-agent-profiles

# 3. Delete the global task files, but only those this tool manages.
MISE_CONFIG="${MISE_CONFIG_DIR:-$(mise doctor --json 2>/dev/null |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["dirs"]["config"])' 2>/dev/null)}"
MISE_CONFIG="${MISE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}"
for task in agent-profiles agent-profiles-init; do
  target="$MISE_CONFIG/tasks/$task"
  if [ -f "$target" ] && grep -q '^# managed-by: flyingnobita-agent-profiles ' "$target"; then
    rm -f "$target"
  elif [ -e "$target" ]; then
    echo "left $target untouched (not managed by flyingnobita-agent-profiles)"
  fi
done

# 4. Optional: delete the versioned deployment.
rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/flyingnobita-agent-profiles"
```

Removing a profile never touches other profiles or tracked project files.
Backups under `${XDG_STATE_HOME:-$HOME/.local/state}/flyingnobita-agent-profiles/backups/`
are kept until you delete them.

## Maintenance

The `mise ap` shortcuts cover daily use. The full helper also exposes:

```bash
bash "$AP_HELPER" doctor --json                    # machine-readable diagnostics
bash "$AP_HELPER" doctor --agent claude --profile demo
bash "$AP_HELPER" run --profile demo -- claude     # long form of `mise ap demo claude`
bash "$AP_HELPER" migrate                          # preview: convert legacy storage
bash "$AP_HELPER" recover --yes                    # finish an interrupted operation
```

- Reset, remove and migrate are previews until `--yes`. They refuse a profile
  that is in use (exit 75) and never kill processes, so run them from a normal
  shell, not from inside a profile.
- Interrupted operations leave a journal; affected commands exit 77 and point at
  `recover` until it finishes or rolls back.
- `doctor` is read-only, and its version probes are informational only.

Exit codes: 64 usage, 65 invalid name or data, 66 not a Git checkout or profile
missing, 69 dependency or namespace unavailable, 73 unsafe layout, 75 busy,
77 refused, 78 broken task or deployment; `run` otherwise returns the agent's
own status. See
[lifecycle.md](skills/flyingnobita-agent-profiles/references/lifecycle.md) and
[troubleshooting.md](skills/flyingnobita-agent-profiles/references/troubleshooting.md).

## Compatibility

Verified on Linux x86_64 on 2026-10-28 (offline evidence) and 2026-10-29
(final QA), with startup and discovery checks in disposable profiles. These are
the four supported integrations:

| Agent integration | Command | Verified version | Profile redirection |
| --- | --- | --- | --- |
| Claude Code | `claude` | 2.1.312 | `CLAUDE_CONFIG_DIR`, `.claude` mount |
| OpenAI Codex CLI | `codex` | 0.165.0 | `CODEX_HOME`, `.codex`/`.agents` mounts |
| Google Antigravity CLI | `agy` | 1.4.9 | `.gemini`/`.agents` mounts, XDG roots |
| OpenCode | `opencode` | 2.2.0 | `OPENCODE_CONFIG_DIR`, XDG roots; private `--standalone` server |

Logged-in model responses and model-driven skill use were not part of the
verification. Sanitized results are in the
[final QA summary](docs/evidence/linux-2026-10-29.md) and the
[offline evidence](docs/evidence/linux-2026-10-28.md); per-agent limits are in
[compatibility.md](skills/flyingnobita-agent-profiles/references/compatibility.md).

## Platforms

| Platform | Status | Notes |
| --- | --- | --- |
| Linux x86_64 | Qualified | Requires bubblewrap and unprivileged user namespaces |
| macOS | Not qualified | Deferred; no bubblewrap redirection layer |

Default Docker containers usually block unprivileged user namespaces. Setup,
`doctor` and `init` were verified there; running a profile returns the
namespace refusal (exit 69).

## Security and shared host resources

Profiles redirect directories and set per-profile environment variables, and
that is all. They are **not a security sandbox**, a virtual machine or a
container.

- A profile keeps the kernel, the filesystem outside the redirected
  directories, network access and the project checkout.
- Inherited environment credentials, such as API keys exported in your shell,
  reach the profile by design.
- OS services stay shared. Antigravity CLI authenticates through the D-Bus
  secret service, which can authenticate a process inside a profile.
- OpenCode's background service uses a fixed host-wide port (49374), so profile
  runs use a private `--standalone` server wherever the command accepts it. Its
  temporary directory (`/tmp/opencode`) is not redirected.
- Services started outside a profile (`systemd --user`, D-Bus activation) cannot
  be attributed to a profile.

Do not run untrusted code in a profile expecting containment; use a VM or a
container with its own credentials and network policy.

## Documentation

| Topic | Reference |
| --- | --- |
| Concepts, credentials, FAQ | [questions.md](skills/flyingnobita-agent-profiles/references/questions.md) |
| Profile init, list, run | [repository-operations.md](skills/flyingnobita-agent-profiles/references/repository-operations.md) |
| Prerequisites, doctor, `mise ap` task | [machine-setup.md](skills/flyingnobita-agent-profiles/references/machine-setup.md) |
| Reset, remove, migrate, recover | [lifecycle.md](skills/flyingnobita-agent-profiles/references/lifecycle.md) |
| Diagnostics and exit codes | [troubleshooting.md](skills/flyingnobita-agent-profiles/references/troubleshooting.md) |
| Platform and agent matrix | [compatibility.md](skills/flyingnobita-agent-profiles/references/compatibility.md) |
| Per-agent notes | [Claude Code](skills/flyingnobita-agent-profiles/references/agents/claude-code.md), [Codex](skills/flyingnobita-agent-profiles/references/agents/codex.md), [Antigravity](skills/flyingnobita-agent-profiles/references/agents/antigravity.md), [OpenCode](skills/flyingnobita-agent-profiles/references/agents/opencode.md) |

## Development

```bash
MISE_TRUSTED_CONFIG_PATHS="$PWD" mise install
mise run lint                 # shellcheck, shfmt, markdownlint, package check
mise run test                 # full Bats suite
mise run ci                   # lint, tests and clean-install checks
mise run release-artifacts    # release checks and local artifacts in dist/
```

Releasing, tagging and deployment are separate, explicit maintainer actions.
Offline live QA is opt-in per agent:
`AP_EVIDENCE_DIR=<private-dir> bash tests/live/claude.sh` (also `codex.sh`,
`agy.sh`, `opencode.sh`).
