#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  # shellcheck source=tests/live/lib.sh
  source "$AP_SUBJECT/tests/live/lib.sh"
  # shellcheck source=tests/live/claude-cleanup.sh
  source "$AP_SUBJECT/tests/live/claude-cleanup.sh"
  OWNED_PID=""
  UNMARKED_PID=""
  AP_LIVE_TEST_GROUPS=""
}

teardown() {
  local pid
  for pid in ${AP_LIVE_TEST_GROUPS:-}; do
    kill -KILL -"$pid" 2>/dev/null || true
  done
  for pid in "$OWNED_PID" "$UNMARKED_PID"; do
    [[ -n "$pid" ]] && kill -KILL -"$pid" 2>/dev/null || true
  done
  teardown_isolation
}

wait_for_dead() {
  local pid="$1" deadline=$((SECONDS + 5))
  while kill -0 "$pid" 2>/dev/null; do
    [[ "$SECONDS" -ge "$deadline" ]] && return 1
    sleep 0.1
  done
  return 0
}

@test "claude live cleanup: empty owned temp scan finds no process" {
  local work="$TEST_TMPDIR/qa-empty-work"
  local profile="$TEST_TMPDIR/qa-empty-profile"
  mkdir -p "$work" "$profile"
  local boot
  boot=$(ap_claude_qa_boot_id)
  [[ -n "$boot" ]]

  run bash -c '
set -uo pipefail
source "$1"
cd "$2"
found="$(ap_claude_qa_owned_pids "$3" "$4")"
printf "%s\n" "$found"
' _ "$AP_SUBJECT/tests/live/claude-cleanup.sh" "$work" "$profile" "$boot"
  assert_success
  assert_output_equals ""
}

@test "claude live cleanup: finds and stops an owned helper but leaves an unmarked child untouched" {
  local work="$TEST_TMPDIR/qa-owned-work"
  local profile="$TEST_TMPDIR/qa-owned-profile"
  mkdir -p "$work" "$profile"
  cd "$work" || return 1

  local boot scan deadline
  boot=$(ap_claude_qa_boot_id)
  [[ -n "$boot" ]]

  # Portable owners: Python start_new_session instead of setsid, and the
  # profile ownership evidence the harness records at spawn time.
  OWNED_PID=$(AGENT_PROFILES_DIR="$profile" \
    ap_live_spawn_test_process "$TEST_TMPDIR/qa-owned.marker" sleep 30)
  UNMARKED_PID=$(env -u AGENT_PROFILES_DIR bash -c 'source "$1"; shift; ap_live_spawn_test_process "$@"' \
    _ "$AP_SUBJECT/tests/live/claude-cleanup.sh" "$TEST_TMPDIR/qa-unmarked.marker" sleep 30)
  AP_LIVE_TEST_GROUPS="$OWNED_PID $UNMARKED_PID"

  deadline=$((SECONDS + 5))
  scan=""
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    scan=$(bash -c '
set -uo pipefail
source "$1"
ap_claude_qa_owned_pids "$2" "$3"
' _ "$AP_SUBJECT/tests/live/claude-cleanup.sh" "$profile" "$boot")
    [[ "$scan" == *"$OWNED_PID"* ]] && break
    sleep 0.1
  done
  [[ "$scan" == *"$OWNED_PID"* ]]
  [[ "$scan" != *"$UNMARKED_PID"* ]]

  # The unmarked neighbour is live at decision time and is never signalled.
  run kill -0 "$UNMARKED_PID"
  assert_success
  run ap_claude_qa_cleanup "$profile" "$boot"
  assert_success
  assert_output_contains "$OWNED_PID"

  wait_for_dead "$OWNED_PID"
  kill -0 "$UNMARKED_PID" 2>/dev/null
}

@test "claude live cleanup: regression: command-substitution scan in a temp cwd detects nothing" {
  local work="$TEST_TMPDIR/qa-selfscan-work"
  local profile="$TEST_TMPDIR/qa-selfscan-profile"
  mkdir -p "$work" "$profile"
  local boot
  boot=$(ap_claude_qa_boot_id)

  # A decoy that shares the scanner's working directory but carries no profile
  # marker: a scanner must never detect itself or an unrelated neighbour.
  local decoy
  decoy=$(cd "$work" && env -u AGENT_PROFILES_DIR bash -c 'source "$1"; shift; ap_live_spawn_test_process "$@"' \
    _ "$AP_SUBJECT/tests/live/claude-cleanup.sh" "$TEST_TMPDIR/qa-decoy.marker" sleep 30)
  AP_LIVE_TEST_GROUPS="$decoy"

  run bash -c '
set -uo pipefail
source "$1"
cd "$2"
found="$(ap_claude_qa_owned_pids "$3" "$4")"
printf "%s\n" "$found"
' _ "$AP_SUBJECT/tests/live/claude-cleanup.sh" "$work" "$profile" "$boot"
  assert_success
  assert_output_equals ""
  assert_output_not_contains "$decoy"
}
