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

@test "codex reference: documentation covers required sections and headings" {
  local ref="$AP_SKILL_DIR/references/agents/codex.md"
  assert_file_exists "$ref"

  local content
  content=$(cat "$ref")

  # Verify mandatory sections per ticket 05 specification
  assert_output_contains_str "$content" "## Directory Redirection"
  assert_output_contains_str "$content" "## Skill Discovery"
  assert_output_contains_str "$content" "## Instruction Discovery"
  assert_output_contains_str "$content" "## Authentication Diagnostics"
  assert_output_contains_str "$content" "## Sandbox Execution"
  assert_output_contains_str "$content" "## Troubleshooting & Gaps"
}

@test "codex reference: covers domain terms and verified CLI surfaces" {
  local ref="$AP_SKILL_DIR/references/agents/codex.md"
  assert_file_exists "$ref"

  local content
  content=$(cat "$ref")

  # CLI discovery and sandbox surfaces
  assert_output_contains_str "$content" "CODEX_HOME"
  assert_output_contains_str "$content" "debug prompt-input"
  assert_output_contains_str "$content" "login status"
  assert_output_contains_str "$content" "codex sandbox"
  assert_output_contains_str "$content" "repository boundary"

  # Domain glossary terms
  assert_output_contains_str "$content" "Host environment"
  assert_output_contains_str "$content" "Agent profile"
}

@test "codex reference: contains no absolute author home paths or leaks" {
  local ref="$AP_SKILL_DIR/references/agents/codex.md"
  assert_file_exists "$ref"

  # Reject user-specific home paths
  run grep -E "/home/[a-z0-9_-]+" "$ref"
  assert_failure
}

assert_output_contains_str() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf "expected to find '%s' in reference document\n" "$needle" >&2
    return 1
  fi
}
