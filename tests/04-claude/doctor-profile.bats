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

@test "doctor: reports agents.claude.profile diagnostics when --profile is specified" {
  local repo="$TEST_TMPDIR/repo-claude-doc"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile alpha
  assert_success

  run bash "$AP_HELPER" doctor --json --agent claude --profile alpha
  assert_success

  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
claude = data["agents"]["claude"]
assert claude["profile"] is not None, "expected claude.profile to be non-null"
prof = claude["profile"]
assert prof["name"] == "alpha"
assert prof["status"] == "initialized"
assert prof["config_dir"] == sys.argv[2]
assert "auth" in prof
assert prof["auth"]["logged_in"] is False
assert prof["auth"]["method"] == "none"
' "$output" "$repo/.agent-profiles/alpha/.claude"
}

@test "doctor: reports uninitialized profile status when requested profile is not initialized" {
  local repo="$TEST_TMPDIR/repo-claude-uninit"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" doctor --json --agent claude --profile ghost
  assert_success

  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
claude = data["agents"]["claude"]
assert claude["profile"] is not None, "expected claude.profile to be non-null"
prof = claude["profile"]
assert prof["name"] == "ghost"
assert prof["status"] == "uninitialized"
' "$output"
}

@test "doctor: never leaks environment credential values in claude profile diagnostics" {
  local repo="$TEST_TMPDIR/repo-claude-sec-doc"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile alpha
  assert_success

  run env ANTHROPIC_API_KEY="secret-ant-key-999" \
    CLAUDE_CODE_OAUTH_TOKEN="secret-oauth-token-888" \
    bash "$AP_HELPER" doctor --json --agent claude --profile alpha
  assert_success

  assert_output_not_contains "secret-ant-key-999"
  assert_output_not_contains "secret-oauth-token-888"
}

@test "doctor: classifies inherited environment credentials without printing their values" {
  local repo="$TEST_TMPDIR/repo-claude-env-auth"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile alpha
  assert_success

  run env ANTHROPIC_API_KEY="doctor-env-secret-777" \
    bash "$AP_HELPER" doctor --json --agent claude --profile alpha
  assert_success
  assert_output_not_contains "doctor-env-secret-777"

  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
auth = data["agents"]["claude"]["profile"]["auth"]
assert auth["logged_in"] is True
assert auth["status"] == "env_inherited"
assert auth["method"] == "environment"
assert "ANTHROPIC_API_KEY" in auth["detail"]
' "$output"
}

@test "doctor: reports profile-stored credentials without reading their contents" {
  local repo="$TEST_TMPDIR/repo-claude-profile-auth"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile alpha
  assert_success

  printf '{"token":"doctor-profile-stored-secret"}\n' \
    >"$repo/.agent-profiles/alpha/.claude/.credentials.json"
  chmod 600 "$repo/.agent-profiles/alpha/.claude/.credentials.json"

  run bash "$AP_HELPER" doctor --json --agent claude --profile alpha
  assert_success
  assert_output_not_contains "doctor-profile-stored-secret"

  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
auth = data["agents"]["claude"]["profile"]["auth"]
assert auth["logged_in"] is True
assert auth["status"] == "profile_stored"
assert auth["method"] == "profile_stored"
' "$output"
}
