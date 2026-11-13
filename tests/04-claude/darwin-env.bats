#!/usr/bin/env bats
# Darwin Claude Code adapter: profile config directory, HOME-relative
# ~/.claude.json and skills, no inherited secure-storage override, and a
# synthetic host credential/setting tree that stays byte-identical.
#
# A Linux host cannot run Darwin, so this file selects the platform probe
# through the internal AP_TEST_PLATFORM_OS seam (see platform.sh). The seam is
# honoured only inside the test suite and is not a supported user option, so a
# green run here proves branch selection and the environment contract only. It
# is never evidence of stock macOS bash 3.2 or of real Claude Code behavior.
# shellcheck disable=SC2030,SC2031

setup_file() {
  # Every Darwin invocation below runs with a PATH that holds every host
  # command except bwrap: profile redirection must not depend on bubblewrap.
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
  cat >"$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf 'claude 2.1.312\n'
  exit 0
fi

# The agent resolves its configuration from CLAUDE_CONFIG_DIR and its project
# state from HOME. Both writes are recorded where the agent would put them.
mkdir -p "$CLAUDE_CONFIG_DIR/skills/config-skill"
mkdir -p "$HOME/.claude/skills/home-skill"
printf 'profile\n' >"$CLAUDE_CONFIG_DIR/skills/config-skill/SKILL.md"
printf 'profile\n' >"$HOME/.claude/skills/home-skill/SKILL.md"
printf '{"project":"profile"}\n' >"$HOME/.claude.json"
printf '{"env":{}}\n' >"$CLAUDE_CONFIG_DIR/settings.json"

printf 'HOME=%s\n' "$HOME"
printf 'CONFIG_DIR=%s\n' "$CLAUDE_CONFIG_DIR"
printf 'SECURE_STORAGE=%s\n' "${CLAUDE_SECURESTORAGE_CONFIG_DIR-UNSET}"
if [[ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]]; then
  printf 'HOST_CREDENTIALS_VISIBLE=yes\n'
else
  printf 'HOST_CREDENTIALS_VISIBLE=no\n'
fi
STUB
  chmod +x "$STUB_BIN/claude"
}

teardown() {
  teardown_isolation
}

# hash_tree <dir>: stable content hash of every file under <dir>, so a test can
# prove a synthetic host tree is byte-identical before and after a profile run.
hash_tree() {
  python3 - "$1" <<'PY'
import hashlib
import os
import sys

root = sys.argv[1]
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        print(digest, os.path.relpath(path, root))
PY
}

@test "darwin claude: profile config and HOME hide synthetic host settings and credentials without mounts" {
  local repo="$TEST_TMPDIR/repo-claude-darwin"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile claude-darwin
  assert_success

  local prof_dir="$repo/.agent-profiles/claude-darwin"

  # Synthetic host configuration, settings and credentials that a mounted
  # Linux profile would hide. Darwin must hide them by environment only.
  mkdir -p "$HOME/.claude/skills/host-skill"
  printf '{"project":"host"}\n' >"$HOME/.claude.json"
  printf '{"host":"settings"}\n' >"$HOME/.claude/settings.json"
  printf 'host\n' >"$HOME/.claude/skills/host-skill/SKILL.md"
  printf '{"token":"host-claude-credential-marker-401"}\n' >"$HOME/.claude/.credentials.json"

  local host_before
  host_before=$(hash_tree "$HOME")

  run env PATH="$STUB_BIN:$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    CLAUDE_SECURESTORAGE_CONFIG_DIR="$TEST_TMPDIR/host-secure-storage" \
    bash "$AP_HELPER" run --profile claude-darwin -- claude
  assert_success
  assert_output_not_contains "created empty host mountpoint"

  assert_output_contains "HOME=$prof_dir"
  assert_output_contains "CONFIG_DIR=$prof_dir/.claude"
  # The inherited secure-storage override must not survive into the profile.
  assert_output_contains "SECURE_STORAGE=UNSET"
  # The host credential file is not reachable through the profile config dir.
  assert_output_contains "HOST_CREDENTIALS_VISIBLE=no"

  # Profile config, ~/.claude.json and both skill roots are profile-local.
  assert_file_exists "$prof_dir/.claude.json"
  assert_file_exists "$prof_dir/.claude/settings.json"
  assert_file_exists "$prof_dir/.claude/skills/config-skill/SKILL.md"
  assert_file_exists "$prof_dir/.claude/skills/home-skill/SKILL.md"
  [[ ! -e "$prof_dir/.claude/.credentials.json" ]]

  # The synthetic host tree is byte-identical: nothing was mounted, copied or
  # written outside profile storage.
  assert_equal "$(hash_tree "$HOME")" "$host_before"
  assert_equal "$(cat "$HOME/.claude/.credentials.json")" \
    '{"token":"host-claude-credential-marker-401"}'
  assert_equal "$(cat "$HOME/.claude.json")" '{"project":"host"}'

  # home/ stays the initialization marker and never becomes the Darwin HOME.
  assert_dir_exists "$prof_dir/home"
  [[ ! -e "$prof_dir/home/.claude.json" ]]
}
