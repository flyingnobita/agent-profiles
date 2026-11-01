#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  CHECK_RELEASE="$AP_SUBJECT/tests/tools/check-release"
  README="$AP_SUBJECT/README.md"
  COMPAT="$AP_SKILL_DIR/references/compatibility.md"
  EVIDENCE="$AP_SUBJECT/docs/evidence/linux-2026-10-28.md"
  DARWIN_EVIDENCE="$AP_SUBJECT/docs/evidence/macos-2026-10-31.md"
}

# drop_lines <source> <dest> <fixed-string>: writes the source without the lines
# containing the fixed string. awk keeps the mutation portable; GNU sed -i does
# not exist on stock macOS.
drop_lines() {
  local source="$1" dest="$2" term="$3"
  awk -v term="$term" 'index($0, term) == 0' "$source" >"$dest"
}

teardown() {
  teardown_isolation
}

@test "release: check-release accepts the repository release surface" {
  assert_file_exists "$CHECK_RELEASE"
  run bash "$CHECK_RELEASE" "$AP_SUBJECT"
  assert_success
}

@test "release: README documents explicit installation, update, removal and maintenance" {
  assert_file_exists "$README"
  run grep -F -- "--skill flyingnobita-agent-profiles" "$README"
  assert_success
  run grep -F -- "npx skills add" "$README"
  assert_success
  run grep -F -- "## Install" "$README"
  assert_success
  run grep -F -- "## Update" "$README"
  assert_success
  run grep -F -- "## Remove" "$README"
  assert_success
  run grep -F -- "## Maintenance" "$README"
  assert_success
}

@test "release: README names the published repository and pinned installer" {
  assert_file_exists "$README"
  run grep -F -- "npx skills@1.7.4 add flyingnobita/agent-profiles" "$README"
  assert_success
  run grep -F -- "proposed, after publication" "$README"
  assert_failure 1
}

@test "release: root LICENSE is the bundled MIT license" {
  assert_file_exists "$AP_SUBJECT/LICENSE"
  assert_file_exists "$AP_SKILL_DIR/LICENSE"
  run cmp -s "$AP_SUBJECT/LICENSE" "$AP_SKILL_DIR/LICENSE"
  assert_success
}

