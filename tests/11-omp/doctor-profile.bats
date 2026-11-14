#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  load '../helpers/platform.bash'
  setup_isolation

  unset ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN OPENAI_API_KEY GEMINI_API_KEY \
    OPENROUTER_API_KEY COPILOT_GITHUB_TOKEN ZAI_API_KEY OPENCODE_API_KEY

  local fake_bin="$TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/omp" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "omp/18.20.0"
  exit 0
fi
exit 0
STUB
  chmod +x "$fake_bin/omp"

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

@test "omp doctor profile: reports agent state and credential source without values" {
  local repo="$TEST_TMPDIR/repo-omp-profile"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  local agent_dir="$repo/.agent-profiles/dev/.omp/agent"
  mkdir -p "$agent_dir/sessions" "$agent_dir/skills/alpha" \
    "$repo/.agent-profiles/dev/.omp/logs" "$repo/.agent-profiles/dev/.omp/natives/18.20.0" \
    "$repo/.agent-profiles/dev/.omp/run/daemons"
  printf 'synthetic-agent-db-secret-712\n' >"$agent_dir/agent.db"
  printf 'synthetic-models-db\n' >"$agent_dir/models.db"

  local before after
  before=$(ap_test_tree_digest "$repo/.agent-profiles/dev")

  run env ANTHROPIC_API_KEY="secret-omp-env-712" \
    bash "$AP_HELPER" doctor --json --agent omp --profile dev
  assert_success
  assert_output_not_contains "synthetic-agent-db-secret-712"
  assert_output_not_contains "secret-omp-env-712"

  python3 - "$output" "$repo/.agent-profiles/dev" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile_dir = sys.argv[2]
profile = data["agents"]["omp"]["profile"]
assert profile is not None, "expected omp profile diagnostics"
assert profile["name"] == "dev"
assert profile["status"] == "initialized"
assert profile["initialized"] is True
assert profile["config_dir"] == profile_dir + "/.omp"
assert profile["agent_dir"] == profile_dir + "/.omp/agent"

artifacts = profile["artifacts"]
assert artifacts["agent_dir"] is True, artifacts
assert artifacts["agent_db"] is True, artifacts
assert artifacts["models_db"] is True, artifacts
assert artifacts["sessions"] is True, artifacts
assert artifacts["skills"] is True, artifacts
assert artifacts["logs"] is True, artifacts
assert artifacts["natives"] is True, artifacts
assert artifacts["runtime"] is True, artifacts

auth = profile["auth"]
assert auth["status"] == "profile_credential_store", auth
assert auth["authenticated"] is None, "database presence must never mean authenticated"
assert auth["credential_store"] == ".omp/agent/agent.db", auth
assert auth["env_credentials"] == ["ANTHROPIC_API_KEY"], auth
assert "not proof of account separation" in auth["note"], auth
PY

  after=$(ap_test_tree_digest "$repo/.agent-profiles/dev")
  assert_equal "$after" "$before"
}

@test "omp doctor profile: fresh profile reports no profile credentials" {
  local repo="$TEST_TMPDIR/repo-omp-profile-fresh"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile fresh
  assert_success

  run env -u ANTHROPIC_API_KEY -u ANTHROPIC_OAUTH_TOKEN -u OPENAI_API_KEY -u GEMINI_API_KEY \
    -u OPENROUTER_API_KEY -u COPILOT_GITHUB_TOKEN -u ZAI_API_KEY -u OPENCODE_API_KEY \
    bash "$AP_HELPER" doctor --json --agent omp --profile fresh
  assert_success

  python3 - "$output" "$repo/.agent-profiles/fresh" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["omp"]["profile"]
assert profile["status"] == "initialized", profile
assert profile["config_dir"] == sys.argv[2] + "/.omp"
auth = profile["auth"]
assert auth["status"] == "no_profile_credentials", auth
assert auth["authenticated"] is None, auth
assert auth["credential_store"] is None, auth
assert auth["env_credentials"] == [], auth
PY
}

@test "omp doctor profile: uninitialized profile is reported without creating it" {
  local repo="$TEST_TMPDIR/repo-omp-profile-ghost"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" doctor --json --agent omp --profile ghost
  assert_success

  python3 - "$output" "$repo/.agent-profiles/ghost" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["omp"]["profile"]
assert profile["name"] == "ghost"
assert profile["status"] == "uninitialized"
assert profile["initialized"] is False
assert profile["config_dir"] == sys.argv[2] + "/.omp"
assert profile["auth"]["status"] == "uninitialized"
assert profile["auth"]["authenticated"] is None
assert profile["auth"]["credential_store"] is None
PY

  [[ ! -e "$repo/.agent-profiles/ghost" ]]
}

@test "omp doctor profile: no profile diagnostics without --profile" {
  local repo="$TEST_TMPDIR/repo-omp-profile-none"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  run bash "$AP_HELPER" doctor --json --agent omp
  assert_success

  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert data["agents"]["omp"]["profile"] is None
' "$output"
}

@test "omp doctor profile: agent filter does not run the omp profile probe" {
  local repo="$TEST_TMPDIR/repo-omp-profile-filter"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  run bash "$AP_HELPER" doctor --json --agent codex --profile dev
  assert_success

  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
omp = data["agents"].get("omp")
assert omp is None or omp["profile"] is None
' "$output"
}
