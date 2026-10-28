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

@test "guard: doctor --json returns valid schema with codex entry" {
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
assert "codex" in data["agents"]
' "$output"
}

@test "guard: init initializes .codex directory and bubblewrap redirects host .codex" {
  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile test-codex
  assert_success
  assert_dir_exists "$repo/.agent-profiles/test-codex/.codex"
  assert_dir_exists "$repo/.agent-profiles/test-codex/.agents"

  mkdir -p "$HOME/.codex"
  run bash "$AP_HELPER" run --profile test-codex -- sh -c 'printf "codex_marker\n" > "$HOME/.codex/marker.txt"'
  assert_success
  assert_file_exists "$repo/.agent-profiles/test-codex/.codex/marker.txt"
  [[ ! -f "$HOME/.codex/marker.txt" ]]
}
