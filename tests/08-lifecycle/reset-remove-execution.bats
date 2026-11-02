#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  load '../helpers/platform.bash'
  setup_isolation
}

teardown() {
  # Long-lived lease holders are registered when they start; a failed assertion
  # must stop exactly those and nothing else.
  ap_test_teardown_owned
  teardown_isolation
}

@test "execution: reset --yes is blocked by active run lease on same profile with exit 75" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile profa
  run bash "$AP_HELPER" init --profile profb
  assert_success

  # Start a run in profa holding the shared lease. The holder signals that it is
  # executing and the lease is confirmed by a refused exclusive probe, so a slow
  # helper start cannot slip past a fixed sleep and let reset win.
  local lease_dir="$TEST_TMPDIR/lease-fixtures"
  local holder_script
  holder_script=$(ap_test_lease_holder_script "$lease_dir")
  local lock_file="$fixture_repo/.agent-profiles/.locks/profa.lock"
  ap_test_start_lease_holder "$AP_HELPER" profa "$holder_script" \
    "$TEST_TMPDIR/profa-started" "$TEST_TMPDIR/profa-release" "$TEST_TMPDIR/profa-holder.log"
  local bg_pid=$AP_TEST_LEASE_PID

  # Reset on profa must fail with 75 because profa lease is held
  run bash "$AP_HELPER" reset --profile profa --yes
  assert_failure 75

  # Reset on profb must succeed because profb is not locked
  run bash "$AP_HELPER" reset --profile profb --yes
  assert_success

  ap_test_release_lease_holder "$TEST_TMPDIR/profa-release" "$bg_pid" "$lock_file"
}

@test "execution: reset --yes recreates empty directories while preserving other profiles" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile prof1
  run bash "$AP_HELPER" init --profile prof2
  assert_success

  local prof1_dir="$fixture_repo/.agent-profiles/prof1"
  local prof2_dir="$fixture_repo/.agent-profiles/prof2"

  # Populate both profiles
  echo "prof1 data" >"$prof1_dir/.config/data.txt"
  echo "prof1 bin" >"$prof1_dir/bin/tool"
  echo "prof2 data" >"$prof2_dir/.config/data.txt"
  echo "prof2 tool" >"$prof2_dir/bin/tool"

  local prof2_hash_before
  prof2_hash_before=$(ap_test_tree_digest "$prof2_dir")

  run bash "$AP_HELPER" reset --profile prof1 --yes
  assert_success

  # Verify prof1 was reset to empty structure with required dirs
  assert_dir_exists "$prof1_dir/home"
  assert_dir_exists "$prof1_dir/.config"
  assert_dir_exists "$prof1_dir/bin"
  assert_dir_exists "$prof1_dir/.claude"
  assert_file_exists "$prof1_dir/.agent-profile"
  [[ ! -f "$prof1_dir/.config/data.txt" ]]
  [[ ! -f "$prof1_dir/bin/tool" ]]

  # Verify prof2 is completely untouched
  local prof2_hash_after
  prof2_hash_after=$(ap_test_tree_digest "$prof2_dir")
  assert_equal "$prof2_hash_before" "$prof2_hash_after"
}

@test "execution: remove --yes deletes target profile and preserves other profiles and project files" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile prof1
  run bash "$AP_HELPER" init --profile prof2
  assert_success

  local prof1_dir="$fixture_repo/.agent-profiles/prof1"
  local prof2_dir="$fixture_repo/.agent-profiles/prof2"

  echo "prof1 data" >"$prof1_dir/.config/data.txt"
  echo "prof2 data" >"$prof2_dir/.config/data.txt"
  echo "mise config" >"$fixture_repo/mise.local.toml"
  echo "# Untracked project file" >"$fixture_repo/project_scratch.txt"

  local prof2_hash_before
  prof2_hash_before=$(ap_test_tree_digest "$prof2_dir")

  run bash "$AP_HELPER" remove --profile prof1 --yes
  assert_success

  # prof1 must be completely removed
  [[ ! -d "$prof1_dir" ]]

  # prof2 must remain completely intact
  assert_dir_exists "$prof2_dir"
  local prof2_hash_after
  prof2_hash_after=$(ap_test_tree_digest "$prof2_dir")
  assert_equal "$prof2_hash_before" "$prof2_hash_after"

  # Project files and local mise config must remain untouched
  assert_file_exists "$fixture_repo/mise.local.toml"
  assert_file_exists "$fixture_repo/project_scratch.txt"
}

@test "execution: journal recorded during mutation and fault injection leaves journal" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile faultprof
  assert_success

  # Inject fault after trashed state
  run env AP_FAULT_AFTER=trashed bash "$AP_HELPER" reset --profile faultprof --yes
  assert_failure 137

  # Journal file must exist under .journal/
  local journal_file="$fixture_repo/.agent-profiles/.journal/reset-faultprof.json"
  assert_file_exists "$journal_file"

  # Validate journal content
  python3 -c '
import json, sys
with open(sys.argv[1], "r") as f:
    data = json.load(f)
assert data["op"] == "reset"
assert data["profile"] == "faultprof"
assert data["state"] == "trashed"
assert "trash_path" in data
assert "boot_id" in data
' "$journal_file"
}

@test "execution: remove preserves unrelated Git exclusion lines" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile prof1
  assert_success

  local exclude_file
  exclude_file=$(git rev-parse --git-path info/exclude)
  [[ "$exclude_file" != /* ]] && exclude_file="$fixture_repo/$exclude_file"
  printf '# foreign exclusion\n*.log\n' >>"$exclude_file"

  run bash "$AP_HELPER" remove --profile prof1 --yes
  assert_success

  run grep -Fx '*.log' "$exclude_file"
  assert_success
  run grep -Fx '# foreign exclusion' "$exclude_file"
  assert_success
  run grep -Fxc '/.agent-profiles/' "$exclude_file"
  assert_success
  assert_equal "$output" "1"
}
