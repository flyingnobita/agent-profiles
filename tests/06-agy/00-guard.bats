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

@test "guard: helper exists at subject and returns semver" {
  assert_file_exists "$AP_HELPER"
  run bash "$AP_HELPER" --version
  assert_success
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "guard: doctor --json returns valid schema with agy entry" {
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
assert "agy" in data["agents"]
' "$output"
}

@test "guard: init creates .gemini and bubblewrap redirects the host .gemini directory" {
  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile test-agy
  assert_success
  assert_dir_exists "$repo/.agent-profiles/test-agy/.gemini"

  mkdir -p "$HOME/.gemini/config"
  run bash "$AP_HELPER" run --profile test-agy -- sh -c 'printf "gemini_marker\n" > "$HOME/.gemini/marker.txt"; mkdir -p "$HOME/.gemini/config"; printf "gemini_config_marker\n" > "$HOME/.gemini/config/marker.txt"'
  assert_success
  assert_file_exists "$repo/.agent-profiles/test-agy/.gemini/marker.txt"
  assert_file_exists "$repo/.agent-profiles/test-agy/.gemini/config/marker.txt"
  [[ ! -f "$HOME/.gemini/marker.txt" ]]
  [[ ! -f "$HOME/.gemini/config/marker.txt" ]]
}

@test "guard: bubblewrap redirects the host .agents directory inside a profile" {
  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile test-agy-agents
  assert_success

  mkdir -p "$HOME/.agents"
  run bash "$AP_HELPER" run --profile test-agy-agents -- sh -c 'printf "agents_marker\n" > "$HOME/.agents/marker.txt"'
  assert_success
  assert_file_exists "$repo/.agent-profiles/test-agy-agents/.agents/marker.txt"
  [[ ! -f "$HOME/.agents/marker.txt" ]]
}

@test "guard: doctor detects a stub agy on PATH without executing it as readiness evidence" {
  local stub_bin="$TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_bin"
  cat >"$stub_bin/agy" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "1.4.9"
  exit 0
fi
exit 0
STUB
  chmod +x "$stub_bin/agy"
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

  run env PATH="$stub_bin:$PATH" bash "$AP_HELPER" doctor --json --agent agy
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
agy = data["agents"]["agy"]
assert agy["status"] == "available", agy
assert agy["version"] == "1.4.9", agy
' "$output"
}
