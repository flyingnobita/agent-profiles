#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  load '../helpers/platform.bash'
  setup_isolation
  TEST_BG_PIDS=()
}

teardown() {
  if [[ ${#TEST_BG_PIDS[@]} -gt 0 ]]; then
    for pid in ${TEST_BG_PIDS[@]+"${TEST_BG_PIDS[@]}"}; do
      [[ -n "$pid" ]] || continue
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
  teardown_isolation
}

# start_open_profile_descriptor <profile-dir> [NAME=VALUE...]:
# Starts a process that keeps a descriptor open inside the profile. On Darwin no
# process may read another process's environment, so an open descriptor inside
# the profile and the inherited profile lease are the markers a live profile user
# actually leaves behind there. Prints the pid.
start_open_profile_descriptor() {
  local prof_dir="$1"
  shift
  (
    exec 8>"$prof_dir/home/activity.marker"
    exec env "$@" sleep 60
  ) </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

# wait_for_active_process_refusal <helper arguments...>:
# Runs the helper until the process scan refuses, leaving that run in
# $status/$output. Polling replaces a sleep-based guess at how long a descriptor
# takes to become visible to the inspector.
wait_for_active_process_refusal() {
  local attempt=0
  while [[ "$attempt" -lt 80 ]]; do
    run bash "$AP_HELPER" "$@"
    if [[ "$status" -eq 75 && "$output" == *"refused: active process"* ]]; then
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

@test "procscan: detects active process with AGENT_PROFILES_DIR and refuses with exit 75" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile targetprof
  assert_success

  local prof_dir="$fixture_repo/.agent-profiles/targetprof"

  # Darwin has no way to read another process's environment, so an environment
  # marker alone is invisible there by design. The markers a live profile user
  # does leave on Darwin are an open descriptor inside the profile and the
  # inherited profile lease; prove the refusal through that evidence there.
  if ap_test_is_darwin; then
    local holder
    holder=$(start_open_profile_descriptor "$prof_dir")
    TEST_BG_PIDS+=("$holder")

    wait_for_active_process_refusal reset --profile targetprof
    assert_failure 75
    assert_output_contains "refused: active process"
    assert_output_contains "$holder"
    return 0
  fi

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

  # Start an fd-closing child (e.g. daemon that closes all fds) in its own
  # session. Python start_new_session replaces setsid, which stock macOS lacks.
  # Darwin has no way to read another process's environment, so an environment
  # marker alone is invisible there by design. The markers a live profile user
  # does leave on Darwin are an open descriptor inside the profile and the
  # inherited profile lease; prove the refusal through that evidence there.
  if ap_test_is_darwin; then
    local holder
    holder=$(start_open_profile_descriptor "$prof_dir")
    TEST_BG_PIDS+=("$holder")

    wait_for_active_process_refusal reset --profile targetprof
    assert_failure 75
    assert_output_contains "refused: active process"
    assert_output_contains "$holder"
    return 0
  fi

  local bg_pid
  bg_pid=$(ap_test_spawn_detached 10 "AGENT_PROFILES_DIR=$prof_dir")
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

  # Darwin has no way to read another process's environment, so an environment
  # marker alone is invisible there by design. The markers a live profile user
  # does leave on Darwin are an open descriptor inside the profile and the
  # inherited profile lease; prove the refusal through that evidence there.
  if ap_test_is_darwin; then
    local holder
    holder=$(start_open_profile_descriptor "$prof_dir")
    TEST_BG_PIDS+=("$holder")

    wait_for_active_process_refusal reset --profile targetprof
    assert_failure 75
    assert_output_contains "refused: active process"
    assert_output_contains "$holder"
    return 0
  fi

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

  if ap_test_is_darwin; then
    # The same secret sits in the environment and in argv of a process that
    # keeps a descriptor open inside the profile, so a leak through either the
    # process table or the descriptor listing would be visible.
    local holder
    (
      exec 8>"$prof_dir/home/activity.marker"
      exec env SECRET_KEY="$secret_marker" sh -c 'sleep 60' sh "$secret_marker"
    ) </dev/null >/dev/null 2>&1 &
    holder=$!
    TEST_BG_PIDS+=("$holder")

    wait_for_active_process_refusal reset --profile targetprof
    assert_failure 75
    assert_output_contains "$holder"
    # The Darwin inspector reports a pid and a command name only: no environment
    # value and no command line. Darwin cannot read them in the first place.
    assert_output_not_contains "$secret_marker"
    return 0
  fi

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
  # This fixture is a synthetic procfs tree, so it only exists on Linux. Darwin
  # has no procfs at all and its fail-closed process inspection is proven in
  # darwin-procscan.bats.
  ap_test_skip_darwin "Linux-only S9: synthetic procfs relevant-unknown fixture; Darwin fail-closed coverage is in darwin-procscan.bats"

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

@test "procscan: migrate refuses while a live process uses a legacy source directory" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"
  mkdir -p "$fixture_repo/.agent-sandbox/.claude"
  echo "legacy content" >"$fixture_repo/.agent-sandbox/home/file.txt"

  # Old inline-layout usage: a process with its working directory inside the
  # legacy source, not the new profile storage.
  local live_pid
  live_pid=$(ap_test_spawn_in_dir "$fixture_repo/.agent-sandbox/.claude" "$TEST_TMPDIR/procscan-cwd.marker" 60)
  ap_test_wait_for_file "$TEST_TMPDIR/procscan-cwd.marker"

  run bash "$AP_HELPER" migrate --yes
  assert_failure 75
  assert_output_contains "PID $live_pid"
  assert_output_contains "legacy storage"

  # The live legacy data was not moved.
  assert_file_exists "$fixture_repo/.agent-sandbox/home/file.txt"
  [[ ! -e "$fixture_repo/.agent-profiles/default" ]]

  kill -TERM -"$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true

  run bash "$AP_HELPER" migrate --yes
  assert_success
  [[ ! -e "$fixture_repo/.agent-sandbox" ]]
}
