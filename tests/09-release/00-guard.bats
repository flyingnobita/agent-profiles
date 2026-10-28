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

@test "guard: pinned bats version is 1.14.0" {
  run bats --version
  assert_success
  assert_output_contains "1.14.0"
}

@test "guard: AP_SUBJECT is a valid directory" {
  [[ -d "$AP_SUBJECT" ]]
}

@test "guard: fixture git repo creation works" {
  repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  [[ -d "$repo/.git" ]]
  run git -C "$repo" rev-parse HEAD
  assert_success
}

@test "guard: isolation environment is isolated from the host HOME" {
  [[ "$HOME" == "$TEST_TMPDIR/home" ]]
  [[ -d "$HOME" ]]
}

@test "guard: helper exists at the subject and reports the packaged version" {
  assert_file_exists "$AP_HELPER"
  run bash "$AP_HELPER" --version
  assert_success
  assert_equal "$output" "$(tr -d '[:space:]' <"$AP_SKILL_DIR/VERSION")"
}

@test "guard: doctor --json parses at the subject" {
  run bash "$AP_HELPER" doctor --json
  assert_success
  echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}
