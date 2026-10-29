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
  assert_file_exists "$MISE_CONFIG_DIR/tasks/agent-profiles"
  run ! grep -Fq "sudo pacman" "$AP_SPY_LOG"
  run ! grep -Fq "mise use" "$AP_SPY_LOG"
}

@test "setup apply: backs up the global mise config before installing a requested agent" {
  build_install_env

  mkdir -p "$MISE_CONFIG_DIR"
  printf '[tools]\nnode = "lts"\n' >"$MISE_CONFIG_DIR/config.toml"
  local config_hash_before
  config_hash_before=$(sha256sum "$MISE_CONFIG_DIR/config.toml" | cut -d' ' -f1)

  run env PATH="$INSTALL_BIN" bash "$AP_HELPER" setup --apply --agent codex
  assert_success
  assert_output_contains "backup:"

  # The original global configuration is preserved in a private backup.
  local backup
  backup=$(find "${XDG_STATE_HOME:-$HOME/.local/state}/flyingnobita-agent-profiles/backups" \
    -path '*mise*' -name config.toml | head -n 1)
  [[ -n "$backup" ]]
  assert_equal "$config_hash_before" "$(sha256sum "$backup" | cut -d' ' -f1)"
}

@test "setup apply: a managed global mise config is left untouched for a requested agent" {
  build_install_env

  mkdir -p "$MISE_CONFIG_DIR" "$TEST_TMPDIR/dotfiles"
  printf '[tools]\nnode = "lts"\n' >"$TEST_TMPDIR/dotfiles/config.toml"
  ln -s "$TEST_TMPDIR/dotfiles/config.toml" "$MISE_CONFIG_DIR/config.toml"
  local config_hash_before
  config_hash_before=$(sha256sum "$TEST_TMPDIR/dotfiles/config.toml" | cut -d' ' -f1)

  run env PATH="$INSTALL_BIN" bash "$AP_HELPER" setup --apply --agent codex \
    --prepare-dir "$TEST_TMPDIR/prepared"
  assert_success
  assert_output_contains "managed"
  assert_output_contains "codex"

  # The managed target and its symlink are untouched.
  [[ -L "$MISE_CONFIG_DIR/config.toml" ]]
  assert_equal "$config_hash_before" "$(sha256sum "$TEST_TMPDIR/dotfiles/config.toml" | cut -d' ' -f1)"
  run ! grep -Fq "mise use --global" "$AP_SPY_LOG"
}

@test "setup apply: a managed mise config parent directory is not rewritten for a requested agent" {
  build_install_env

  mkdir -p "$TEST_TMPDIR/dotfiles/mise" "$TEST_TMPDIR/mise"
  printf '[tools]\nnode = "lts"\n' >"$TEST_TMPDIR/dotfiles/mise/config.toml"
  rmdir "$MISE_CONFIG_DIR"
  ln -s "$TEST_TMPDIR/dotfiles/mise" "$MISE_CONFIG_DIR"
  local config_hash_before
  config_hash_before=$(sha256sum "$TEST_TMPDIR/dotfiles/mise/config.toml" | cut -d' ' -f1)

  run env PATH="$INSTALL_BIN" bash "$AP_HELPER" setup --apply --agent codex \
    --prepare-dir "$TEST_TMPDIR/prepared"
  assert_success
  assert_output_contains "managed configuration detected"

  [[ -L "$MISE_CONFIG_DIR" ]]
  assert_equal "$config_hash_before" "$(sha256sum "$TEST_TMPDIR/dotfiles/mise/config.toml" | cut -d' ' -f1)"
  run ! grep -Fq "mise use --global" "$AP_SPY_LOG"

  # A real prepared source artifact is produced instead of an in-place edit.
  assert_file_exists "$TEST_TMPDIR/prepared/mise/config.toml.fragment"
  run grep -F -- 'codex = "latest"' "$TEST_TMPDIR/prepared/mise/config.toml.fragment"
  assert_success
  run grep -F -- "prepared/mise/config.toml.fragment" "$TEST_TMPDIR/prepared/INSTRUCTIONS.md"
  assert_success
}

