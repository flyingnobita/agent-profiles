# Pi and oh-my-pi macOS QA Evidence (2026-11-15)

Sanitized summary for the Pi 1.5.2 and oh-my-pi 18.20.0 profile runs on a macOS
arm64 host, agent-profiles release `0.5.0-33ca32e3`. Only generic paths and
results are published here; raw output stays private.

## Environment

- macOS 27.2.1 arm64 desktop host; stock `/bin/bash` 3.2 for the shipped helper.
- Disposable Git checkout under a temporary directory, a fresh profile, and no
  credential values supplied by the QA run.
- The platform adapter needs no bubblewrap and no mount table on Darwin.

## Redirection

Each CLI was started through the deployed helper:

```bash
agent-profiles run --profile qa -- pi --offline -p hi
agent-profiles run --profile qa -- timeout 20 omp -p hi
```

Environment credential variables were removed for the run. Results:

| Check | Pi 1.5.2 | oh-my-pi 18.20.0 |
| --- | --- | --- |
| Profile state | `.pi/agent/{auth.json,models-store.json,sessions/}` created in the profile | `.omp/agent/{agent.db,models.db,skill-descriptions.db,sessions/}` created in the profile |
| Host state | no session for the test checkout under host `~/.pi/agent/sessions` | no session for the test checkout under host `~/.omp/agent/sessions` |
| Profile `HOME` | the profile directory | the profile directory |
| Mount table | none | none |

Pi reached a provider credit error during the non-interactive request, which is
not a model readiness claim; the state files it wrote before that point are the
redirection evidence. oh-my-pi printed its version and then started a session
that the harness stopped after the timeout, leaving its profile state behind.

## Not Claimed

- Model-driven skill invocation, successful model responses and enforced sandbox
  denial remain credential-dependent gaps.
- Ancestor-directory skill discovery outside the repository was not exercised.
- macOS Keychain use by either CLI was not inspected.
- The `skills` CLI install and `setup --apply` step were exercised on the host;
  no other machine configuration was changed by this QA.
