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
  cd "$TEST_TMPDIR/work" || exit 1
}

teardown() {
  teardown_isolation
}

@test "setup apply: a symlinked tasks directory is detected and left untouched" {
  mkdir -p "$TEST_TMPDIR/dotfiles/tasks" "$MISE_CONFIG_DIR"
  ln -s "$TEST_TMPDIR/dotfiles/tasks" "$MISE_CONFIG_DIR/tasks"

  run bash "$AP_HELPER" setup --apply
  assert_success
  assert_output_contains "managed configuration"
  assert_output_contains "--prepare-dir"
  [[ -z "$(ls -A "$TEST_TMPDIR/dotfiles/tasks")" ]]
}

@test "setup apply: prepare-dir writes prepared files and instructions without touching the target" {
  mkdir -p "$TEST_TMPDIR/dotfiles/tasks" "$MISE_CONFIG_DIR"
  ln -s "$TEST_TMPDIR/dotfiles/tasks" "$MISE_CONFIG_DIR/tasks"
  local prepared="$TEST_TMPDIR/prepared"

  run bash "$AP_HELPER" setup --apply --prepare-dir "$prepared"
  assert_success
  assert_output_contains "prepared"

  local task
  for task in agent-profiles-init agent-profiles; do
    assert_file_exists "$prepared/tasks/$task"
    [[ -x "$prepared/tasks/$task" ]]
    grep -Fq '#MISE dir="{{cwd}}"' "$prepared/tasks/$task"
    grep -Fq '# managed-by: flyingnobita-agent-profiles' "$prepared/tasks/$task"
  done
  assert_file_exists "$prepared/INSTRUCTIONS.md"
  grep -Fq "$MISE_CONFIG_DIR/tasks" "$prepared/INSTRUCTIONS.md"
  grep -Fq "setup --apply" "$prepared/INSTRUCTIONS.md"
  [[ -z "$(ls -A "$TEST_TMPDIR/dotfiles/tasks")" ]]
}

@test "setup apply: chezmoi-managed configuration is detected read-only" {
  mkdir -p "$TEST_TMPDIR/spy" "$MISE_CONFIG_DIR/tasks"
  export AP_SPY_LOG="$TEST_TMPDIR/spy.log"
  make_spy "$TEST_TMPDIR/spy" chezmoi

  run env PATH="$TEST_TMPDIR/spy:$PATH" bash "$AP_HELPER" setup --apply
  assert_success
  assert_output_contains "managed configuration"
  assert_output_contains "chezmoi"
  [[ ! -e "$MISE_CONFIG_DIR/tasks/agent-profiles-init" ]]
  [[ ! -e "$MISE_CONFIG_DIR/tasks/agent-profiles" ]]
}

@test "setup apply: a read-only tasks directory is detected and left untouched" {
  mkdir -p "$MISE_CONFIG_DIR/tasks"
  chmod 500 "$MISE_CONFIG_DIR/tasks"

  run bash "$AP_HELPER" setup --apply
  assert_success
  assert_output_contains "managed configuration"
  [[ -z "$(ls -A "$MISE_CONFIG_DIR/tasks")" ]]

  chmod 700 "$MISE_CONFIG_DIR/tasks"
}

@test "setup apply: managed configuration still deploys the versioned release for prepared tasks" {
  mkdir -p "$TEST_TMPDIR/dotfiles/tasks" "$MISE_CONFIG_DIR"
  ln -s "$TEST_TMPDIR/dotfiles/tasks" "$MISE_CONFIG_DIR/tasks"
  local prepared="$TEST_TMPDIR/prepared managed"
  local release_root="${XDG_DATA_HOME:-$HOME/.local/share}/flyingnobita-agent-profiles/releases"

  run bash "$AP_HELPER" setup --apply --prepare-dir "$prepared"
  assert_success

  # The versioned release lives in owned XDG data, not in managed configuration.
  [[ -d "$release_root" ]]
  local release
  release=$(find "$release_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ -n "$release" ]]
  assert_file_exists "$release/scripts/agent-profiles"

  # Adopt the prepared tasks into the managed source as a user would.
  cp "$prepared/tasks/agent-profiles-init" "$prepared/tasks/agent-profiles" "$TEST_TMPDIR/dotfiles/tasks/"

  # A rerun keeps the managed target authoritative and still deploys the release.
  run bash "$AP_HELPER" setup --apply --prepare-dir "$prepared"
  assert_success

  # The tasks now run from the versioned release resources.
  local fixture_repo="$TEST_TMPDIR/work/repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"
  run mise run agent-profiles-init -- --profile demo
  assert_success
  assert_dir_exists "$fixture_repo/.agent-profiles/demo/home"

  run mise run agent-profiles -- --profile demo sh -c 'printf "%s\n" "$AGENT_PROFILES_NAME"'
  assert_success
  assert_output_contains "demo"
}

@test "setup apply: managed mode reports prepared tasks instead of applied task writes" {
  mkdir -p "$TEST_TMPDIR/dotfiles/tasks" "$MISE_CONFIG_DIR"
  ln -s "$TEST_TMPDIR/dotfiles/tasks" "$MISE_CONFIG_DIR/tasks"
  local prepared="$TEST_TMPDIR/prepared"

  run bash "$AP_HELPER" setup --apply --prepare-dir "$prepared"
  assert_success
  assert_output_contains "prepared: $prepared/tasks/agent-profiles-init"
  assert_output_not_contains "task: $MISE_CONFIG_DIR/tasks/agent-profiles-init"
}
