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

doctor_check() {
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
for check in data["checks"]:
    if check["id"] == sys.argv[2]:
        print(check["status"])
        print(check.get("detail", ""))
        print(check.get("hint", ""))
        sys.exit(0)
sys.exit(2)
' "$1" "$2"
}

@test "doctor: reports effective task configuration and namespace readiness after setup" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  run bash "$AP_HELPER" doctor --json
  assert_success

  local tasks
  tasks=$(doctor_check "$output" tasks)
  [[ "$(printf '%s\n' "$tasks" | sed -n '1p')" == "available" ]]
  [[ "$tasks" == *"$MISE_CONFIG_DIR/tasks"* ]]

  local namespaces
  namespaces=$(doctor_check "$output" namespaces)
  [[ "$(printf '%s\n' "$namespaces" | sed -n '1p')" == "available" ]]
  [[ "$namespaces" == *"namespaces"* ]]
}

@test "doctor: a moved release is reported broken with its missing path" {
  run bash "$AP_HELPER" setup --apply
  assert_success
  local release
  release=$(sed -n 's/^# release: //p' "$MISE_CONFIG_DIR/tasks/agent-profiles-init")
  mv "$release" "$release.moved"

  run mise run agent-profiles-init -- --profile demo
  assert_failure 78
  assert_output_contains "$release"
  assert_output_contains "rerun"

  run bash "$AP_HELPER" doctor --json
  assert_success
  local tasks
  tasks=$(doctor_check "$output" tasks)
  [[ "$(printf '%s\n' "$tasks" | sed -n '1p')" == "error" ]]
  [[ "$tasks" == *"$release"* ]]
}

@test "doctor: a skill update without setup rerun is reported stale" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local copy="$TEST_TMPDIR/skill-copy"
  cp -a "$AP_SKILL_DIR" "$copy"
  printf '\n# update that was not deployed\n' >>"$copy/scripts/lib/common.sh"

  run bash "$copy/scripts/agent-profiles" doctor --json
  assert_success
  local tasks
  tasks=$(doctor_check "$output" tasks)
  [[ "$(printf '%s\n' "$tasks" | sed -n '1p')" == "warning" ]]
  [[ "${tasks,,}" == *"stale"* ]]
}

@test "doctor: a project-level task shadows the global task and is reported" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local repo="$TEST_TMPDIR/shadow-repo"
  create_fixture_repo "$repo"
  printf '[tasks.agent-profiles-init]\nrun = "echo project shadow"\n' >"$repo/mise.toml"
  cd "$repo"

  run env MISE_TRUSTED_CONFIG_PATHS="$repo" bash "$AP_HELPER" doctor --json
  assert_success
  local tasks
  tasks=$(doctor_check "$output" tasks)
  [[ "$(printf '%s\n' "$tasks" | sed -n '1p')" == "warning" ]]
  [[ "${tasks,,}" == *"project"* ]]
}

@test "doctor: task and namespace checks are read-only" {
  run bash "$AP_HELPER" setup --apply
  assert_success
  # Exclude the host agent shims and mise from PATH so this assertion isolates
  # the ticket 03 task/namespace sections from informational version probes.
  local bin="$TEST_TMPDIR/ro-bin"
  make_restricted_bin "$bin" mise claude codex agy opencode

  local before after
  before=$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
    "$XDG_CACHE_HOME" "$MISE_CONFIG_DIR" "$MISE_DATA_DIR" "$MISE_STATE_DIR" "$MISE_CACHE_DIR")

  run env PATH="$bin" bash "$AP_HELPER" doctor --json
  assert_success

  after=$(snapshot_tree "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
    "$XDG_CACHE_HOME" "$MISE_CONFIG_DIR" "$MISE_DATA_DIR" "$MISE_STATE_DIR" "$MISE_CACHE_DIR")
  assert_equal "$after" "$before"
}

@test "doctor: a failing bubblewrap namespace probe is reported with an actionable cause" {
  local spy="$TEST_TMPDIR/spy-bin"
  mkdir -p "$spy"
  cat >"$spy/bwrap" <<'BWRAP'
#!/usr/bin/env bash
exit 1
BWRAP
  chmod +x "$spy/bwrap"

  run env PATH="$spy:$PATH" bash "$AP_HELPER" doctor --json
  assert_success
  local namespaces
  namespaces=$(doctor_check "$output" namespaces)
  [[ "$(printf '%s\n' "$namespaces" | sed -n '1p')" == "error" ]]
  [[ "${namespaces,,}" == *"seccomp"* || "${namespaces,,}" == *"userns"* || "${namespaces,,}" == *"apparmor"* ]]
}
