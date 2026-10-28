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

@test "guard: pinned skills version is 1.7.4" {
  run skills --version
  assert_success
  assert_output_contains "1.7.4"
}

@test "guard: pinned shellcheck version is 0.11.0" {
  run shellcheck --version
  assert_success
  assert_output_contains "0.11.0"
}

@test "guard: pinned shfmt version is 3.14.1" {
  run shfmt --version
  assert_success
  assert_output_contains "3.14.1"
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

@test "guard: isolation environment is isolated from host HOME" {
  [[ "$HOME" != "/home/omarchy" ]]
  [[ "$HOME" == "$TEST_TMPDIR/home" ]]
  [[ -d "$HOME" ]]
}
