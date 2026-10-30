#!/usr/bin/env bats
# Darwin process safety for destructive lifecycle operations.
#
# macOS has no procfs, so the process scan must come from stock /bin/ps,
# /usr/sbin/sysctl and /usr/sbin/lsof through the platform adapter, and it must
# fail closed when that inspection is not available. A Linux host cannot run
# Darwin, so these tests select the Darwin inspector through the internal
# AP_TEST_PLATFORM_OS seam (see platform.sh) and move the Darwin inspection
# tools through the internal AP_DARWIN_LSOF/AP_DARWIN_PS seams. The seams are
# honoured only inside the test suite, are not user-facing options and are not
# documented supported variables. A green run on Linux therefore proves branch
# selection and the ps/lsof contract only; it is never evidence of stock macOS
# bash 3.2, BSD userland or the Darwin kernel. That evidence belongs to the
# macOS job and the MBP-M4 run.
# shellcheck disable=SC2030,SC2031

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  TEST_BG_PIDS=()
  # A path that never exists: with the Darwin inspector selected, procfs must
  # not be consulted at all.
  AP_DARWIN_TEST_NO_PROCFS="$TEST_TMPDIR/no-procfs"
}

teardown() {
  local pid
  if [[ ${#TEST_BG_PIDS[@]} -gt 0 ]]; then
    for pid in "${TEST_BG_PIDS[@]}"; do
      [[ -n "$pid" ]] || continue
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
  teardown_isolation
}

# spawn_lease_session <repo> <profile> <pid-file> <holder-var>:
# Starts a profile run session whose direct parent exits at once, so only the
# inherited profile lease descriptor keeps the session marker alive.
spawn_lease_session() {
  local repo="$1" profile="$2" pid_file="$3"
  (
    cd "$repo" || exit 1
    # shellcheck disable=SC2016
    AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" \
      bash "$AP_HELPER" run --profile "$profile" -- \
      sh -c 'sleep 30 >/dev/null 2>&1 & echo $! >"$1"' _ "$pid_file"
  )
}

@test "darwin procscan: an inherited profile lease blocks reset and unrelated processes do not" {
  local repo="$TEST_TMPDIR/repo-darwin-lease"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile leased
  assert_success
  run bash "$AP_HELPER" init --profile other
  assert_success
  run bash "$AP_HELPER" init --profile free
  assert_success

  local lease_file="$repo/.agent-profiles/.locks/leased.lock"
  local holder_pid_file="$TEST_TMPDIR/leased-holder.pid"
  run spawn_lease_session "$repo" leased "$holder_pid_file"
  assert_success
  assert_file_exists "$holder_pid_file"
  local holder_pid
  holder_pid=$(cat "$holder_pid_file")
  [[ "$holder_pid" =~ ^[0-9]+$ ]]
  TEST_BG_PIDS+=("$holder_pid")

  # The descendant outlived the direct parent, so the shared lease can only
  # still be open in the inherited descriptor. The Darwin inspector must name
  # that holder instead of reporting an anonymous busy profile.
  run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" bash "$AP_HELPER" reset --profile leased --yes
  assert_failure 75
  assert_output_contains "cannot acquire exclusive lock for profile 'leased'"
  assert_output_contains "PID $holder_pid"
  assert_output_contains "$lease_file"
  # The refused mutation changed nothing.
  assert_dir_exists "$repo/.agent-profiles/leased/home"

  # A second profile's live lease is unrelated and must not refuse this one.
  local other_pid_file="$TEST_TMPDIR/other-holder.pid"
  run spawn_lease_session "$repo" other "$other_pid_file"
  assert_success
  local other_pid
  other_pid=$(cat "$other_pid_file")
  TEST_BG_PIDS+=("$other_pid")

  run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" bash "$AP_HELPER" reset --profile free --yes
  assert_success
  assert_output_contains "Reset profile 'free' successfully"
  assert_output_not_contains "$other_pid"

  # Once the lease holder exits the lock is released and reset proceeds.
  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  local attempt=0
  while [[ "$attempt" -lt 60 ]]; do
    run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" bash "$AP_HELPER" reset --profile leased --yes
    [[ "$status" -eq 0 ]] && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  assert_success
  assert_output_contains "Reset profile 'leased' successfully"
}

# Waits until the Darwin inspector classifies a live holder. Leaves the refusal
# of the last probe in $output, so the caller asserts on it. Polling replaces a
# sleeps-based guess at how long an open descriptor takes to become visible.
wait_for_scan_refusal() {
  local attempt=0
  while [[ "$attempt" -lt 80 ]]; do
    run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" bash "$AP_HELPER" "$@"
    if [[ "$status" -eq 75 && "$output" == *"PID "* ]]; then
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  printf '%s\n' "no Darwin process refusal observed; last status $status: $output" >&2
  return 1
}

@test "darwin procscan: open profile files and legacy working directories refuse mutation without leaking values" {
  local repo="$TEST_TMPDIR/repo-darwin-open"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile target
  assert_success
  local prof_dir="$repo/.agent-profiles/target"
  local marker_file="$prof_dir/home/activity.marker"
  local secret="DARWIN_PROCSCAN_SECRET_7182"

  # An open descriptor inside the profile with a secret in the environment and
  # in argv: the refusal may print the PID and command name only.
  (
    exec 8>"$marker_file"
    SECRET_TOKEN="$secret" sh -c 'sleep 30' sh "$secret"
  ) </dev/null >/dev/null 2>&1 &
  local holder_pid=$!
  TEST_BG_PIDS+=("$holder_pid")

  wait_for_scan_refusal reset --profile target
  assert_output_contains "refused: active process"
  assert_output_contains "profile 'target'"
  assert_output_contains "PID $holder_pid"
  assert_output_contains "sleep"
  assert_output_not_contains "$secret"
  # Nothing was mutated and the profile is still complete.
  assert_dir_exists "$prof_dir/home"
  assert_file_exists "$marker_file"

  wait_for_scan_refusal remove --profile target --yes
  assert_output_contains "PID $holder_pid"
  assert_output_not_contains "$secret"
  assert_dir_exists "$prof_dir"

  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  # A legacy working directory is refused for migrate, and the legacy data is
  # left exactly where it was.
  mkdir -p "$repo/.agent-sandbox/home" "$repo/.agent-sandbox/.claude"
  printf 'legacy content\n' >"$repo/.agent-sandbox/home/file.txt"
  (
    cd "$repo/.agent-sandbox/.claude" || exit 1
    exec sh -c 'sleep 60' sh "$secret"
  ) </dev/null >/dev/null 2>&1 &
  local legacy_pid=$!
  TEST_BG_PIDS+=("$legacy_pid")

  wait_for_scan_refusal migrate --yes
  assert_output_contains "legacy storage"
  assert_output_contains "PID $legacy_pid"
  assert_output_not_contains "$secret"
  assert_file_exists "$repo/.agent-sandbox/home/file.txt"
  [[ ! -e "$repo/.agent-profiles/default" ]]

  kill -9 "$legacy_pid" 2>/dev/null || true
  wait "$legacy_pid" 2>/dev/null || true

  # An interrupted operation leaves data in trash: recover must refuse while a
  # process still uses that data instead of rolling the journal forward.
  mkdir -p "$repo/.agent-profiles/.trash"
  local trash_path="$repo/.agent-profiles/.trash/target.12345"
  mv "$prof_dir" "$trash_path"
  mkdir -p "$repo/.agent-profiles/.journal"
  python3 - "$repo/.agent-profiles/.journal/remove-target.json" "$trash_path" "$prof_dir" <<'PY'
import json, sys
journal, trash, profile_dir = sys.argv[1:4]
with open(journal, "w") as handle:
    json.dump({
        "op": "remove",
        "profile": "target",
        "state": "trashed",
        "profile_dir": profile_dir,
        "trash_path": trash,
        "assume_unrelated": [],
        "boot_id": "00000000-0000-0000-0000-000000000000",
    }, handle)
PY
  (
    cd "$trash_path/home" || exit 1
    exec sh -c 'sleep 60' sh "$secret"
  ) </dev/null >/dev/null 2>&1 &
  local trash_pid=$!
  TEST_BG_PIDS+=("$trash_pid")

  wait_for_scan_refusal recover --yes
  assert_output_contains "PID $trash_pid"
  assert_output_not_contains "$secret"
  # The journal and the trashed data are untouched by the refusal.
  assert_file_exists "$repo/.agent-profiles/.journal/remove-target.json"
  assert_dir_exists "$trash_path/home"

  kill -9 "$trash_pid" 2>/dev/null || true
  wait "$trash_pid" 2>/dev/null || true
}
