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

@test "discovery: npx skills add --list discovers flyingnobita-agent-profiles" {
  run skills add "$AP_SUBJECT" --list
  assert_success
  assert_output_contains "flyingnobita-agent-profiles"
}
