# 08: Reset, remove, and migrate profiles safely

> Historical specification. The approved Linux delivery is completed and
> integrated. See the [delivery record](../../agents/delivery-progress.md)
> for verification, scope decisions and remaining limitations. The original
> criteria below are preserved as written; unchecked boxes are not open tasks.

**What to build:** Review and perform lifecycle operations on one selected profile, preserving other profiles and recovering earlier storage layouts through a private backup.

**Blocked by:** 02: Create and run named Linux profiles.

**Archive status:** Completed for the approved Linux scope; integrated as `8566f03`.

**Original intake status:** ready-for-agent

- [ ] The helper supports targeted reset and removal with a preview identifying the exact selected profile and the consequences for its settings, transcripts, credentials and installed tools.
- [ ] Reject unsafe names, traversal and unexpected symlink roots before mutation. Handle active-profile processes explicitly; never kill unrelated agent sessions or delete another profile implicitly.
- [ ] Resetting one profile recreates its empty directories while preserving all others. Removing one profile leaves other profiles, project files, local mise configuration and unrelated Git exclusions intact.
- [ ] Detect old .agent-sandbox storage, both unnamed and named layouts, and unnamed data under the new storage name. Refuse silent reuse or automatic merging of ambiguous layouts.
- [ ] Migration preserves the original data in a private backup outside the Git checkout before rebuilding selected profile storage. Explain why absolute paths in scripts, symlinks or caches can require reinstalling tools.
- [ ] Mixed old/new layouts preserve already working named profiles. Record backup and migration results without printing sensitive contents, and define recovery for interrupted operations.
- [ ] The installed skill routes reset, remove and migration requests to the corresponding helper operation and loads only relevant lifecycle instructions.
- [ ] Verify target previews, refusal cases, selective reset/removal, old named and unnamed layouts, mixed-layout preservation and private-backup recovery in disposable fixtures.
