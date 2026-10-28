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

@test "manifest: check-package tool passes for subject" {
  run bash "$AP_SUBJECT/tests/tools/check-package" "$AP_SUBJECT"
  assert_success
}

@test "manifest: required package files exist" {
  assert_file_exists "$AP_SKILL_DIR/SKILL.md"
  assert_file_exists "$AP_SKILL_DIR/VERSION"
  assert_file_exists "$AP_SKILL_DIR/LICENSE"
  assert_file_exists "$AP_SKILL_DIR/scripts/agent-profiles"
  assert_file_exists "$AP_SKILL_DIR/scripts/lib/common.sh"
}

@test "manifest: SKILL.md router size budget (<= 100 lines, <= 6 KB)" {
  assert_file_exists "$AP_SKILL_DIR/SKILL.md"
  lines=$(wc -l < "$AP_SKILL_DIR/SKILL.md")
  bytes=$(wc -c < "$AP_SKILL_DIR/SKILL.md")
  [[ "$lines" -le 100 ]]
  [[ "$bytes" -le 6144 ]]
}

@test "manifest: SKILL.md frontmatter matches specification" {
  assert_file_exists "$AP_SKILL_DIR/SKILL.md"
  assert_file_exists "$AP_SKILL_DIR/VERSION"
  ver=$(tr -d '[:space:]' < "$AP_SKILL_DIR/VERSION")

  run grep "^name: flyingnobita-agent-profiles" "$AP_SKILL_DIR/SKILL.md"
  assert_success

  run grep "^license: MIT" "$AP_SKILL_DIR/SKILL.md"
  assert_success

  run grep "Linux (bash, git, python3, mise, bubblewrap); macOS not qualified" "$AP_SKILL_DIR/SKILL.md"
  assert_success

  run grep "version: $ver" "$AP_SKILL_DIR/SKILL.md"
  assert_success
}
