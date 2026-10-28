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
}

teardown() {
  teardown_isolation
}

@test "setup preview: reports OS identity from the AP_OS_RELEASE fixture" {
  run bash "$AP_HELPER" setup --preview
  assert_success
  assert_output_contains "ID=arch"
  assert_output_contains "Arch Linux"
  assert_output_contains "arch family"
}

@test "setup preview: reports the detected package manager for the distribution family" {
  local spy="$TEST_TMPDIR/spy-bin"
  export AP_SPY_LOG="$TEST_TMPDIR/spy.log"
  make_spy "$spy" pacman

  run env PATH="$spy:$PATH" bash "$AP_HELPER" setup --preview
  assert_success
  assert_output_contains "Package manager: pacman"
  [[ ! -s "$AP_SPY_LOG" ]]
}

@test "setup preview: names a missing dependency and its detected-manager install command" {
  local bin="$TEST_TMPDIR/min-bin"
  make_restricted_bin "$bin" bwrap

  run env PATH="$bin" bash "$AP_HELPER" setup --preview
  assert_success
  assert_output_contains "MISSING] bwrap"
  assert_output_contains "pacman -S bubblewrap"
}

@test "setup preview: mise is reported as an unsupported automatic installation path" {
  local bin="$TEST_TMPDIR/min-bin"
  make_restricted_bin "$bin" mise

  run env PATH="$bin" bash "$AP_HELPER" setup --preview
  assert_success
  assert_output_contains "MANUAL] mise: unsupported automatic path"
  assert_output_contains "curl"
}

@test "setup preview: resolves agent installation sources from PATH" {
  local bin="$TEST_TMPDIR/min-bin"
  make_restricted_bin "$bin" claude codex agy opencode
  write_fake_agent "$bin/claude" "2.1.312"
  write_fake_agent "$bin/codex" "0.163.0"

  run env PATH="$bin" bash "$AP_HELPER" setup --preview
  assert_success
  assert_output_contains "FOUND] claude: $bin/claude"
  assert_output_contains "FOUND] codex: $bin/codex"
  assert_output_contains "MISSING] agy"
  assert_output_contains "MISSING] opencode"
}

@test "setup preview: unsupported distribution family is named instead of guessed" {
  write_os_release alpine "" "Alpine Linux"

  run bash "$AP_HELPER" setup --preview
  assert_success
  assert_output_contains "Alpine Linux"
  assert_output_contains "unsupported automatic path"
}

@test "setup preview: is read-only and calls no package manager, sudo or curl" {
  local bin="$TEST_TMPDIR/min-bin"
  make_restricted_bin "$bin" mise
  export AP_SPY_LOG="$TEST_TMPDIR/spy.log"
  local spy
  for spy in pacman apt-get sudo curl dnf zypper apk; do
    make_spy "$bin" "$spy"
  done

  mkdir -p "$TEST_TMPDIR/work"
  local before after
  before=$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" \
    "$MISE_CONFIG_DIR" "$MISE_DATA_DIR" "$MISE_STATE_DIR" "$MISE_CACHE_DIR" "$TEST_TMPDIR/work")

  run env PATH="$bin" bash "$AP_HELPER" setup --preview
  assert_success
  assert_output_contains "No changes made"

  after=$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" \
    "$MISE_CONFIG_DIR" "$MISE_DATA_DIR" "$MISE_STATE_DIR" "$MISE_CACHE_DIR" "$TEST_TMPDIR/work")
  assert_equal "$after" "$before"
  [[ ! -s "$AP_SPY_LOG" ]]
  [[ ! -e "$MISE_CONFIG_DIR/tasks/agent-profiles-init" ]]
  [[ ! -e "$MISE_CONFIG_DIR/tasks/agent-profiles" ]]
}

@test "setup: unknown options and conflicting modes are usage errors" {
  run bash "$AP_HELPER" setup --bogus
  assert_failure 64

  run bash "$AP_HELPER" setup --preview --apply
  assert_failure 64

  run bash "$AP_HELPER" setup unexpected-argument
  assert_failure 64
}
