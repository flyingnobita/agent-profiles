# Contributing

Thanks for helping improve Agent Profiles. This guide covers how to propose a
change, the checks it must pass, and how to work with AI coding agents here.

Contributions are accepted under the [MIT license](LICENSE).

Rules marked **outside contributors** apply to anyone without write access
to the repository. Maintainers and their agents follow [AGENTS.md](AGENTS.md)
instead.

## Before you start

- **Search first.** Look through [open and closed issues](https://github.com/flyingnobita/agent-profiles/issues?q=is%3Aissue)
  before filing a new one.
- **Outside contributors: open an issue before a pull request** for anything beyond a typo or a small
  documentation fix. Describe the problem, not only the solution, and wait for a
  maintainer to agree on scope. Pull requests are not treated as feature
  requests; an unrequested feature PR may be closed without review.
- **Read the domain docs.** [GLOSSARY.md](GLOSSARY.md) defines the project's
  vocabulary (an agent profile is not a sandbox; use "configuration
  redirection", not "isolation"). [docs/adr/](docs/adr/) records decisions; if
  your change contradicts one, say so in the issue rather than working around it.
- **Security issues** go to the maintainer privately through
  [GitHub private vulnerability reporting](https://github.com/flyingnobita/agent-profiles/security/advisories/new),
  never a public issue. Read
  [Security and shared host resources](README.md#security-and-shared-host-resources)
  first: profiles are not a security boundary, so behavior listed there is
  expected.

## Development setup

You need `git`, `python3` and [mise](https://mise.jdx.dev/). On Linux you also
need `bubblewrap` with unprivileged user namespaces. macOS arm64 uses the stock
`/bin/bash` 3.2.

```bash
git clone https://github.com/flyingnobita/agent-profiles.git
cd agent-profiles
MISE_TRUSTED_CONFIG_PATHS="$PWD" mise install   # exact-pinned tools from mise.toml
```

| Command | What it checks |
| --- | --- |
| `mise run lint` | ShellCheck, shfmt, markdownlint, package contract |
| `mise run test` | Full Bats suite, in parallel (`AP_TEST_JOBS=1` runs serially) |
| `mise exec -- bats tests/<area>/<file>.bats` | One test file |
| `mise run check-install` | Clean install from a disposable copy with `npx skills` |
| `mise run ci` | All of the above; CI runs it on Linux and macOS |

**Outside contributors:** locally, run `mise run lint` and the `.bats` files
your change touches. The pull request's CI runs the full suite and the install check on Linux and
macOS, and both must pass before merge.

## Making a change

### Code

- Bash with `set -euo pipefail`, 2-space indentation, and nothing newer than
  Bash 3.2 (no `mapfile`, GNU-only `readlink -f`, `stat -c` or `realpath`). Use
  the portability helpers in `skills/agent-profiles/scripts/lib/`.
- Follow the existing naming: `ap_cmd_<command>`, `ap_agent_<id>_*`, and the
  `ap_` prefix for internal functions. Agent-specific code belongs in
  `scripts/lib/agents/`.
- Fail through `ap_die` with the documented exit codes in
  [troubleshooting.md](skills/agent-profiles/references/troubleshooting.md).
- Validate before mutating. Lifecycle operations keep their preview,
  confirmation, locking and journal steps; never weaken a refusal to make a
  test pass.
- Never print or store credential values. Diagnostics name environment
  variables only.
- Comments explain why, not what.

### Tests

- **Test first.** Write a failing Bats test at a public seam (the CLI, a
  documented hook) before the fix, and confirm it fails for the right reason. A
  missing tool or fixture is not a valid red.
- Put tests in the numbered area they belong to and reuse
  `tests/helpers/`. Tests use temporary `HOME` and XDG roots and must not touch
  real configuration.
- The suite runs in parallel. Keep each test independent of the others, call
  nested Bats as `"$BATS_ROOT/bin/bats"`, and never pipe into `grep -q` under
  `pipefail` (the writer can die of SIGPIPE); send `grep` output to
  `/dev/null` instead.
- No new skips. The only allowed platform skip is `ap_test_skip_darwin` with a
  reason, and an audit test enforces this.
- Replace sleeps with markers or bounded polling.
- Real-agent checks in `tests/live/` are opt-in and outside the suite. Report
  them as unverified unless you ran them.

### Documentation

- Update user-facing docs (README, `references/`) in the same pull request as
  the behavior they describe.
- Add a line to the top of [CHANGELOG.md](CHANGELOG.md) for user-visible
  changes, in the existing format:
  `- MMM-DD, YYYY - HH:MM AM/PM +HH:MM - What changed, from the user's view`.
- Record a significant design decision as an ADR in `docs/adr/`.

## Commits and pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/):
  `type(scope): subject`, with types `feat`, `fix`, `perf`, `docs`, `test`,
  `ci` or `chore`. Write the subject in the imperative, lower case, without a
  trailing period.
- One logical change per commit. Keep behavior changes and unrelated
  documentation or formatting in separate commits.
- Sign your commits (SSH or GPG).
- Branch from `main`, and name the branch after the change
  (`fix/darwin-lock-timeout`).
- Keep pull requests small enough to review in one sitting. Start the
  description with the goal, link the issue (`Fixes #12` or `Refs #12`), list
  the main changes, and state exactly what you verified and on which platform.
  Say what you did not verify.
- All CI jobs must pass. A flaky test is a bug to report, not a reason to
  rerun until green.

## Working with AI coding agents

AI-assisted contributions are welcome. This repository is set up for them:
[AGENTS.md](AGENTS.md) is the entry point agents read, and it links to the
tracker, label and domain conventions in [docs/agents/](docs/agents/).

You are the author of everything you submit, whoever or whatever typed it:

- **Understand every line.** You must be able to explain and defend the change
  in review. Do not submit code you have not read.
- **Verify claims yourself.** Agents report tests as passing, files as
  changed or bugs as fixed when they are not. Run the checks and read the
  output before putting a claim in a pull request.
- **Outside contributors: disclose substantial AI use** in the pull request
  description: which tool, and which parts it produced.
- **No AI attribution in commits.** Do not add AI attribution or
  `Co-Authored-By` trailers.
- **Keep scope tight.** Agents tend to refactor nearby code, add options and
  rewrite documentation. Remove anything the issue did not ask for.
- **Do not weaken checks.** Deleting a failing assertion, adding a skip,
  loosening a refusal or bumping a timeout without a measured reason will be
  rejected.
- **Protect secrets.** Agents read your environment and files. Run them in a
  profile without production credentials, and check that no token, path to a
  private file or log containing either reaches a commit, issue or evidence
  file.
- **Write for both readers.** When you change `AGENTS.md`, `SKILL.md` or
  `references/`, remember that agents follow these files literally: state
  rules directly, keep `SKILL.md` within its size limits (enforced by
  `mise run lint`), and put detail in references.
- **No unattended AI comments.** Do not post issues, reviews or replies
  generated by an agent without reading and editing them first.

## Releases

Releases, tags and deployment are maintainer actions. Contributors do not bump
`skills/agent-profiles/VERSION` or the plugin manifest versions.
