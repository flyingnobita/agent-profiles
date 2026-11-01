# Linux agent profiles delivery

The user approved the nine-ticket plan and test seams on October 28, 2026.
The original ticket specifications are preserved in the
[completed delivery archive](../archive/2026-10-linux-delivery/README.md). The
delivery run retains the full approved plan, reports, command evidence, and
resource identities outside Git.

## Confirmed scope

- Build the self-contained `flyingnobita-agent-profiles` skill under the MIT license.
- Support named Linux profiles, mise tasks, Claude Code, Codex CLI, Antigravity CLI
  (`agy`), OpenCode, and safe lifecycle and migration operations.
- Keep macOS unqualified and document shared host resources and inherited credentials.
- Retain local commits and release artifacts. Publication, remote creation, pull
  requests, tags, releases, and real-machine deployment require a separate request.
- Use at most three implementers in isolated worktrees. Each ticket starts from the
  current integration tip after its blockers are independently verified and merged.

## Verification contract

- S1: Public helper CLI assertions cover parsing, errors, output, and diagnostics.
- S2: Disposable Git fixtures cover paths, worktrees, permissions, and exclusions.
- S3: Inside-profile probes cover mounts, environment, forwarding, concurrency,
  nesting, and command-lifetime leases.
- S4: Synthetic agent executables cover environment wiring and secret-safe diagnosis.
- S5: Real mise in temporary configuration covers directory preservation and tasks.
- S6: Clean installation from disposable source copies covers package independence.
- S7: Package and routing checks cover references, metadata, and progressive disclosure.
- S8: Offline real CLI checks cover startup, discovery, authentication diagnostics,
  and credential-free sandbox enforcement. These are separate from version probes.
- S9: Lifecycle fault injection covers refusal, locking, migration, and recovery.

Each vertical slice starts with a failing test at an approved public seam. Red
evidence records its test commit and subject SHA. Empty-base packaging contracts
are distinguished from behavioral tests; missing tools or fixtures never count as
behavioral reds. Named guard tests preserve existing behavior. Full tests, lint,
installation checks, final independent review, and disposable Linux QA gate completion.

Credential-dependent model checks remain unverified unless separately authorized.
Other unmet acceptance criteria remain open and require a scope decision.
QA may fetch pinned mise/npm tooling and use disposable `archlinux:latest` and
`ubuntu:24.04` containers. Test-owned containers and newly pulled images are cleaned
up; existing host configuration, credentials, sessions, and resources are preserved.

## Ticket state

Only the orchestrator updates this table. Completion requires verified integration.

| Ticket | Outcome | Blocked by | State | Integrated commit |
| --- | --- | --- | --- | --- |
| 01 | Installable skill and readiness | None | Verified and integrated | `6776906` |
| 02 | Named Linux profile runtime | 01 | Verified and integrated | `c6817cb` |
| 03 | Machine setup and mise tasks | 02 | Verified and integrated | `1fbd78f` |
| 04 | Claude Code integration | 02 | Verified and integrated | `376201d` |
| 05 | Codex CLI integration | 02 | Verified and integrated | `5eed95d` |
| 06 | Antigravity CLI integration | 02 | Verified and integrated | `e59a7ee` |
| 07 | OpenCode integration | 02 | Verified and integrated | `bea878c` |
| 08 | Lifecycle and migration | 02 | Verified and integrated | `8566f03` |
| 09 | Public Linux release readiness | 03-08 | Verified and integrated | `3503944` |

## Ownership

Ticket 02 provides shared runtime, locking interfaces, and live-test support before
parallel agent work begins. One implementer owns shared changelog and final evidence
updates. Lifecycle operations hold exclusive leases for every affected profile.
All doctor modes preserve persistent configuration, using disposable probe state
when agent commands would otherwise initialize it.

## Implementer profile update

On October 29, 2026 the user authorized Pi for all new implementers and
handoffs of tickets 04, 05, and 08 from quota-blocked Antigravity sessions.
The effective default is `deepseek/deepseek-flash` with high thinking.
The original partial work, reports and independent evidence were preserved through
integration. After publication, completed delivery worktrees and merged branches
were removed with ownership and ancestry checks. All tickets 01-09 are
independently verified and integrated.
The integration gate at `2bd6013` passed 332 tests with no skips, lint, and both
clean-install modes. The initial closeout commits changed documentation only;
subsequent CI portability fixes changed test fixtures, with all 332 tests passing
again on GitHub at `dea1c24`. The product runtime remains unchanged. Local v0.1.0 artifacts,
checksums and release notes are retained.

## Whole-branch verification

Three rounds of independent Standards and Spec review resolved all must-fix
findings. The final code review is clean at `2bd6013`; documentation closeout is
also independently reviewed. Genuine red checks, corrected fixtures, maintenance
guards and initial failed QA probes remain distinguished in the retained evidence.

