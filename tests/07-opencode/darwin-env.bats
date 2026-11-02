#!/usr/bin/env bats
# Darwin OpenCode adapter: OPENCODE_CONFIG_DIR, the four XDG roots and the
# HOME-relative ~/.agents skill root stay profile-local, and the accepted-command
# --standalone injection is preserved without a mount table.
#
# A Linux host cannot run Darwin, so this file selects the platform probe
# through the internal AP_TEST_PLATFORM_OS seam (see platform.sh). The seam is
# honoured only inside the test suite and is not a supported user option, so a
# green run here proves branch selection and the environment contract only. It
# is never evidence of stock macOS bash 3.2 or of real OpenCode behavior.
# shellcheck disable=SC2030,SC2031

setup_file() {
  # Every Darwin invocation below runs with a PATH that holds every host
  # command except bwrap: profile redirection must not depend on bubblewrap.
  NO_BWRAP_BIN="$BATS_FILE_TMPDIR/no-bwrap-bin"
  mkdir -p "$NO_BWRAP_BIN"

  local dir tool name
  local old_ifs="$IFS"
  IFS=':'
  for dir in $PATH; do
    IFS="$old_ifs"
    [[ -d "$dir" ]] || continue
    for tool in "$dir"/*; do
      [[ -x "$tool" && ! -d "$tool" ]] || continue
      name="$(basename "$tool")"
      [[ "$name" == "bwrap" ]] && continue
      [[ -e "$NO_BWRAP_BIN/$name" ]] && continue
      ln -s "$tool" "$NO_BWRAP_BIN/$name" 2>/dev/null || true
    done
  done
  IFS="$old_ifs"

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
  cat >"$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf '2.2.0\n'
  exit 0
fi

agents_root="$HOME/.agents/skills"

# Record host visibility before writing profile state, so a leaked host config
# file cannot look clean afterwards.
if [[ -f "$OPENCODE_CONFIG_DIR/host-only.json" ]]; then
  host_config="yes"
else
  host_config="no"
fi

mkdir -p "$OPENCODE_CONFIG_DIR/skills" "$agents_root" \
  "$XDG_DATA_HOME/opencode" "$XDG_STATE_HOME/opencode" "$XDG_CACHE_HOME/opencode"
printf '{"profile":"config"}\n' >"$OPENCODE_CONFIG_DIR/opencode.json"
printf 'profile\n' >"$OPENCODE_CONFIG_DIR/skills/opencode-skill.md"
printf 'profile\n' >"$agents_root/agents-skill.md"
printf 'profile\n' >"$XDG_DATA_HOME/opencode/marker.txt"
printf 'profile\n' >"$XDG_STATE_HOME/opencode/marker.txt"
printf 'profile\n' >"$XDG_CACHE_HOME/opencode/marker.txt"

printf 'ARGS=%s\n' "$*"
printf 'HOME=%s\n' "$HOME"
printf 'OPENCODE_CONFIG_DIR=%s\n' "$OPENCODE_CONFIG_DIR"
printf 'XDG_CONFIG_HOME=%s\n' "$XDG_CONFIG_HOME"
printf 'XDG_DATA_HOME=%s\n' "$XDG_DATA_HOME"
printf 'XDG_STATE_HOME=%s\n' "$XDG_STATE_HOME"
printf 'XDG_CACHE_HOME=%s\n' "$XDG_CACHE_HOME"
printf 'AGENTS_ROOT=%s\n' "$agents_root"
printf 'HOST_CONFIG_VISIBLE=%s\n' "$host_config"
STUB
  chmod +x "$STUB_BIN/opencode"
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

@test "darwin opencode: config XDG and HOME skill roots use profile and standalone injection is preserved" {
  local repo="$TEST_TMPDIR/repo-opencode-darwin"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile opencode-darwin
  assert_success

  local prof_dir="$repo/.agent-profiles/opencode-darwin"

  # Synthetic host OpenCode state in both roots a mounted Linux profile hides.
  mkdir -p "$HOME/.opencode" "$HOME/.agents/skills" "$XDG_CONFIG_HOME/opencode"
  printf '{"host":"config"}\n' >"$HOME/.opencode/host-only.json"
  printf '{"host":"xdg"}\n' >"$XDG_CONFIG_HOME/opencode/opencode.json"
  printf '{"token":"host-opencode-credential-marker-704"}\n' >"$XDG_CONFIG_HOME/opencode/auth.json"
  printf 'host\n' >"$HOME/.agents/skills/host-skill.md"

  local host_home_before host_xdg_before
  host_home_before=$(hash_tree "$HOME")
  host_xdg_before=$(hash_tree "$XDG_CONFIG_HOME")

  run env PATH="$STUB_BIN:$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" run --profile opencode-darwin -- opencode
  assert_success
  assert_output_not_contains "created empty host mountpoint"

  # The accepted TUI command still gets a private standalone server.
  assert_output_contains "ARGS=--standalone"

  assert_output_contains "HOME=$prof_dir"
  assert_output_contains "OPENCODE_CONFIG_DIR=$prof_dir/.opencode"
  assert_output_contains "XDG_CONFIG_HOME=$prof_dir/.config"
  assert_output_contains "XDG_DATA_HOME=$prof_dir/.local/share"
  assert_output_contains "XDG_STATE_HOME=$prof_dir/.local/state"
  assert_output_contains "XDG_CACHE_HOME=$prof_dir/.cache"
  assert_output_contains "AGENTS_ROOT=$prof_dir/.agents/skills"
  assert_output_contains "HOST_CONFIG_VISIBLE=no"

  # A command that rejects --standalone still runs unchanged.
  run env PATH="$STUB_BIN:$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" run --profile opencode-darwin -- opencode upgrade
  assert_success
  assert_output_contains "ARGS=upgrade"

  assert_file_exists "$prof_dir/.opencode/opencode.json"
  assert_file_exists "$prof_dir/.opencode/skills/opencode-skill.md"
  assert_file_exists "$prof_dir/.local/share/opencode/marker.txt"
  assert_file_exists "$prof_dir/.local/state/opencode/marker.txt"
  assert_file_exists "$prof_dir/.cache/opencode/marker.txt"
  assert_file_exists "$prof_dir/.agents/skills/agents-skill.md"
  [[ ! -e "$prof_dir/.opencode/host-only.json" ]]
  [[ ! -e "$prof_dir/.agents/skills/host-skill.md" ]]

  # Both synthetic host roots are byte-identical and the credential never leaked.
  assert_equal "$(hash_tree "$HOME")" "$host_home_before"
  assert_equal "$(hash_tree "$XDG_CONFIG_HOME")" "$host_xdg_before"
  assert_output_not_contains "host-opencode-credential-marker-704"
}
