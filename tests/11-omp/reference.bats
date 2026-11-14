#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation

  REF="$AP_SKILL_DIR/references/agents/omp.md"
}

teardown() {
  teardown_isolation
}

assert_ref_contains() {
  local needle="$1"
  if [[ "$(cat "$REF")" != *"$needle"* ]]; then
    printf "expected to find '%s' in %s\n" "$needle" "$REF" >&2
    return 1
  fi
}

@test "omp reference: documents the required profile sections" {
  assert_file_exists "$REF"

  assert_ref_contains "## Directory Redirection"
  assert_ref_contains "## Skill and Customization Discovery"
  assert_ref_contains "## Authentication Diagnostics"
  assert_ref_contains "## Shared Host Resources"
  assert_ref_contains "## Sandbox and Permission Modes"
  assert_ref_contains "## Versions and Onboarding"
  assert_ref_contains "## Troubleshooting and Gaps"
}

@test "omp reference: targets omp and records the profile directories" {
  assert_file_exists "$REF"

  assert_ref_contains "omp"
  assert_ref_contains "oh-my-pi"
  assert_ref_contains "~/.omp/agent"
  assert_ref_contains ".omp/agent"
  assert_ref_contains "PI_CODING_AGENT_DIR"
  assert_ref_contains "Pi"
}

@test "omp reference: records the verified skill locations and the shared agents root" {
  assert_file_exists "$REF"

  assert_ref_contains ".omp/agent/skills"
  assert_ref_contains ".agents/skills"
  assert_ref_contains "ancestor"
}

@test "omp reference: separates agent state, environment names and unverified login" {
  assert_file_exists "$REF"

  assert_ref_contains "agent.db"
  assert_ref_contains "environment variable name"
  assert_ref_contains "not proof of account separation"
}

@test "omp reference: names shared resources, sandbox modes, versions and gaps" {
  assert_file_exists "$REF"

  assert_ref_contains "mise"
  assert_ref_contains "daemon"
  assert_ref_contains "Tested version"
  assert_ref_contains "18.20.0"
  assert_ref_contains "credential-dependent"
}

@test "omp reference: uses agent-profile domain terms without author home paths" {
  assert_file_exists "$REF"

  assert_ref_contains "Host environment"
  assert_ref_contains "Agent profile"

  run grep -E "/home/[a-z0-9_-]+" "$REF"
  assert_failure
}
