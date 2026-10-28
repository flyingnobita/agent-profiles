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

@test "opencode live harness: script exists, parses and documents its evidence contract" {
  local script="$AP_SUBJECT/tests/live/opencode.sh"
  assert_file_exists "$script"

  run bash -n "$script"
  assert_success

  run bash "$script" --help
  assert_success
  assert_output_contains "AP_EVIDENCE_DIR"
  assert_output_contains "tests/live/opencode.sh"
}

@test "opencode live harness: requires a private evidence directory" {
  local script="$AP_SUBJECT/tests/live/opencode.sh"

  run env -u AP_EVIDENCE_DIR bash "$script"
  assert_failure 64
  assert_output_contains "AP_EVIDENCE_DIR is required"
}

@test "opencode live harness: uses standalone servers, offline isolation and owned cleanup" {
  local script="$AP_SUBJECT/tests/live/opencode.sh"
  assert_file_exists "$script"

  run grep -F -- "--standalone" "$script"
  assert_success
  run grep -F -- "--unshare-net" "$script"
  assert_success
  run grep -F -- "env -i" "$script"
  assert_success
  run grep -F -- "ap_live_setup_isolation" "$script"
  assert_success
  run grep -F -- "ap_live_cleanup_pgid" "$script"
  assert_success
  run grep -F -- "/api/skill" "$script"
  assert_success
  run grep -F -- "service status" "$script"
  assert_success
}
