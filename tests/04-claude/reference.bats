#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation
}

teardown() {
  teardown_isolation
}

claude_ref() {
  printf '%s\n' "$AP_SKILL_DIR/references/agents/claude-code.md"
}

@test "claude reference: records the tested version and Linux prerequisites" {
  local ref
  ref=$(claude_ref)
  assert_file_exists "$ref"

  run grep -F -- "2.1.312" "$ref"
  assert_success
  run grep -F -- "bubblewrap" "$ref"
  assert_success
  run grep -F -- "socat" "$ref"
  assert_success
  run grep -F -- "mise" "$ref"
  assert_success
}

@test "claude reference: explains config redirection, home paths and credential handling" {
  local ref
  ref=$(claude_ref)

  run grep -F -- "CLAUDE_CONFIG_DIR" "$ref"
  assert_success
  run grep -F -- ".claude.json" "$ref"
  assert_success
  run grep -F -- "CLAUDE_SECURESTORAGE_CONFIG_DIR" "$ref"
  assert_success
  run grep -F -- "claude auth status" "$ref"
  assert_success
  run grep -F -- "credentials" "$ref"
  assert_success
}

@test "claude reference: explains discovery and remaining bundled or managed sources" {
  local ref
  ref=$(claude_ref)

  run grep -F -- "claude mcp list" "$ref"
  assert_success
  run grep -F -- "stream-json" "$ref"
  assert_success
  run grep -F -- "cc-plugin-agents-md" "$ref"
  assert_success
  run grep -F -- "managed settings" "$ref"
  assert_success
  run grep -F -- "host" "$ref"
  assert_success
}

@test "claude reference: explains sandbox configuration and enforcement limits" {
  local ref
  ref=$(claude_ref)

  run grep -F -- "claude sandbox status" "$ref"
  assert_success
  run grep -F -- "sandbox.enabled" "$ref"
  assert_success
  run grep -F -- "failIfUnavailable" "$ref"
  assert_success
  run grep -F -- "allowUnsandboxedCommands" "$ref"
  assert_success
  run grep -F -- "Read-only file system" "$ref"
  assert_success
  run grep -F -- "background session" "$ref"
  assert_success
}

@test "claude reference: focused troubleshooting avoids other integrations and transcripts" {
  local ref
  ref=$(claude_ref)

  run grep -q "^## Troubleshooting" "$ref"
  assert_success
  run grep -F -- "not logged in" "$ref"
  assert_success
  run grep -F -- "not readiness" "$ref"
  assert_success

  # The guide stays focused: no other agent integration or command transcript.
  run grep -E "CODEX_HOME|OPENCODE_CONFIG_DIR|\.gemini|tests/live" "$ref"
  assert_failure
}
