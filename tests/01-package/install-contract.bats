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

@test "install contract: clean installation verifies all four agent registrations in isolated environment" {
  local target_home="$TEST_TMPDIR/home_direct"
  mkdir -p "$target_home"
  run env -i PATH="$PATH" \
    HOME="$target_home" \
    XDG_CONFIG_HOME="$target_home/.config" \
    XDG_DATA_HOME="$target_home/.local/share" \
    XDG_STATE_HOME="$target_home/.local/state" \
    XDG_CACHE_HOME="$target_home/.cache" \
    CODEX_HOME="$target_home/.codex" \
    CLAUDE_CONFIG_DIR="$target_home/.claude" \
    OPENCODE_CONFIG_DIR="$target_home/.opencode" \
    DISABLE_TELEMETRY=1 \
    npm_config_cache="$TEST_TMPDIR/npm_cache" \
    skills add "$AP_SUBJECT" -g -y --copy --skill flyingnobita-agent-profiles --agent claude-code codex antigravity-cli opencode
  assert_success

  # Verify all 4 agent registrations
  assert_dir_exists "$target_home/.claude/skills/flyingnobita-agent-profiles"
  assert_dir_exists "$target_home/.agents/skills/flyingnobita-agent-profiles"
}

@test "install contract: installed helper executes from a separate working directory with isolated environment" {
  local target_home="$TEST_TMPDIR/home_direct"
  mkdir -p "$target_home"
  env -i PATH="$PATH" \
    HOME="$target_home" \
    XDG_CONFIG_HOME="$target_home/.config" \
    XDG_DATA_HOME="$target_home/.local/share" \
    XDG_STATE_HOME="$target_home/.local/state" \
    XDG_CACHE_HOME="$target_home/.cache" \
    CODEX_HOME="$target_home/.codex" \
    CLAUDE_CONFIG_DIR="$target_home/.claude" \
    OPENCODE_CONFIG_DIR="$target_home/.opencode" \
    DISABLE_TELEMETRY=1 \
    npm_config_cache="$TEST_TMPDIR/npm_cache" \
    skills add "$AP_SUBJECT" -g -y --copy --skill flyingnobita-agent-profiles --agent claude-code codex antigravity-cli opencode

  local sep_repo="$TEST_TMPDIR/sep_repo"
  create_fixture_repo "$sep_repo"

  run env -i PATH="$PATH" HOME="$target_home" bash "$target_home/.agents/skills/flyingnobita-agent-profiles/scripts/agent-profiles" --version
  assert_success
  assert_output_contains "0.1.0"
}
