#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation
}

teardown() {
  teardown_isolation
}

@test "pi guard: helper exists at subject and returns semver" {
  assert_file_exists "$AP_HELPER"
  run bash "$AP_HELPER" --version
  assert_success
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "pi guard: doctor --json returns valid schema with pi entry" {
  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" doctor --json
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert "version" in data
assert "checks" in data
assert "agents" in data
assert "pi" in data["agents"]
' "$output"
}

@test "pi guard: init creates .pi and a profile write lands there, not in host HOME" {
  local repo="$TEST_TMPDIR/repo-pi-redirect"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile test-pi
  assert_success
  assert_dir_exists "$repo/.agent-profiles/test-pi/.pi"

  mkdir -p "$HOME/.pi/agent"
  printf 'host-only\n' >"$HOME/.pi/agent/host-marker"

  run bash "$AP_HELPER" run --profile test-pi -- sh -c '
mkdir -p "$HOME/.pi/agent"
printf "profile\n" >"$HOME/.pi/agent/marker"
if [[ -f "$HOME/.pi/agent/host-marker" ]]; then printf "HOST_VISIBLE=yes\n"; else printf "HOST_VISIBLE=no\n"; fi
'
  assert_success
  assert_output_contains "HOST_VISIBLE=no"
  assert_file_exists "$repo/.agent-profiles/test-pi/.pi/agent/marker"
  [[ ! -f "$HOME/.pi/agent/marker" ]]
}

@test "pi guard: an inherited PI_CODING_AGENT_DIR is cleared inside a profile" {
  local repo="$TEST_TMPDIR/repo-pi-inherited"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile test-pi
  assert_success

  run env PI_CODING_AGENT_DIR="$TEST_TMPDIR/foreign-agent-dir" \
    bash "$AP_HELPER" run --profile test-pi -- sh -c 'printf "PI_DIR=%s\n" "${PI_CODING_AGENT_DIR:-unset}"'
  assert_success
  assert_output_contains "PI_DIR=unset"
}

@test "pi guard: doctor detects a stub pi on PATH without executing it as readiness evidence" {
  local stub_bin="$TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_bin"
  cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "1.5.2"
  exit 0
fi
exit 0
STUB
  chmod +x "$stub_bin/pi"
  cat >"$stub_bin/mise" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "which" ]]; then
  exit 1
fi
exec /usr/bin/mise "$@"
STUB
  chmod +x "$stub_bin/mise"

  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run env PATH="$stub_bin:$PATH" bash "$AP_HELPER" doctor --json --agent pi
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
pi = data["agents"]["pi"]
assert pi["status"] == "available", pi
assert pi["version"] == "1.5.2", pi
' "$output"
}