@test "setup apply: multiple requested agents keep the original config backup" {
  build_install_env

  mkdir -p "$MISE_CONFIG_DIR"
  printf '[tools]\nnode = "lts"\n' >"$MISE_CONFIG_DIR/config.toml"
  local original
  original=$(sha256sum "$MISE_CONFIG_DIR/config.toml" | cut -d' ' -f1)

  # Simulate mise rewriting the global config for each install.
  cat >"$INSTALL_BIN/mise" <<MISE_WRAPPER
#!/usr/bin/env bash
printf '%s\n' "mise \$*" >>"\$AP_SPY_LOG"
if [[ "\${1:-}" == "use" ]]; then
  printf '%s = "latest"\n' "\${3%%@*}" >>"$MISE_CONFIG_DIR/config.toml"
  exit 0
fi
if [[ "\${1:-}" == "install" ]]; then
  exit 0
fi
exec "$REAL_MISE" "\$@"
MISE_WRAPPER
  chmod +x "$INSTALL_BIN/mise"

  run env PATH="$INSTALL_BIN" bash "$AP_HELPER" setup --apply --agent codex --agent claude
  assert_success

  local backups
  backups=$(find "${XDG_STATE_HOME:-$HOME/.local/state}/flyingnobita-agent-profiles/backups" \
    -path '*mise*' -name config.toml)
  [[ "$(printf '%s\n' "$backups" | grep -c .)" -eq 1 ]]
  assert_equal "$original" "$(sha256sum "$backups" | cut -d' ' -f1)"
}

@test "setup apply: repeated managed installs with an arbitrary prepare dir stay byte-identical" {
  build_install_env

  mkdir -p "$TEST_TMPDIR/dotfiles/mise"
  printf '[tools]\nnode = "lts"\n' >"$TEST_TMPDIR/dotfiles/mise/config.toml"
  rmdir "$MISE_CONFIG_DIR"
  ln -s "$TEST_TMPDIR/dotfiles/mise" "$MISE_CONFIG_DIR"
  local config_hash_before
  config_hash_before=$(sha256sum "$TEST_TMPDIR/dotfiles/mise/config.toml" | cut -d' ' -f1)

  # Arbitrary prepare directory name, including spaces and multiple agents.
  local prepare="$TEST_TMPDIR/prepared dir with spaces"
  run env PATH="$INSTALL_BIN" bash "$AP_HELPER" setup --apply \
    --agent codex --agent claude --prepare-dir "$prepare"
  assert_success

  local snapshot_first
  snapshot_first=$(snapshot_tree "$prepare")
  assert_file_exists "$prepare/mise/config.toml.fragment"
  assert_file_exists "$prepare/INSTRUCTIONS.md"
  [[ "$(grep -c '^## Managed global mise configuration$' "$prepare/INSTRUCTIONS.md")" -eq 1 ]]
  [[ "$(grep -c '^codex = "latest"$' "$prepare/mise/config.toml.fragment")" -eq 1 ]]
  [[ "$(grep -c '^claude = "latest"$' "$prepare/mise/config.toml.fragment")" -eq 1 ]]

  # A repeated run with the same arguments adds nothing and changes nothing.
  run env PATH="$INSTALL_BIN" bash "$AP_HELPER" setup --apply \
    --agent codex --agent claude --prepare-dir "$prepare"
  assert_success
  assert_equal "$snapshot_first" "$(snapshot_tree "$prepare")"

  # The real managed target is still untouched.
  [[ -L "$MISE_CONFIG_DIR" ]]
  assert_equal "$config_hash_before" "$(sha256sum "$TEST_TMPDIR/dotfiles/mise/config.toml" | cut -d' ' -f1)"
  run ! grep -Fq "mise use --global" "$AP_SPY_LOG"
}
