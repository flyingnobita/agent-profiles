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

# Copy the package as check-package sees it: the skill, the plugin manifests
# beside it under skills/, and the repository marketplace.
copy_package() {
  local repo="$1"
  mkdir -p "$repo/skills"
  cp -a "$AP_SKILL_DIR" "$repo/skills/agent-profiles"
  cp -a "$AP_SUBJECT/skills/.claude-plugin" "$AP_SUBJECT/skills/.codex-plugin" "$repo/skills/"
  cp -a "$AP_SUBJECT/.claude-plugin" "$repo/"
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

  # The skill is published under its unprefixed name, so the public router name
  # and the release version are pinned rather than inferred from the folder.
  run grep -x "name: agent-profiles" "$AP_SKILL_DIR/SKILL.md"
  assert_success

  run grep -x "0.4.0" "$AP_SKILL_DIR/VERSION"
  assert_success

  run grep -x "  version: 0.4.0" "$AP_SKILL_DIR/SKILL.md"
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

  # The description is routing metadata, so it names both qualified platforms
  # rather than the Linux-only wording that shipped before macOS arm64 was
  # qualified.
  run grep -E "^description: .*Linux and macOS arm64" "$AP_SKILL_DIR/SKILL.md"
  assert_success
  run grep -E "^description: .*Named Linux" "$AP_SKILL_DIR/SKILL.md"
  assert_failure 1
}

@test "manifest: check-package refuses the retired macOS not-qualified frontmatter" {
  assert_file_exists "$CHECK_PACKAGE"

  local repo="$TEST_TMPDIR/package"
  local skill="$repo/skills/agent-profiles"
  copy_package "$repo"

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

@test "manifest: check-package refuses plugin manifests whose version drifts from VERSION" {
  local repo="$TEST_TMPDIR/package"
  copy_package "$repo"
  run bash "$CHECK_PACKAGE" "$repo"
  assert_success

  # Claude Code and Codex cache a plugin install by its plugin.json version, so
  # a manifest left behind on a release would hide that release from plugin
  # users. Every manifest that states a version must match VERSION.
  local manifest
  for manifest in skills/.claude-plugin/plugin.json skills/.codex-plugin/plugin.json .claude-plugin/marketplace.json; do
    rm -rf "$repo"
    copy_package "$repo"
    python3 - "$repo/$manifest" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
target = data["plugins"][0] if "plugins" in data else data
target["version"] = "0.0.1"
json.dump(data, open(path, "w"))
PY
    run bash "$CHECK_PACKAGE" "$repo"
    assert_failure
    assert_output_contains "$manifest"
    assert_output_contains "0.0.1"
  done
}

@test "manifest: check-package keeps the plugin root at skills/ and its skill path exact" {
  local repo="$TEST_TMPDIR/package"
  local manifest
  copy_package "$repo"

  # Each manifest names the skill directory itself, and 0.4.0 publishes that
  # directory without the prefix, so the exact path is asserted here instead of
  # being inferred from the package check.
  for manifest in skills/.claude-plugin/plugin.json skills/.codex-plugin/plugin.json; do
    run python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["skills"])' "$repo/$manifest"
    assert_output_equals "./agent-profiles"
  done

  run bash "$CHECK_PACKAGE" "$repo"
  assert_success

  # Plugin installs copy the whole plugin root into the agent's cache, so the
  # root stays skills/ rather than the repository with its tests and docs.
  python3 - "$repo/.claude-plugin/marketplace.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["plugins"][0]["source"] = "./"
json.dump(data, open(path, "w"))
PY
  run bash "$CHECK_PACKAGE" "$repo"
  assert_failure
  assert_output_contains "./skills"

  # Codex finds no skill when the path names the plugin root ("./" or "."),
  # so each manifest names the skill directory itself.
  for manifest in skills/.claude-plugin/plugin.json skills/.codex-plugin/plugin.json; do
    rm -rf "$repo"
    copy_package "$repo"
    python3 - "$repo/$manifest" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["skills"] = "./"
json.dump(data, open(path, "w"))
PY
    run bash "$CHECK_PACKAGE" "$repo"
    assert_failure
    assert_output_contains "$manifest"
  done
}
