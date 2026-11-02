# Darwin redirection uses environment variables, not filesystem enforcement

**Status:** accepted

Linux redirects an agent profile with bubblewrap bind mounts, which need
unprivileged user namespaces. Darwin has no equivalent namespace, so on macOS a
profile is redirected only by pointing the agent CLIs and toolchains at profile
storage through their own environment and configuration variables. A macOS
profile therefore gives the same configuration separation as Linux but none of
the mount-level enforcement, and the documentation says so instead of implying
parity.

## Consequences

- Host files an agent CLI reads without honoring a redirect variable stay
  readable; the compatibility reference names that limit per agent.
- macOS evidence covers configuration redirection, startup, discovery and
  diagnostics, never enforcement, which is not claimed on Darwin.
- The cheap routes back to parity are deliberately rejected: symlinking the
  host's `.claude`, `.codex`, `.gemini` or `.agents` directories into a profile
  mutates the host environment the design exists to leave alone, and
  `sandbox-exec` seatbelt profiles are a deprecated API that would silently
  raise the security claim.
