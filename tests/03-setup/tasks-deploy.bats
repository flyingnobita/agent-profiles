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

@test "setup apply: deploys a versioned release with a sha256 manifest" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local release
  release=$(sed -n 's/^# release: //p' "$MISE_CONFIG_DIR/tasks/agent-profiles")
  assert_dir_exists "$release"
  [[ "$release" == "$XDG_DATA_HOME/flyingnobita-agent-profiles/releases/"* ]]
  [[ "$(basename "$release")" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{8}$ ]]
  assert_file_exists "$release/scripts/agent-profiles"
  assert_file_exists "$release/VERSION"
  assert_file_exists "$release/manifest.sha256"
  (cd "$release" && sha256sum -c manifest.sha256 --quiet)
}

@test "setup apply: installs exactly one executable global file task using the released helper" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local task="$MISE_CONFIG_DIR/tasks/agent-profiles" release
  assert_file_exists "$task"
  [[ -x "$task" ]]
  [[ "$(find "$MISE_CONFIG_DIR/tasks" -type f | wc -l)" -eq 1 ]]
  grep -Fq '#MISE dir="{{cwd}}"' "$task"
  grep -Eq '^# managed-by: flyingnobita-agent-profiles [0-9]+\.[0-9]+\.[0-9]+ sha256:[0-9a-f]{64}$' "$task"
  release=$(sed -n 's/^# release: //p' "$task")
  grep -Fq "$release/scripts/agent-profiles" "$task"
}

@test "setup apply: mise ap new creates a profile through mise" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run mise ap new demo
  assert_success
  assert_dir_exists "$repo/.agent-profiles/demo/home"
}

@test "setup apply: agent-profiles task forwards arguments through mise to the helper" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run mise ap new demo
  assert_success

  run mise run agent-profiles -- --profile demo printf '%s\n' 'a b'
  assert_success
  assert_output_contains "a b"

  # shellcheck disable=SC2016
  run mise run agent-profiles -- --profile demo sh -c 'printf "%s\n" "$AGENT_PROFILES_NAME"'
  assert_success
  assert_output_contains "demo"
}

@test "setup apply: a copied installed skill deploys durable tasks that survive its removal" {
  local installed="$TEST_TMPDIR/installed/skills/flyingnobita-agent-profiles"
  mkdir -p "$(dirname "$installed")"
  cp -a "$AP_SKILL_DIR" "$installed"

  run bash "$installed/scripts/agent-profiles" setup --apply
  assert_success

  local release
  release=$(sed -n 's/^# release: //p' "$MISE_CONFIG_DIR/tasks/agent-profiles")
  [[ "$release" == "$XDG_DATA_HOME/flyingnobita-agent-profiles/releases/"* ]]
  [[ "$release" != "$installed"* ]]

  rm -rf "$TEST_TMPDIR/installed"

  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run mise ap new demo
  assert_success
  assert_dir_exists "$repo/.agent-profiles/demo/home"
}
