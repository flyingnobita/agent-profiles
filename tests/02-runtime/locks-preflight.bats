#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation
}

teardown() {
  rm -f "$AP_SKILL_DIR/scripts/lib/preflight.d/99-test-fail.sh"
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

@test "locks: rejects symlinked lock and runs files with exit 73 and preserves outside sentinel" {
  local repo="$TEST_TMPDIR/repo-lock-file-symlink"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  local outside_dir="$TEST_TMPDIR/outside_locks"
  mkdir -p "$outside_dir"
  printf "original-sentinel\n" > "$outside_dir/default.lock"

  # Replace lock file with symlink pointing outside
  rm -f "$repo/.agent-profiles/.locks/default.lock"
  ln -s "$outside_dir/default.lock" "$repo/.agent-profiles/.locks/default.lock"

  run bash "$AP_HELPER" run -- true
  assert_failure
  assert_equal "$status" 73
  assert_output_contains "symbolic link"

  # Outside sentinel must remain untouched
  local content
  content=$(cat "$outside_dir/default.lock")
  assert_equal "$content" "original-sentinel"

  # Also test runs file symlink
  rm -f "$repo/.agent-profiles/.locks/default.lock"
  touch "$repo/.agent-profiles/.locks/default.lock"
  printf "original-runs\n" > "$outside_dir/default.runs"
  rm -f "$repo/.agent-profiles/.locks/default.runs"
  ln -s "$outside_dir/default.runs" "$repo/.agent-profiles/.locks/default.runs"

  run bash "$AP_HELPER" run -- true
  assert_failure
  assert_equal "$status" 73
  assert_output_contains "symbolic link"
  assert_equal "$(cat "$outside_dir/default.runs")" "original-runs"
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

@test "preflight: executes preflight hooks during init and list and nested run" {
  local repo="$TEST_TMPDIR/repo-preflight-lifecycle"
  create_fixture_repo "$repo"
  cd "$repo"

  local hook_dir="$AP_SKILL_DIR/scripts/lib/preflight.d"
  mkdir -p "$hook_dir"
  cat <<'EOF' > "$hook_dir/99-test-fail.sh"
#!/usr/bin/env bash
ap_die 77 "preflight test hook failed"
EOF
  chmod +x "$hook_dir/99-test-fail.sh"

  # 1. init must fail due to preflight
  run bash "$AP_HELPER" init
  assert_failure
  assert_equal "$status" 77
  assert_output_contains "preflight test hook failed"

  # 2. list must fail due to preflight
  run bash "$AP_HELPER" list
  assert_failure
  assert_equal "$status" 77
  assert_output_contains "preflight test hook failed"

  # Remove hook, init profile cleanly
  rm -f "$hook_dir/99-test-fail.sh"
  run bash "$AP_HELPER" init
  assert_success

  # Re-inject hook; nested run must also execute preflight
  cat <<'EOF' > "$hook_dir/99-test-fail.sh"
#!/usr/bin/env bash
ap_die 77 "preflight test hook failed"
EOF
  chmod +x "$hook_dir/99-test-fail.sh"

  run bash "$AP_HELPER" run -- bash "$AP_HELPER" run -- true
  rm -f "$hook_dir/99-test-fail.sh"
  assert_failure
  assert_equal "$status" 77
  assert_output_contains "preflight test hook failed"
}

@test "modular: sources shipped agent modules and executes declared ap_agent_env hook in disposable package copy" {
  local repo="$TEST_TMPDIR/repo-agent-env"
  create_fixture_repo "$repo"
  cd "$repo"

  # Create disposable copy of skill package
  local disp_skill="$TEST_TMPDIR/disp_skill"
  mkdir -p "$disp_skill"
  cp -a "$AP_SKILL_DIR"/* "$disp_skill/"

  # Add synthetic agent env hook to lib/agents/claude.sh in disposable copy
  cat <<'EOF' >> "$disp_skill/scripts/lib/agents/claude.sh"

ap_agent_env_claude() {
  local prof_dir="$1"
  export SYNTHETIC_CLAUDE_LOADED="active:$prof_dir"
}
EOF

  local disp_helper="$disp_skill/scripts/agent-profiles"
  chmod +x "$disp_helper"

  run bash "$disp_helper" init
  assert_success

  run bash "$disp_helper" run -- sh -c 'echo "$SYNTHETIC_CLAUDE_LOADED"'
  assert_success
  assert_output_contains "active:$repo/.agent-profiles/default"
}
