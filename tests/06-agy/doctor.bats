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

@test "agy doctor: resolves the real binary through mise and reports its version" {
  command -v agy >/dev/null 2>&1 || skip "agy is not installed on this host"

  local repo="$TEST_TMPDIR/repo-agy-doctor"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" doctor --json --agent agy
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
agy = data["agents"]["agy"]
path = agy.get("path")
assert path is not None, agy
assert not (path.endswith("/bin/mise") or path == "/usr/bin/mise"), f"resolved path was mise: {path}"
assert path.split("/")[-1] in ("agy", "antigravity"), f"unexpected agy binary path: {path}"
version = agy.get("version")
assert version, agy
assert version[0].isdigit(), f"unexpected agy version: {version}"
' "$output"
}

@test "agy doctor: a standalone PATH binary is used when mise does not manage agy" {
  local repo="$TEST_TMPDIR/repo-agy-standalone"
  create_fixture_repo "$repo"
  cd "$repo"

  local fake_bin="$TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/agy" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "1.4.9"
  exit 0
fi
exit 0
STUB
  chmod +x "$fake_bin/agy"

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

  run env PATH="$fake_mise_bin:$fake_bin:$PATH" bash "$AP_HELPER" doctor --json --agent agy
  assert_success
  python3 - "$output" "$fake_bin/agy" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
agy = data["agents"]["agy"]
assert agy["status"] == "available", agy
assert agy["version"] == "1.4.9", agy
assert agy["path"] == sys.argv[2], agy
PY
}
