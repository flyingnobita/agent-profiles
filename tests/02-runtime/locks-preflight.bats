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

@test "locks: run acquires shared profile lease that blocks exclusive lock during execution" {
  local repo="$TEST_TMPDIR/repo-lock-lease"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  local lock_file="$repo/.agent-profiles/.locks/default.lock"
  assert_file_exists "$lock_file"

  # The holder signals that it is executing and the lease is observed by a
  # refused exclusive probe, so the check needs neither a fixed sleep nor a
  # fixed command lifetime.
  local holder_script
  holder_script=$(ap_test_lease_holder_script "$TEST_TMPDIR/lease-fixtures")
  local release="$TEST_TMPDIR/lease-release"
  ap_test_start_lease_holder "$AP_HELPER" default "$holder_script" \
    "$TEST_TMPDIR/lease-started.marker" "$release" "$TEST_TMPDIR/lease-holder.log"
  local bg_pid=$AP_TEST_LEASE_PID

  # Attempt exclusive lock on profile lock file - must fail while run is active
  run ap_test_try_lock "$lock_file"
  assert_failure

  ap_test_release_lease_holder "$release" "$bg_pid" "$lock_file"

  # Now exclusive lock must succeed
  run ap_test_try_lock "$lock_file"
  assert_success
}

@test "locks: a lease holder is observed as held even when helper startup is delayed" {
  local repo="$TEST_TMPDIR/repo-lock-slow-start"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  local lock_file="$repo/.agent-profiles/.locks/default.lock"

  # Deliberate startup delay at the public seam: every helper invocation spends
  # a second in repository discovery before it can take the lease. A fixture
  # that slept a fixed 0.5-0.6 s here (the pattern the hosted macOS runner
  # broke) asserts against a lease that does not exist yet. Readiness must come
  # from the command's own start plus the refused exclusive probe.
  local slow_bin="$TEST_TMPDIR/slow-start-bin"
  local real_git
  real_git=$(command -v git)
  mkdir -p "$slow_bin"
  cat >"$slow_bin/git" <<SHIM
#!/usr/bin/env bash
sleep 1
exec "$real_git" "\$@"
SHIM
  chmod +x "$slow_bin/git"
  export PATH="$slow_bin:$PATH"

  local holder_script
  holder_script=$(ap_test_lease_holder_script "$TEST_TMPDIR/lease-fixtures")
  local release="$TEST_TMPDIR/slow-release"
  ap_test_start_lease_holder "$AP_HELPER" default "$holder_script" \
    "$TEST_TMPDIR/slow-started" "$release" "$TEST_TMPDIR/slow-holder.log"
  local bg_pid=$AP_TEST_LEASE_PID

  run bash "$AP_HELPER" reset --profile default --yes
  assert_failure 75
  assert_output_contains "in use"

  ap_test_release_lease_holder "$release" "$bg_pid" "$lock_file"

  run bash "$AP_HELPER" reset --profile default --yes
  assert_success
}