Final QA is accepted. Actual offline startup, discovery and authentication
diagnostics passed for all four supported CLIs. Codex enforcement checks proved
controlled write denial. Claude qualified a background-session shell-mode `!`
command with strict sandbox settings; foreground/manual shell-mode was not
qualified. Profiles are not a security sandbox. Model-dependent checks remain
explicitly unverified. Arch and Ubuntu containers installed genuinely missing
prerequisites through pacman and apt-get and deployed the helper and both task
shims idempotently. The init task ran successfully; the run task delegates to
helper `run`, which truthfully returns namespace restriction exit 69 in default
Docker. Full profile execution in default Docker is not qualified. Test-owned containers, images, networks,
processes and temporary directories were removed; original Docker inventories match.

A fresh controlled audit preserved hashes and metadata for 211 selected persistent
settings, configuration, credential and mise paths. A configuration-file content
change during an earlier paused interval remains unattributed. The user accepted
the current Codex file as-is; it was preserved, and equality across that earlier
interval is not claimed. Credential contents were never read out or copied.

## Local delivery complete

All nine tickets, independent verification, review, QA, documentation and local
artifact preparation are complete. The published branch is `main`.
The original issue inputs and private evidence remain available for inspection;
completed delivery branches and worktrees were removed after publication.
Sanitized final evidence is in [the final Linux QA summary](../evidence/linux-2026-10-29.md).

Live model responses and model-driven skill invocation remain credential-dependent
gaps; macOS is unqualified. At local delivery closeout, no remote, push, PR, tag,
public release or deployment had occurred.

## Subsequent publication and retrospective

The user subsequently authorized source publication to
<https://github.com/flyingnobita/agent-profiles>. The published `main` was verified
initially at `ea19dae`; repository-source installation in copy mode then passed
in a disposable home. Subsequent CI and documentation updates reached `main` at
`dea1c24`. [GitHub Actions run 40825706875](https://github.com/flyingnobita/agent-profiles/actions/runs/40825706875)
passed all 332 tests, lint, both clean-install modes and release artifact checks.
The runner installs bubblewrap and probes namespaces before verification. The
two fixture portability failures from the first full hosted run were corrected
without changing product behavior; the earlier failures remain in the CI history.

All ten retrospective improvements were implemented in source. Their next-run
effectiveness remains to be observed; the private retro ledger retains measures
and commit references. This does not establish fleet-wide deployment.

## Housekeeping complete

- Removed 12 completed delivery worktrees and their owned worker workspaces.
- Deleted 13 merged local branches after checking ancestry against published main.
- Confirmed no processes remained with a removed delivery worktree as their cwd.
- Retained private evidence, CI logs, duplicate artifact receipts and original
  issue inputs; rebuilt and verified the current artifact in the main checkout.
- Preserved the separate `rapid-cloud` worktree because its ownership was outside
  the delivery cleanup evidence.

Current follow-ups and their completion criteria are in
[outstanding.md](outstanding.md). Tagged releases and real-host installation
remain separate actions; no such completion is inferred from source publication.

## macOS platform delivery

Issue #6 asked for macOS support, previously deferred. The user approved the
plan and seams S1-S10 on 2026-10-30: macOS arm64 becomes a qualified platform
for the same four integrations, using environment and configuration redirection
only (recorded in `docs/adr/0001-darwin-environment-only-redirection.md`), stock
macOS `/bin/bash` 3.2 with no new prerequisite, verification on the real MBP-M4
machine plus a new arm64 CI job, and a 0.3.0 release.

Delivery ran as one unit in eight ordered slices, each gated by the orchestrator:
S1 portability kernel, S2 Darwin run and redirection, S3 agent adapters and
Darwin doctor, S4 process safety and portable live harness, S5 setup, S6 test
tier and arm64 CI, S7 release tooling, S8 Linux and macOS qualification. Every
slice's new tests were re-run against the base commit before being accepted, and
Linux keeps zero skips with bubblewrap behaviour unchanged.

Three plan variances are recorded rather than hidden. First, the per-agent
env-root hooks needed no code changes, because the Darwin HOME and the existing
env hooks already produced the required per-agent roots, so those tests are
guards that pin behaviour instead of adding it; the doctor and diagnostics parts
of the same modules did change, with the Darwin Keychain branch in
`lib/agents/agy.sh`, the lsof listener classification in `lib/agents/opencode.sh`
and the portable login probe in `lib/agents/codex.sh`. Second, `mise.toml`
gained a `node = "22.23.4"` tool pin instead of the plan's "stays unchanged
unless a strictly necessary alias is added": the two npm-backed tools had no
runtime pin and macOS arm64 QA failed on a host without a system node. Third,
three provenance groups were reclassified during the gates after independent
receipts showed they pass on the base commit.

### Scope decision after real-machine QA

The plan required real four-agent evidence on the macOS host for full
qualification and said that, if unobtainable, the scope must return to the user.
No agent CLI was installed on the qualification machine, so the version, startup,
discovery and authentication classes for Claude Code, Codex CLI, Antigravity CLI
and OpenCode could not be observed there. On 2026-11-01 the user accepted the
narrowed claim for this release: macOS arm64 is qualified for profile mechanics,
configuration redirection and diagnostics, while the four real-agent classes on
Darwin are recorded as unverified and carried as a follow-up on issue #6. The
release surface, the evidence summary and the compatibility reference state that
boundary rather than implying parity with the Linux evidence classes.
