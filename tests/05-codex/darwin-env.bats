#!/usr/bin/env bats
# Darwin Codex adapter: CODEX_HOME and the HOME-relative ~/.agents skill root
# stay profile-local, A and B discovery markers cannot cross, and a synthetic
# host Codex configuration stays byte-identical.
#
# A Linux host cannot run Darwin, so this file selects the platform probe
# through the internal AP_TEST_PLATFORM_OS seam (see platform.sh). The seam is
# honoured only inside the test suite and is not a supported user option, so a
# green run here proves branch selection and the environment contract only. It
# is never evidence of stock macOS bash 3.2 or of real Codex behavior.
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
  cat >"$STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf 'codex-cli 0.165.0\n'
  exit 0
fi

label="${1:-unknown}"
skills_home="$HOME/.agents/skills"

# Codex discovers skills from CODEX_HOME and from the HOME-relative .agents
# root. Both writes are recorded where the agent would put them.
mkdir -p "$CODEX_HOME/skills" "$skills_home"
printf '%s\n' "$label" >"$CODEX_HOME/skills/$label.txt"
printf '%s\n' "$label" >"$skills_home/$label.txt"

printf 'HOME=%s\n' "$HOME"
printf 'CODEX_HOME=%s\n' "$CODEX_HOME"
printf 'AGENTS_ROOT=%s\n' "$skills_home"
printf 'CODEX_SKILLS=%s\n' "$(cd "$CODEX_HOME/skills" && printf '%s ' *.txt 2>/dev/null || true)"
printf 'AGENT_SKILLS=%s\n' "$(cd "$skills_home" && printf '%s ' *.txt 2>/dev/null || true)"
if [[ -f "$CODEX_HOME/config.toml" || -f "$CODEX_HOME/auth.json" ]]; then
  printf 'HOST_CONFIG_VISIBLE=yes\n'
else
  printf 'HOST_CONFIG_VISIBLE=no\n'
fi
STUB
  chmod +x "$STUB_BIN/codex"
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

@test "darwin codex: CODEX_HOME and HOME skill roots stay profile-local without mounts" {
  local repo="$TEST_TMPDIR/repo-codex-darwin"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile codex-a
  assert_success
  run bash "$AP_HELPER" init --profile codex-b
  assert_success

  local prof_a="$repo/.agent-profiles/codex-a"
  local prof_b="$repo/.agent-profiles/codex-b"

  # Synthetic host Codex state that a mounted Linux profile would hide.
  mkdir -p "$HOME/.codex/skills/host-skill" "$HOME/.agents/skills/host-skill"
  printf 'model = "host"\n' >"$HOME/.codex/config.toml"
  printf '{"token":"host-codex-credential-marker-502"}\n' >"$HOME/.codex/auth.json"
  printf 'host\n' >"$HOME/.codex/skills/host-skill/SKILL.md"
  printf 'host\n' >"$HOME/.agents/skills/host-skill/SKILL.md"

  local host_before
  host_before=$(hash_tree "$HOME")

  run env PATH="$STUB_BIN:$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" run --profile codex-a -- codex a
  assert_success
  assert_output_not_contains "created empty host mountpoint"
  assert_output_contains "HOME=$prof_a"
  assert_output_contains "CODEX_HOME=$prof_a/.codex"
  assert_output_contains "AGENTS_ROOT=$prof_a/.agents"
  assert_output_contains "CODEX_SKILLS=a.txt "
  assert_output_contains "AGENT_SKILLS=a.txt "
  assert_output_contains "HOST_CONFIG_VISIBLE=no"

  run env PATH="$STUB_BIN:$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" run --profile codex-b -- codex b
  assert_success
  assert_output_contains "HOME=$prof_b"
  assert_output_contains "CODEX_HOME=$prof_b/.codex"
  assert_output_contains "AGENTS_ROOT=$prof_b/.agents"
  assert_output_contains "CODEX_SKILLS=b.txt "
  assert_output_contains "AGENT_SKILLS=b.txt "
  assert_output_contains "HOST_CONFIG_VISIBLE=no"

  # A and B markers never cross profile boundaries, in either skill root.
  assert_equal "$(cat "$prof_a/.codex/skills/a.txt")" "a"
  assert_equal "$(cat "$prof_a/.agents/skills/a.txt")" "a"
  assert_equal "$(cat "$prof_b/.codex/skills/b.txt")" "b"
  assert_equal "$(cat "$prof_b/.agents/skills/b.txt")" "b"
  [[ ! -e "$prof_a/.codex/skills/b.txt" ]]
  [[ ! -e "$prof_b/.codex/skills/a.txt" ]]
  [[ ! -e "$prof_a/.agents/skills/b.txt" ]]
  [[ ! -e "$prof_b/.agents/skills/a.txt" ]]
  # The synthetic host canary was never discovered as a profile skill.
  [[ ! -e "$prof_a/.codex/skills/host-skill" ]]
  [[ ! -e "$prof_a/.agents/skills/host-skill" ]]

  # The synthetic host tree is byte-identical and its credential never leaked.
  assert_equal "$(hash_tree "$HOME")" "$host_before"
  assert_output_not_contains "host-codex-credential-marker-502"
}
