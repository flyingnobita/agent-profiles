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

@test "guard: SKILL.md routing table links to valid existing references" {
  local skill_md="$AP_SKILL_DIR/SKILL.md"
  assert_file_exists "$skill_md"

  # Extract markdown links of form [label](references/...)
  local links
  links=$(grep -oE '\[[^]]+\]\((references/[^)]+)\)' "$skill_md" | sed -E 's/.*\(references\/(.*)\)/\1/')

  for rel in $links; do
    assert_file_exists "$AP_SKILL_DIR/references/$rel"
  done
}

@test "routing: cases.tsv cases resolve to target references with required headings and terms" {
  local cases_file="$AP_SUBJECT/tests/routing/cases.tsv"
  assert_file_exists "$cases_file"

  while IFS=$'\t' read -r topic _query target_ref required_heading required_term || [[ -n "$topic" ]]; do
    [[ "$topic" == "topic" ]] && continue # header
    [[ -z "$topic" ]] && continue

    local ref_path="$AP_SKILL_DIR/$target_ref"
    assert_file_exists "$ref_path"

    # Check required heading exists in target reference
    run grep -F "$required_heading" "$ref_path"
    assert_success

    # Check required term exists in target reference
    run grep -F "$required_term" "$ref_path"
    assert_success
  done <"$cases_file"
}

@test "guard: questions.md explicitly covers mandatory domain concepts" {
  local q_file="$AP_SKILL_DIR/references/questions.md"
  assert_file_exists "$q_file"

  # 1. Not a security boundary for untrusted code
  run grep -Fi "not a security boundary" "$q_file"
  assert_success
  run grep -Fi "untrusted code" "$q_file"
  assert_success

  # 2. Inherited credentials
  run grep -Fi "inherited environment credentials" "$q_file"
  assert_success

  # 3. Shared host resources
  run grep -Fi "shared host resources" "$q_file"
  assert_success

  # 4. Linux evidence vs unverified macOS
  run grep -Fi "Linux with unprivileged user namespaces" "$q_file"
  assert_success
  run grep -Fi "macOS" "$q_file"
  assert_success
  run grep -Fi "not qualified" "$q_file"
  assert_success
}

@test "guard: reading a reference causes zero configuration or file changes" {
  local fixture_dir="$TEST_TMPDIR/check-tree"
  create_fixture_repo "$fixture_dir"

  local before_hash
  before_hash=$(git -C "$fixture_dir" rev-parse HEAD)
  local before_status
  before_status=$(git -C "$fixture_dir" status --porcelain)

  # Consult questions reference
  local content
  content=$(cat "$AP_SKILL_DIR/references/questions.md")
  [[ -n "$content" ]]

  local after_hash
  after_hash=$(git -C "$fixture_dir" rev-parse HEAD)
  local after_status
  after_status=$(git -C "$fixture_dir" status --porcelain)

  assert_equal "$before_hash" "$after_hash"
  assert_equal "$before_status" "$after_status"
}

@test "guard: progressive disclosure loads 1-hop focused reference per question" {
  local cases_file="$AP_SUBJECT/tests/routing/cases.tsv"
  assert_file_exists "$cases_file"

  # Verify every case maps to a single focused reference under references/
  while IFS=$'\t' read -r topic _query target_ref _heading _term || [[ -n "$topic" ]]; do
    [[ "$topic" == "topic" ]] && continue
    [[ -z "$topic" ]] && continue

    [[ "$target_ref" =~ ^references/[a-zA-Z0-9/_-]+\.md$ ]]
    # Ensure no reference links point back to source code or unnecessary files
    grep -q -E '\.\./scripts' "$AP_SKILL_DIR/$target_ref" 2>/dev/null && return 1 || true
  done <"$cases_file"
}

@test "routing: SKILL.md resolves helper relative to skill directory and documents read-only Q&A" {
  local skill_md="$AP_SKILL_DIR/SKILL.md"
  assert_file_exists "$skill_md"

  # Must not contain bare ambiguous command 'bash scripts/agent-profiles'
  run grep -E '^\s*bash scripts/agent-profiles' "$skill_md"
  assert_failure

  # Must mention resolving relative to skill directory or skill path
  run grep -Fi "relative to" "$skill_md"
  assert_success

  # Must document read-only Q&A without mutating repo or config
  run grep -Fi "without mutating" "$skill_md"
  assert_success
}

@test "routing: helper --help summarizes every implemented command and no false planned list" {
  run bash "$AP_HELPER" --help
  assert_success
  assert_output_contains "Implemented commands:"
  assert_output_not_contains "Planned"

  for cmd in doctor init list run setup reset remove migrate recover; do
    assert_output_contains "  $cmd"
  done

  # setup is implemented and runs a read-only preview by default
  run bash "$AP_HELPER" setup --preview
  assert_success
  assert_output_contains "No changes made"

  # Unknown commands still reject with an actionable message
  run bash "$AP_HELPER" definitely-unknown
  assert_failure
  assert_equal "$status" 64
  assert_output_contains "unknown command"
  assert_output_contains "Available commands"
}

@test "routing: SKILL.md command summary documents every implemented command" {
  local skill_md="$AP_SKILL_DIR/SKILL.md"
  assert_file_exists "$skill_md"

  run grep -F "Planned future commands" "$skill_md"
  assert_failure

  for cmd in doctor init list run setup reset remove migrate recover; do
    run grep -F "bash \"\$AP_HELPER\" $cmd" "$skill_md"
    assert_success
  done
}
