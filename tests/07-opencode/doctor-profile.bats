#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation

  unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY
  unset DEEPSEEK_API_KEY OPENROUTER_API_KEY OPENCODE_API_KEY

  local fake_bin="$TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/opencode" <<'STUB'
#!/usr/bin/env bash
printf 'executed\n' >>"$AP_OPENCODE_EXEC_MARKER"
if [[ "${1:-}" == "--version" ]]; then
  echo "opencode v2.2.0"
  exit 0
fi
exit 0
STUB
  chmod +x "$fake_bin/opencode"

  cat >"$fake_bin/mise" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "which" ]]; then
  exit 1
fi
exec /usr/bin/mise "$@"
STUB
  chmod +x "$fake_bin/mise"

  export PATH="$fake_bin:$PATH"
  export AP_OPENCODE_EXEC_MARKER="$TEST_TMPDIR/opencode-executed.marker"
}

teardown() {
  teardown_isolation
}

@test "opencode doctor profile: reports profile artifacts and auth sources without running the CLI" {
  local repo="$TEST_TMPDIR/repo-opencode-profile"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  local profile_dir="$repo/.agent-profiles/dev"
  mkdir -p "$profile_dir/.opencode/skills/alpha" "$profile_dir/.opencode/skill" \
    "$profile_dir/.local/share/opencode" "$profile_dir/.local/state/opencode" \
    "$profile_dir/.cache/opencode"
  printf '{"model":"synthetic-marker"}\n' >"$profile_dir/.opencode/opencode.json"
  printf '{"deepseek":{"type":"api","key":"secret-legacy-key-913"}}\n' \
    >"$profile_dir/.local/share/opencode/auth.json"

  local before after
  before=$(cd "$profile_dir" && find . -type f -exec sha256sum {} + | sort)

  run env DEEPSEEK_API_KEY="secret-env-value-913" OPENROUTER_API_KEY="secret-env-value-914" \
    bash "$AP_HELPER" doctor --json --agent opencode --profile dev
  assert_success
  assert_output_not_contains "secret-legacy-key-913"
  assert_output_not_contains "secret-env-value-913"
  assert_output_not_contains "secret-env-value-914"
  [[ ! -f "$AP_OPENCODE_EXEC_MARKER" ]]

  python3 - "$output" "$profile_dir" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile_dir = sys.argv[2]
profile = data["agents"]["opencode"]["profile"]
assert profile is not None, "expected opencode profile diagnostics"
assert profile["name"] == "dev"
assert profile["status"] == "initialized"
assert profile["initialized"] is True
assert profile["config_dir"] == profile_dir + "/.opencode"

artifacts = profile["artifacts"]
for key in ("config", "config_document", "skills", "data", "state", "cache", "legacy_auth_json"):
    assert key in artifacts, (key, artifacts)
assert artifacts["config"] is True, artifacts
assert artifacts["config_document"] is True, artifacts
assert artifacts["skills"] is True, artifacts
assert artifacts["data"] is True, artifacts
assert artifacts["state"] is True, artifacts
assert artifacts["cache"] is True, artifacts
assert artifacts["legacy_auth_json"] is True, artifacts

auth = profile["auth"]
assert auth["status"] == "profile_credential_files", auth
assert auth["authenticated"] is None, "file presence must never mean authenticated"
assert auth["profile_files"] == [".local/share/opencode/auth.json"], auth["profile_files"]
assert auth["env_credentials"] == ["DEEPSEEK_API_KEY", "OPENROUTER_API_KEY"], auth["env_credentials"]
assert "not proof of account separation" in auth["note"], auth
assert auth["detail"], auth

shared = profile["shared"]
service = shared["background_service_port"]
assert service["port"] == 49374, service
assert service["status"] in ("listening", "not_listening", "unverified"), service
assert "mise_managed" in shared, shared
PY

  after=$(cd "$profile_dir" && find . -type f -exec sha256sum {} + | sort)
  assert_equal "$after" "$before"
}

