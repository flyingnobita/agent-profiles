#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  load 'lib.bash'
  setup_isolation
  setup_mise_env
  write_os_release arch arch "Arch Linux"

  REPO="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$REPO"
  cd "$REPO" || exit 1
}

teardown() {
  teardown_isolation
}

ap() {
  bash "$AP_HELPER" ap "$@"
}

@test "ap: NAME CMD runs the command in an existing profile" {
  run bash "$AP_HELPER" init --profile demo
  assert_success

  run ap demo sh -c 'printf "name=%s\n" "$AGENT_PROFILES_NAME"' sh
  assert_success
  assert_output_contains "name=demo"
}

@test "ap: arguments after the command are forwarded unchanged" {
  run bash "$AP_HELPER" init --profile demo
  assert_success

  run ap demo printf '%s|' 'a b' --profile -- x
  assert_success
  assert_output_contains "a b|--profile|--|x|"
}

@test "ap: NAME alone opens your shell inside the profile" {
  run bash "$AP_HELPER" init --profile demo
  assert_success

  local shell="$TEST_TMPDIR/fake-shell"
  printf '#!/usr/bin/env bash\nprintf "shell in %%s\\n" "$AGENT_PROFILES_NAME"\n' >"$shell"
  chmod +x "$shell"

  run env SHELL="$shell" bash "$AP_HELPER" ap demo
  assert_success
  assert_output_contains "shell in demo"
}

@test "ap: a missing profile is not created without a terminal or --create" {
  run ap demo true
  assert_failure 66
  assert_output_contains "profile 'demo' does not exist"
  assert_output_contains "--create"
  [[ ! -e "$REPO/.agent-profiles/demo" ]]
}

@test "ap: --create makes a missing profile and runs the command" {
  run ap --create demo sh -c 'printf "name=%s\n" "$AGENT_PROFILES_NAME"' sh
  assert_success
  assert_dir_exists "$REPO/.agent-profiles/demo/home"
  assert_output_contains "name=demo"
}

@test "ap: in a terminal a missing profile is created only after a yes" {
  command -v script >/dev/null 2>&1 || skip "script(1) is not available"

  run script -qec "bash '$AP_HELPER' ap demo true" /dev/null <<<"n"
  assert_failure
  [[ ! -e "$REPO/.agent-profiles/demo" ]]

  run script -qec "bash '$AP_HELPER' ap demo true" /dev/null <<<"y"
  assert_success
  assert_output_contains "Create profile 'demo'"
  assert_dir_exists "$REPO/.agent-profiles/demo/home"
}

@test "ap: new, ls and rm manage profiles by plain name" {
  run ap new demo
  assert_success
  assert_dir_exists "$REPO/.agent-profiles/demo/home"

  run ap ls
  assert_success
  assert_output_contains "demo"

  run ap rm demo
  assert_success
  assert_dir_exists "$REPO/.agent-profiles/demo/home"

  run ap rm demo --yes
  assert_success
  [[ ! -e "$REPO/.agent-profiles/demo" ]]
}

@test "ap: the --profile form of the previous task keeps working" {
  run ap new demo
  assert_success

  run ap --profile demo sh -c 'printf "name=%s\n" "$AGENT_PROFILES_NAME"' sh
  assert_success
  assert_output_contains "name=demo"
}

@test "ap: migrate, recover and --version reach the helper" {
  run ap --version
  assert_success
  assert_output_equals "$(tr -d '[:space:]' <"$AP_SKILL_DIR/VERSION")"

  run ap migrate
  assert_success
  assert_output_contains "No legacy profile storage"

  run ap recover
  assert_success
  assert_output_contains "No interrupted operations"
}

@test "ap: no arguments prints usage" {
  run ap
  assert_failure 64
  assert_output_contains "mise ap NAME"
}

@test "setup apply: installs one quiet agent-profiles task aliased ap" {
  run bash "$AP_HELPER" setup --apply --tasks-only
  assert_success

  local task="$MISE_CONFIG_DIR/tasks/agent-profiles"
  assert_file_exists "$task"
  [[ ! -e "$MISE_CONFIG_DIR/tasks/agent-profiles-init" ]]
  grep -Fxq '#MISE alias="ap"' "$task"
  grep -Fxq '#MISE quiet=true' "$task"

  run mise ap --create demo sh -c 'printf "name=%s\n" "$AGENT_PROFILES_NAME"' sh
  assert_success
  assert_output_contains "name=demo"
  assert_output_not_contains "[agent-profiles]"
}

@test "setup apply: a retired managed agent-profiles-init task is backed up and removed" {
  local retired="$MISE_CONFIG_DIR/tasks/agent-profiles-init"
  mkdir -p "$(dirname "$retired")"
  printf '#!/usr/bin/env bash\n# managed-by: flyingnobita-agent-profiles 0.1.0 sha256:%064d\n' 0 >"$retired"

  run bash "$AP_HELPER" setup --apply --tasks-only
  assert_success
  assert_output_contains "removed retired task: $retired"
  [[ ! -e "$retired" ]]
  [[ -n "$(find "$XDG_STATE_HOME/flyingnobita-agent-profiles/backups" -type f -name agent-profiles-init)" ]]
}

@test "setup apply: a foreign agent-profiles-init task is left untouched" {
  local foreign="$MISE_CONFIG_DIR/tasks/agent-profiles-init"
  mkdir -p "$(dirname "$foreign")"
  printf '#!/usr/bin/env bash\necho mine\n' >"$foreign"

  run bash "$AP_HELPER" setup --apply --tasks-only
  assert_success
  grep -Fq 'echo mine' "$foreign"
}
