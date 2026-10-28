# Claude Code Integration

Guidance for running Claude Code (`claude`) inside a named agent profile. Tested
on Linux with Claude Code 2.1.312. Version probes are informational: a successful
`claude --version` does not show that startup, discovery, authentication or
sandboxing work.

## Version And Prerequisites

- Claude Code 2.1.312 was exercised for this reference (Linux x86_64).
- Required: the `claude` launcher on `PATH`, bubblewrap (`bwrap`), `socat`, git
  and python3. The installed skill's base runtime already requires bubblewrap and
  unprivileged user namespaces.
- A host mise command wrapper still resolves the native Claude Code launcher from
  `~/.local/share/claude/versions`. Keep `mise` available on `PATH`; the profile
  run preserves the host's effective `MISE_*` directories.
- Offline diagnostics use `bwrap --unshare-net`. They cannot make a model call,
  but Claude Code may attempt a connection to `api.anthropic.com` and report a
  network error before showing an interactive screen.

## Configuration Redirection

`agent-profiles run --profile NAME -- claude` exports:

- `CLAUDE_CONFIG_DIR=<checkout>/.agent-profiles/NAME/.claude`
- no inherited `CLAUDE_SECURESTORAGE_CONFIG_DIR` (it is unset)

The runtime also bind-mounts the profile's `.claude` directory over `~/.claude`.
With `CLAUDE_CONFIG_DIR` set, Claude Code 2.1.312 keeps its adjusted global
configuration in `$CLAUDE_CONFIG_DIR/.claude.json`, plus `projects/`, `sessions/`
and `backups/` inside the same directory.

Do not assume `~/.claude.json` is isolated by the mount alone. Verify it through
`CLAUDE_CONFIG_DIR`: in the tested version the user-scope file is read from the
profile, and a synthetic host `~/.claude.json` carrying an MCP server and marker
was not read or imported. Host `~/.claude/settings.json`, `~/.claude/skills` and
`~/.claude/.credentials.json` are hidden by the profile mount.

Project-scoped `.mcp.json` files and repository `.claude/` settings remain part
of the checkout and are not redirected by the profile. Treat them as host
repository content, not as profile state.

## Discovery

Check what the selected profile exposes:

```bash
bash "$AP_HELPER" run --profile NAME -- claude mcp list
bash "$AP_HELPER" run --profile NAME -- claude -p --output-format stream-json --verbose "discovery probe"
```

The headless `system`/`init` event reports `skills`, `slash_commands`,
`mcp_servers`, `plugins` and `tools`. In profile testing:

- a marker skill and settings file in profile A appeared only with `--profile A`,
  and profile B saw only its own marker;
- a user-scope MCP server stored in profile A's `.claude.json` appeared only in
  profile A;
- a synthetic host `.claude.json` MCP server, host settings marker and host skill
  did not appear in either profile, and `inotifywait` observed no host reads;
- the interactive `/skills` view and the `!` shell mode use the same profile
  configuration.

Discovery surfaces can vary by version. If `stream-json` or `/skills` changes,
use `claude mcp list`, `claude sandbox status` and `claude doctor` before
concluding that a profile is isolated.

## Bundled And Managed Sources

These remain applicable inside every profile and are expected:

- built-in plugins shipped with the version, including `cc-plugin-agents-md` and
  `cc-plugin-plugin-authoring`, with their bundled skills and commands;
- built-in tools and modes reported by the init event (for example Bash, Read,
  Edit and Workflow);
- project `.claude/settings.json`, `.claude/settings.local.json` and `.mcp.json`
  from the checkout;
- settings passed with `--settings` for one session.

Remote managed settings and organization policy are not fetched when no usable
credentials are present. A failed managed-settings fetch is reported by the
session; it does not mean the profile imported host configuration.

## Authentication

Ask Claude Code for its own classification instead of inspecting credential
contents:

```bash
bash "$AP_HELPER" run --profile NAME -- claude auth status
```

In 2.1.312 this prints JSON (and exits 1 when logged out) with `loggedIn`,
`authMethod`, `apiProvider`, `configDirectory` and, when applicable,
`apiKeySource`. Observed classes:

