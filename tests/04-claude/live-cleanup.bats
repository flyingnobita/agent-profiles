#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  # shellcheck source=tests/live/claude-cleanup.sh
  source "$AP_SUBJECT/tests/live/claude-cleanup.sh"
  OWNED_PID=""
  UNMARKED_PID=""
}

teardown() {
  local pid
  for pid in "$OWNED_PID" "$UNMARKED_PID"; do
    [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
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
  local start boot
  start=$(ap_claude_qa_uptime_ticks)
  boot=$(ap_claude_qa_boot_id)
  [[ -n "$start" && -n "$boot" ]]

  run bash -c '
set -uo pipefail
source "$1"
cd "$2"
found="$(ap_claude_qa_owned_pids "$3" "$4" "$5")"
printf "%s\n" "$found"
' _ "$AP_SUBJECT/tests/live/claude-cleanup.sh" "$work" "$profile" "$start" "$boot"
  assert_success
  assert_output_equals ""
}

@test "claude live cleanup: finds and stops an owned helper but leaves an unmarked child untouched" {
  local work="$TEST_TMPDIR/qa-owned-work"
  local profile="$TEST_TMPDIR/qa-owned-profile"
  mkdir -p "$work" "$profile"
  cd "$work" || return 1

  local start boot scan deadline
  start=$(ap_claude_qa_uptime_ticks)
  boot=$(ap_claude_qa_boot_id)
  [[ -n "$start" && -n "$boot" ]]

  env AGENT_PROFILES_DIR="$profile" setsid sleep 30 &
  OWNED_PID=$!
  setsid sleep 30 &
  UNMARKED_PID=$!
  sleep 0.2

  deadline=$((SECONDS + 5))
  scan=""
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    scan=$(bash -c '
set -uo pipefail
source "$1"
ap_claude_qa_owned_pids "$2" "$3" "$4"
' _ "$AP_SUBJECT/tests/live/claude-cleanup.sh" "$profile" "$start" "$boot")
    [[ "$scan" == *"$OWNED_PID"* ]] && break
    sleep 0.1
  done
  [[ "$scan" == *"$OWNED_PID"* ]]
  [[ "$scan" != *"$UNMARKED_PID"* ]]

  run ap_claude_qa_cleanup "$profile" "$start" "$boot"
  assert_success
  assert_output_contains "$OWNED_PID"

  wait_for_dead "$OWNED_PID"
  kill -0 "$UNMARKED_PID" 2>/dev/null
}

@test "claude live cleanup: regression: command-substitution scan in a temp cwd detects nothing" {
  local work="$TEST_TMPDIR/qa-selfscan-work"
  local profile="$TEST_TMPDIR/qa-selfscan-profile"
  mkdir -p "$work" "$profile"
  local start boot
  start=$(ap_claude_qa_uptime_ticks)
  boot=$(ap_claude_qa_boot_id)

  run bash -c '
set -uo pipefail
source "$1"
cd "$2"
found="$(ap_claude_qa_owned_pids "$3" "$4" "$5")"
printf "%s\n" "$found"
' _ "$AP_SUBJECT/tests/live/claude-cleanup.sh" "$work" "$profile" "$start" "$boot"
  assert_success
  assert_output_equals ""
}
