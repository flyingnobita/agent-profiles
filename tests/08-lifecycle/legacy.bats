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

@test "legacy: init and run refuse with exit 77 when unnamed .agent-sandbox is detected" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  # Unnamed .agent-sandbox layout: agent subdirs directly in .agent-sandbox
  mkdir -p "$fixture_repo/.agent-sandbox/home"
  mkdir -p "$fixture_repo/.agent-sandbox/.claude"

  run bash "$AP_HELPER" init
  assert_failure 77
  assert_output_contains "legacy profile storage detected"
  assert_output_contains "migrate"

  run bash "$AP_HELPER" run -- true
  assert_failure 77
  assert_output_contains "legacy profile storage detected"
}

@test "legacy: init and run refuse with exit 77 when named .agent-sandbox is detected" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  # Named .agent-sandbox layout: named subdirs in .agent-sandbox
  mkdir -p "$fixture_repo/.agent-sandbox/worker1/home"

  run bash "$AP_HELPER" init --profile worker1
  assert_failure 77
  assert_output_contains "legacy profile storage detected"

  run bash "$AP_HELPER" run --profile worker1 -- true
  assert_failure 77
  assert_output_contains "legacy profile storage detected"
}

@test "legacy: init and run refuse with exit 77 when unnamed agent dirs exist under .agent-profiles" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  # Unnamed dirs directly under .agent-profiles
  mkdir -p "$fixture_repo/.agent-profiles/home"
  mkdir -p "$fixture_repo/.agent-profiles/.codex"

  run bash "$AP_HELPER" init
  assert_failure 77
  assert_output_contains "legacy profile storage detected"

  run bash "$AP_HELPER" run -- true
  assert_failure 77
  assert_output_contains "legacy profile storage detected"
}

@test "legacy: init and run refuse with exit 77 in mixed layout with working profiles" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  # Mixed: working named profile in .agent-profiles and legacy .agent-sandbox
  mkdir -p "$fixture_repo/.agent-profiles/activeprof/home"
  mkdir -p "$fixture_repo/.agent-sandbox/home"

  run bash "$AP_HELPER" init --profile other
  assert_failure 77
  assert_output_contains "legacy profile storage detected"

  run bash "$AP_HELPER" run --profile activeprof -- true
  assert_failure 77
  assert_output_contains "legacy profile storage detected"
}

@test "legacy: list and doctor do not refuse when legacy layouts are detected" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-profiles/workingprof/home"
  mkdir -p "$fixture_repo/.agent-sandbox/home"

  # list should succeed with exit 0 and note legacy storage
  run bash "$AP_HELPER" list
  assert_success
  assert_output_contains "workingprof"
  assert_output_contains "legacy profile storage"

  # doctor should succeed with exit 0
  run bash "$AP_HELPER" doctor --json
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
legacy_check = any("legacy" in str(c).lower() for c in data["checks"])
assert legacy_check
' "$output"
}
