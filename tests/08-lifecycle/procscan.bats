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

@test "procscan: detects active process with AGENT_PROFILES_DIR and refuses with exit 75" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile targetprof
  assert_success

  local prof_dir="$fixture_repo/.agent-profiles/targetprof"

  # Start a test-owned background process simulating an active agent session
  AGENT_PROFILES_DIR="$prof_dir" sleep 10 </dev/null >/dev/null 2>&1 &
  local bg_pid=$!
  TEST_BG_PIDS+=("$bg_pid")

  run bash "$AP_HELPER" reset --profile targetprof
  assert_failure 75
  assert_output_contains "refused: active process"
  assert_output_contains "$bg_pid"
  assert_output_contains "sleep"

  kill -9 "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
}

@test "procscan: detects active process holding open fd in profile directory and refuses with exit 75" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile targetprof
  assert_success

  local prof_dir="$fixture_repo/.agent-profiles/targetprof"

  # Start a process that opens a file inside the profile directory
  (
    exec 8>"$prof_dir/home/activity.marker"
    sleep 10
  ) </dev/null >/dev/null 2>&1 &
  local bg_pid=$!
  TEST_BG_PIDS+=("$bg_pid")

  run bash "$AP_HELPER" remove --profile targetprof
  assert_failure 75
  assert_output_contains "refused: active process"
  assert_output_contains "$bg_pid"

  kill -9 "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
}

@test "procscan: detects fd-closing process with AGENT_PROFILES_DIR in environment" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile targetprof
  assert_success

  local prof_dir="$fixture_repo/.agent-profiles/targetprof"

  # Start an fd-closing child (e.g. daemon that closes all fds)
  AGENT_PROFILES_DIR="$prof_dir" setsid sh -c 'exec 0<&- 1>&- 2>&-; sleep 10' </dev/null >/dev/null 2>&1 &
  local bg_pid=$!
  TEST_BG_PIDS+=("$bg_pid")

  run bash "$AP_HELPER" reset --profile targetprof
  assert_failure 75
  assert_output_contains "refused: active process"
  assert_output_contains "$bg_pid"

  kill -9 "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
}

@test "procscan: detects legacy AGENT_SANDBOX_DIR process and refuses with exit 75" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile targetprof
  assert_success

  local prof_dir="$fixture_repo/.agent-profiles/targetprof"

  AGENT_SANDBOX_DIR="$prof_dir" sleep 10 </dev/null >/dev/null 2>&1 &
  local bg_pid=$!
  TEST_BG_PIDS+=("$bg_pid")

  run bash "$AP_HELPER" reset --profile targetprof
  assert_failure 75
  assert_output_contains "refused: active process"
  assert_output_contains "$bg_pid"

  kill -9 "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
}

@test "procscan: never leaks cmdline arguments or environment variable values in output" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile targetprof
  assert_success

  local prof_dir="$fixture_repo/.agent-profiles/targetprof"
  local secret_marker="SUPER_SECRET_TOKEN_DO_NOT_LEAK_12345"

  AGENT_PROFILES_DIR="$prof_dir" SECRET_KEY="$secret_marker" sh -c "sleep 10" --with-arg="$secret_marker" </dev/null >/dev/null 2>&1 &
  local bg_pid=$!
  TEST_BG_PIDS+=("$bg_pid")

  run bash "$AP_HELPER" reset --profile targetprof
  assert_failure 75
  assert_output_contains "$bg_pid"
  assert_output_not_contains "$secret_marker"

  kill -9 "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
}

@test "procscan: ignores unrelated background processes" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile targetprof
  run bash "$AP_HELPER" init --profile otherprof
  assert_success

  local other_dir="$fixture_repo/.agent-profiles/otherprof"

  AGENT_PROFILES_DIR="$other_dir" sleep 10 </dev/null >/dev/null 2>&1 &
  local bg_pid=$!
  TEST_BG_PIDS+=("$bg_pid")

  # reset on targetprof should NOT be blocked by process running in otherprof
  run bash "$AP_HELPER" reset --profile targetprof
  # It should succeed or show preview (status 0), not refuse with 75
  assert_success
  assert_output_not_contains "$bg_pid"

  kill -9 "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
}

@test "procscan: detects uninspectable orphaned process under AP_PROC_ROOT as relevant-unknown" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile targetprof
  assert_success

  # Simulate a synthetic /proc root with an uninspectable orphaned process 99999
  local fake_proc="$TEST_TMPDIR/fake_proc"
  mkdir -p "$fake_proc/99999"
  # comm
  printf "orphaned_daemon\n" >"$fake_proc/99999/comm"
  # stat: field 1 pid, field 2 (comm), field 3 state, field 4 ppid (1 = orphan), ... field 22 starttime
  printf "99999 (orphaned_daemon) S 1 99999 99999 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 100000 0 0 0\n" >"$fake_proc/99999/stat"
  # status: PPid: 1, Uid: $(id -u)
  printf "Name:\torphaned_daemon\nPPid:\t1\nUid:\t%s\t%s\t%s\t%s\n" "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" >"$fake_proc/99999/status"
  # environ, fd, cwd unreadable (non-existent or chmod 000)
  touch "$fake_proc/99999/environ"
  chmod 000 "$fake_proc/99999/environ" 2>/dev/null || rm -f "$fake_proc/99999/environ"

  run env AP_PROC_ROOT="$fake_proc" bash "$AP_HELPER" reset --profile targetprof
  assert_failure 75
  assert_output_contains "99999"
  assert_output_contains "orphaned_daemon"
  assert_output_contains "relevant-unknown"

  # With --assume-unrelated 99999, it proceeds past process scan
  run env AP_PROC_ROOT="$fake_proc" bash "$AP_HELPER" reset --profile targetprof --assume-unrelated 99999
  assert_success
}
