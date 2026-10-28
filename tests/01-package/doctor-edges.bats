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

@test "doctor edge: unsupported --agent exits 64 with actionable message" {
  run bash "$AP_HELPER" doctor --agent bash
  assert_failure 64
  assert_output_contains "unsupported agent: bash"
  assert_output_contains "Supported agents: claude, codex, agy, opencode"
}

@test "doctor edge: invalid --profile exits 65 with actionable message" {
  run bash "$AP_HELPER" doctor --profile "INVALID/NAME"
  assert_failure 65
  assert_output_contains "invalid profile name"
}

@test "doctor edge: empty --profile exits with error" {
  run bash "$AP_HELPER" doctor --profile ""
  assert_failure
}

@test "doctor edge: missing python3 in text mode exits 69 with actionable stderr" {
  local no_py_bin="$TEST_TMPDIR/no-py-bin"
  mkdir -p "$no_py_bin"
  for cmd in bash git mise bwrap readlink dirname cat grep sed awk timeout which uname env rm mkdir touch printf cut tr ls head tail; do
    p=$(command -v "$cmd" 2>/dev/null || true)
    if [[ -n "$p" ]]; then
      ln -s "$p" "$no_py_bin/$cmd"
    fi
  done

  run env PATH="$no_py_bin" bash "$AP_HELPER" doctor
  assert_failure 69
  assert_output_contains "python3 is required but not found on PATH"
}

@test "doctor edge: missing python3 with --json exits 69 with JSON fallback" {
  local no_py_bin="$TEST_TMPDIR/no-py-bin"
  mkdir -p "$no_py_bin"
  for cmd in bash git mise bwrap readlink dirname cat grep sed awk timeout which uname env rm mkdir touch printf cut tr ls head tail; do
    p=$(command -v "$cmd" 2>/dev/null || true)
    if [[ -n "$p" ]]; then
      ln -s "$p" "$no_py_bin/$cmd"
    fi
  done

  run env PATH="$no_py_bin" bash "$AP_HELPER" doctor --json
  assert_failure 69
  assert_output_contains '"status": "unavailable"'
  assert_output_contains '"error": "python3 is required but not found on PATH"'
}
