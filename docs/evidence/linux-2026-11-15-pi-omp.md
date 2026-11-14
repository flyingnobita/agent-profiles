# Pi and oh-my-pi Linux QA Evidence (2026-11-15)

Sanitized summary for the AP-24 integration of Pi 1.5.2 and oh-my-pi 18.20.0.
Only generic paths and results are published here; raw logs stay private in
`AP_EVIDENCE_DIR` because they can contain host-specific paths and session text.

## Environment

- Linux x86_64 host, disposable profiles in a throwaway Git checkout, synthetic
  home directory, `bwrap --unshare-net` for every profile run.
- No credential value, host login or model call was used.
- The opt-in scripts are `tests/live/pi.sh` and `tests/live/omp.sh`; each
  refuses to run without `AP_EVIDENCE_DIR`.

## Reported Leak (before the integration)

A profile run of each CLI, with a synthetic home, was started before any code
change:

- `pi --offline -p hi` created `~/.pi/agent/auth.json`,
  `models-store.json` and a session directory in the **host** home.
- `omp -p hi` created `~/.omp/agent`, `~/.omp/logs`, `~/.omp/natives` and
  `~/.omp/run` in the **host** home.

That reproduces the issue's premise on Linux: without a mount the CLIs read and
write host state, because profile preparation changed XDG roots but not
`~/.pi` or `~/.omp`.

## Results

| Class | Pi 1.5.2 | oh-my-pi 18.20.0 |
| --- | --- | --- |
| Version | pass; doctor resolved the mise-installed binary | pass; doctor resolved the mise-installed binary |
| Redirection | pass; `.pi/agent/auth.json`, `models-store.json` and a session directory landed in the profile | pass; `.omp/agent/agent.db`, `models.db`, sessions and `.omp/run` landed in the profile |
| A/B separation | pass; profile marker skills stayed in their own profile | pass; profile marker skills stayed in their own profile |
| Host preservation | pass; the synthetic home tree was byte-identical after QA and a host `.pi` marker was not read | pass; the synthetic home tree was byte-identical after QA and a host `.omp` marker was not read |
| Auth diagnostics | pass; profile file path and inherited environment name reported; no value printed; `authenticated: null` | pass; credential database path and inherited environment name reported; database not opened; `authenticated: null` |
| Startup | unauthenticated exit ("No API key found"); not a readiness marker | unauthenticated startup, stopped by the harness timeout; not a readiness marker |
| Discovery | credential-dependent gap; skill markers were written to `.pi/agent/skills` and `.agents/skills`, reads were not observed | credential-dependent gap; skill markers were written to `.omp/agent/skills` and `.agents/skills`, reads were not observed |
| Sandbox | credential-dependent gap; no enforced denial tested | credential-dependent gap; no enforced denial tested |

## Platform Contract

The Darwin branch was exercised with a synthetic executable in
`tests/10-pi/darwin-env.bats` and `tests/11-omp/darwin-env.bats`: profile `HOME`
covered `~/.pi`, `~/.omp` and `~/.agents`, an inherited
`PI_CODING_AGENT_DIR` was cleared, and no bubblewrap or mountpoint was needed.
This proves branch selection and the environment contract only; it is not
evidence of stock macOS bash 3.2 or of real CLI behavior.

A macOS arm64 desktop host independently observed Pi 1.5.2 writing
`.pi/agent/{settings.json,auth.json,trust.json,models-store.json,sessions/}`
under the profile `HOME` on 2026-11-14 (recorded on issue #34). oh-my-pi was
installed there but not run inside a profile for this release.

## Gaps

- Model-driven skill invocation, enforced sandbox denial and any credentialed
  model response remain unverified for both CLIs.
- Ancestor-directory skill discovery outside the repository is unverified; the
  same class of gap is tracked for OpenCode in #54.
- Any use of the macOS Keychain by either CLI was not inspected.
- An external oh-my-pi auth broker (`OMP_AUTH_BROKER_URL`) is a shared source
  and was not exercised.
