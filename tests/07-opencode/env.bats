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

@test "opencode env: run exports OPENCODE_CONFIG_DIR pointing to the profile .opencode directory" {
  local repo="$TEST_TMPDIR/repo-opencode-env"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  run bash "$AP_HELPER" run --profile dev -- sh -c 'printf "OPENCODE_CONFIG_DIR_VAL=%s\n" "$OPENCODE_CONFIG_DIR"'
  assert_success
  assert_output_contains "OPENCODE_CONFIG_DIR_VAL=$repo/.agent-profiles/dev/.opencode"
}

@test "opencode env: run purges an inherited OPENCODE_CONFIG_DIR before setting the profile value" {
  local repo="$TEST_TMPDIR/repo-opencode-inherited"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile custom
  assert_success

  run env OPENCODE_CONFIG_DIR="/foreign/host/path" bash "$AP_HELPER" run --profile custom -- sh -c 'printf "OPENCODE_CONFIG_DIR_VAL=%s\n" "$OPENCODE_CONFIG_DIR"'
  assert_success
  assert_output_contains "OPENCODE_CONFIG_DIR_VAL=$repo/.agent-profiles/custom/.opencode"
}

@test "opencode env: run keeps data, state and cache inside the profile while the config root is overridden" {
  local repo="$TEST_TMPDIR/repo-opencode-xdg"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile xdg
  assert_success

  run bash "$AP_HELPER" run --profile xdg -- sh -c '
printf "DATA=%s\n" "$XDG_DATA_HOME"
printf "STATE=%s\n" "$XDG_STATE_HOME"
printf "CACHE=%s\n" "$XDG_CACHE_HOME"
'
  assert_success
  assert_output_contains "DATA=$repo/.agent-profiles/xdg/.local/share"
  assert_output_contains "STATE=$repo/.agent-profiles/xdg/.local/state"
  assert_output_contains "CACHE=$repo/.agent-profiles/xdg/.cache"
}

@test "opencode env: the profile configuration directory exists with private permissions" {
  local repo="$TEST_TMPDIR/repo-opencode-perms"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile perms
  assert_success

  run bash "$AP_HELPER" run --profile perms -- true
  assert_success
  assert_dir_exists "$repo/.agent-profiles/perms/.opencode"
  run stat -c '%a' "$repo/.agent-profiles/perms/.opencode"
  assert_success
  assert_equal "$output" "700"
}
