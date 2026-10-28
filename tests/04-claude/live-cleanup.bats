#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation
}

teardown() {
  teardown_isolation
}

@test "claude live cleanup: empty owned temp scan does not detect the scanner" {
  local script="$AP_SUBJECT/tests/live/claude.sh"
  local work="$TEST_TMPDIR/qa-empty-work"
  local extracted="$TEST_TMPDIR/test_owned_pids.bash"
  mkdir -p "$work"

  # Reproduce the current scanner from the live harness without launching an
  # agent. An empty disposable directory must produce no owned process.
  sed -n '/^test_owned_pids() {/,/^}/p' "$script" >"$extracted"
  [[ -s "$extracted" ]]

  run env -u AGENT_PROFILES_DIR bash -c '
set -uo pipefail
WORK="$1"
source "$2"
cd "$WORK"
found="$(test_owned_pids)"
printf '%s\n' "$found"
' _ "$work" "$extracted"
  assert_success
  assert_output_equals ""
}
