#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  TEST_BG_PIDS=()
}

teardown() {
  if [[ ${#TEST_BG_PIDS[@]} -gt 0 ]]; then
    for pid in "${TEST_BG_PIDS[@]}"; do
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
  teardown_isolation
}

@test "execution: reset --yes is blocked by active run lease on same profile with exit 75" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile profa
  run bash "$AP_HELPER" init --profile profb
  assert_success

  # Start a background run in profa holding the shared lease
  bash "$AP_HELPER" run --profile profa -- sleep 10 </dev/null >/dev/null 2>&1 &
  local bg_pid=$!
  TEST_BG_PIDS+=("$bg_pid")

  # Wait briefly for process and lease to be established
  sleep 0.5

  # Reset on profa must fail with 75 because profa lease is held
  run bash "$AP_HELPER" reset --profile profa --yes
  assert_failure 75

  # Reset on profb must succeed because profb is not locked
  run bash "$AP_HELPER" reset --profile profb --yes
  assert_success

  kill -9 "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
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
  prof2_hash_before=$(find "$prof2_dir" -type f -exec sha256sum {} + | sort | sha256sum)

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
  prof2_hash_after=$(find "$prof2_dir" -type f -exec sha256sum {} + | sort | sha256sum)
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
  prof2_hash_before=$(find "$prof2_dir" -type f -exec sha256sum {} + | sort | sha256sum)

  run bash "$AP_HELPER" remove --profile prof1 --yes
  assert_success

  # prof1 must be completely removed
  [[ ! -d "$prof1_dir" ]]

  # prof2 must remain completely intact
  assert_dir_exists "$prof2_dir"
  local prof2_hash_after
  prof2_hash_after=$(find "$prof2_dir" -type f -exec sha256sum {} + | sort | sha256sum)
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