@test "release: compatibility matrix is dated and names exactly the four product integrations" {
  assert_file_exists "$README"
  assert_file_exists "$COMPAT"

  for file in "$README" "$COMPAT"; do
    local rows
    rows=$(awk '
      /^## (Compatibility|Agent CLI Integration Matrix)$/ { inside = 1; next }
      inside && /^## / { exit }
      inside && /^\|/ { print }
    ' "$file")
    [[ -n "$rows" ]]
    # Two header rows plus exactly four data rows.
    [[ "$(printf '%s\n' "$rows" | grep -c '^|')" -eq 6 ]]
    printf '%s\n' "$rows" | grep -qF "Claude Code"
    printf '%s\n' "$rows" | grep -qF "Codex CLI"
    printf '%s\n' "$rows" | grep -qF "Antigravity CLI"
    printf '%s\n' "$rows" | grep -qF "OpenCode"
  done

  run grep -F -- "2026-10-28" "$README"
  assert_success
  run grep -F -- "2.1.312" "$COMPAT"
  assert_success
  run grep -F -- "0.165.0" "$COMPAT"
  assert_success
  run grep -F -- "1.4.9" "$COMPAT"
  assert_success
  run grep -F -- "2.2.0" "$COMPAT"
  assert_success
}

@test "release: README and compatibility reference state the shared host boundaries" {
  assert_file_exists "$README"
  assert_file_exists "$COMPAT"
  for file in "$README" "$COMPAT"; do
    run grep -Fi "not a security sandbox" "$file"
    assert_success
    run grep -Fi "inherited" "$file"
    assert_success
    run grep -Fi "macOS" "$file"
    assert_success
    # macOS is qualified by configuration redirection only, not the deferred and
    # unverified platform the earlier release documented.
    run grep -Fi "configuration redirection only" "$file"
    assert_success
    run grep -Fi "macOS is not qualified" "$file"
    assert_failure 1
  done
  run grep -Fi "shared host resources" "$README"
  assert_success
  # The macOS guarantee is documented as weaker than the Linux mount layer.
  run grep -Fi "same enforcement" "$README"
  assert_success
  run grep -Fi "weaker of the two" "$COMPAT"
  assert_success
}

@test "release: published evidence summary separates the classes and stays sanitized" {
  assert_file_exists "$EVIDENCE"
  for class in Version Startup Discovery Auth Sandbox; do
    run grep -F -- "$class" "$EVIDENCE"
    assert_success
  done
  for agent in "Claude Code" "Codex CLI" "Antigravity CLI" "OpenCode"; do
    run grep -F -- "$agent" "$EVIDENCE"
    assert_success
  done
  run grep -F -- "credential-dependent gap" "$EVIDENCE"
  assert_success
  run grep -Fi "sanitized" "$EVIDENCE"
  assert_success
}

@test "release: Darwin evidence records four agents and credentialed model runs as unverified" {
  assert_file_exists "$DARWIN_EVIDENCE"

  for agent in "Claude Code" "Codex CLI" "Antigravity CLI" "OpenCode"; do
    run grep -F -- "$agent" "$DARWIN_EVIDENCE"
    assert_success
  done

  # The real agent CLIs were never exercised on the qualification host, so their
  # version, startup, discovery and authentication classes are recorded as not
  # observed instead of being inferred from the Linux run.
  run grep -F -- "not observed" "$DARWIN_EVIDENCE"
  assert_success
  run grep -F -- "no agent CLI was installed" "$DARWIN_EVIDENCE"
  assert_success

  # Credentialed model runs are a gap on every platform, not only on Darwin.
  run grep -F -- "credential-dependent gap" "$DARWIN_EVIDENCE"
  assert_success
  run grep -F -- "not observed on any platform" "$DARWIN_EVIDENCE"
  assert_success

  # Only a sanitized summary is published: no account names, no private host
  # paths and no raw log content.
  run grep -Fi -- "sanitized" "$DARWIN_EVIDENCE"
  assert_success
  run grep -Fi -- "raw logs" "$DARWIN_EVIDENCE"
  assert_success
  run grep -Eq -- "@[a-z0-9.-]+\.[a-z]{2,}|/Users/|/home/|BEGIN [A-Z ]*PRIVATE KEY|Bearer [A-Za-z0-9]" \
    "$DARWIN_EVIDENCE"
  assert_failure 1
}

@test "release: check-release verifies the release surface has no author paths" {
  assert_file_exists "$CHECK_RELEASE"
  run bash "$CHECK_RELEASE" "$AP_SUBJECT"
  assert_success
  assert_output_contains "no author paths or private delivery identifiers"
}

@test "release: check-release refuses a release surface that reverts to the macOS not-qualified claim" {
  assert_file_exists "$CHECK_RELEASE"

  local repo="$TEST_TMPDIR/repo-regression"
  local readme="$TEST_TMPDIR/README.md"
  local compat="$TEST_TMPDIR/compatibility.md"
  local notes="$TEST_TMPDIR/RELEASE_NOTES.md"
  mkdir -p "$repo"
  cp -a "$AP_SUBJECT/." "$repo/"
  rm -rf "$repo/.git" "$repo/dist"
  local compat_path="$repo/skills/flyingnobita-agent-profiles/references/compatibility.md"

  # The documented surface is accepted before anything is changed.
  run bash "$CHECK_RELEASE" "$repo"
  assert_success

  # The platform status is asserted per row, so a row that reverts to the
  # deferred claim is refused even though the section still names macOS.
  cp -p "$repo/README.md" "$readme"
  python3 - "$repo/README.md" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path) as handle:
    text = handle.read()
text = re.sub(
    r"(?m)^\| macOS arm64 \|.*$",
    "| macOS arm64 | Not qualified | Deferred and unverified |",
    text,
)
with open(path, "w") as handle:
    handle.write(text)
PY
  run bash "$CHECK_RELEASE" "$repo"
  assert_failure
  assert_output_contains "does not report macOS as Qualified"
  cp -p "$readme" "$repo/README.md"

  cp -p "$compat_path" "$compat"
  python3 - "$compat_path" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path) as handle:
    text = handle.read()
text = re.sub(
    r"(?m)^\| macOS \(arm64\) \|.*$",
    "| macOS (arm64) | Not Qualified | Deferred and unverified |",
    text,
)
with open(path, "w") as handle:
    handle.write(text)
PY
  run bash "$CHECK_RELEASE" "$repo"
  assert_failure
  assert_output_contains "does not report macOS as Qualified"
  cp -p "$compat" "$compat_path"

  # The archived v0.1.0 section still records the deferred claim; the current
  # scope may not.
  cp -p "$repo/RELEASE_NOTES.md" "$notes"
  python3 - "$repo/RELEASE_NOTES.md" "$(tr -d '[:space:]' <"$AP_SKILL_DIR/VERSION")" <<'PY'
import sys

path, version = sys.argv[1], sys.argv[2]
title = "# flyingnobita-agent-profiles v%s\n" % version
with open(path) as handle:
    lines = handle.readlines()
with open(path, "w") as handle:
    for line in lines:
        handle.write(line)
        if line == title:
            handle.write("\nmacOS is not qualified in this release.\n")
