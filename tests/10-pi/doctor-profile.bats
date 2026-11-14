#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  load '../helpers/platform.bash'
  setup_isolation

  unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY ZAI_API_KEY OPENCODE_API_KEY

  local fake_bin="$TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/pi" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "1.5.2"
  exit 0
fi
exit 0
STUB
  chmod +x "$fake_bin/pi"

  cat >"$fake_bin/mise" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "which" ]]; then
  exit 1
fi
exec /usr/bin/mise "$@"
STUB
  chmod +x "$fake_bin/mise"

  export PATH="$fake_bin:$PATH"
}

teardown() {
  teardown_isolation
}

@test "pi doctor profile: reports agent artifacts and credential sources without values" {
  local repo="$TEST_TMPDIR/repo-pi-profile"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  local agent_dir="$repo/.agent-profiles/dev/.pi/agent"
  mkdir -p "$agent_dir/sessions" "$agent_dir/skills/alpha"
  printf '{"synthetic":"marker"}\n' >"$agent_dir/settings.json"
  printf '{"apiKey":"secret-pi-token-811"}\n' >"$agent_dir/auth.json"

  local before after
  before=$(ap_test_tree_digest "$repo/.agent-profiles/dev")

  run env ANTHROPIC_API_KEY="secret-pi-env-811" \
    bash "$AP_HELPER" doctor --json --agent pi --profile dev
  assert_success
  assert_output_not_contains "secret-pi-token-811"
  assert_output_not_contains "secret-pi-env-811"

  python3 - "$output" "$repo/.agent-profiles/dev" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile_dir = sys.argv[2]
profile = data["agents"]["pi"]["profile"]
assert profile is not None, "expected pi profile diagnostics"
assert profile["name"] == "dev"
assert profile["status"] == "initialized"
assert profile["initialized"] is True
assert profile["config_dir"] == profile_dir + "/.pi/agent"

artifacts = profile["artifacts"]
assert artifacts["agent_dir"] is True, artifacts
assert artifacts["settings"] is True, artifacts
assert artifacts["auth_json"] is True, artifacts
assert artifacts["sessions"] is True, artifacts
assert artifacts["skills"] is True, artifacts

auth = profile["auth"]
assert auth["status"] == "profile_credential_files", auth
assert auth["authenticated"] is None, "file presence must never mean authenticated"
assert auth["profile_files"] == [".pi/agent/auth.json"], auth["profile_files"]
assert auth["env_credentials"] == ["ANTHROPIC_API_KEY"], auth
assert "not proof of account separation" in auth["note"], auth
PY

  after=$(ap_test_tree_digest "$repo/.agent-profiles/dev")
  assert_equal "$after" "$before"
}

@test "pi doctor profile: fresh profile reports no profile credentials" {
  local repo="$TEST_TMPDIR/repo-pi-profile-fresh"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile fresh
  assert_success

  run env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GEMINI_API_KEY -u OPENROUTER_API_KEY \
    -u ZAI_API_KEY -u OPENCODE_API_KEY \
    bash "$AP_HELPER" doctor --json --agent pi --profile fresh
  assert_success

  python3 - "$output" "$repo/.agent-profiles/fresh" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["pi"]["profile"]
assert profile["status"] == "initialized", profile
assert profile["config_dir"] == sys.argv[2] + "/.pi/agent"
auth = profile["auth"]
assert auth["status"] == "no_profile_credentials", auth
assert auth["authenticated"] is None, auth
assert auth["profile_files"] == [], auth
assert auth["env_credentials"] == [], auth
PY
}

@test "pi doctor profile: uninitialized profile is reported without creating it" {
  local repo="$TEST_TMPDIR/repo-pi-profile-ghost"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" doctor --json --agent pi --profile ghost
  assert_success

  python3 - "$output" "$repo/.agent-profiles/ghost" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["pi"]["profile"]
assert profile["name"] == "ghost"
assert profile["status"] == "uninitialized"
assert profile["initialized"] is False
assert profile["config_dir"] == sys.argv[2] + "/.pi/agent"
assert profile["auth"]["status"] == "uninitialized"
assert profile["auth"]["authenticated"] is None
assert profile["auth"]["profile_files"] == []
PY

  [[ ! -e "$repo/.agent-profiles/ghost" ]]
}

@test "pi doctor profile: no profile diagnostics without --profile" {
  local repo="$TEST_TMPDIR/repo-pi-profile-none"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  run bash "$AP_HELPER" doctor --json --agent pi
  assert_success

  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert data["agents"]["pi"]["profile"] is None
' "$output"
}

@test "pi doctor profile: agent filter does not run the pi profile probe" {
  local repo="$TEST_TMPDIR/repo-pi-profile-filter"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  run bash "$AP_HELPER" doctor --json --agent codex --profile dev
  assert_success

  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
pi = data["agents"].get("pi")
assert pi is None or pi["profile"] is None
' "$output"
}
