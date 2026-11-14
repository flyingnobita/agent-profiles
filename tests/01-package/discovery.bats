#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation
}

teardown() {
  teardown_isolation
}

@test "discovery: skill package directory exists in subject" {
  assert_dir_exists "$AP_SKILL_DIR"
}

@test "discovery: npx skills add --list discovers agent-profiles" {
  run skills add "$AP_SUBJECT" --list
  assert_success
  # The listing names the skill after its directory, and "agent-profiles" is a
  # suffix of the old prefixed name, so the old name must be absent too.
  assert_output_contains "agent-profiles"
  assert_output_not_contains "flyingnobita-agent-profiles"
}
