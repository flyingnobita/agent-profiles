# Repository Operations

Guidance for managing agent profiles within a Git repository checkout.

## Initializing Profiles

To initialize the default profile in the current checkout:

```bash
agent-profiles init
```

To initialize a custom named profile:

```bash
agent-profiles init --profile my-worker
```

Profile initialization creates storage under `.agent-profiles/<name>/` and ensures the directory is excluded in Git metadata (`info/exclude`).

## Listing Profiles

To list all profiles configured in the current checkout:

```bash
agent-profiles list
```

Add `--json` for structured output.

## Executing Commands Inside a Profile

Run any command within a named profile:

```bash
agent-profiles run --profile my-worker -- command arg1 arg2
```

If `--profile` is omitted, the `default` profile is used.
Profile options must precede the command to execute.
