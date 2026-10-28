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

@test "install contract: check-install script enforces CODEX_HOME and CLAUDE_CONFIG_DIR isolation" {
  run grep -F 'CODEX_HOME=' "$AP_SUBJECT/tests/tools/check-install"
  assert_success
  run grep -F 'CLAUDE_CONFIG_DIR=' "$AP_SUBJECT/tests/tools/check-install"
  assert_success
}

@test "install contract: check-install script verifies all agent registration targets in .claude and .agents" {
  run grep -F '.claude/skills/flyingnobita-agent-profiles' "$AP_SUBJECT/tests/tools/check-install"
  assert_success
  run grep -F '.agents/skills/flyingnobita-agent-profiles' "$AP_SUBJECT/tests/tools/check-install"
  assert_success
}

@test "install contract: check-install runs installed helper from separate cwd" {
  run grep -F 'separate_' "$AP_SUBJECT/tests/tools/check-install"
  assert_success
}
