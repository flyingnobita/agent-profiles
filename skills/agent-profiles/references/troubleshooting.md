# Troubleshooting Guide

Common issues, diagnostic messages, and recovery procedures.

## Common Diagnostic Codes

- **Exit 64 (Usage error)**: Check command syntax and options. Subcommand names must be lowercase letters and hyphens. Profile options must precede the command.
- **Exit 65 (Invalid profile name)**: Profile names must be 1 to 32 characters, start with a lowercase letter, and contain only `[a-z0-9_-]`.
- **Exit 66 (`not a git repository`)**: Profiles live inside a Git checkout. `cd` into one or run `git init`, then retry. `agent-profiles init` also requires Git.
- **Exit 69 (Environment / dependency unavailable)**: Required tooling is missing or disabled on the host: on Linux `bwrap` or unprivileged user namespaces, on macOS a missing prerequisite. macOS arm64 needs no bubblewrap, and a Darwin build that is not arm64 is a `doctor` warning rather than an exit-69 refusal.
- **Exit 73 (Unsafe layout)**: Detected symlinked storage roots, path traversal, or overlapping mount targets. Storage roots must be physical directories.
- **Exit 75 (Resource busy / lock held)**: Another profile command holds a lock or lease, or a nested profile invocation was attempted with a different profile.
- **Exit 77 (Refused / legacy layout / interrupted operation)**: Stale operation journals or unmigrated legacy `.agent-sandbox` directories detected. Run `agent-profiles recover` or `agent-profiles migrate`.
- **Exit 78 (Broken task / deployment)**: Mise task shims point to a missing helper release. Rerun `agent-profiles setup`.

## Process Scan Refusals

When performing destructive lifecycle operations (`reset`, `remove`, `migrate`), the helper scans `/proc` for active processes using the target profile. If active processes are detected:

1. The operation is refused with exit code 75 (`EX_BUSY`).
2. PIDs and process names are reported.
3. The helper never kills processes.
4. Stop the reported processes or wait for them to finish, then rerun the command.

## Missing Bubblewrap or User Namespaces

On Linux, profile redirection requires `bubblewrap` and unprivileged user
namespaces:

- On Arch Linux / Omarchy: `sudo pacman -S bubblewrap`
- On Ubuntu / Debian: `sudo apt install bubblewrap`
- If unprivileged user namespaces are restricted, verify sysctl: `sysctl kernel.unprivileged_userns_clone` or check AppArmor namespace restrictions.

On macOS arm64 bubblewrap is not used and does not need to be installed. A
profile there is redirected by environment and configuration variables only;
`doctor` reports the bubblewrap, user-namespace and namespace-hardening checks
as not applicable rather than missing, and reports a non-arm64 Darwin build as
unqualified. That warning is the only architecture gate: `run` and `setup` still
proceed on a non-arm64 Darwin host, so profile execution there is unvalidated.

## Diagnosing Environment Issues

Run the diagnostic command:

```bash
agent-profiles doctor
```

For machine-readable JSON output:

```bash
agent-profiles doctor --json
```

## Stale Operation Recovery

If an operation was abruptly interrupted (e.g., power loss or SIGKILL):

```bash
agent-profiles recover
```
