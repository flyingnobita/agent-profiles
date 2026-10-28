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

@test "setup preview: names proposed release, task, conflict and requested agent changes read-only" {
  mkdir -p "$TEST_TMPDIR/work"
  cd "$TEST_TMPDIR/work" || exit 1
  export AP_SPY_LOG="$TEST_TMPDIR/spy.log"

  # A foreign task file and a pre-existing managed task make the plan concrete.
  mkdir -p "$MISE_CONFIG_DIR/tasks"
  printf '#!/usr/bin/env bash\necho foreign\n' >"$MISE_CONFIG_DIR/tasks/agent-profiles-init"
  printf '# managed-by: flyingnobita-agent-profiles 0.0.0 sha256:%064d\n' 0 \
    >"$MISE_CONFIG_DIR/tasks/agent-profiles"

  local before
  before=$(snapshot_tree "$MISE_CONFIG_DIR" "${XDG_STATE_HOME:-$HOME/.local/state}")

  run bash "$AP_HELPER" setup --preview --agent codex
  assert_success
  assert_output_contains "Planned changes"
  assert_output_contains "release:"
  assert_output_contains "task: $MISE_CONFIG_DIR/tasks/agent-profiles-init"
  assert_output_contains "conflict"
  assert_output_contains "agent: codex"
  assert_output_contains "No changes made"

  local after
  after=$(snapshot_tree "$MISE_CONFIG_DIR" "${XDG_STATE_HOME:-$HOME/.local/state}")
  assert_equal "$before" "$after"
  run ! grep -Fq "mise use" "$AP_SPY_LOG"
  run ! grep -Fq "pacman" "$AP_SPY_LOG"
}

@test "setup preview: --tasks-only marks prerequisite and agent installation as skipped" {
  mkdir -p "$TEST_TMPDIR/work"
  cd "$TEST_TMPDIR/work" || exit 1

  run bash "$AP_HELPER" setup --preview --tasks-only --agent codex
  assert_success
  assert_output_contains "tasks-only"
  assert_output_contains "skipped"
  assert_output_not_contains "install through the mise registry on --apply"
  assert_output_not_contains "install:"
}

@test "setup preview: managed configuration with --prepare-dir names prepared destinations" {
  mkdir -p "$TEST_TMPDIR/work" "$TEST_TMPDIR/dotfiles/mise"
  cd "$TEST_TMPDIR/work" || exit 1
  printf '[tools]\nnode = "lts"\n' >"$TEST_TMPDIR/dotfiles/mise/config.toml"
  rm -rf "$MISE_CONFIG_DIR"
  ln -s "$TEST_TMPDIR/dotfiles/mise" "$MISE_CONFIG_DIR"

  local before
  before=$(snapshot_tree "$TEST_TMPDIR/dotfiles" "$TEST_TMPDIR/prepared")

  local bin="$TEST_TMPDIR/no-agents-bin"
  make_restricted_bin "$bin" codex claude agy opencode

  run env PATH="$bin" bash "$AP_HELPER" setup --preview --agent codex --prepare-dir "$TEST_TMPDIR/prepared"
  assert_success
  assert_output_contains "release: "
  assert_output_not_contains "release: skipped"
  assert_output_contains "prepared/tasks/agent-profiles-init"
  assert_output_contains "prepared/INSTRUCTIONS.md"
  assert_output_contains "prepared/mise/config.toml.fragment"

  # A preview writes nothing, including no prepared files.
  local after
  after=$(snapshot_tree "$TEST_TMPDIR/dotfiles" "$TEST_TMPDIR/prepared")
  assert_equal "$before" "$after"
}

@test "setup preview: managed config with an installed agent does not promise a fragment" {
  local bin="$TEST_TMPDIR/fake-bin"
  write_fake_agent "$bin/codex" "9.9.9"
  mkdir -p "$TEST_TMPDIR/work" "$TEST_TMPDIR/dotfiles/mise"
  cd "$TEST_TMPDIR/work" || exit 1
  printf '[tools]\nnode = "lts"\n' >"$TEST_TMPDIR/dotfiles/mise/config.toml"
  rm -rf "$MISE_CONFIG_DIR"
  ln -s "$TEST_TMPDIR/dotfiles/mise" "$MISE_CONFIG_DIR"

  run env PATH="$bin:$PATH" bash "$AP_HELPER" setup --preview --agent codex \
    --prepare-dir "$TEST_TMPDIR/prepared"
  assert_success
  assert_output_contains "agent: codex (already available at"
  assert_output_not_contains "config.toml.fragment"
}
