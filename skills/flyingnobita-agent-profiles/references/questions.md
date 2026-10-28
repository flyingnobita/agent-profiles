# Frequently Asked Questions

## Concepts and Architecture

### What is an agent profile?

An agent profile is a named collection of agent settings, state, and user-installed tools associated with one project checkout. It allows different agent workflows (or different agents) to maintain separate configurations and package installations without duplicating repository files.

### Is an agent profile a security sandbox?

No. An agent profile is a workflow and dependency separation mechanism, not a security boundary for untrusted code. Profile sessions retain access to shared host resources, including project files, network, and inherited environment credentials. Do not execute untrusted or hostile code inside a profile expecting containment.

### How does profile separation work?

On Linux, agent profiles use `bubblewrap` (`bwrap`) to redirect user-level agent configuration directories (`.claude`, `.codex`, `.gemini`, `.agents`, `.opencode`) and separate XDG data/config/cache paths to `.agent-profiles/<name>/` inside the checkout. Package managers (`npm`, `cargo`, `uv`, `pip`) write tools to profile-specific directories. Host `mise` configuration and directory paths are preserved.

### How are credentials handled?

Profiles do not copy, write, or manage host secrets. Inherited environment credentials (such as API keys exported in your shell) pass through to profile sessions by design. Tool logins executed within a profile remain confined to that profile's configuration storage.

### What is the default profile?

When no profile name is explicitly specified via `--profile`, the helper uses `default`. The default profile follows the exact same separation rules and directory structure as any other named profile.

### How do package managers interact with profiles?

Package managers such as `npm`, `cargo`, `uv`, and `pip` write user-installed tools and global binaries to profile-isolated directories under `.agent-profiles/<name>/`. Profile binary directories take precedence on `PATH`. The project's existing repository package managers, lockfiles, and dependencies remain untouched.

### Why are profiles not a substitute for VM or container isolation?

Agent profiles provide directory redirection using `bubblewrap` to separate configuration state and tool installation locations across agent sessions. They do not eliminate the host Linux kernel attack surface, restrict network access by default, or isolate memory. Profiles separate workflows on the developer's machine; they do not contain untrusted code.

## Operating System Support

### What platforms are supported?

Linux with unprivileged user namespaces and `bubblewrap` is supported. macOS behavior is not qualified and remains unverified. Running on non-Linux platforms reports that the operating system is not qualified.
