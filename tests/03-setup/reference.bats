#!/usr/bin/env bats

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  REFERENCE="$AP_SKILL_DIR/references/machine-setup.md"
}

teardown() {
  teardown_isolation
}

@test "machine setup reference: documents prerequisites and supported setup paths" {
  run cat "$REFERENCE"
  assert_success
  assert_output_contains "## System Prerequisites"
  assert_output_contains "## Detection and Preview"
  assert_output_contains "unprivileged user namespaces"
  assert_output_contains "unsupported automatic path"
  assert_output_contains "curl"
}

@test "machine setup reference: documents apply, task integration and forwarding" {
  run cat "$REFERENCE"
  assert_success
  assert_output_contains "## Global Mise Task Integration"
  assert_output_contains "agent-profiles setup"
  assert_output_contains "agent-profiles-init"
  assert_output_contains "mise run agent-profiles-init -- --profile"
  assert_output_contains "--tasks-only"
}

@test "machine setup reference: documents conflicts, backups and managed configuration" {
  run cat "$REFERENCE"
  assert_success
  assert_output_contains "## Task Conflicts and Backups"
  assert_output_contains "--prepare-dir"
  assert_output_contains "chezmoi"
  assert_output_contains "untouched"
}

@test "machine setup reference: documents versioned deployment and diagnosis" {
  run cat "$REFERENCE"
  assert_success
  assert_output_contains "## Versioned Deployment"
  assert_output_contains "manifest"
  assert_output_contains "stale"
  assert_output_contains "## Doctor Checks"
  assert_output_contains "namespaces"
  assert_output_contains "seccomp"
}

@test "machine setup reference: documents optional agents and the documented test input" {
  run cat "$REFERENCE"
  assert_success
  assert_output_contains "mise registry"
  assert_output_contains "--agent"
  assert_output_contains "AP_OS_RELEASE"
  assert_output_contains "## Troubleshooting"
}
