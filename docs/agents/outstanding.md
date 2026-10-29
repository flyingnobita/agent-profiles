# Outstanding follow-ups

Updated October 29, 2026. This is the consolidated project follow-up list, linked
from the delivery tracker and release notes. Items below are not unfinished
acceptance gates for the delivered Linux scope. No installation, deployment,
credential use, new platform work or release publication is authorized by a row.

## Completed

- All nine implementation tickets and all ten retrospective improvements are
  implemented in source.
- Source publication is verified at `dea1c24` on `main`.
- [Hosted CI](https://github.com/flyingnobita/agent-profiles/actions/runs/40825706875)
  passed 332 tests, lint, both clean-install modes and release artifact validation.
- The 12 delivery worktrees and owned worker workspaces and 13 merged local
  branches were removed. Original issue inputs, private evidence and the current
  verified artifact are retained.

## Follow-ups awaiting a decision or verification

| ID | Item | Status and next trigger | Completion evidence |
| --- | --- | --- | --- |
| F1 | Real-machine skill installation and setup | Unverified here; choose a target and authorize installation | Preview, installed skill discovery/version, deployment doctor, two tasks and a disposable profile run verified on the chosen host |
| F2 | Fleet deployment of delivery-skill improvements | Fleet-wide state unverified here; inspect the dotfiles deployment register and target sources before authorizing any apply | Per-host source/deployed equality and relevant checks; record exclusions or unreachable hosts explicitly |
| F3 | Effectiveness of retrospective fixes | Implemented, awaiting a subsequent delivery | Evaluate the existing private retro ledger's measures against a new run, marking held or regressed without rewriting this run's evidence |
| F4 | Separate `rapid-cloud` worktree | Intentionally retained; establish ownership and whether it is still needed | Owner confirms disposal; then verify clean state, landed commits and no active work before removal |

Unverified means this session has no sufficient completion evidence, not that an
installation or rollout elsewhere is known to be absent. F2 concerns delivery
tooling owned by the dotfiles source repository, not agent-profiles installation.

## Optional future scope

| ID | Item | Status and prerequisite |
| --- | --- | --- |
| O1 | Tagged GitHub Release | Optional; separately authorize a full release with versioned notes and verified artifacts |
| O2 | Authenticated model responses and model-driven skill invocation | Explicitly unverified; separately authorize credentials/model calls and define acceptance |
| O3 | macOS implementation and qualification | Deferred platform scope; requires its own design, implementation and verification |

The existing Linux limitations remain in [compatibility.md](../../skills/flyingnobita-agent-profiles/references/compatibility.md).
The earlier unattributed Codex configuration change remains a historical evidence
limitation accepted by the user, not an unresolved restoration task. Full
foreground/manual Claude shell-mode enforcement and execution under restricted
default Docker are not claimed by this release.

## Updating this list

Record new agreed project follow-ups here with their status, trigger and observable
completion evidence. On completion, move the item into Completed with a commit,
CI run or inspected receipt reference. Link detailed implementation tickets from
this list rather than copying their contents. A future configured issue tracker
may own the tickets; this page can then remain their status index.