- fresh profile: `loggedIn: false`, `authMethod: none`, profile
  `configDirectory`;
- inherited `ANTHROPIC_API_KEY`: `loggedIn: true`, `authMethod: api_key`,
  `apiKeySource: ANTHROPIC_API_KEY` (the value is never printed);
- profile-stored sign-in: credentials live under the profile `.claude`
  directory, not in the host home.

`agent-profiles doctor --agent claude --profile NAME` reports the profile name,
initialization state, config directory and an auth classification using
`logged_in`, `status` and `method` (`none`, `environment`, `profile_stored`). It
reads no credential contents and never prints environment values. A profile becomes
logged in only through the normal `claude auth login`, `claude setup-token`, or
an explicitly inherited environment variable; the helper never copies, links or
makes host credential files writable.

Linux keyring or secret-service storage can sit outside the profile. Treat
OS-provided credentials as host resources that may remain visible; they are not
a profile isolation guarantee.

## Sandbox

Claude Code's Bash sandbox is separate from the profile wrapper. Check its
resolved posture first:

```bash
bash "$AP_HELPER" run --profile NAME -- claude sandbox status
```

The JSON reports `enabled`, `enabledSource`, `strictMode`, `strictModeSource`,
and the filesystem policy. Enable it with `sandbox.enabled` in the profile's
`.claude/settings.json`, for example:

```json
{
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false
  }
}
```

Linux enforcement uses bubblewrap and `socat`. `failIfUnavailable` makes a
missing dependency an error instead of a silent unsandboxed fallback.

Important version behavior: in a normal interactive session, a command typed at
the `!` shell-mode prompt runs outside the sandbox. A **background session** in
strict mode (`allowUnsandboxedCommands: false`) does sandbox shell-mode commands.
To verify enforcement without a model call:

1. start an idle background session with `claude --bg`;
2. attach to it and run `!touch <path outside the workspace>`;
3. expect `Read-only file system` and no created file;
4. run `!touch <path inside the workspace>` and expect the file to appear;
5. stop the test-owned session with `claude stop <id>`.

Tested result: a write outside the checkout was denied with
`Read-only file system`, a write inside the checkout succeeded, and the session
stopped cleanly. Nested bubblewrap and restricted container namespaces can make
the sandbox unavailable; report the actual error rather than claiming
enforcement. Credential-dependent model responses and model-driven skill
invocation remain unverified unless separate authorization and credentials
exist.

## Troubleshooting

- **`claude` not found or the mise wrapper fails**: verify the launcher resolves
  with the host `MISE_*` directories preserved; a synthetic `HOME` also needs a
  readable native launcher directory (`~/.local/share/claude`).
- **Not logged in**: run `claude auth status` (a fresh profile is not logged in), then sign in normally inside the
  profile. Do not copy host credential files.
- **Sandbox unavailable**: check `claude sandbox status`, bubblewrap, `socat`,
  AppArmor/user-namespace restrictions, and nested-container limits.
- **`!` command wrote outside the workspace**: normal interactive shell mode is
  unsandboxed in the tested version; repeat the check from a strict background
  session.
- **Host MCP server appears**: confirm extra `--mcp-config` arguments and project
  `.mcp.json`; the profile user-scope config is `$CLAUDE_CONFIG_DIR/.claude.json`.
- **`--version` succeeds but startup fails**: use the init event or a real TUI
  launch, `claude auth status` and `claude sandbox status`; `--version` success
  is not readiness.
- **Profile not initialized**: run `agent-profiles init --profile NAME` in the
  checkout before `run`.

## Verification Summary

| Check | Surface | Tested result |
| --- | --- | --- |
| Version | `claude --version` through the mise wrapper | 2.1.312 |
| Startup | headless init event; TUI startup banner offline | init event observed; TUI reached banner, network error offline |
| Discovery | init `skills`, `mcp_servers`; `claude mcp list` | profile markers isolated; bundled sources recorded |
| Host isolation | synthetic host markers + `inotifywait` | no host config or credential reads |
| Auth | `claude auth status` | fresh logged out; env API key classified; no credential copy |
| Sandbox | `claude sandbox status`; strict background `!touch` | enabled/strict; outside write denied; inside write allowed |
