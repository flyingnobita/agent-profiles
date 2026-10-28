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

@test "claude env: exports CLAUDE_CONFIG_DIR pointing to profile .claude directory" {
  local repo="$TEST_TMPDIR/repo-claude-env"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile alpha
  assert_success

  local expected_cfg="$repo/.agent-profiles/alpha/.claude"

  run bash "$AP_HELPER" run --profile alpha -- printenv CLAUDE_CONFIG_DIR
  assert_success
  assert_equal "$output" "$expected_cfg"
}

@test "claude env: resets CLAUDE_SECURESTORAGE_CONFIG_DIR if set in inherited environment" {
  local repo="$TEST_TMPDIR/repo-claude-sec"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile alpha
  assert_success

  run env CLAUDE_SECURESTORAGE_CONFIG_DIR="/host/unrelated/secure" \
    bash "$AP_HELPER" run --profile alpha -- python3 -c '
import os
print("SECURE=" + os.environ.get("CLAUDE_SECURESTORAGE_CONFIG_DIR", "UNSET"))
'
  assert_success
  assert_output_contains "SECURE=UNSET"
}
