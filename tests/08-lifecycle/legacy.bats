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

  # Even if default profile directory exists, run must refuse with exit 77 due to legacy storage
  mkdir -p "$fixture_repo/.agent-profiles/default/home"
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

  mkdir -p "$fixture_repo/.agent-profiles/worker1/home"
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

  # If a named profile also exists, run on that profile still refuses due to root unnamed legacy layout
  mkdir -p "$fixture_repo/.agent-profiles/myprof/home"
  run bash "$AP_HELPER" run --profile myprof -- true
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

@test "legacy: valid profile names that match agent directory names stay usable named profiles" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  # bin, home, npm-global, uv-tools, cargo-global and python-user are valid
  # profile names under the approved grammar; they are not unnamed legacy data.
  local name
  for name in bin home npm-global uv-tools cargo-global python-user; do
    run bash "$AP_HELPER" init --profile "$name"
    assert_success
    assert_dir_exists "$fixture_repo/.agent-profiles/$name/home"
  done

  # A new unrelated profile must not be blocked by the existing named profiles.
  run bash "$AP_HELPER" init --profile other
  assert_success

  run bash "$AP_HELPER" list
  assert_success
  assert_output_contains "bin"
  assert_output_contains "other"
  assert_output_not_contains "legacy profile storage"

  # The same-named profile stays runnable and is not treated as legacy storage.
  run bash "$AP_HELPER" run --profile bin -- sh -c 'printf "%s\n" "$AGENT_PROFILES_NAME"'
  assert_success
  assert_output_contains "bin"
}

@test "legacy: mixed named profiles and genuine unnamed agent dirs still refuse init until migrate" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  # A real named profile named bin plus genuine unnamed legacy data.
  run bash "$AP_HELPER" init --profile bin
  assert_success
  mkdir -p "$fixture_repo/.agent-profiles/.claude/projects/p1"
  printf '{"legacy":true}\n' >"$fixture_repo/.agent-profiles/.claude/projects/p1/session.jsonl"

  run bash "$AP_HELPER" init --profile other
  assert_failure 77
  assert_output_contains "legacy profile storage detected"

  # The named profile itself is still recognizable to list.
  run bash "$AP_HELPER" list
  assert_success
  assert_output_contains "bin"
}
