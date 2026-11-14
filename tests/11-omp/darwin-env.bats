#!/usr/bin/env bats
# Darwin oh-my-pi adapter: HOME-relative ~/.omp and ~/.agents skill roots stay
# profile-local, an inherited PI_CODING_AGENT_DIR is cleared, and profile runs
# need no mount table.
#
# A Linux host cannot run Darwin, so this file selects the platform probe
# through the internal AP_TEST_PLATFORM_OS seam (see platform.sh). The seam is
# honoured only inside the test suite and is not a supported user option, so a
# green run here proves branch selection and the environment contract only. It
# is never evidence of stock macOS bash 3.2 or of real oh-my-pi behavior.
# shellcheck disable=SC2030,SC2031

setup_file() {
  NO_BWRAP_BIN="$BATS_FILE_TMPDIR/no-bwrap-bin"
  mkdir -p "$NO_BWRAP_BIN"

  # shellcheck source=tests/helpers/restricted-path.bash
  source "$BATS_TEST_DIRNAME/../helpers/restricted-path.bash"
  ap_test_restricted_bin "$NO_BWRAP_BIN" bwrap

  export NO_BWRAP_BIN
}

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation

  STUB_BIN="$TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  cat >"$STUB_BIN/omp" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf 'omp/18.20.0\n'
  exit 0
fi

if [[ -f "$HOME/.omp/agent/host-marker" ]]; then
  host_marker="yes"
else
  host_marker="no"
fi

mkdir -p "$HOME/.omp/agent/sessions" "$HOME/.omp/logs" "$HOME/.omp/natives/18.20.0" \
  "$HOME/.agents/skills/omp-skill"
printf 'profile\n' >"$HOME/.omp/agent/agent.db"
printf 'profile\n' >"$HOME/.omp/logs/omp.log"
printf 'profile\n' >"$HOME/.agents/skills/omp-skill/SKILL.md"

printf 'HOME=%s\n' "$HOME"
printf 'PI_CODING_AGENT_DIR=%s\n' "${PI_CODING_AGENT_DIR:-unset}"
printf 'HOST_MARKER_VISIBLE=%s\n' "$host_marker"
STUB
  chmod +x "$STUB_BIN/omp"
}

teardown() {
  teardown_isolation
}

@test "darwin omp: profile HOME, agent state and skill root stay profile-local" {
  local repo="$TEST_TMPDIR/repo-omp-darwin"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile omp-darwin
  assert_success

  local prof_dir="$repo/.agent-profiles/omp-darwin"

  mkdir -p "$HOME/.omp/agent" "$HOME/.agents/skills"
  printf 'host\n' >"$HOME/.omp/agent/host-marker"
  printf 'host\n' >"$HOME/.agents/skills/host-skill.md"

  run env PATH="$STUB_BIN:$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    PI_CODING_AGENT_DIR="$TEST_TMPDIR/foreign-agent-dir" \
    bash "$AP_HELPER" run --profile omp-darwin -- omp
  assert_success
  assert_output_not_contains "created empty host mountpoint"

  assert_output_contains "HOME=$prof_dir"
  assert_output_contains "PI_CODING_AGENT_DIR=unset"
  assert_output_contains "HOST_MARKER_VISIBLE=no"

  assert_file_exists "$prof_dir/.omp/agent/agent.db"
  assert_file_exists "$prof_dir/.omp/logs/omp.log"
  assert_file_exists "$prof_dir/.agents/skills/omp-skill/SKILL.md"
  [[ ! -e "$prof_dir/.omp/agent/host-marker" ]]
  [[ ! -e "$prof_dir/.agents/skills/host-skill.md" ]]
}

@test "darwin omp: doctor reports profile agent state without a mount table" {
  local repo="$TEST_TMPDIR/repo-omp-darwin-doctor"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile omp-doctor
  assert_success
  mkdir -p "$repo/.agent-profiles/omp-doctor/.omp/agent/sessions"
  : >"$repo/.agent-profiles/omp-doctor/.omp/agent/agent.db"

  run env PATH="$STUB_BIN:$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" doctor --json --agent omp --profile omp-doctor
  assert_success

  python3 - "$output" "$repo/.agent-profiles/omp-doctor" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["omp"]["profile"]
assert profile["status"] == "initialized", profile
assert profile["config_dir"] == sys.argv[2] + "/.omp", profile["config_dir"]
assert profile["agent_dir"] == sys.argv[2] + "/.omp/agent", profile["agent_dir"]
assert profile["artifacts"]["agent_db"] is True, profile["artifacts"]
assert profile["artifacts"]["sessions"] is True, profile["artifacts"]
PY
}