@test "locks: an aborted lease fixture leaves no owned holder or descendant behind" {
  # Failure path, not the happy path: a long-lived holder is started, readiness
  # is reached, and then the test aborts with a failing assertion - so only
  # teardown can clean up. The probe runs in a nested Bats process, which is the
  # only way to observe what a test's own teardown did after it failed.
  local probe="$TEST_TMPDIR/failure-path.bats"
  local pid_record="$TEST_TMPDIR/aborted-holder.pid"
  local child_record="$TEST_TMPDIR/aborted-child.pid"
  local helpers_dir
  helpers_dir=$(cd "$BATS_TEST_DIRNAME/../helpers" && pwd -P)

  # The leak this guards is the Darwin one: there is no bubblewrap sandbox, so
  # nothing else ends a forgotten holder when its parent test dies. The probe
  # therefore runs the env-only adapter with bwrap genuinely absent from PATH.
  local no_bwrap="$TEST_TMPDIR/no-bwrap-bin"
  mkdir -p "$no_bwrap"
  # shellcheck source=tests/helpers/restricted-path.bash
  source "$BATS_TEST_DIRNAME/../helpers/restricted-path.bash"
  ap_test_restricted_bin "$no_bwrap" bwrap

  cat >"$probe" <<'PROBE'
#!/usr/bin/env bats
setup() {
  source "$AP_TEST_HELPERS/isolation.bash"
  source "$AP_TEST_HELPERS/fixtures.bash"
  source "$AP_TEST_HELPERS/platform.bash"
  setup_isolation
  export PATH="$AP_TEST_NO_BWRAP_PATH"
  export AP_TEST_PLATFORM_OS=Darwin
}

teardown() {
  ap_test_teardown_owned
  teardown_isolation
}

@test "fixture aborts after readiness" {
  local repo="$TEST_TMPDIR/abort-repo"
  create_fixture_repo "$repo"
  cd "$repo"
  local helper="$AP_SKILL_DIR/scripts/agent-profiles"
  # This is the no-bwrap Darwin adapter: nothing else can end a forgotten holder.
  [ -z "$(command -v bwrap)" ]
  bash "$helper" init --profile default >/dev/null

  local script
  script=$(ap_test_lease_holder_script "$TEST_TMPDIR/lease-fixtures")
  local lock_file="$repo/.agent-profiles/.locks/default.lock"

  ap_test_start_lease_holder "$helper" default "$script" \
    "$TEST_TMPDIR/holder-started" "$TEST_TMPDIR/holder-release" "$TEST_TMPDIR/holder.log"
  printf '%s\n' "$AP_TEST_LEASE_PID" >"$AP_TEST_PID_RECORD"
  ap_test_lease_wait_held "$lock_file" 300

  ap_test_start_lease_descendant "$helper" default "$script" \
    "$TEST_TMPDIR/child-started" "$TEST_TMPDIR/child-release" \
    "$TEST_TMPDIR/child.pid" "$TEST_TMPDIR/descendant.log"
  cat "$TEST_TMPDIR/child.pid" >"$AP_TEST_CHILD_RECORD"

  # Deliberate failure after both fixtures reached readiness.
  false
}
PROBE

  run ap_test_timeout 180 env AP_TEST_HELPERS="$helpers_dir" \
    AP_TEST_NO_BWRAP_PATH="$no_bwrap" \
    AP_TEST_PID_RECORD="$pid_record" AP_TEST_CHILD_RECORD="$child_record" \
    "$(command -v bats)" "$probe"
  assert_failure
  assert_output_contains "fixture aborts after readiness"

  local holder child
  holder=$(cat "$pid_record")
  child=$(cat "$child_record")
  [[ -n "$holder" && -n "$child" ]]
  [[ "$holder" != "$child" ]]

  # Neither the holder nor its background descendant may survive the aborted
  # test: the nested teardown stops the registered holder, the registered
  # descendant, and releases nothing outside the registry.
  ap_test_wait_pid_gone "$holder"
  ap_test_wait_pid_gone "$child"
}

@test "locks: a lease holder cannot outlive its bounded fixture lifetime" {
  # Last-resort bound, for the case where the owning test process is killed
  # before teardown can run: the holder's own hard lifetime ends it. The fixture
  # is started directly and never signalled by this test.
  local script
  script=$(ap_test_lease_holder_script "$TEST_TMPDIR/lease-fixtures")
  local marker="$TEST_TMPDIR/bounded-started"
  local release="$TEST_TMPDIR/bounded-release"
  sh "$script" "$marker" "$release" 2 </dev/null >"$TEST_TMPDIR/bounded.log" 2>&1 &
  local pid=$!
  ap_test_register_owned_pid "$pid"
  ap_test_wait_for_file "$marker" 100
  ap_test_pid_running "$pid"

  ap_test_wait_pid_gone "$pid" 150
  wait "$pid" 2>/dev/null || true
}

