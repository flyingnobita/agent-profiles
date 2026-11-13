#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  setup_mise_roots
}

teardown() {
  teardown_isolation
}

# Every test in this file exercises the real mise binary, and mise writes to its
# own state: a `mise link`/`mise uninstall` pair would otherwise mutate whatever
# installation the invoking user has. Each test therefore runs against
# disposable roots, exactly like tests/03-setup/lib.bash:setup_mise_env, so a
# crashed test cannot leave a host installation behind.
setup_mise_roots() {
  export MISE_CONFIG_DIR="$TEST_TMPDIR/mise/config"
  export MISE_DATA_DIR="$TEST_TMPDIR/mise/data"
  export MISE_STATE_DIR="$TEST_TMPDIR/mise/state"
  export MISE_CACHE_DIR="$TEST_TMPDIR/mise/cache"
  export MISE_TRUSTED_CONFIG_PATHS="$TEST_TMPDIR"
  mkdir -p "$MISE_CONFIG_DIR" "$MISE_DATA_DIR" "$MISE_STATE_DIR" "$MISE_CACHE_DIR"
}

# The host installation paths mise would use when a MISE_* root is not set. None
# of them may gain test state: the linked tool, its shim entry and the install
# record belong to the disposable roots. (mise regenerates a system-shim cache
# under the default data home in any invocation, so that one cache directory is
# not by itself evidence of a mutation.)
assert_host_mise_state_untouched() {
  local path
  for path in \
    "$HOME/.config/mise" \
    "$HOME/.local/share/mise/installs" \
    "$HOME/.local/share/mise/shims/my-hermetic-tool" \
    "$HOME/.local/state/mise" \
    "$HOME/.cache/mise"; do
    if [[ -e "$path" ]]; then
      echo "host mise state was touched: $path" >&2
      return 1
    fi
  done
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
  # shellcheck source=tests/helpers/restricted-path.bash
  source "$BATS_TEST_DIRNAME/../helpers/restricted-path.bash"
  ap_test_restricted_bin "$no_mise_bin" mise

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

  # Link as a custom local tool in mise (offline, no network or auth). The link
  # lands in the disposable data root, never in a host mise installation.
  MISE_YES=1 mise link -f node@custom-test "$tool_dir"
  assert_dir_exists "$MISE_DATA_DIR/installs/node/custom-test"

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

  # Clean up linked tool inside the disposable root
  MISE_YES=1 mise uninstall node@custom-test 2>/dev/null || true
  [[ ! -e "$MISE_DATA_DIR/installs/node/custom-test" ]]

  # Nothing leaked into a host mise installation: the default paths are still
  # absent and mise still reports the disposable data root as its own.
  assert_host_mise_state_untouched
  local effective_data_dir
  effective_data_dir=$(mise doctor --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["dirs"]["data"])')
  assert_equal "$effective_data_dir" "$MISE_DATA_DIR"
}
