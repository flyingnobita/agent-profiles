#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  load '../helpers/platform.bash'
  setup_isolation

  unset GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CLOUD_PROJECT

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

@test "agy doctor profile: reports .gemini artifacts, auth sources and file names without values" {
  local repo="$TEST_TMPDIR/repo-agy-profile"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  local gemini_dir="$repo/.agent-profiles/dev/.gemini"
  local state_dir="$gemini_dir/antigravity-cli"
  mkdir -p "$state_dir/cache" "$gemini_dir/config/skills/alpha" \
    "$gemini_dir/config/plugins/pkg-a/skills/plugin-skill"
  printf '{"synthetic":"marker"}\n' >"$state_dir/settings.json"
  printf '{"oauth":"secret-token-value-913"}\n' >"$state_dir/oauth_creds.json"
  printf '{"mcpServers":{}}\n' >"$gemini_dir/config/mcp_config.json"
  mkdir -p "$repo/.agent-profiles/dev/.config/antigravity"
  printf '{"plugin":"secret-plugin-value-913"}\n' \
    >"$repo/.agent-profiles/dev/.config/antigravity/plugin-secrets.json"

  local before after
  before=$(ap_test_tree_digest "$repo/.agent-profiles/dev")

  run env GEMINI_API_KEY="secret-env-value-913" DBUS_SESSION_BUS_ADDRESS="unix:path=$TEST_TMPDIR/absent-bus" \
    XDG_RUNTIME_DIR="$TEST_TMPDIR/run" \
    bash "$AP_HELPER" doctor --json --agent agy --profile dev
  assert_success
  assert_output_not_contains "secret-token-value-913"
  assert_output_not_contains "secret-plugin-value-913"
  assert_output_not_contains "secret-env-value-913"

  python3 - "$output" "$repo/.agent-profiles/dev" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile_dir = sys.argv[2]
profile = data["agents"]["agy"]["profile"]
assert profile is not None, "expected agy profile diagnostics"
assert profile["name"] == "dev"
assert profile["status"] == "initialized"
assert profile["initialized"] is True
assert profile["config_dir"] == profile_dir + "/.gemini"

artifacts = profile["artifacts"]
assert artifacts["cli_state"] is True, artifacts
assert artifacts["cli_settings"] is True, artifacts
assert artifacts["config"] is True, artifacts
assert artifacts["skills"] is True, artifacts
assert artifacts["plugins"] is True, artifacts
assert artifacts["mcp_config"] is True, artifacts
assert artifacts["plugin_secrets"] is True, artifacts

auth = profile["auth"]
assert auth["status"] == "profile_credential_files", auth
assert auth["authenticated"] is None, "file presence must never mean authenticated"
assert auth["profile_files"] == [
    ".gemini/antigravity-cli/oauth_creds.json",
    ".config/antigravity/plugin-secrets.json",
], auth["profile_files"]
assert auth["env_credentials"] == ["GEMINI_API_KEY"], auth
assert "os_credential_service" in auth, auth
assert auth["os_credential_service"]["status"] in ("present", "absent", "unverified"), auth
assert auth["detail"], auth
assert "not proof of account separation" in auth["note"], auth
PY

  after=$(ap_test_tree_digest "$repo/.agent-profiles/dev")
  assert_equal "$after" "$before"
}

@test "agy doctor profile: fresh profile reports no profile credentials and separates auth sources" {
  local repo="$TEST_TMPDIR/repo-agy-profile-fresh"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile fresh
  assert_success

  run env -u GEMINI_API_KEY -u GOOGLE_API_KEY -u GOOGLE_APPLICATION_CREDENTIALS -u GOOGLE_CLOUD_PROJECT \
    -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$TEST_TMPDIR/run" \
    bash "$AP_HELPER" doctor --json --agent agy --profile fresh
  assert_success

  python3 - "$output" "$repo/.agent-profiles/fresh" "$(ap_test_platform_os)" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile_dir = sys.argv[2]
darwin = sys.argv[3] == "Darwin"
profile = data["agents"]["agy"]["profile"]
assert profile["status"] == "initialized", profile
assert profile["config_dir"] == profile_dir + "/.gemini"
auth = profile["auth"]
assert auth["status"] == "no_profile_credentials", auth
assert auth["authenticated"] is None, auth
assert auth["profile_files"] == [], auth
assert auth["env_credentials"] == [], auth
shared = profile["shared"]
assert shared["session_bus"] is False, shared
service = auth["os_credential_service"]
if darwin:
    # macOS exposes one Keychain to the whole user session, so the shared
    # credential service is always present there and D-Bus is never consulted.
    assert service["status"] == "present", service
    assert "Keychain" in service["detail"], service
    assert shared["os_credential_service"] == "present", shared
else:
    assert service["status"] == "absent", service
    assert shared["os_credential_service"] == "absent", shared
PY
}

