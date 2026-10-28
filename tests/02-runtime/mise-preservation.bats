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

@test "mise: preserves host effective mise dirs inside profile" {
  local repo="$TEST_TMPDIR/repo-mise-effective"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  # Probe host mise effective dirs before profile
  local host_data_dir
  host_data_dir=$(python3 -c '
import subprocess, json
try:
    res = subprocess.run(["mise", "doctor", "--json"], stdout=subprocess.PIPE, text=True, check=True)
    print(json.loads(res.stdout).get("dirs", {}).get("data", ""))
except Exception:
    pass
')
  [[ -n "$host_data_dir" ]]

  run bash "$AP_HELPER" run -- python3 -c '
import os
data_dir = os.environ.get("MISE_DATA_DIR", "")
config_dir = os.environ.get("MISE_CONFIG_DIR", "")
state_dir = os.environ.get("MISE_STATE_DIR", "")
cache_dir = os.environ.get("MISE_CACHE_DIR", "")

assert data_dir, "MISE_DATA_DIR missing"
assert config_dir, "MISE_CONFIG_DIR missing"
assert state_dir, "MISE_STATE_DIR missing"
assert cache_dir, "MISE_CACHE_DIR missing"
print(f"EFFECTIVE_DATA={data_dir}")
'
  assert_success
  assert_output_contains "EFFECTIVE_DATA=$host_data_dir"
}

@test "guard: mise preserves explicit custom MISE_DATA_DIR override" {
  local repo="$TEST_TMPDIR/repo-mise-override"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  local custom_dir="$TEST_TMPDIR/custom_mise_data"
  mkdir -p "$custom_dir"

  run env MISE_DATA_DIR="$custom_dir" bash "$AP_HELPER" run -- python3 -c '
import os
data_dir = os.environ.get("MISE_DATA_DIR", "")
assert data_dir == "'"$custom_dir"'", f"expected {data_dir} to equal {custom_dir}"
print("OVERRIDE_OK")
'
  assert_success
  assert_output_contains "OVERRIDE_OK"
}

@test "guard: mise passes through other inherited MISE_ variables" {
  local repo="$TEST_TMPDIR/repo-mise-passthrough"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  run env MISE_TEST_VAR="hello_mise_passthrough" bash "$AP_HELPER" run -- python3 -c '
import os
val = os.environ.get("MISE_TEST_VAR", "")
assert val == "hello_mise_passthrough", f"got {val}"
print("PASSTHROUGH_OK")
'
  assert_success
  assert_output_contains "PASSTHROUGH_OK"
}

@test "mise: generic commands run successfully even if mise is missing from PATH" {
  local repo="$TEST_TMPDIR/repo-mise-missing"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  # Path with mise removed
  local no_mise_bin="$TEST_TMPDIR/no_mise_bin"
  mkdir -p "$no_mise_bin"
  local old_ifs="$IFS"
  IFS=':'
  for bin_dir in $PATH; do
    IFS="$old_ifs"
    for tool in "$bin_dir"/*; do
      [[ -x "$tool" && ! -d "$tool" ]] || continue
      local name
      name="$(basename "$tool")"
      [[ "$name" == "mise" ]] && continue
      [[ ! -e "$no_mise_bin/$name" ]] && ln -s "$tool" "$no_mise_bin/$name" 2>/dev/null || true
    done
  done
  IFS="$old_ifs"

  run env PATH="$no_mise_bin" bash "$AP_HELPER" run -- echo "generic_cmd_ok"
  assert_success
  assert_output_contains "generic_cmd_ok"
}

@test "mise: resolves hermetic local mise-linked executable fixture and preserves caller cwd" {
  local repo="$TEST_TMPDIR/repo-mise-tool"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init
  assert_success

  # Create a hermetic local tool executable directory
  local tool_dir="$TEST_TMPDIR/fake_hermetic_tool"
  mkdir -p "$tool_dir/bin"
  cat <<'EOF' > "$tool_dir/bin/my-hermetic-tool"
#!/bin/sh
echo "HERMETIC_TOOL_OK:cwd=$(pwd)"
EOF
  chmod +x "$tool_dir/bin/my-hermetic-tool"

  # Link as a custom local tool in mise (offline, no network or auth)
  MISE_YES=1 mise link -f node@custom-test "$tool_dir"

  # Configure repo to use this linked tool
  cat <<'EOF' > "$repo/mise.toml"
[tools]
node = "custom-test"
EOF

  # Run from subdirectory to test caller cwd preservation
  mkdir -p "$repo/nested/sub"
  cd "$repo/nested/sub"

  # Execute through generic agent-profiles run
  run bash "$AP_HELPER" run -- mise exec -- my-hermetic-tool
  assert_success
  assert_output_contains "HERMETIC_TOOL_OK:cwd=$repo/nested/sub"

  # Clean up linked tool
  MISE_YES=1 mise uninstall node@custom-test 2>/dev/null || true
}
