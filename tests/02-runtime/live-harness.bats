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

@test "live harness: setup isolation preserves effective mise directories and resets auth/config overrides" {
  local lib_sh="$AP_SUBJECT/tests/live/lib.sh"
  assert_file_exists "$lib_sh"
  # shellcheck source=/dev/null
  source "$lib_sh"

  # Set host-like variables that must be cleared
  export ANTHROPIC_API_KEY="sk-ant-test-secret"
  export OPENAI_API_KEY="sk-proj-test-secret"
  export CODEX_HOME="$TEST_TMPDIR/fake-codex"
  export CLAUDE_CONFIG_DIR="$TEST_TMPDIR/fake-claude"

  local iso_dir="$TEST_TMPDIR/live_iso"
  ap_live_setup_isolation "$iso_dir"

  # Secrets and config overrides must be cleared
  [[ -z "${ANTHROPIC_API_KEY:-}" ]]
  [[ -z "${OPENAI_API_KEY:-}" ]]
  [[ -z "${CODEX_HOME:-}" ]]
  [[ -z "${CLAUDE_CONFIG_DIR:-}" ]]

  # Synthetic home and XDG dirs configured
  assert_equal "$HOME" "$iso_dir/home"
  assert_equal "$XDG_CONFIG_HOME" "$iso_dir/config"
  assert_equal "$XDG_DATA_HOME" "$iso_dir/data"

  # If mise was present, MISE_DATA_DIR should be preserved from host
  if command -v mise >/dev/null 2>&1; then
    [[ -n "${MISE_DATA_DIR:-}" ]]
  fi
}

@test "live harness: synthetic home verification preserves private checksums and detects file mutations without printing secrets" {
  local lib_sh="$AP_SUBJECT/tests/live/lib.sh"
  assert_file_exists "$lib_sh"
  # shellcheck source=/dev/null
  source "$lib_sh"

  local test_home="$TEST_TMPDIR/synth_home"
  ap_live_create_synthetic_home "$test_home"

  # Checksum file must have private permissions (0600)
  local perm
  perm=$(stat -c "%a" "$test_home/.checksums.sha256")
  assert_equal "$perm" "600"

  # Untouched verification must succeed
  run ap_live_verify_host_untouched "$test_home"
  assert_success

  # Mutate with a secret marker
  echo "super-secret-token" >> "$test_home/.claude/settings.json"

  # Verification must fail and MUST NOT output the secret contents
  run ap_live_verify_host_untouched "$test_home"
  assert_failure
  assert_output_not_contains "super-secret-token"
}

@test "live harness: cleanup_pgid requires test-owned marker and process identity and rejects unrelated PGID" {
  local lib_sh="$AP_SUBJECT/tests/live/lib.sh"
  assert_file_exists "$lib_sh"
  # shellcheck source=/dev/null
  source "$lib_sh"

  local marker_file="$TEST_TMPDIR/test_pgid.marker"

  # 1. Reject missing or empty marker
  run ap_live_cleanup_pgid 12345 ""
  assert_failure

  # 2. Reject root/init process (PGID 1)
  printf "1\n" > "$marker_file"
  run ap_live_cleanup_pgid 1 "$marker_file"
  assert_failure

  # 3. Reject mismatched marker
  printf "99999\n" > "$marker_file"
  run ap_live_cleanup_pgid 88888 "$marker_file"
  assert_failure

  # 4. Successfully clean up test-spawned process group
  local child_pgid
  child_pgid=$(ap_live_spawn_test_process "$marker_file" sleep 30)
  [[ -n "$child_pgid" ]]
  assert_file_exists "$marker_file"

  # Process group must be running
  kill -0 -"$child_pgid" 2>/dev/null

  # Cleanup with matching marker and process identity
  run ap_live_cleanup_pgid "$child_pgid" "$marker_file"
  assert_success

  # Process group must now be dead
  sleep 0.2
  ! kill -0 -"$child_pgid" 2>/dev/null
}