@test "agy doctor profile: an available OS credential service is reported as a shared source, not as authentication" {
  local repo="$TEST_TMPDIR/repo-agy-profile-os"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile oscred
  assert_success

  local run_dir="$TEST_TMPDIR/run"
  mkdir -p "$run_dir"
  : >"$run_dir/bus"

  local stub_bin="$TEST_TMPDIR/dbus-stub"
  mkdir -p "$stub_bin"
  local dbus_marker="$TEST_TMPDIR/dbus-invoked"
  cat >"$stub_bin/dbus-send" <<STUB
#!/usr/bin/env bash
printf 'invoked\n' >>"$dbus_marker"
echo "method return time=1.0 sender=org.freedesktop.DBus -> destination=:1.1"
echo "   boolean true"
exit 0
STUB
  chmod +x "$stub_bin/dbus-send"

  run env -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$run_dir" PATH="$stub_bin:$PATH" \
    bash "$AP_HELPER" doctor --json --agent agy --profile oscred
  assert_success

  python3 - "$output" "$(ap_test_platform_os)" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
darwin = sys.argv[2] == "Darwin"
auth = data["agents"]["agy"]["profile"]["auth"]
service = auth["os_credential_service"]
shared = data["agents"]["agy"]["profile"]["shared"]
assert service["status"] == "present", service
assert service["detail"], service
assert auth["status"] == "no_profile_credentials", auth
assert auth["authenticated"] is None, "an OS credential service is not an authenticated profile"
assert shared["os_credential_service"] == "present", shared
if darwin:
    # Darwin's shared credential service is the Keychain: it is reported as a
    # shared source without any D-Bus session bus being present or queried.
    assert shared["session_bus"] is False, shared
    assert "Keychain" in service["detail"], service
else:
    assert shared["session_bus"] is True, shared
PY

  if ap_test_is_darwin; then
    # The D-Bus stub must never be consulted on Darwin.
    [[ ! -e "$dbus_marker" ]]
  else
    assert_file_exists "$dbus_marker"
  fi
}

@test "agy doctor profile: uninitialized profile is reported without creating it" {
  local repo="$TEST_TMPDIR/repo-agy-profile-ghost"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" doctor --json --agent agy --profile ghost
  assert_success

  python3 - "$output" "$repo/.agent-profiles/ghost" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["agy"]["profile"]
assert profile["name"] == "ghost"
assert profile["status"] == "uninitialized"
assert profile["initialized"] is False
assert profile["config_dir"] == sys.argv[2] + "/.gemini"
assert profile["auth"]["status"] == "uninitialized"
assert profile["auth"]["authenticated"] is None
assert profile["auth"]["profile_files"] == []
PY

  [[ ! -e "$repo/.agent-profiles/ghost" ]]
}

@test "agy doctor profile: no profile diagnostics without --profile" {
  local repo="$TEST_TMPDIR/repo-agy-profile-none"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile dev
  assert_success

  run bash "$AP_HELPER" doctor --json --agent agy
  assert_success

  python3 - "$output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["agents"]["agy"]["profile"] is None
PY
}

@test "agy doctor profile: agent filter does not run the agy profile probe" {
  local repo="$TEST_TMPDIR/repo-agy-profile-filter"
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
agy = data["agents"].get("agy")
assert agy is None or agy["profile"] is None
PY
}
