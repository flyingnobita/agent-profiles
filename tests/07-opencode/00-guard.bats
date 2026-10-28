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

@test "guard: helper exists at subject and returns semver" {
  assert_file_exists "$AP_HELPER"
  run bash "$AP_HELPER" --version
  assert_success
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "guard: doctor --json returns valid schema with opencode entry" {
  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" doctor --json
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert "version" in data
assert "checks" in data
assert "agents" in data
assert "opencode" in data["agents"]
' "$output"
}

@test "guard: bubblewrap redirects the XDG configuration, data, state and cache roots" {
  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile test-opencode-xdg
  assert_success

  run bash "$AP_HELPER" run --profile test-opencode-xdg -- sh -c '
mkdir -p "$XDG_CONFIG_HOME/opencode" "$XDG_DATA_HOME/opencode" "$XDG_STATE_HOME/opencode" "$XDG_CACHE_HOME/opencode"
printf "config\n" >"$XDG_CONFIG_HOME/opencode/marker.txt"
printf "data\n" >"$XDG_DATA_HOME/opencode/marker.txt"
printf "state\n" >"$XDG_STATE_HOME/opencode/marker.txt"
printf "cache\n" >"$XDG_CACHE_HOME/opencode/marker.txt"
'
  assert_success
  local profile_dir="$repo/.agent-profiles/test-opencode-xdg"
  assert_file_exists "$profile_dir/.config/opencode/marker.txt"
  assert_file_exists "$profile_dir/.local/share/opencode/marker.txt"
  assert_file_exists "$profile_dir/.local/state/opencode/marker.txt"
  assert_file_exists "$profile_dir/.cache/opencode/marker.txt"
  [[ ! -f "$HOME/.config/opencode/marker.txt" ]]
  [[ ! -f "$HOME/.local/share/opencode/marker.txt" ]]
}
