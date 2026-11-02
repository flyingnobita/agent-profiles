#!/usr/bin/env bats
# Darwin live-harness ownership and cleanup without procfs.
#
# The live harness must prove UID, profile ownership, process-group identity and
# start/boot identity before it signals anything, and it must refuse a reused
# identity instead of killing a stranger. macOS has no procfs and stock bash 3.2
# has no mapfile/associative arrays, so identity comes from stock ps plus the
# shipped standard-library adapter, and the Darwin inspection branch is selected
# through the internal AP_TEST_PLATFORM_OS seam (see platform.sh).
#
# Red evidence: the base live harness reads /proc unconditionally and has no
# portable identity primitive, so this test fails on the base subject on Linux
# as well (ap_live_pid_identity does not exist there). The behaviour it exists
# for - complete ownership proof with no procfs at all - is only exercised on
# real Darwin by the macOS job and the MBP-M4 run; a green Linux run proves
# branch selection and the ps/lsof contract, never stock macOS itself.
# shellcheck disable=SC2030,SC2031

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  unset AGENT_PROFILES_DIR
}

teardown() {
  local pid
  for pid in ${AP_LIVE_TEST_GROUPS:-}; do
    kill -KILL -"$pid" 2>/dev/null || true
  done
  teardown_isolation
}

force_stop_group() {
  local pgid="$1"
  kill -TERM -"$pgid" 2>/dev/null || true
  sleep 0.1
  kill -KILL -"$pgid" 2>/dev/null || true
}

@test "darwin live cleanup: owned process groups survive parent exit and reused identities are refused without procfs" {
  local lib_sh="$AP_SUBJECT/tests/live/lib.sh"
  assert_file_exists "$lib_sh"
  # shellcheck source=/dev/null
  source "$lib_sh"

  # Select the Darwin inspection branch: procfs must not be required.
  export AP_TEST_PLATFORM_OS=Darwin
  AP_LIVE_TEST_GROUPS=""

  local profile_dir="$TEST_TMPDIR/darwin-owned-profile"
  mkdir -p "$profile_dir"
  export AGENT_PROFILES_DIR="$profile_dir"

  local marker="$TEST_TMPDIR/darwin-owned.marker"
  local spawner_pid_file="$TEST_TMPDIR/darwin-spawner.pid"
  local pgid=""
  # Spawn from an intermediate shell that exits at once: the only thing that
  # still identifies the group afterwards is its recorded identity.
  pgid=$(bash -c 'source "$1"; shift; printf "%s\n" "$$" >"$1"; shift; ap_live_spawn_test_process "$@"' \
    _ "$lib_sh" "$spawner_pid_file" "$marker" bash -c 'sleep 30 & sleep 30 & wait')
  [[ "$pgid" =~ ^[0-9]+$ ]]
  AP_LIVE_TEST_GROUPS="$AP_LIVE_TEST_GROUPS $pgid"

  local spawner_pid
  spawner_pid=$(cat "$spawner_pid_file")
  run kill -0 "$spawner_pid"
  assert_failure
  run kill -0 -"$pgid"
  assert_success

  # The recorded identity is the platform-native one, and it matches.
  local recorded_boot recorded_start recorded_uid identity seen_pgid seen_start
  recorded_boot=$(ap_live_marker_field "$marker" boot_id)
  recorded_start=$(ap_live_marker_field "$marker" start_ticks)
  recorded_uid=$(ap_live_marker_field "$marker" uid)
  assert_equal "$recorded_boot" "$(ap_live_boot_identity)"
  assert_equal "$recorded_uid" "$(id -u)"
  identity=$(ap_live_pid_identity "$pgid")
  read -r seen_pgid seen_start <<<"$identity"
  assert_equal "$seen_pgid" "$pgid"
  assert_equal "$seen_start" "$recorded_start"
  assert_equal "$(ap_live_pid_uid "$pgid")" "$(id -u)"

  # Cleanup signals only after every check passed, and the whole group dies.
  run ap_live_cleanup_pgid "$pgid" "$marker" "$profile_dir"
  assert_success
  sleep 0.2
  run kill -0 -"$pgid"
  assert_failure
  assert_equal "$(ap_live_pgid_members "$pgid" | wc -l | tr -d ' ')" "0"
  [[ ! -f "$marker" ]]

  # A reused identity is refused: the marker names a different start identity.
  local reused_marker="$TEST_TMPDIR/darwin-reused.marker"
  local reused_pgid=""
  reused_pgid=$(ap_live_spawn_test_process "$reused_marker" sleep 30)
  AP_LIVE_TEST_GROUPS="$AP_LIVE_TEST_GROUPS $reused_pgid"
  printf 'pgid=%s\nleader_pid=%s\nboot_id=%s\nstart_ticks=%s\nuid=%s\n' \
    "$reused_pgid" "$reused_pgid" "$(ap_live_boot_identity)" "1" "$(id -u)" >"$reused_marker"

  run ap_live_cleanup_pgid "$reused_pgid" "$reused_marker" "$profile_dir"
  assert_failure
  assert_output_contains "process identity"
  run kill -0 -"$reused_pgid"
  assert_success
  force_stop_group "$reused_pgid"

  # A marker from a different boot is refused as well.
  local boot_marker="$TEST_TMPDIR/darwin-boot.marker"
  local boot_pgid=""
  boot_pgid=$(ap_live_spawn_test_process "$boot_marker" sleep 30)
  AP_LIVE_TEST_GROUPS="$AP_LIVE_TEST_GROUPS $boot_pgid"
  local boot_pgid_identity boot_start
  boot_pgid_identity=$(ap_live_pid_identity "$boot_pgid")
  read -r _ boot_start <<<"$boot_pgid_identity"
  printf 'pgid=%s\nleader_pid=%s\nboot_id=%s\nstart_ticks=%s\nuid=%s\n' \
    "$boot_pgid" "$boot_pgid" "darwin-1.0" "$boot_start" "$(id -u)" >"$boot_marker"

  run ap_live_cleanup_pgid "$boot_pgid" "$boot_marker" "$profile_dir"
  assert_failure
  assert_output_contains "boot identity"
  run kill -0 -"$boot_pgid"
  assert_success
  force_stop_group "$boot_pgid"

  # A group that does not carry the QA profile is refused, not signalled.
  local unowned_marker="$TEST_TMPDIR/darwin-unowned.marker"
  local unowned_pgid=""
  unowned_pgid=$(env -u AGENT_PROFILES_DIR bash -c 'source "$1"; shift; ap_live_spawn_test_process "$@"' \
    _ "$lib_sh" "$unowned_marker" sleep 30)
  AP_LIVE_TEST_GROUPS="$AP_LIVE_TEST_GROUPS $unowned_pgid"
  run ap_live_cleanup_pgid "$unowned_pgid" "$unowned_marker" "$profile_dir"
  assert_failure
  assert_output_contains "AGENT_PROFILES_DIR"
  run kill -0 -"$unowned_pgid"
  assert_success
  force_stop_group "$unowned_pgid"
}
