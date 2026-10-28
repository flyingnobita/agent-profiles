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

@test "init: creates default profile with private permissions and required subdirectories" {
  local repo="$TEST_TMPDIR/repo-init-default"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init
  assert_success

  local prof_dir="$repo/.agent-profiles/default"
  assert_dir_exists "$prof_dir"
  assert_file_exists "$prof_dir/.agent-profile"

  # Required subdirectories
  local subdirs=(.claude .codex .gemini .agents .opencode home bin npm-global uv-tools cargo-global python-user .config .local/share .local/state .cache)
  for sub in "${subdirs[@]}"; do
    assert_dir_exists "$prof_dir/$sub"
  done

  # Private permissions (0700)
  local mode_storage
  mode_storage=$(stat -c "%a" "$repo/.agent-profiles")
  assert_equal "$mode_storage" "700"

  local mode_profile
  mode_profile=$(stat -c "%a" "$prof_dir")
  assert_equal "$mode_profile" "700"
}

@test "init: creates custom named profile with --profile and --profile= syntax" {
  local repo="$TEST_TMPDIR/repo-init-custom"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile worker_1
  assert_success
  assert_dir_exists "$repo/.agent-profiles/worker_1/home"

  run bash "$AP_HELPER" init --profile=worker-2
  assert_success
  assert_dir_exists "$repo/.agent-profiles/worker-2/home"
}

@test "init: rejects invalid profile names with exit 65" {
  local repo="$TEST_TMPDIR/repo-init-invalid"
  create_fixture_repo "$repo"
  cd "$repo"

  # Test invalid names: uppercase, starts with digit, traversal, hyphen start, slash, space, too long (>32)
  local invalid_names=("" "Worker" "1worker" "-worker" "a/b" ".." "a b" "toolongnamethatexceedsthirtytwocharacters")
  for name in "${invalid_names[@]}"; do
    run bash "$AP_HELPER" init --profile "$name"
    assert_failure
    assert_equal "$status" 65
    assert_output_contains "invalid profile name"
  done
}

@test "init: fails with exit 66 outside of a git checkout" {
  local non_git="$TEST_TMPDIR/non-git-dir"
  mkdir -p "$non_git"
  cd "$non_git"

  run bash "$AP_HELPER" init
  assert_failure
  assert_equal "$status" 66
  assert_output_contains "not a git repository"
}

@test "init: resolves Git root from subdirectory and preserves exclude" {
  local repo="$TEST_TMPDIR/repo-init-subdir"
  create_fixture_repo "$repo"
  mkdir -p "$repo/sub/deep/dir"
  cd "$repo/sub/deep/dir"

  run bash "$AP_HELPER" init --profile subtest
  assert_success

  # Storage created at repo root, not in sub/deep/dir
  assert_dir_exists "$repo/.agent-profiles/subtest/home"
  [[ ! -d "$repo/sub/deep/dir/.agent-profiles" ]]

  # Check info/exclude has /.agent-profiles/ anchored entry
  local exclude_file
  exclude_file=$(git -C "$repo" rev-parse --git-path info/exclude)
  [[ "$exclude_file" != /* ]] && exclude_file="$repo/$exclude_file"
  assert_file_exists "$exclude_file"
  run grep -Fx '/.agent-profiles/' "$exclude_file"
  assert_success

  # Porcelain status is clean
  run git -C "$repo" status --porcelain
  assert_success
  assert_equal "$output" ""
}

@test "init: supports separate Git worktrees with distinct profiles" {
  local repo="$TEST_TMPDIR/repo-main"
  create_fixture_repo "$repo"
  local wt="$TEST_TMPDIR/repo-wt"
  git -C "$repo" worktree add "$wt" -b wt-branch

  cd "$wt"
  run bash "$AP_HELPER" init --profile wt-prof
  assert_success

  assert_dir_exists "$wt/.agent-profiles/wt-prof"
  [[ ! -d "$repo/.agent-profiles/wt-prof" ]]
}

@test "init: is idempotent and does not duplicate exclude entries" {
  local repo="$TEST_TMPDIR/repo-init-idem"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile test-prof
  assert_success

  # Write dummy marker in profile home
  echo "preserved" > "$repo/.agent-profiles/test-prof/home/marker.txt"

  # Run init again
  run bash "$AP_HELPER" init --profile test-prof
  assert_success

  # Check marker preserved
  assert_file_exists "$repo/.agent-profiles/test-prof/home/marker.txt"
  local marker
  marker=$(cat "$repo/.agent-profiles/test-prof/home/marker.txt")
  assert_equal "$marker" "preserved"

  # Check exclude has exactly one /.agent-profiles/ entry
  local exclude_file
  exclude_file=$(git -C "$repo" rev-parse --git-path info/exclude)
  [[ "$exclude_file" != /* ]] && exclude_file="$repo/$exclude_file"
  local count
  count=$(grep -Fxc '/.agent-profiles/' "$exclude_file")
  assert_equal "$count" "1"
}

@test "list: lists initialized profiles in text and json mode and ignores reserved dot dirs" {
  local repo="$TEST_TMPDIR/repo-list"
  create_fixture_repo "$repo"
  cd "$repo"

  # Initialize default and two named profiles
  run bash "$AP_HELPER" init
  assert_success
  run bash "$AP_HELPER" init --profile alpha
  assert_success
  run bash "$AP_HELPER" init --profile beta
  assert_success

  # Create reserved dot directories
  mkdir -p "$repo/.agent-profiles/.locks" "$repo/.agent-profiles/.journal" "$repo/.agent-profiles/.trash"

  # Test text list
  run bash "$AP_HELPER" list
  assert_success
  assert_output_contains "alpha"
  assert_output_contains "beta"
  assert_output_contains "default"
  assert_output_not_contains ".locks"
  assert_output_not_contains ".journal"
  assert_output_not_contains ".trash"

  # Test json list
  run bash "$AP_HELPER" list --json
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert "profiles" in data
profiles = data["profiles"]
assert "alpha" in profiles
assert "beta" in profiles
assert "default" in profiles
assert not any(p.startswith(".") for p in profiles)
' "$output"
}
