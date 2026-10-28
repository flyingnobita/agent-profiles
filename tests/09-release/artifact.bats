#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  CHECK_RELEASE="$AP_SUBJECT/tests/tools/check-release"
  RELEASE_TOOL="$AP_SUBJECT/tools/release-artifacts"
  NOTES="$AP_SUBJECT/RELEASE_NOTES.md"
  VERSION="$(tr -d '[:space:]' <"$AP_SKILL_DIR/VERSION")"
}

teardown() {
  teardown_isolation
}

@test "release: versioned release notes describe the local v0.1.0 scope" {
  assert_file_exists "$NOTES"
  run grep -E "^# .*flyingnobita-agent-profiles v$VERSION$" "$NOTES"
  assert_success
  for term in "MIT" "Linux" "not qualified" "not a security sandbox" \
    "credential-dependent" "not published"; do
    run grep -Fi -- "$term" "$NOTES"
    assert_success
  done
}

@test "release: mise defines the release-artifacts task that verifies before building" {
  run grep -F -- "[tasks.release-artifacts]" "$AP_SUBJECT/mise.toml"
  assert_success
  run grep -F -- "check-release" "$AP_SUBJECT/mise.toml"
  assert_success
  run grep -F -- "tools/release-artifacts" "$AP_SUBJECT/mise.toml"
  assert_success
}

@test "release: release-artifacts builds a tarball, checksum and notes outside Git" {
  assert_file_exists "$RELEASE_TOOL"
  local out="$TEST_TMPDIR/dist"
  run bash "$RELEASE_TOOL" "$AP_SUBJECT" --output-dir "$out"
  assert_success

  assert_file_exists "$out/flyingnobita-agent-profiles-$VERSION.tar.gz"
  assert_file_exists "$out/flyingnobita-agent-profiles-$VERSION.tar.gz.sha256"
  assert_file_exists "$out/RELEASE_NOTES.md"

  run bash -c "cd '$out' && sha256sum -c 'flyingnobita-agent-profiles-$VERSION.tar.gz.sha256'"
  assert_success

  # Build output must not become tracked content.
  run grep -qxF -- "dist/" "$AP_SUBJECT/.gitignore"
  assert_success
}

@test "release: the built artifact verifies, extracts and runs from a disposable copy" {
  assert_file_exists "$RELEASE_TOOL"
  local out="$TEST_TMPDIR/dist"
  run bash "$RELEASE_TOOL" "$AP_SUBJECT" --output-dir "$out"
  assert_success

  run bash "$CHECK_RELEASE" "$AP_SUBJECT" --artifacts "$out"
  assert_success
  assert_output_contains "artifact checksum verifies"
  assert_output_contains "extracted artifact runs --version and doctor --json"
}

@test "release: check-release rejects a tampered artifact" {
  local out="$TEST_TMPDIR/dist-tampered"
  mkdir -p "$out"
  run bash "$RELEASE_TOOL" "$AP_SUBJECT" --output-dir "$out"
  assert_success

  printf 'x' >>"$out/flyingnobita-agent-profiles-$VERSION.tar.gz"
  run bash "$CHECK_RELEASE" "$AP_SUBJECT" --artifacts "$out"
  assert_failure
  assert_output_contains "artifact checksum verification failed"
}
