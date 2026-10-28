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

@test "claude live harness: script exists, parses and documents its evidence contract" {
  local script="$AP_SUBJECT/tests/live/claude.sh"
  assert_file_exists "$script"

  run bash -n "$script"
  assert_success

  run bash "$script" --help
  assert_success
  assert_output_contains "AP_EVIDENCE_DIR"
  assert_output_contains "tests/live/claude.sh"
}

@test "claude live harness: requires a private evidence directory" {
  local script="$AP_SUBJECT/tests/live/claude.sh"

  run env -u AP_EVIDENCE_DIR bash "$script"
  assert_failure 64
  assert_output_contains "AP_EVIDENCE_DIR is required"
}
