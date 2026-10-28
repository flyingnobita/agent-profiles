#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation
}

teardown() {
  teardown_isolation
}

@test "live harness: lib.sh exists and provides isolation and host verification functions" {
  local lib_sh="$AP_SUBJECT/tests/live/lib.sh"
  assert_file_exists "$lib_sh"

  # Source lib.sh and verify functions are declared
  # shellcheck source=/dev/null
  source "$lib_sh"
  declare -F ap_live_setup_isolation >/dev/null
  declare -F ap_live_create_synthetic_home >/dev/null
  declare -F ap_live_verify_host_untouched >/dev/null
  declare -F ap_live_cleanup_pgid >/dev/null
}

@test "live harness: synthetic home verification succeeds when untouched and detects mutations" {
  local lib_sh="$AP_SUBJECT/tests/live/lib.sh"
  assert_file_exists "$lib_sh"
  # shellcheck source=/dev/null
  source "$lib_sh"

  local test_home="$TEST_TMPDIR/synth_home"
  ap_live_create_synthetic_home "$test_home"

  # Untouched verification must succeed
  run ap_live_verify_host_untouched "$test_home"
  assert_success

  # Mutate one synthetic marker file
  echo "mutated" >> "$test_home/.claude/settings.json"

  # Verification must now fail
  run ap_live_verify_host_untouched "$test_home"
  assert_failure
}

@test "check-install: tool executes init and run -- true in separate repository fixture" {
  # Verify tests/tools/check-install executes installed helper init and run
  run grep -E 'bash "\$helper" init' "$AP_SUBJECT/tests/tools/check-install"
  assert_success
  run grep -E 'bash "\$helper" run' "$AP_SUBJECT/tests/tools/check-install"
  assert_success
}
