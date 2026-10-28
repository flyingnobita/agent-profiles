# Lifecycle Operations

Guidance for resetting, removing, migrating, and recovering agent profiles.

## Resetting a Profile

Reset clears settings, tool installs, and caches for one profile, returning it to an empty state:

```bash
agent-profiles reset --profile my-worker
```

Add `--yes` to proceed without interactive confirmation.

## Removing a Profile

Remove deletes one profile directory and clears associated leases:

```bash
agent-profiles remove --profile my-worker
```

Add `--yes` to proceed without interactive confirmation.

## Migrating Legacy Storage

If a repository contains legacy `.agent-sandbox` storage from prior revisions:

```bash
agent-profiles migrate
```

Migration validates contents with SHA-256 digests and creates a backup outside the checkout.

## Interrupted Operation Recovery

To roll forward or clean up interrupted lifecycle journals:

```bash
agent-profiles recover
```