PY
  run bash "$CHECK_RELEASE" "$repo"
  assert_failure
  assert_output_contains "still claims macOS is not qualified"
  cp -p "$notes" "$repo/RELEASE_NOTES.md"

  run bash "$CHECK_RELEASE" "$repo"
  assert_success
}

@test "release: check-release refuses a blanket macOS qualification without its limits" {
  assert_file_exists "$CHECK_RELEASE"

  local repo="$TEST_TMPDIR/repo-blanket-macos"
  local readme="$TEST_TMPDIR/README-blanket.md"
  local compat="$TEST_TMPDIR/compatibility-blanket.md"
  mkdir -p "$repo"
  cp -a "$AP_SUBJECT/." "$repo/"
  rm -rf "$repo/.git" "$repo/dist"
  local compat_path="$repo/skills/flyingnobita-agent-profiles/references/compatibility.md"

  run bash "$CHECK_RELEASE" "$repo"
  assert_success

  # The documented cells scope macOS to profile mechanics and diagnostics and
  # name what was not observed. A row that claims the same coverage as Linux is
  # refused: the platform status, not just the word Qualified, is the contract.
  cp -p "$repo/README.md" "$readme"
  python3 - "$repo/README.md" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path) as handle:
    text = handle.read()
text = re.sub(
    r"(?m)^\| macOS arm64 \|.*$",
    "| macOS arm64 | Qualified | Same as Linux, all four agent CLIs verified |",
    text,
)
with open(path, "w") as handle:
    handle.write(text)
PY
  run bash "$CHECK_RELEASE" "$repo"
  assert_failure
  assert_output_contains "profile mechanics"
  cp -p "$readme" "$repo/README.md"

  cp -p "$compat_path" "$compat"
  python3 - "$compat_path" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path) as handle:
    text = handle.read()
text = re.sub(
    r"(?m)^\| macOS \(arm64\) \|.*$",
    "| macOS (arm64) | Qualified | Same as Linux, all four agent CLIs verified |",
    text,
)
with open(path, "w") as handle:
    handle.write(text)
PY
  run bash "$CHECK_RELEASE" "$repo"
  assert_failure
  assert_output_contains "profile mechanics"
  cp -p "$compat" "$compat_path"

  run bash "$CHECK_RELEASE" "$repo"
  assert_success
}

@test "release: check-release refuses a Darwin evidence summary that drops a gap" {
  assert_file_exists "$CHECK_RELEASE"

  local repo="$TEST_TMPDIR/repo-darwin-evidence"
  local original="$TEST_TMPDIR/macos-2026-10-31.md"
  local mutated="$TEST_TMPDIR/mutated-macos-2026-10-31.md"
  mkdir -p "$repo"
  cp -a "$AP_SUBJECT/." "$repo/"
  rm -rf "$repo/.git" "$repo/dist"
  local darwin="$repo/docs/evidence/macos-2026-10-31.md"
  cp -p "$darwin" "$original"

  run bash "$CHECK_RELEASE" "$repo"
  assert_success

  # The host had no agent CLI, and the summary has to keep saying so rather than
  # borrow the Linux observations for Darwin.
  drop_lines "$original" "$mutated" "no agent CLI was installed"
  cp -p "$mutated" "$darwin"
  run bash "$CHECK_RELEASE" "$repo"
  assert_failure
  assert_output_contains "real agent CLI classes were not observed"

  # Credentialed model runs stay recorded as a gap on every platform. Only the
  # phrase is rewritten, so the class row itself still matches.
  awk '{ gsub(/credential-dependent gap/, "gap that depends on credentials"); print }' \
    "$original" >"$mutated"
  cp -p "$mutated" "$darwin"
  run bash "$CHECK_RELEASE" "$repo"
  assert_failure
  assert_output_contains "credential-dependent gap"

  # Every integration the release claims to support is named by the evidence.
  awk '{ gsub(/Antigravity CLI/, "Antigravity"); print }' "$original" >"$mutated"
  cp -p "$mutated" "$darwin"
  run bash "$CHECK_RELEASE" "$repo"
  assert_failure
  assert_output_contains "Antigravity CLI"

  # Only a sanitized summary is published.
  drop_lines "$original" "$mutated" "Sanitized summary"
  cp -p "$mutated" "$darwin"
  run bash "$CHECK_RELEASE" "$repo"
  assert_failure
  assert_output_contains "sanitized"

  # The summary itself is a required release file.
  rm -f "$darwin"
  run bash "$CHECK_RELEASE" "$repo"
  assert_failure
  assert_output_contains "docs/evidence/macos-2026-10-31.md"

  cp -p "$original" "$darwin"
  run bash "$CHECK_RELEASE" "$repo"
  assert_success
}
