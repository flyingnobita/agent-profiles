#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  load 'lib.bash'
  setup_isolation
  setup_mise_env
  write_os_release arch arch "Arch Linux"
  mkdir -p "$TEST_TMPDIR/work"
  cd "$TEST_TMPDIR/work"
}

teardown() {
  teardown_isolation
}

@test "setup apply: deploys a versioned release with a sha256 manifest" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local release
  release=$(sed -n 's/^# release: //p' "$MISE_CONFIG_DIR/tasks/agent-profiles-init")
  assert_dir_exists "$release"
  [[ "$release" == "$XDG_DATA_HOME/flyingnobita-agent-profiles/releases/"* ]]
  [[ "$(basename "$release")" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{8}$ ]]
  assert_file_exists "$release/scripts/agent-profiles"
  assert_file_exists "$release/VERSION"
  assert_file_exists "$release/manifest.sha256"
  (cd "$release" && sha256sum -c manifest.sha256 --quiet)
}

@test "setup apply: installs exactly two executable global file tasks using the released helper" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local task release
  for task in agent-profiles-init agent-profiles; do
    assert_file_exists "$MISE_CONFIG_DIR/tasks/$task"
    [[ -x "$MISE_CONFIG_DIR/tasks/$task" ]]
    grep -Fq '#MISE dir="{{cwd}}"' "$MISE_CONFIG_DIR/tasks/$task"
    grep -Eq '^# managed-by: flyingnobita-agent-profiles [0-9]+\.[0-9]+\.[0-9]+ sha256:[0-9a-f]{64}$' \
      "$MISE_CONFIG_DIR/tasks/$task"
    release=$(sed -n 's/^# release: //p' "$MISE_CONFIG_DIR/tasks/$task")
    grep -Fq "$release/scripts/agent-profiles" "$MISE_CONFIG_DIR/tasks/$task"
  done
}

@test "setup apply: agent-profiles-init task initializes a profile through mise" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run mise run agent-profiles-init -- --profile demo
  assert_success
  assert_dir_exists "$repo/.agent-profiles/demo/home"
}

@test "setup apply: agent-profiles task forwards arguments through mise to the helper" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run mise run agent-profiles-init -- --profile demo
  assert_success

  run mise run agent-profiles -- --profile demo printf '%s\n' 'a b'
  assert_success
  assert_output_contains "a b"

  run mise run agent-profiles -- --profile demo sh -c 'printf "%s\n" "$AGENT_PROFILES_NAME"'
  assert_success
  assert_output_contains "demo"
}
