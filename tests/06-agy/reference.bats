#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation

  REF="$AP_SKILL_DIR/references/agents/antigravity.md"
}

teardown() {
  teardown_isolation
}

assert_ref_contains() {
  local needle="$1"
  if [[ "$(cat "$REF")" != *"$needle"* ]]; then
    printf "expected to find '%s' in %s\n" "$needle" "$REF" >&2
    return 1
  fi
}

@test "antigravity reference: documents the required profile sections" {
  assert_file_exists "$REF"

  assert_ref_contains "## Directory Redirection"
  assert_ref_contains "## Skill and Customization Discovery"
  assert_ref_contains "## Authentication Diagnostics"
  assert_ref_contains "## Shared Host Resources"
  assert_ref_contains "## Sandbox and Permission Modes"
  assert_ref_contains "## Versions and Onboarding"
  assert_ref_contains "## Troubleshooting and Gaps"
}

@test "antigravity reference: targets agy and does not claim Gemini CLI support" {
  assert_file_exists "$REF"

  assert_ref_contains "agy"
  assert_ref_contains "not the Gemini CLI"
  assert_ref_contains ".gemini"
}

@test "antigravity reference: records the verified skill locations and exposed gaps" {
  assert_file_exists "$REF"

  assert_ref_contains ".gemini/config/skills"
  assert_ref_contains ".gemini/skills"
  assert_ref_contains ".gemini/antigravity-cli/skills"
  assert_ref_contains ".gemini/antigravity/skills"
  assert_ref_contains ".agents/skills"
  assert_ref_contains "agy plugin list"
  assert_ref_contains "not verified offline"
}

@test "antigravity reference: separates filesystem, environment and OS authentication" {
  assert_file_exists "$REF"

  assert_ref_contains "profile credential file"
  assert_ref_contains "environment variable name"
  assert_ref_contains "OS credential service"
  assert_ref_contains "not proof of account separation"
}

@test "antigravity reference: names shared resources, sandbox modes, versions and gaps" {
  assert_file_exists "$REF"

  assert_ref_contains "session bus"
  assert_ref_contains "remote-control"
  assert_ref_contains "--sandbox"
  assert_ref_contains "Tested version"
  assert_ref_contains "1.4.9"
  assert_ref_contains "credential-dependent gap"
}

@test "antigravity reference: uses agent-profile domain terms without author home paths" {
  assert_file_exists "$REF"

  assert_ref_contains "Host environment"
  assert_ref_contains "Agent profile"

  run grep -E "/home/[a-z0-9_-]+" "$REF"
  assert_failure
}
