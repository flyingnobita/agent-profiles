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

@test "locks: run acquires shared profile lease that blocks exclusive lock during execution" {
  local repo="$TEST_TMPDIR/repo-lock-lease"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  local lock_file="$repo/.agent-profiles/.locks/default.lock"
  assert_file_exists "$lock_file"

  # Start run with sleep in background
  bash "$AP_HELPER" run -- sleep 2 &
  local bg_pid=$!

  # Give it a moment to enter bwrap and acquire lock
  sleep 0.4

  # Attempt exclusive lock on profile lock file - must fail while run is active
  run flock -n -x "$lock_file" true
  assert_failure

  # Wait for background run to finish
  wait "$bg_pid"

  # Now exclusive lock must succeed
  run flock -n -x "$lock_file" true
  assert_success
}

@test "locks: shared lease survives parent exit and is held by background child process" {
  local repo="$TEST_TMPDIR/repo-lock-descendant"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  local lock_file="$repo/.agent-profiles/.locks/default.lock"
  local pid_file="$TEST_TMPDIR/child.pid"

  # Launch command that spawns background child keeping inherited fds, then parent exits
  bash "$AP_HELPER" run -- sh -c 'sleep 5 & echo $! > "'"$pid_file"'"'
  assert_file_exists "$pid_file"
  local child_pid
  child_pid=$(cat "$pid_file")
  [[ -n "$child_pid" ]]

  # Exclusive lock must fail because child process holds inherited lease fd
  run flock -n -x "$lock_file" true
  assert_failure

  # Kill child process
  kill -9 "$child_pid" 2>/dev/null || true
  wait "$child_pid" 2>/dev/null || true
  sleep 0.2

  # Now exclusive lock must succeed
  run flock -n -x "$lock_file" true
  assert_success
}

@test "locks: records boot_id and start_ticks in runs file" {
  local repo="$TEST_TMPDIR/repo-lock-runs"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile test-runs
  assert_success

  run bash "$AP_HELPER" run --profile test-runs -- true
  assert_success

  local runs_file="$repo/.agent-profiles/.locks/test-runs.runs"
  assert_file_exists "$runs_file"

  local last_line
  last_line=$(tail -n 1 "$runs_file")
  # Must contain boot_id (UUID-like) and numeric start_ticks
  [[ "$last_line" =~ ^[0-9a-fA-F-]+[[:space:]]+[0-9]+$ ]]
}

@test "locks: rejects symlinked .locks directory with exit 73" {
  local repo="$TEST_TMPDIR/repo-lock-symlink"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  local target_locks="$TEST_TMPDIR/custom_locks"
  mkdir -p "$target_locks"
  rm -rf "$repo/.agent-profiles/.locks"
  ln -s "$target_locks" "$repo/.agent-profiles/.locks"

  run bash "$AP_HELPER" run -- true
  assert_failure
  assert_equal "$status" 73
  assert_output_contains ".locks"
}

@test "preflight: executes preflight hooks and aborts if hook fails" {
  local repo="$TEST_TMPDIR/repo-preflight"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  # Inject a failing preflight hook into preflight.d
  local hook_dir="$AP_SKILL_DIR/scripts/lib/preflight.d"
  mkdir -p "$hook_dir"
  cat <<'EOF' > "$hook_dir/99-test-fail.sh"
#!/usr/bin/env bash
ap_die 77 "preflight test hook failed"
EOF
  chmod +x "$hook_dir/99-test-fail.sh"

  run bash "$AP_HELPER" run -- true
  rm -f "$hook_dir/99-test-fail.sh"

  assert_failure
  assert_equal "$status" 77
  assert_output_contains "preflight test hook failed"
}