@test "locks: shared lease survives parent exit and is held by background child process" {
  local repo="$TEST_TMPDIR/repo-lock-descendant"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  local lock_file="$repo/.agent-profiles/.locks/default.lock"
  local pid_file="$TEST_TMPDIR/child.pid"

  # Launch command that spawns a background child keeping the inherited lease
  # descriptor, then the parent exits. The descendant is bounded by a release
  # file and a hard lifetime, registered for teardown, and readiness waits for
  # its start marker plus a refused exclusive probe.
  local holder_script
  holder_script=$(ap_test_lease_holder_script "$TEST_TMPDIR/lease-fixtures")
  local marker="$TEST_TMPDIR/descendant-started"
  local release="$TEST_TMPDIR/descendant-release"
  ap_test_start_lease_descendant "$AP_HELPER" default "$holder_script" \
    "$marker" "$release" "$pid_file" "$TEST_TMPDIR/descendant.log"
  local child_pid
  child_pid=$(cat "$pid_file")
  [[ -n "$child_pid" ]]

  # Exclusive lock must fail because child process holds inherited lease fd
  run ap_test_try_lock "$lock_file"
  assert_failure

  # Kill child process and wait for the lease to be observably released.
  ap_test_stop_owned_pid "$child_pid"
  ap_test_wait_pid_gone "$child_pid"
  ap_test_lease_wait_free "$lock_file"

  # Now exclusive lock must succeed
  run ap_test_try_lock "$lock_file"
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

# disposable_skill_copy <dir>: copies the shipped skill so a test can inject a
# preflight hook without writing into the checkout. The suite stays safe to run
# concurrently and leaves the source tree byte-identical.
disposable_skill_copy() {
  local dir="$1"
  mkdir -p "$dir"
  cp -a "$AP_SKILL_DIR"/* "$dir/"
  printf '%s\n' "$dir/scripts/agent-profiles"
}

@test "preflight: executes preflight hooks and aborts if hook fails" {
  local repo="$TEST_TMPDIR/repo-preflight"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  local helper
  helper=$(disposable_skill_copy "$TEST_TMPDIR/disposable-preflight")

  # Inject a failing preflight hook into the disposable copy.
  local hook_dir="$TEST_TMPDIR/disposable-preflight/scripts/lib/preflight.d"
  mkdir -p "$hook_dir"
  cat <<'HOOK' >"$hook_dir/99-test-fail.sh"
#!/usr/bin/env bash
ap_die 77 "preflight test hook failed"
HOOK
  chmod +x "$hook_dir/99-test-fail.sh"

  run bash "$helper" run -- true

  assert_failure
  assert_equal "$status" 77
  assert_output_contains "preflight test hook failed"
}

@test "preflight: executes preflight hooks during init and list and nested run" {
  local repo="$TEST_TMPDIR/repo-preflight-lifecycle"
  create_fixture_repo "$repo"
  cd "$repo"

  local helper
  helper=$(disposable_skill_copy "$TEST_TMPDIR/disposable-preflight-lifecycle")

  local hook_dir="$TEST_TMPDIR/disposable-preflight-lifecycle/scripts/lib/preflight.d"
  mkdir -p "$hook_dir"
  cat <<'HOOK' >"$hook_dir/99-test-fail.sh"
#!/usr/bin/env bash
ap_die 77 "preflight test hook failed"
HOOK
  chmod +x "$hook_dir/99-test-fail.sh"

  # 1. init must fail due to preflight
  run bash "$helper" init
  assert_failure
  assert_equal "$status" 77
  assert_output_contains "preflight test hook failed"

  # 2. list must fail due to preflight
  run bash "$helper" list
  assert_failure
  assert_equal "$status" 77
  assert_output_contains "preflight test hook failed"

  # Remove hook, init profile cleanly
  rm -f "$hook_dir/99-test-fail.sh"
  run bash "$helper" init
  assert_success

  # Re-inject hook; nested run must also execute preflight
  cat <<'HOOK' >"$hook_dir/99-test-fail.sh"
#!/usr/bin/env bash
ap_die 77 "preflight test hook failed"
HOOK
  chmod +x "$hook_dir/99-test-fail.sh"

  run bash "$helper" run -- bash "$helper" run -- true
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