@test "opencode doctor profile: fresh profile reports no profile credentials" {
  local repo="$TEST_TMPDIR/repo-opencode-profile-fresh"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile fresh
  assert_success

  run env -u DEEPSEEK_API_KEY -u OPENROUTER_API_KEY bash "$AP_HELPER" doctor --json --agent opencode --profile fresh
  assert_success

  python3 - "$output" "$repo/.agent-profiles/fresh" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["opencode"]["profile"]
assert profile["status"] == "initialized", profile
assert profile["config_dir"] == sys.argv[2] + "/.opencode"
auth = profile["auth"]
assert auth["status"] == "no_profile_credentials", auth
assert auth["authenticated"] is None, auth
assert auth["profile_files"] == [], auth
assert auth["credential_providers"] == [], auth
assert auth["env_credentials"] == [], auth
PY
}

@test "opencode doctor profile: stored credential provider ids are reported without their values" {
  local repo="$TEST_TMPDIR/repo-opencode-profile-db"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile stored
  assert_success

  local data_dir="$repo/.agent-profiles/stored/.local/share/opencode"
  mkdir -p "$data_dir"
  python3 - "$data_dir/opencode.db" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE credential (integration_id TEXT, secret TEXT)")
con.execute("INSERT INTO credential VALUES ('deepseek', 'secret-db-key-913')")
con.commit()
con.close()
PY

  run bash "$AP_HELPER" doctor --json --agent opencode --profile stored
  assert_success
  assert_output_not_contains "secret-db-key-913"

  python3 - "$output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
auth = data["agents"]["opencode"]["profile"]["auth"]
assert auth["credential_providers"] == ["deepseek"], auth
assert auth["status"] == "profile_credential_files", auth
assert auth["authenticated"] is None, auth
PY
}

@test "opencode doctor profile: uninitialized profile is reported without creating it" {
  local repo="$TEST_TMPDIR/repo-opencode-profile-ghost"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" doctor --json --agent opencode --profile ghost
  assert_success

  python3 - "$output" "$repo/.agent-profiles/ghost" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["opencode"]["profile"]
assert profile["name"] == "ghost"
assert profile["status"] == "uninitialized"
assert profile["initialized"] is False
assert profile["config_dir"] == sys.argv[2] + "/.opencode"
assert profile["auth"]["status"] == "uninitialized"
assert profile["auth"]["authenticated"] is None
assert profile["auth"]["profile_files"] == []
PY

  [[ ! -e "$repo/.agent-profiles/ghost" ]]
  [[ ! -f "$AP_OPENCODE_EXEC_MARKER" ]]
}

@test "opencode doctor profile: no profile diagnostics without --profile" {
  local repo="$TEST_TMPDIR/repo-opencode-profile-none"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  run bash "$AP_HELPER" doctor --json --agent opencode
  assert_success

  python3 - "$output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["agents"]["opencode"]["profile"] is None
PY
}

@test "opencode doctor profile: agent filter does not run the opencode profile probe" {
  local repo="$TEST_TMPDIR/repo-opencode-profile-filter"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  run bash "$AP_HELPER" doctor --json --agent codex --profile dev
  assert_success

  python3 - "$output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
opencode = data["agents"].get("opencode")
assert opencode is None or opencode["profile"] is None
PY
}

@test "opencode doctor profile: the shared default service port is classified without starting a service" {
  local repo="$TEST_TMPDIR/repo-opencode-profile-port"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile port
  assert_success

  local port
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  python3 - "$port" "$TEST_TMPDIR/listener.ready" <<'PY' &
import socket
import sys
import time

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", int(sys.argv[1])))
sock.listen(1)
open(sys.argv[2], "w").close()
time.sleep(20)
PY
  local listener_pid=$!
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -f "$TEST_TMPDIR/listener.ready" ]] && break
    sleep 0.1
  done

  run env AP_OPENCODE_SERVICE_PORT="$port" bash "$AP_HELPER" doctor --json --agent opencode --profile port
  local listening_output="$output"
  kill "$listener_pid" 2>/dev/null || true
  wait "$listener_pid" 2>/dev/null || true
  assert_success

  python3 - "$listening_output" "$port" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
service = data["agents"]["opencode"]["profile"]["shared"]["background_service_port"]
assert service["port"] == int(sys.argv[2]), service
assert service["status"] == "listening", service
PY
}
