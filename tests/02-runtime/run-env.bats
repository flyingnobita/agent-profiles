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

@test "run: requires a command and exits 64 if missing" {
  local repo="$TEST_TMPDIR/repo-run-nocmd"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  run bash "$AP_HELPER" run
  assert_failure
  assert_equal "$status" 64
  assert_output_contains "missing command"
}

@test "run: exits 66 if selected profile is not initialized" {
  local repo="$TEST_TMPDIR/repo-run-uninit"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" run --profile uninit-prof -- echo ok
  assert_failure
  assert_equal "$status" 66
  assert_output_contains "profile 'uninit-prof' is not initialized"
}

@test "run: rejects unknown leading option with exit 64" {
  local repo="$TEST_TMPDIR/repo-run-opt"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  run bash "$AP_HELPER" run --invalid-opt echo ok
  assert_failure
  assert_equal "$status" 64
  assert_output_contains "unknown option"
}

@test "run: forwards arguments unchanged including flags and --profile after command" {
  local repo="$TEST_TMPDIR/repo-run-fwd"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile worker1
  assert_success

  # Forward arguments after command, including --profile flag which should NOT be consumed
  run bash "$AP_HELPER" run --profile worker1 -- printf '%s\n' "arg1" "--profile" "other" "arg with space"
  assert_success
  run bash "$AP_HELPER" run --profile worker1 printf '%s\n' "first" "second"
  assert_success
  assert_output_contains "first"
  assert_output_contains "second"
}

@test "run: preserves complex arguments with spaces, newlines, quotes, and empty args" {
  local repo="$TEST_TMPDIR/repo-run-args"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  local multi_line="line 1
line 2"
  run bash "$AP_HELPER" run -- python3 -c '
import sys
args = sys.argv[1:]
assert len(args) == 4, f"expected 4 args, got {len(args)}"
assert args[0] == "hello world", f"got {args[0]!r}"
assert args[1] == "", f"got {args[1]!r}"
assert args[2] == sys.argv[4], f"got {args[2]!r}"
print("ARGS_OK")
' "hello world" "" "$multi_line" "$multi_line"
  assert_success
  assert_output_contains "ARGS_OK"
}

@test "run: resets managed environment variables and exports profile directories and aliases" {
  local repo="$TEST_TMPDIR/repo-run-env"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile test-env
  assert_success

  local prof_dir="$repo/.agent-profiles/test-env"

  # Pass inherited managed variables that must be reset
  run env \
    AGENT_PROFILES_NAME="stale" \
    AGENT_SANDBOX_DIR="/tmp/stale-sandbox" \
    CLAUDE_CONFIG_DIR="/tmp/stale-claude" \
    CODEX_HOME="/tmp/stale-codex" \
    OPENCODE_CONFIG_DIR="/tmp/stale-opencode" \
    XDG_CONFIG_HOME="/tmp/stale-config" \
    NPM_CONFIG_PREFIX="/tmp/stale-npm" \
    bash "$AP_HELPER" run --profile test-env -- python3 -c '
import os
prof_dir = os.environ["AGENT_PROFILES_DIR"]
assert os.environ["AGENT_PROFILES_NAME"] == "test-env"
assert os.environ["AGENT_SANDBOX_PROFILE"] == "test-env"
assert os.environ["AGENT_SANDBOX_DIR"] == prof_dir
assert os.environ["XDG_CONFIG_HOME"] == os.path.join(prof_dir, ".config")
assert os.environ["XDG_DATA_HOME"] == os.path.join(prof_dir, ".local/share")
assert os.environ["XDG_STATE_HOME"] == os.path.join(prof_dir, ".local/state")
assert os.environ["XDG_CACHE_HOME"] == os.path.join(prof_dir, ".cache")
assert os.environ["NPM_CONFIG_PREFIX"] == os.path.join(prof_dir, "npm-global")
assert os.environ["UV_TOOL_DIR"] == os.path.join(prof_dir, "uv-tools")
assert os.environ["CARGO_INSTALL_ROOT"] == os.path.join(prof_dir, "cargo-global")
assert os.environ["GOBIN"] == os.path.join(prof_dir, "bin")
assert os.environ["PYTHONUSERBASE"] == os.path.join(prof_dir, "python-user")
print("ENV_OK")
'
  assert_success
  assert_output_contains "ENV_OK"
}

@test "run: configures PATH with profile bin directories first and purges stale profile paths" {
  local repo="$TEST_TMPDIR/repo-run-path"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init --profile path-prof
  assert_success

  local prof_dir="$repo/.agent-profiles/path-prof"

  # Pass PATH containing a stale profile bin path
  local stale_path="/tmp/other-repo/.agent-profiles/other/bin"
  run env PATH="$stale_path:$PATH" bash "$AP_HELPER" run --profile path-prof -- python3 -c '
import os
path = os.environ["PATH"].split(":")
prof_dir = os.environ["AGENT_PROFILES_DIR"]

# First entries must be profile bin paths
expected_leading = [
    os.path.join(prof_dir, "npm-global/bin"),
    os.path.join(prof_dir, "bin"),
    os.path.join(prof_dir, "cargo-global/bin"),
    os.path.join(prof_dir, "python-user/bin")
]
assert path[:4] == expected_leading, f"leading path mismatch: {path[:4]} vs {expected_leading}"

# Stale profile paths must be purged
assert not any("/.agent-profiles/other/" in p for p in path), "stale profile path not purged"
print("PATH_OK")
'
  assert_success
  assert_output_contains "PATH_OK"
}

@test "run: installed uv tool in UV_TOOL_BIN_DIR resolves through generic run" {
  local repo="$TEST_TMPDIR/repo-run-uv-tool"
  create_fixture_repo "$repo"
  cd "$repo"
  run bash "$AP_HELPER" init
  assert_success

  local prof_dir="$repo/.agent-profiles/default"
  # Create a fake installed tool executable in UV_TOOL_BIN_DIR
  mkdir -p "$prof_dir/bin"
  cat <<'EOF' > "$prof_dir/bin/fake-uv-tool"
#!/bin/sh
echo "fake-uv-tool-active"
EOF
  chmod +x "$prof_dir/bin/fake-uv-tool"

  run bash "$AP_HELPER" run -- fake-uv-tool
  assert_success
  assert_output_contains "fake-uv-tool-active"

  # Verify UV_TOOL_BIN_DIR environment variable is <profile>/bin
  run bash "$AP_HELPER" run -- sh -c 'echo "UV_BIN=$UV_TOOL_BIN_DIR"'
  assert_success
  assert_output_contains "UV_BIN=$prof_dir/bin"
}
