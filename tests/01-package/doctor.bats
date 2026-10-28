#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation
}

teardown() {
  teardown_isolation
}

@test "doctor: runs successfully in text mode" {
  run bash "$AP_HELPER" doctor
  assert_success
  assert_output_contains "OS:"
  assert_output_contains "Dependencies:"
  assert_output_contains "Agents:"
}

@test "doctor: --json produces valid JSON matching schema" {
  run bash "$AP_HELPER" doctor --json
  assert_success

  # Verify top-level keys
  run python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert "version" in data, "missing version"
assert "os" in data, "missing os"
assert "checks" in data, "missing checks"
assert "agents" in data, "missing agents"
assert isinstance(data["checks"], list), "checks is not a list"
assert isinstance(data["agents"], dict), "agents is not a dict"
for agent in ["claude", "codex", "agy", "opencode"]:
    assert agent in data["agents"], f"missing agent {agent}"
    assert "status" in data["agents"][agent]
' "$output"
  assert_success
}

@test "doctor: missing optional agent does not prevent diagnosing another" {
  # Create a custom bin with a stub codex but no claude
  local stub_bin="$TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_bin"
  cat << 'EOF' > "$stub_bin/codex"
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "codex-cli 0.163.0"
  exit 0
fi
EOF
  chmod +x "$stub_bin/codex"

  # Run doctor with restricted PATH
  run env PATH="$stub_bin:/usr/bin:/bin" bash "$AP_HELPER" doctor --json
  assert_success

  run python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert data["agents"]["codex"]["status"] == "available"
assert data["agents"]["claude"]["status"] == "missing"
' "$output"
  assert_success
}

@test "doctor: synthetic version probe runs in temporary isolated environment" {
  local stub_bin="$TEST_TMPDIR/dirty-bin"
  mkdir -p "$stub_bin"
  cat << 'EOF' > "$stub_bin/claude"
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  touch "$HOME/dirty-marker.tmp"
  echo "claude 2.1.312"
  exit 0
fi
EOF
  chmod +x "$stub_bin/claude"

  run env PATH="$stub_bin:$PATH" bash "$AP_HELPER" doctor --json
  assert_success

  # The dirty marker must NOT be in the caller's HOME
  [[ ! -f "$HOME/dirty-marker.tmp" ]]
}

@test "doctor: secret safety never leaks environment credential values" {
  export ANTHROPIC_API_KEY="sk-ant-super-secret-marker-12345"
  export OPENAI_API_KEY="sk-proj-super-secret-marker-67890"

  run bash "$AP_HELPER" doctor
  assert_success
  assert_output_not_contains "super-secret-marker-12345"
  assert_output_not_contains "super-secret-marker-67890"

  run bash "$AP_HELPER" doctor --json
  assert_success
  assert_output_not_contains "super-secret-marker-12345"
  assert_output_not_contains "super-secret-marker-67890"
}

@test "doctor: reports actionable hints for missing dependencies" {
  # Run in environment without bwrap
  local no_bwrap_bin="$TEST_TMPDIR/no-bwrap-bin"
  mkdir -p "$no_bwrap_bin"
  for cmd in bash git python3 mise readlink dirname cat grep sed timeout which uname env rm mkdir touch printf cut tr ls head tail; do
    p=$(command -v "$cmd" 2>/dev/null || true)
    if [[ -n "$p" ]]; then
      ln -s "$p" "$no_bwrap_bin/$cmd"
    fi
  done

  run env PATH="$no_bwrap_bin" bash "$AP_HELPER" doctor --json
  assert_success

  run python3 -c '
import json, sys
data = json.loads(sys.argv[1])
bwrap_checks = [c for c in data["checks"] if c["id"] == "bwrap"]
assert len(bwrap_checks) > 0, "no bwrap check found"
assert bwrap_checks[0]["status"] == "missing"
assert len(bwrap_checks[0]["hint"]) > 0, "bwrap check has no actionable hint"
' "$output"
  assert_success
}
