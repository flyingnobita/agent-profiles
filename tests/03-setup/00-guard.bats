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

@test "guard: pinned bats version is 1.14.0" {
  run bats --version
  assert_success
  assert_output_contains "1.14.0"
}

@test "guard: pinned skills version is 1.7.4" {
  run skills --version
  assert_success
  assert_output_contains "1.7.4"
}

@test "guard: AP_SUBJECT is a valid directory and helper exists" {
  [[ -d "$AP_SUBJECT" ]]
  assert_file_exists "$AP_HELPER"
  [[ -x "$AP_HELPER" ]]
}

@test "guard: helper --version returns valid semver" {
  run bash "$AP_HELPER" --version
  assert_success
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "guard: doctor --json returns valid schema" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" doctor --json
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert "version" in data
assert "checks" in data
assert "agents" in data
' "$output"
}
