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

@test "preview: reset requires --profile argument and rejects missing with exit 64" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" reset
  assert_failure 64
  assert_output_contains "reset requires --profile"

  run bash "$AP_HELPER" reset --profile
  assert_failure 64
}

@test "preview: remove requires --profile argument and rejects missing with exit 64" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" remove
  assert_failure 64
  assert_output_contains "remove requires --profile"

  run bash "$AP_HELPER" remove --profile
  assert_failure 64
}

@test "preview: rejects invalid profile names with exit 65" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" reset --profile "INVALID_CAPS"
  assert_failure 65
  assert_output_contains "invalid profile name"

  run bash "$AP_HELPER" remove --profile "../traversal"
  assert_failure 65
  assert_output_contains "invalid profile name"
}

@test "preview: rejects uninitialized profile with exit 66" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" reset --profile uninitprof
  assert_failure 66
  assert_output_contains "is not initialized"

  run bash "$AP_HELPER" remove --profile uninitprof
  assert_failure 66
  assert_output_contains "is not initialized"
}

@test "preview: rejects symlinked profile directory with exit 73" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$TEST_TMPDIR/outside_dir"
  mkdir -p "$fixture_repo/.agent-profiles"
  ln -s "$TEST_TMPDIR/outside_dir" "$fixture_repo/.agent-profiles/symprof"

  run bash "$AP_HELPER" reset --profile symprof
  assert_failure 73
  assert_output_contains "symbolic link"

  run bash "$AP_HELPER" remove --profile symprof
  assert_failure 73
  assert_output_contains "symbolic link"
}

@test "preview: displays exact absolute path and categorized consequences without mutating profile" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile targetprof
  assert_success

  local prof_dir="$fixture_repo/.agent-profiles/targetprof"

  # Populate categories with realistic files
  # 1. Settings
  echo '{"theme": "dark"}' >"$prof_dir/.config/settings.json"
  echo 'format=1' >"$prof_dir/.agent-profile"
  # 2. Transcripts
  mkdir -p "$prof_dir/.local/share/transcripts"
  echo "transcript line 1" >"$prof_dir/.local/share/transcripts/session.log"
  # 3. Credentials (fake credentials - verify content is never printed)
  mkdir -p "$prof_dir/.codex"
  echo "SECRET_API_TOKEN_XYZ_987654" >"$prof_dir/.codex/auth.json"
  # 4. Installed tools
  mkdir -p "$prof_dir/npm-global/bin"
  touch "$prof_dir/npm-global/bin/my-tool"

  # Snapshot sha256 checksum of the entire profile directory before preview
  local hash_before
  hash_before=$(find "$prof_dir" -type f -exec sha256sum {} + | sort | sha256sum)

  run bash "$AP_HELPER" reset --profile targetprof
  assert_success
  assert_output_contains "Reset preview for profile 'targetprof':"
  assert_output_contains "Path: $prof_dir"
  assert_output_contains "Settings:"
  assert_output_contains "Transcripts:"
  assert_output_contains "Credentials:"
  assert_output_contains "Installed tools:"
  assert_output_not_contains "SECRET_API_TOKEN_XYZ_987654"
  assert_output_contains "Pass --yes to proceed"

  # Verify profile is completely untouched
  local hash_after
  hash_after=$(find "$prof_dir" -type f -exec sha256sum {} + | sort | sha256sum)
  assert_equal "$hash_before" "$hash_after"

  # Test remove preview
  run bash "$AP_HELPER" remove --profile targetprof
  assert_success
  assert_output_contains "Remove preview for profile 'targetprof':"
  assert_output_contains "Path: $prof_dir"
  assert_output_contains "Settings:"
  assert_output_contains "Transcripts:"
  assert_output_contains "Credentials:"
  assert_output_contains "Installed tools:"
  assert_output_not_contains "SECRET_API_TOKEN_XYZ_987654"
  assert_output_contains "Pass --yes to proceed"

  local hash_after_remove_preview
  hash_after_remove_preview=$(find "$prof_dir" -type f -exec sha256sum {} + | sort | sha256sum)
  assert_equal "$hash_before" "$hash_after_remove_preview"
}

@test "preview: counts real per-agent conversation stores as transcripts" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile convprof
  assert_success
  local prof_dir="$fixture_repo/.agent-profiles/convprof"

  # Claude Code transcripts: <uuid>.jsonl under .claude/projects/<project>/
  mkdir -p "$prof_dir/.claude/projects/-tmp-repo"
  printf '{"type":"user","message":"PRIVATE_CLAUDE_TRANSCRIPT"}\n' \
    >"$prof_dir/.claude/projects/-tmp-repo/6f1c2b7e-1111-4222-8333-944455556666.jsonl"
  # Antigravity CLI conversations and an opaque conversation store.
  mkdir -p "$prof_dir/.gemini/antigravity-cli/conversations"
  printf 'PRIVATE_AGY_CONVERSATION\n' >"$prof_dir/.gemini/antigravity-cli/conversations/conv-1"
  mkdir -p "$prof_dir/.gemini/antigravity/conversations"
  printf 'PRIVATE_AGY_OPAQUE\n' >"$prof_dir/.gemini/antigravity/conversations/c1.pb"
  # Codex sessions.
  mkdir -p "$prof_dir/.codex/sessions/2026/10/28"
  printf '{"type":"session"}\n' >"$prof_dir/.codex/sessions/2026/10/28/rollout-1.jsonl"
  # OpenCode session database.
  mkdir -p "$prof_dir/.local/share/opencode"
  printf 'sqlite-bytes\n' >"$prof_dir/.local/share/opencode/opencode.db"

  run bash "$AP_HELPER" reset --profile convprof
  assert_success

  # Five conversation stores must be reported as transcripts, never zero.
  local transcripts_line
  transcripts_line=$(printf '%s\n' "$output" | grep -E '^  Transcripts:')
  [[ -n "$transcripts_line" ]]
  local count
  count=$(printf '%s\n' "$transcripts_line" | sed -E 's/.*: ([0-9]+) file\(s\).*/\1/')
  [[ "$count" -ge 5 ]]

  # Never print conversation contents.
  assert_output_not_contains "PRIVATE_CLAUDE_TRANSCRIPT"
  assert_output_not_contains "PRIVATE_AGY_CONVERSATION"
  assert_output_not_contains "PRIVATE_AGY_OPAQUE"
}

@test "preview: reports uncategorized profile state instead of hiding it" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile otherprof
  assert_success
  local prof_dir="$fixture_repo/.agent-profiles/otherprof"
  mkdir -p "$prof_dir/.weird-agent-state"
  printf 'opaque\n' >"$prof_dir/.weird-agent-state/blob.bin"

  run bash "$AP_HELPER" remove --profile otherprof
  assert_success
  assert_output_contains "Other files:"
}
