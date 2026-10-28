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

@test "guard: nested same-profile run executes without re-wrapping and dedupes PATH" {
  local repo="$TEST_TMPDIR/repo-nested-same"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile nested-same
  assert_success

  run bash "$AP_HELPER" run --profile nested-same -- bash "$AP_HELPER" run --profile nested-same -- python3 -c '
import os
path = os.environ["PATH"].split(":")
prof_dir = os.environ["AGENT_PROFILES_DIR"]
bin_dir = os.path.join(prof_dir, "bin")

# Check that bin_dir appears exactly once in PATH
count = path.count(bin_dir)
assert count == 1, f"expected bin_dir to appear once, appeared {count} times: {path}"
print("NESTED_SAME_OK")
'
  assert_success
  assert_output_contains "NESTED_SAME_OK"
}

@test "nested: different-profile nested run refuses with exit 75" {
  local repo="$TEST_TMPDIR/repo-nested-diff"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile prof-a
  assert_success
  run bash "$AP_HELPER" init --profile prof-b
  assert_success

  run bash "$AP_HELPER" run --profile prof-a -- bash "$AP_HELPER" run --profile prof-b -- echo ok
  assert_failure
  assert_equal "$status" 75
  assert_output_contains "nested execution"
}

@test "nested: different checkout with same profile name refuses with exit 75" {
  local repo_a="$TEST_TMPDIR/repo-cross-a"
  local repo_b="$TEST_TMPDIR/repo-cross-b"
  create_fixture_repo "$repo_a"
  create_fixture_repo "$repo_b"

  cd "$repo_a"
  run bash "$AP_HELPER" init --profile default
  assert_success

  cd "$repo_b"
  run bash "$AP_HELPER" init --profile default
  assert_success

  # From inside repo_a's container, cd to repo_b and attempt to run default
  cd "$repo_a"
  run bash "$AP_HELPER" run --profile default -- sh -c '
    cd "'"$repo_b"'"
    bash "'"$AP_HELPER"'" run --profile default -- echo "should_not_run"
  '
  assert_failure
  assert_equal "$status" 75
  assert_output_contains "nested execution"
}

@test "nested: operates correctly in git checkout containing spaces in path" {
  local repo_spaces="$TEST_TMPDIR/repo with spaces in path"
  create_fixture_repo "$repo_spaces"
  cd "$repo_spaces"

  run bash "$AP_HELPER" init --profile default
  assert_success

  run bash "$AP_HELPER" run --profile default -- bash "$AP_HELPER" run --profile default -- python3 -c '
import os
assert "repo with spaces in path" in os.environ["AGENT_PROFILES_DIR"]
print("SPACES_OK")
'
  assert_success
  assert_output_contains "SPACES_OK"
}

@test "nested: spurious inherited AGENT_PROFILES_DIR without live mount is ignored and reset" {
  local repo="$TEST_TMPDIR/repo-nested-spurious"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile target-prof
  assert_success

  run env \
    AGENT_PROFILES_DIR="/tmp/spurious-profile" \
    AGENT_PROFILES_NAME="spurious" \
    AGENT_SANDBOX_DIR="/tmp/spurious-sandbox" \
    bash "$AP_HELPER" run --profile target-prof -- python3 -c '
import os
assert os.environ["AGENT_PROFILES_NAME"] == "target-prof"
assert "/tmp/spurious" not in os.environ["AGENT_PROFILES_DIR"]
print("SPURIOUS_RESET_OK")
'
  assert_success
  assert_output_contains "SPURIOUS_RESET_OK"
}

@test "aliasing: rejects symlinked profile root with exit 73" {
  local repo="$TEST_TMPDIR/repo-alias-symlink"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile base-prof
  assert_success

  # Symlink alias-prof to base-prof
  ln -s "$repo/.agent-profiles/base-prof" "$repo/.agent-profiles/alias-prof"

  run bash "$AP_HELPER" run --profile alias-prof -- echo ok
  assert_failure
  assert_equal "$status" 73
  assert_output_contains "symbolic link"
}

@test "guard: concurrent runs in different profiles execute in parallel without conflict" {
  local repo="$TEST_TMPDIR/repo-concurrency"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile worker-a
  assert_success
  run bash "$AP_HELPER" init --profile worker-b
  assert_success

  # Start two concurrent runs in parallel with sleep
  bash "$AP_HELPER" run --profile worker-a -- sleep 1 &
  local pid_a=$!

  bash "$AP_HELPER" run --profile worker-b -- sleep 1 &
  local pid_b=$!

  wait "$pid_a"
  local status_a=$?

  wait "$pid_b"
  local status_b=$?

  assert_equal "$status_a" 0
  assert_equal "$status_b" 0
}
