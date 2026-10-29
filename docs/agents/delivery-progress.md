# Linux agent profiles delivery

The user approved the nine-ticket plan and test seams on October 28, 2026.
The original ticket specifications are in the initiating checkout's
`.scratch/agent-profiles/issues/` directory. The delivery run retains the full
approved plan, reports, command evidence, and resource identities outside Git.

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
The original worktrees, partial changes, reports, and independent evidence
remain preserved. All tickets 01-09 are independently verified and integrated.
The integration gate at `2bd6013` passed 332 tests with no skips, lint, and both
clean-install modes. Later closeout commits change documentation only; the runtime
and test trees are identical to the qualified code. Local v0.1.0 artifacts,
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
artifact preparation are complete. The retained branch is `deliver/agent-profiles`.
The original issue inputs and local worktrees remain available for inspection.
Sanitized final evidence is in [the final Linux QA summary](../evidence/linux-2026-10-29.md).

Live model responses and model-driven skill invocation remain credential-dependent
gaps; macOS is unqualified. Repository-source installation and publication remain
separate future work. No remote, push, PR, tag, public release or deployment occurred.
