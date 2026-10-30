# Agent instructions

## Agent skills

### Issue tracker

Use GitHub Issues in `flyingnobita/agent-profiles`.
Read [tracker operations](docs/agents/issue-tracker.md) before tracker operations.

### Triage labels

Use the five default triage labels.
See [triage labels](docs/agents/triage-labels.md).

### Domain docs

Single-context layout: root `GLOSSARY.md` and `docs/adr/`.
Read [domain docs](docs/agents/domain.md) before domain exploration.

## Delivery

Tracker default: GitHub Issues in `flyingnobita/agent-profiles`.

**Time reporting:** Report times to the user in this machine's local time. Stored evidence, commit metadata and Dagr timestamps stay in UTC.

**Autonomous delivery:** When the user starts work in this repository (an issue, spec, tickets or a description), agents may push the work branch, open a pull request, and merge it into the default branch without a further request, provided all checks pass: the full test suite, linters, the review stage, and QA when it was run. Scope changes still require the user's approval.
