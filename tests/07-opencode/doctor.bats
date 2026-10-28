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

@test "opencode doctor: resolves the real binary through mise and reports its version" {
  command -v opencode >/dev/null 2>&1 || skip "opencode is not installed on this host"

  local repo="$TEST_TMPDIR/repo-opencode-doctor"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" doctor --json --agent opencode
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
opencode = data["agents"]["opencode"]
path = opencode.get("path")
assert path is not None, opencode
assert not (path.endswith("/bin/mise") or path == "/usr/bin/mise"), f"resolved path was mise: {path}"
assert path.split("/")[-1].startswith("opencode"), f"unexpected opencode binary path: {path}"
version = opencode.get("version")
assert version, opencode
assert version[0].isdigit(), f"unexpected opencode version: {version}"
' "$output"
}

@test "opencode doctor: a standalone PATH binary is used when mise does not manage opencode" {
  local repo="$TEST_TMPDIR/repo-opencode-standalone"
  create_fixture_repo "$repo"
  cd "$repo"

  local fake_bin="$TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "opencode v2.2.0"
  exit 0
fi
exit 0
STUB
  chmod +x "$fake_bin/opencode"

  local fake_mise_bin="$TEST_TMPDIR/fake-mise-bin"
  mkdir -p "$fake_mise_bin"
  cat >"$fake_mise_bin/mise" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "which" ]]; then
  exit 1
fi
exec /usr/bin/mise "$@"
STUB
  chmod +x "$fake_mise_bin/mise"

  run env PATH="$fake_mise_bin:$fake_bin:$PATH" bash "$AP_HELPER" doctor --json --agent opencode
  assert_success
  python3 - "$output" "$fake_bin/opencode" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
opencode = data["agents"]["opencode"]
assert opencode["status"] == "available", opencode
assert opencode["version"] == "2.2.0", opencode
assert opencode["path"] == sys.argv[2], opencode
PY
}
