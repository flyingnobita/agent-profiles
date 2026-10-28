# Agent profiles

Agent profiles separate an agent's personal settings and installed tools while retaining access to shared host resources.

## Language

**Agent profile**:
A named collection of agent settings, state, and user-installed tools associated with one project checkout. It is not a security boundary for untrusted code.
_Avoid_: Sandbox, isolated account

**Default profile**:
The agent profile selected when the user does not name a profile. It has the same separation rules as any other named profile.

**Host environment**:
The user's machine and resources shared with profile sessions, including project files, inherited environment credentials, and operating-system services.

**Agent integration**:
The supported behavior and guidance for using one agent CLI within an agent profile, including discovery, authentication diagnostics, and command execution.
