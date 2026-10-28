#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

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
  export AP_SPY_LOG="$TEST_TMPDIR/spy.log"
}

teardown() {
  teardown_isolation
}

# Build a controlled PATH where bwrap, the agents and the real program installers
# are absent. mise is replaced by a wrapper that records calls and only passes
# read-only subcommands through to the real binary, so tests never install tools.
build_install_env() {
  REAL_MISE="$(command -v mise)"
  INSTALL_BIN="$TEST_TMPDIR/min-bin"
  make_restricted_bin "$INSTALL_BIN" bwrap pacman sudo apt-get apt dnf zypper apk curl \
    claude codex agy opencode mise

  make_spy "$INSTALL_BIN" pacman
  make_spy "$INSTALL_BIN" sudo

  cat >"$INSTALL_BIN/mise" <<MISE_WRAPPER
#!/usr/bin/env bash
printf '%s\n' "mise \$*" >>"\$AP_SPY_LOG"
if [[ "\${1:-}" == "use" || "\${1:-}" == "install" ]]; then
  exit 0
fi
exec "$REAL_MISE" "\$@"
MISE_WRAPPER
  chmod +x "$INSTALL_BIN/mise"
}

@test "setup apply: installs only the missing prerequisite through the detected manager" {
  build_install_env

  run env PATH="$INSTALL_BIN" bash "$AP_HELPER" setup --apply
  assert_success
  assert_output_contains "bubblewrap"

  grep -Fq "sudo pacman -S --noconfirm bubblewrap" "$AP_SPY_LOG"
  run ! grep -Eq "sudo pacman -S --noconfirm (git|bash|python)" "$AP_SPY_LOG"
  run ! grep -Fq "mise use" "$AP_SPY_LOG"
}

@test "setup apply: installs a requested missing agent through the mise registry" {
  build_install_env

  run env PATH="$INSTALL_BIN" bash "$AP_HELPER" setup --apply --agent codex
  assert_success

  grep -Fq "mise use --global codex@latest" "$AP_SPY_LOG"
  run ! grep -Eq "mise use --global (claude|agy|opencode)@" "$AP_SPY_LOG"
}

@test "setup apply: agents are optional and untouched unless requested" {
  build_install_env

  run env PATH="$INSTALL_BIN" bash "$AP_HELPER" setup --apply
  assert_success
  run ! grep -Fq "mise use" "$AP_SPY_LOG"
}

@test "setup apply: --tasks-only performs no prerequisite or agent installation" {
  build_install_env

  run env PATH="$INSTALL_BIN" bash "$AP_HELPER" setup --apply --tasks-only --agent codex
  assert_success
  assert_file_exists "$MISE_CONFIG_DIR/tasks/agent-profiles-init"
  assert_file_exists "$MISE_CONFIG_DIR/tasks/agent-profiles"
  run ! grep -Fq "sudo pacman" "$AP_SPY_LOG"
  run ! grep -Fq "mise use" "$AP_SPY_LOG"
}
