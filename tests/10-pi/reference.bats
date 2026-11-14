#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation

  REF="$AP_SKILL_DIR/references/agents/pi.md"
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

@test "pi reference: documents the required profile sections" {
  assert_file_exists "$REF"

  assert_ref_contains "## Directory Redirection"
  assert_ref_contains "## Skill and Customization Discovery"
  assert_ref_contains "## Authentication Diagnostics"
  assert_ref_contains "## Shared Host Resources"
  assert_ref_contains "## Sandbox and Permission Modes"
  assert_ref_contains "## Versions and Onboarding"
  assert_ref_contains "## Troubleshooting and Gaps"
}

@test "pi reference: targets pi and records the profile directories" {
  assert_file_exists "$REF"

  assert_ref_contains "pi"
  assert_ref_contains "~/.pi/agent"
  assert_ref_contains ".pi/agent"
  assert_ref_contains "PI_CODING_AGENT_DIR"
  assert_ref_contains "oh-my-pi"
}

@test "pi reference: records the verified skill locations and the shared agents root" {
  assert_file_exists "$REF"

  assert_ref_contains ".pi/agent/skills"
  assert_ref_contains ".pi/skills"
  assert_ref_contains ".agents/skills"
  assert_ref_contains "ancestor"
}

@test "pi reference: separates profile files, environment names and unverified state" {
  assert_file_exists "$REF"

  assert_ref_contains "auth.json"
  assert_ref_contains "environment variable name"
  assert_ref_contains "not proof of account separation"
}

@test "pi reference: names shared resources, sandbox modes, versions and gaps" {
  assert_file_exists "$REF"

  assert_ref_contains "mise"
  assert_ref_contains "project trust"
  assert_ref_contains "Tested version"
  assert_ref_contains "1.5.2"
  assert_ref_contains "credential-dependent"
}

@test "pi reference: uses agent-profile domain terms without author home paths" {
  assert_file_exists "$REF"

  assert_ref_contains "Host environment"
  assert_ref_contains "Agent profile"

  run grep -E "/home/[a-z0-9_-]+" "$REF"
  assert_failure
}
