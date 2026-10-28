#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation

  REF="$AP_SKILL_DIR/references/agents/opencode.md"
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

@test "opencode reference: documents the required profile sections" {
  assert_file_exists "$REF"

  assert_ref_contains "## Directory Redirection"
  assert_ref_contains "## Configuration Diagnostics"
  assert_ref_contains "## Skill Discovery"
  assert_ref_contains "## Authentication Diagnostics"
  assert_ref_contains "## Server Isolation"
  assert_ref_contains "## Versions and Troubleshooting"
}

@test "opencode reference: records the verified OPENCODE_CONFIG_DIR replacement behavior" {
  assert_file_exists "$REF"

  assert_ref_contains "OPENCODE_CONFIG_DIR"
  assert_ref_contains "replaces"
  assert_ref_contains "additive"
  assert_ref_contains "debug paths"
  assert_ref_contains "debug config"
}

@test "opencode reference: records the verified skill sources and surfaces" {
  assert_file_exists "$REF"

  assert_ref_contains "/api/skill"
  assert_ref_contains "the second request"
  assert_ref_contains "debug agents"
  assert_ref_contains ".opencode/skills"
  assert_ref_contains ".claude/skills"
  assert_ref_contains ".agents/skills"
  assert_ref_contains "/builtin/"
  assert_ref_contains "mention"
}

@test "opencode reference: separates profile, environment and shared authentication sources" {
  assert_file_exists "$REF"

  assert_ref_contains "auth list"
  assert_ref_contains "credential"
  assert_ref_contains "environment variable name"
  assert_ref_contains "not proof of account separation"
  assert_ref_contains "must not be copied"
}

@test "opencode reference: names server isolation, versions and remaining gaps" {
  assert_file_exists "$REF"

  assert_ref_contains "--standalone"
  assert_ref_contains "service status"
  assert_ref_contains "49374"
  assert_ref_contains "shared"
  assert_ref_contains "Tested version"
  assert_ref_contains "2.2.0"
  assert_ref_contains "credential-dependent gap"
  assert_ref_contains "not verified"
}

@test "opencode reference: uses agent-profile domain terms without author home paths" {
  assert_file_exists "$REF"

  assert_ref_contains "Host environment"
  assert_ref_contains "Agent profile"

  run grep -E "/home/[a-z0-9_-]+" "$REF"
  assert_failure
}
