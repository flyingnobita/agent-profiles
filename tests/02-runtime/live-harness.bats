#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  unset AGENT_PROFILES_DIR
}

teardown() {
  local marker pgid
  for marker in "$TEST_TMPDIR"/*.marker; do
    [[ -f "$marker" ]] || continue
    pgid=$(awk -F= '$1 == "pgid" { print $2; exit }' "$marker")
    if [[ ! "$pgid" =~ ^[0-9]+$ ]]; then
      pgid=$(tr -d '[:space:]' <"$marker" 2>/dev/null || true)
    fi
    if [[ "$pgid" =~ ^[0-9]+$ ]]; then
      kill -KILL -"$pgid" 2>/dev/null || true
    fi
  done
  teardown_isolation
}

force_stop_group() {
  local pgid="$1"
  kill -TERM -"$pgid" 2>/dev/null || true
  sleep 0.1
  kill -KILL -"$pgid" 2>/dev/null || true
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
  echo "super-secret-token" >>"$test_home/.claude/settings.json"

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
  printf "1\n" >"$marker_file"
  run ap_live_cleanup_pgid 1 "$marker_file"
  assert_failure

  # 3. Reject mismatched marker
  printf "99999\n" >"$marker_file"
  run ap_live_cleanup_pgid 88888 "$marker_file" "$TEST_TMPDIR/test-profile"
  assert_failure

  # 4. Successfully clean up test-spawned process group
  local profile_dir="$TEST_TMPDIR/test-profile"
  mkdir -p "$profile_dir"
  local child_pgid
  child_pgid=$(AGENT_PROFILES_DIR="$profile_dir" ap_live_spawn_test_process "$marker_file" sleep 30)
  [[ -n "$child_pgid" ]]
  assert_file_exists "$marker_file"

  # Process group must be running
  kill -0 -"$child_pgid" 2>/dev/null

  # Cleanup with matching marker and process identity
  run ap_live_cleanup_pgid "$child_pgid" "$marker_file" "$profile_dir"
  assert_success

  # Process group must now be dead
  sleep 0.2
  if kill -0 -"$child_pgid" 2>/dev/null; then
    echo "process group $child_pgid survived cleanup" >&2
    return 1
  fi
}

@test "live harness: cleanup_pgid handles a multi-process group with one UID" {
  local lib_sh="$AP_SUBJECT/tests/live/lib.sh"
  assert_file_exists "$lib_sh"
  # shellcheck source=/dev/null
  source "$lib_sh"

  local profile_dir="$TEST_TMPDIR/owned-profile"
  mkdir -p "$profile_dir"

  local marker_file="$TEST_TMPDIR/multiprocess.marker"
  local child_pgid
  child_pgid=$(AGENT_PROFILES_DIR="$profile_dir" ap_live_spawn_test_process "$marker_file" bash -c 'sleep 30 & sleep 30 & wait')

  # The group has the shell plus two sleeps, all under one UID.
  [[ "$(ps -o pid= -g "$child_pgid" | wc -l)" -ge 3 ]]
  kill -0 -"$child_pgid" 2>/dev/null

  run ap_live_cleanup_pgid "$child_pgid" "$marker_file" "$profile_dir"
  assert_success

  sleep 0.2
  if kill -0 -"$child_pgid" 2>/dev/null; then
    echo "process group $child_pgid survived cleanup" >&2
    return 1
  fi
}

@test "live harness: cleanup_pgid refuses a group without the QA profile marker" {
  local lib_sh="$AP_SUBJECT/tests/live/lib.sh"
  assert_file_exists "$lib_sh"
  # shellcheck source=/dev/null
  source "$lib_sh"

  local marker_file="$TEST_TMPDIR/unmarked.marker"
  local child_pgid
  child_pgid=$(ap_live_spawn_test_process "$marker_file" sleep 30)

  run ap_live_cleanup_pgid "$child_pgid" "$marker_file" "$TEST_TMPDIR/unowned-profile"
  assert_failure
  assert_output_contains "AGENT_PROFILES_DIR"
  kill -0 -"$child_pgid" 2>/dev/null

  force_stop_group "$child_pgid"
}

@test "live harness: cleanup_pgid refuses a marker whose process identity was reused" {
  local lib_sh="$AP_SUBJECT/tests/live/lib.sh"
  assert_file_exists "$lib_sh"
  # shellcheck source=/dev/null
  source "$lib_sh"

  local profile_dir="$TEST_TMPDIR/reused-profile"
  mkdir -p "$profile_dir"

  local marker_file="$TEST_TMPDIR/reused.marker"
  local child_pgid
  child_pgid=$(AGENT_PROFILES_DIR="$profile_dir" ap_live_spawn_test_process "$marker_file" sleep 30)

  # Valid structure and target, but the recorded process start time is wrong.
  printf 'pgid=%s\nleader_pid=%s\nboot_id=%s\nstart_ticks=1\nuid=%s\n' \
    "$child_pgid" "$child_pgid" "$(cat /proc/sys/kernel/random/boot_id)" "$(id -u)" \
    >"$marker_file"

  run ap_live_cleanup_pgid "$child_pgid" "$marker_file" "$profile_dir"
  assert_failure
  assert_output_contains "identity"
  kill -0 -"$child_pgid" 2>/dev/null

  force_stop_group "$child_pgid"
}

@test "live harness: cleanup_pgid refuses a structured marker for a different group" {
  local lib_sh="$AP_SUBJECT/tests/live/lib.sh"
  assert_file_exists "$lib_sh"
  # shellcheck source=/dev/null
  source "$lib_sh"

  local profile_dir="$TEST_TMPDIR/mismatched-profile"
  mkdir -p "$profile_dir"

  local marker_file="$TEST_TMPDIR/mismatched.marker"
  local child_pgid
  child_pgid=$(AGENT_PROFILES_DIR="$profile_dir" ap_live_spawn_test_process "$marker_file" sleep 30)

  sed -i 's/^pgid=.*/pgid=999999/' "$marker_file"

  run ap_live_cleanup_pgid "$child_pgid" "$marker_file" "$profile_dir"
  assert_failure
  assert_output_contains "does not match target"
  kill -0 -"$child_pgid" 2>/dev/null

  force_stop_group "$child_pgid"
}
