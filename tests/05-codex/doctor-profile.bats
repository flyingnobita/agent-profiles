#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation

  unset OPENAI_API_KEY OPENAI_BASE_URL OPENAI_ORG_ID OPENAI_PROJECT CODEX_API_KEY

  local fake_bin="$TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/codex" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "codex-cli 0.165.0"
  exit 0
fi
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  if [[ -n "${CODEX_HOME:-}" && -f "$CODEX_HOME/auth.json" ]]; then
    echo "Logged in using ChatGPT"
    exit 0
  fi
  echo "Not logged in"
  exit 1
fi
exit 0
STUB
  chmod +x "$fake_bin/codex"

  cat >"$fake_bin/mise" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "which" && "${2:-}" == "codex" ]]; then
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

@test "codex doctor profile: reports CODEX_HOME, artifacts, env names and reported login without treating presence as authentication" {
  local repo="$TEST_TMPDIR/repo-codex-profile"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  local codex_dir="$repo/.agent-profiles/dev/.codex"
  printf '{"synthetic":"marker"}\n' >"$codex_dir/auth.json"
  printf 'model = "synthetic"\n' >"$codex_dir/config.toml"
  mkdir -p "$codex_dir/skills/.system"
  printf 'bundled-marker\n' >"$codex_dir/skills/.system/marker"

  local before
  before=$(cd "$codex_dir" && find . -type f -exec sha256sum {} + | sort)

  run env OPENAI_API_KEY="secret-codex-key-777" \
    bash "$AP_HELPER" doctor --json --agent codex --profile dev
  assert_success
  assert_output_not_contains "secret-codex-key-777"

  python3 - "$output" "$codex_dir" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
codex_dir = sys.argv[2]
profile = data["agents"]["codex"]["profile"]
assert profile is not None, "expected codex.profile diagnostics"
assert profile["name"] == "dev"
assert profile["status"] == "initialized"
assert profile["initialized"] is True
assert profile["config_dir"] == codex_dir
assert profile["artifacts"] == {
    "auth_json": True,
    "config_toml": True,
    "sandbox_migration": False,
    "skills_system": True,
}, profile["artifacts"]
assert profile["auth"]["env_credentials"] == ["OPENAI_API_KEY"]
assert profile["auth"]["status"] == "login_reported"
assert profile["auth"]["logged_in"] is None, "presence or a status report must not mean authenticated"
assert profile["auth"]["probe_exit"] == 0
assert "not validated" in profile["auth"]["detail"]
PY

  local after
  after=$(cd "$codex_dir" && find . -type f -exec sha256sum {} + | sort)
  assert_equal "$after" "$before"
}

@test "codex doctor profile: fresh profile is logged out and reports no artifacts" {
  local repo="$TEST_TMPDIR/repo-codex-profile-fresh"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile fresh
  assert_success

  run env -u OPENAI_API_KEY -u OPENAI_BASE_URL -u OPENAI_ORG_ID -u OPENAI_PROJECT -u CODEX_API_KEY \
    bash "$AP_HELPER" doctor --json --agent codex --profile fresh
  assert_success

  python3 - "$output" "$repo/.agent-profiles/fresh/.codex" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["codex"]["profile"]
assert profile["status"] == "initialized"
assert profile["config_dir"] == sys.argv[2]
assert profile["artifacts"] == {
    "auth_json": False,
    "config_toml": False,
    "sandbox_migration": False,
    "skills_system": False,
}, profile["artifacts"]
assert profile["auth"]["env_credentials"] == []
assert profile["auth"]["status"] == "logged_out"
assert profile["auth"]["logged_in"] is False
assert profile["auth"]["probe_exit"] == 1
PY
}

@test "codex doctor profile: uninitialized profile is reported without creating it" {
  local repo="$TEST_TMPDIR/repo-codex-profile-ghost"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" doctor --json --agent codex --profile ghost
  assert_success

  python3 - "$output" "$repo/.agent-profiles/ghost/.codex" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["codex"]["profile"]
assert profile["name"] == "ghost"
assert profile["status"] == "uninitialized"
assert profile["initialized"] is False
assert profile["config_dir"] == sys.argv[2]
assert profile["artifacts"] == {
    "auth_json": False,
    "config_toml": False,
    "sandbox_migration": False,
    "skills_system": False,
}
assert profile["auth"]["status"] == "uninitialized"
assert profile["auth"]["logged_in"] is None
assert profile["auth"]["probe_exit"] is None
PY

  [[ ! -e "$repo/.agent-profiles/ghost" ]]
}

@test "codex doctor profile: no profile diagnostics without --profile" {
  local repo="$TEST_TMPDIR/repo-codex-profile-none"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  run bash "$AP_HELPER" doctor --json --agent codex
  assert_success

  python3 - "$output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["agents"]["codex"]["profile"] is None
PY
}

@test "codex doctor profile: agent filter does not run the codex profile probe" {
  local repo="$TEST_TMPDIR/repo-codex-profile-filter"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  run bash "$AP_HELPER" doctor --json --agent claude --profile dev
  assert_success

  python3 - "$output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert "codex" not in data["agents"] or data["agents"]["codex"]["profile"] is None
PY
}
