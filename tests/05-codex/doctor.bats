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

@test "codex doctor: resolves mise-backed launcher to real codex binary and parses codex version" {
  local repo="$TEST_TMPDIR/repo-codex-doctor"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" doctor --json
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
codex = data["agents"]["codex"]
assert codex["status"] in ["available", "unverified"]
assert codex["path"] is not None
cp = codex["path"]
assert not (cp.endswith("/bin/mise") or cp == "/usr/bin/mise"), f"resolved path was mise binary: {cp}"
assert cp.endswith("codex"), f"resolved path does not end with codex: {cp}"
cv = codex.get("version")
if cv:
    assert cv.startswith("0."), f"expected codex version starting with 0., got {cv}"
' "$output"
}

@test "codex doctor: standalone fallback uses direct PATH binary when mise is not managing codex" {
  local repo="$TEST_TMPDIR/repo-codex-standalone"
  create_fixture_repo "$repo"
  cd "$repo"

  local fake_bin="$TEST_TMPDIR/fake_bin"
  mkdir -p "$fake_bin"
  cat <<'EOF' > "$fake_bin/codex"
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "codex-cli 0.163.0"
  exit 0
fi
exit 0
EOF
  chmod +x "$fake_bin/codex"

  local fake_mise_bin="$TEST_TMPDIR/fake_mise_bin"
  mkdir -p "$fake_mise_bin"
  cat <<'EOF' > "$fake_mise_bin/mise"
#!/usr/bin/env bash
# Simulate mise without codex installed
if [[ "$1" == "which" && "$2" == "codex" ]]; then
  exit 1
fi
exec /usr/bin/mise "$@"
EOF
  chmod +x "$fake_mise_bin/mise"

  run env PATH="$fake_mise_bin:$fake_bin:$PATH" bash "$AP_HELPER" doctor --json --agent codex
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
codex = data["agents"]["codex"]
assert codex["status"] == "available"
assert codex["version"] == "0.163.0"
assert codex["path"] == sys.argv[2]
' "$output" "$fake_bin/codex"
}
