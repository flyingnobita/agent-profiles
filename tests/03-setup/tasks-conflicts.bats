#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
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

@test "setup apply: a repeated run is idempotent and creates no extra backups or releases" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local releases="$XDG_DATA_HOME/flyingnobita-agent-profiles/releases"
  local backups="$XDG_STATE_HOME/flyingnobita-agent-profiles/backups"
  local tasks_before
  tasks_before=$(sha256sum "$MISE_CONFIG_DIR"/tasks/agent-profiles* | LC_ALL=C sort)

  run bash "$AP_HELPER" setup --apply
  assert_success

  assert_equal "$(sha256sum "$MISE_CONFIG_DIR"/tasks/agent-profiles* | LC_ALL=C sort)" "$tasks_before"
  [[ "$(find "$releases" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]]
  if [[ -d "$backups" ]]; then
    [[ -z "$(find "$backups" -type f)" ]]
  fi
}

@test "setup apply: a foreign task file is reported and left byte-identical" {
  mkdir -p "$MISE_CONFIG_DIR/tasks"
  printf '#!/usr/bin/env bash\necho foreign task\n' >"$MISE_CONFIG_DIR/tasks/agent-profiles-init"
  chmod +x "$MISE_CONFIG_DIR/tasks/agent-profiles-init"
  local before
  before=$(sha256sum "$MISE_CONFIG_DIR/tasks/agent-profiles-init")

  run bash "$AP_HELPER" setup --apply
  assert_success
  assert_output_contains "conflict"
  assert_output_contains "agent-profiles-init"
  assert_equal "$(sha256sum "$MISE_CONFIG_DIR/tasks/agent-profiles-init")" "$before"
  assert_file_exists "$MISE_CONFIG_DIR/tasks/agent-profiles"
  [[ "$(cat "$MISE_CONFIG_DIR/tasks/agent-profiles-init")" == *"foreign task"* ]]
}

@test "setup apply: an inline global config task is reported and untouched" {
  mkdir -p "$MISE_CONFIG_DIR"
  printf '[tasks.agent-profiles]\nrun = "echo foreign-inline"\n' >"$MISE_CONFIG_DIR/config.toml"
  local before
  before=$(sha256sum "$MISE_CONFIG_DIR/config.toml")

  run bash "$AP_HELPER" setup --apply
  assert_success
  assert_output_contains "conflict"
  assert_output_contains "agent-profiles"
  assert_equal "$(sha256sum "$MISE_CONFIG_DIR/config.toml")" "$before"
  [[ ! -e "$MISE_CONFIG_DIR/tasks/agent-profiles" ]]
  assert_file_exists "$MISE_CONFIG_DIR/tasks/agent-profiles-init"
}

@test "setup apply: a modified managed task is backed up outside the tasks directory" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  printf '# local edit that must be preserved in a backup\n' >>"$MISE_CONFIG_DIR/tasks/agent-profiles-init"

  run bash "$AP_HELPER" setup --apply
  assert_success
  assert_output_contains "backup"

  local backups
  backups=$(find "$XDG_STATE_HOME/flyingnobita-agent-profiles/backups" -type f -name agent-profiles-init)
  [[ -n "$backups" ]]
  [[ "$backups" != "$MISE_CONFIG_DIR/tasks/"* ]]
  grep -Fq "local edit that must be preserved" "$backups"
  grep -Fq '# managed-by: flyingnobita-agent-profiles' "$MISE_CONFIG_DIR/tasks/agent-profiles-init"
}

@test "setup apply: a new release keeps the previous verified release" {
  run bash "$AP_HELPER" setup --apply
  assert_success
  local release_one
  release_one=$(sed -n 's/^# release: //p' "$MISE_CONFIG_DIR/tasks/agent-profiles-init")

  local copy="$TEST_TMPDIR/skill-copy"
  cp -a "$AP_SKILL_DIR" "$copy"
  printf '\n# local follow-up change changes the manifest digest\n' >>"$copy/scripts/lib/common.sh"

  run bash "$copy/scripts/agent-profiles" setup --apply
  assert_success
  local release_two
  release_two=$(sed -n 's/^# release: //p' "$MISE_CONFIG_DIR/tasks/agent-profiles-init")

  [[ "$release_one" != "$release_two" ]]
  assert_dir_exists "$release_one"
  assert_dir_exists "$release_two"
  (cd "$release_one" && sha256sum -c manifest.sha256 --quiet)
  (cd "$release_two" && sha256sum -c manifest.sha256 --quiet)
}

@test "setup apply: repeated setup stays idempotent without cmp or diffutils" {
  local bin="$TEST_TMPDIR/no-cmp-bin"
  make_restricted_bin "$bin" cmp diff

  run env PATH="$bin" bash "$AP_HELPER" setup --apply
  assert_success
  local tasks_before
  tasks_before=$(sha256sum "$MISE_CONFIG_DIR"/tasks/agent-profiles* | LC_ALL=C sort)

  run env PATH="$bin" bash "$AP_HELPER" setup --apply
  assert_success

  assert_equal "$(sha256sum "$MISE_CONFIG_DIR"/tasks/agent-profiles* | LC_ALL=C sort)" "$tasks_before"
  if [[ -d "$XDG_STATE_HOME/flyingnobita-agent-profiles/backups" ]]; then
    [[ -z "$(find "$XDG_STATE_HOME/flyingnobita-agent-profiles/backups" -type f)" ]]
  fi
}
