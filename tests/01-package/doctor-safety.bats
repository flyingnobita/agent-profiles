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

@test "doctor safety: never leaks raw probe output containing secrets in version_probe" {
  local stub_bin="$TEST_TMPDIR/secret-stub-bin"
  mkdir -p "$stub_bin"
  cat << 'EOF' > "$stub_bin/claude"
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "test-profile-secret-123 1.2.3"
  exit 0
fi
EOF
  chmod +x "$stub_bin/claude"

  run env PATH="$stub_bin:$PATH" bash "$AP_HELPER" doctor --json
  assert_success

  # Verify raw secret marker is NOT in output
  assert_output_not_contains "test-profile-secret-123"

  # Verify parsed version and controlled classification
  run python3 -c '
import json, sys
data = json.loads(sys.argv[1])
claude = data["agents"]["claude"]
ver = claude.get("version")
assert ver == "1.2.3", f"unexpected version {ver}"
st = claude.get("status")
assert st == "available", f"unexpected status {st}"
probe = claude.get("version_probe")
assert probe == "verified", f"unexpected probe classification {probe}"
' "$output"
  assert_success
}

@test "doctor safety: failing probe marks agent unverified instead of available" {
  local stub_bin="$TEST_TMPDIR/fail-stub-bin"
  mkdir -p "$stub_bin"
  cat << 'EOF' > "$stub_bin/claude"
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "fatal: internal initialization failure with secret 999" >&2
  exit 1
fi
EOF
  chmod +x "$stub_bin/claude"

  run env PATH="$stub_bin:$PATH" bash "$AP_HELPER" doctor --agent claude --json
  assert_success

  # Raw stderr must NOT be in output
  assert_output_not_contains "internal initialization failure"
  assert_output_not_contains "secret 999"

  # Status must be unverified, NOT available
  run python3 -c '
import json, sys
data = json.loads(sys.argv[1])
claude = data["agents"]["claude"]
st = claude.get("status")
assert st == "unverified", f"expected unverified, got {st}"
ver = claude.get("version")
assert ver is None, f"expected null version, got {ver}"
probe = claude.get("version_probe")
assert probe == "probe_failed", f"unexpected probe {probe}"
' "$output"
  assert_success
}

@test "doctor safety: hanging probe times out and marks agent unverified" {
  local stub_bin="$TEST_TMPDIR/hang-stub-bin"
  mkdir -p "$stub_bin"
  cat << 'EOF' > "$stub_bin/claude"
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  sleep 10
  exit 0
fi
EOF
  chmod +x "$stub_bin/claude"

  run env PATH="$stub_bin:$PATH" bash "$AP_HELPER" doctor --agent claude --json
  assert_success

  run python3 -c '
import json, sys
data = json.loads(sys.argv[1])
claude = data["agents"]["claude"]
st = claude.get("status")
assert st == "unverified", f"expected unverified, got {st}"
ver = claude.get("version")
assert ver is None, f"expected null version, got {ver}"
probe = claude.get("version_probe")
assert probe == "timeout", f"unexpected probe {probe}"
' "$output"
  assert_success
}

@test "doctor safety: arbitrary MISE_ environment variables are not forwarded to synthetic probe" {
  local stub_bin="$TEST_TMPDIR/mise-check-bin"
  local leak_file="$TEST_TMPDIR/leaked-env.tmp"
  mkdir -p "$stub_bin"
  cat << EOF > "$stub_bin/claude"
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  if [[ -n "\${MISE_SECRET_TOKEN:-}" ]]; then
    touch "$leak_file"
  fi
  echo "claude 2.1.312"
  exit 0
fi
EOF
  chmod +x "$stub_bin/claude"

  export MISE_SECRET_TOKEN="topsecret12345"
  run env PATH="$stub_bin:$PATH" bash "$AP_HELPER" doctor --agent claude --json
  assert_success

  # The leak file must NOT exist
  [[ ! -f "$leak_file" ]]
}

@test "doctor modularity: per-agent modules exist under lib/agents" {
  for agent in claude codex agy opencode; do
    assert_file_exists "$AP_SKILL_DIR/scripts/lib/agents/$agent.sh"
  done
}
