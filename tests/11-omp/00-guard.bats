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

@test "omp guard: helper exists at subject and returns semver" {
  assert_file_exists "$AP_HELPER"
  run bash "$AP_HELPER" --version
  assert_success
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "omp guard: doctor --json returns valid schema with omp entry" {
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
assert "omp" in data["agents"]
' "$output"
}

@test "omp guard: init creates .omp and a profile write lands there, not in host HOME" {
  local repo="$TEST_TMPDIR/repo-omp-redirect"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile test-omp
  assert_success
  assert_dir_exists "$repo/.agent-profiles/test-omp/.omp"

  mkdir -p "$HOME/.omp/agent"
  printf 'host-only\n' >"$HOME/.omp/agent/host-marker"

  run bash "$AP_HELPER" run --profile test-omp -- sh -c '
mkdir -p "$HOME/.omp/agent"
printf "profile\n" >"$HOME/.omp/agent/marker"
if [[ -f "$HOME/.omp/agent/host-marker" ]]; then printf "HOST_VISIBLE=yes\n"; else printf "HOST_VISIBLE=no\n"; fi
'
  assert_success
  assert_output_contains "HOST_VISIBLE=no"
  assert_file_exists "$repo/.agent-profiles/test-omp/.omp/agent/marker"
  [[ ! -f "$HOME/.omp/agent/marker" ]]
}

@test "omp guard: an inherited PI_CODING_AGENT_DIR is cleared inside a profile" {
  local repo="$TEST_TMPDIR/repo-omp-inherited"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile test-omp
  assert_success

  run env PI_CODING_AGENT_DIR="$TEST_TMPDIR/foreign-agent-dir" \
    bash "$AP_HELPER" run --profile test-omp -- sh -c 'printf "PI_DIR=%s\n" "${PI_CODING_AGENT_DIR:-unset}"'
  assert_success
  assert_output_contains "PI_DIR=unset"
}

@test "omp guard: doctor detects a stub omp on PATH without executing it as readiness evidence" {
  local stub_bin="$TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_bin"
  cat >"$stub_bin/omp" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "omp/18.20.0"
  exit 0
fi
exit 0
STUB
  chmod +x "$stub_bin/omp"
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

  run env PATH="$stub_bin:$PATH" bash "$AP_HELPER" doctor --json --agent omp
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
omp = data["agents"]["omp"]
assert omp["status"] == "available", omp
assert omp["version"] == "18.20.0", omp
' "$output"
}
