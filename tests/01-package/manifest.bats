#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  CHECK_PACKAGE="$AP_SUBJECT/tests/tools/check-package"
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

  # Both platforms are qualified: Linux with its bubblewrap mount layer, macOS
  # arm64 with configuration redirection only. Neither is a sandbox.
  run grep -E "^compatibility: .*Linux" "$AP_SKILL_DIR/SKILL.md"
  assert_success
  run grep -E "^compatibility: .*macOS arm64" "$AP_SKILL_DIR/SKILL.md"
  assert_success
  run grep -E "^compatibility: .*configuration redirection only" "$AP_SKILL_DIR/SKILL.md"
  assert_success
  run grep -E "^compatibility: .*macOS not qualified" "$AP_SKILL_DIR/SKILL.md"
  assert_failure 1

  run grep "version: $ver" "$AP_SKILL_DIR/SKILL.md"
  assert_success
}

@test "manifest: check-package refuses the retired macOS not-qualified frontmatter" {
  assert_file_exists "$CHECK_PACKAGE"

  local repo="$TEST_TMPDIR/package"
  local skill="$repo/skills/flyingnobita-agent-profiles"
  mkdir -p "$repo/skills"
  cp -a "$AP_SKILL_DIR" "$skill"

  # The documented surface is accepted before anything is changed.
  run bash "$CHECK_PACKAGE" "$repo"
  assert_success

  # 0.2.0 and earlier claimed macOS was not qualified. A frontmatter that
  # reverts to that claim must not pass, so the package check stays coupled to
  # the documented platform status instead of accepting any Linux/macOS pair.
  python3 - "$skill/SKILL.md" <<'PY'
import sys

path = sys.argv[1]
retired = "compatibility: Linux (bash, git, python3, mise, bubblewrap); macOS not qualified\n"
with open(path) as handle:
    lines = handle.readlines()
with open(path, "w") as handle:
    for line in lines:
        handle.write(retired if line.startswith("compatibility:") else line)
PY

  run grep -F -- "macOS not qualified" "$skill/SKILL.md"
  assert_success
  run bash "$CHECK_PACKAGE" "$repo"
  assert_failure
  assert_output_contains "macOS"
}
