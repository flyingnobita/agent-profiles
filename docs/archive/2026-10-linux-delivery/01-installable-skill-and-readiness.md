# 01: Installable skill with readiness checks and Q&A

> Historical specification. The approved Linux delivery is completed and
> integrated. See the [delivery record](../../agents/delivery-progress.md)
> for verification, scope decisions and remaining limitations. The original
> criteria below are preserved as written; unchecked boxes are not open tasks.

**What to build:** Install the public flyingnobita-agent-profiles skill into a clean agent environment, ask it questions without changing the machine, and obtain a secret-safe readiness report. This is the first usable slice of a self-contained public project.

**Blocked by:** None (can start immediately).

**Archive status:** Completed for the approved Linux scope; integrated as `6776906`.

**Original intake status:** ready-for-agent

- [ ] The skill is named flyingnobita-agent-profiles and is discoverable and installable with npx skills add using a local source during development and a repository source after publication.
- [ ] The installed package includes every required script and reference, resolves its own resources relative to its installation, and works without the author's dotfiles checkout, absolute home paths, fleet services or other personal skills.
- [ ] A small entry point routes machine setup, repository operations and questions to focused references. Demonstrate that a question loads only the relevant reference and causes no installation or configuration changes.
- [ ] A bundled doctor command detects OS, relevant dependency availability and versions, and installed support for Claude Code (claude), OpenAI Codex CLI (codex), Google Antigravity CLI (agy) and OpenCode (opencode). Missing optional agents do not prevent diagnosing another.
- [ ] Diagnostics distinguish available, missing and unverified capabilities without printing credentials or entire environments. Missing dependencies produce actionable results without installing anything.
- [ ] Answers explain profile separation, inherited credentials, shared host resources and the absence of a security boundary for untrusted code. Linux evidence and unverified macOS behavior are distinguished.
- [ ] Validate skill metadata, reference reachability and a clean local npx skills add installation. Check realistic setup, operation and Q&A routing requests without loading all references or helper source unnecessarily.
