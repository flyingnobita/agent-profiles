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

@test "codex env: run exports CODEX_HOME pointing to profile .codex" {
  local repo="$TEST_TMPDIR/repo-codex-env"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  run bash "$AP_HELPER" run --profile dev -- sh -c 'printf "CODEX_HOME_VAL=%s\n" "$CODEX_HOME"'
  assert_success
  assert_output_contains "CODEX_HOME_VAL=$repo/.agent-profiles/dev/.codex"
}

@test "codex env: run purges inherited CODEX_HOME before setting profile value" {
  local repo="$TEST_TMPDIR/repo-codex-inherited"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile custom
  assert_success

  run env CODEX_HOME="/foreign/host/path" bash "$AP_HELPER" run --profile custom -- sh -c 'printf "CODEX_HOME_VAL=%s\n" "$CODEX_HOME"'
  assert_success
  assert_output_contains "CODEX_HOME_VAL=$repo/.agent-profiles/custom/.codex"
}
