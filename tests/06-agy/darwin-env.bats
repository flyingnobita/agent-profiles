#!/usr/bin/env bats
# Darwin Antigravity adapter: agy has no configuration-directory variable in the
# tested version, so HOME redirection is the only mechanism that puts ~/.gemini,
# the XDG plugin-secret root and ~/.agents inside the selected profile.
#
# A Linux host cannot run Darwin, so this file selects the platform probe
# through the internal AP_TEST_PLATFORM_OS seam (see platform.sh). The seam is
# honoured only inside the test suite and is not a supported user option, so a
# green run here proves branch selection and the environment contract only. It
# is never evidence of stock macOS bash 3.2 or of real Antigravity behavior.
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
  cat >"$STUB_BIN/agy" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf '1.4.9\n'
  exit 0
fi

gemini_home="$HOME/.gemini"
agents_root="$HOME/.agents/skills"

# Antigravity has no configuration-directory variable: every path below comes
# from HOME or the XDG root. Record host visibility before writing profile state
# so a leaked host ~/.gemini cannot look clean afterwards.
if [[ -f "$gemini_home/antigravity-cli/host-only-settings.json" ]]; then
  host_settings="yes"
else
  host_settings="no"
fi

mkdir -p "$gemini_home/antigravity-cli" "$gemini_home/config/skills" \
  "$agents_root" "${XDG_CONFIG_HOME:-$HOME/.config}/antigravity"
printf '{"profile":"settings"}\n' >"$gemini_home/antigravity-cli/settings.json"
printf '{"profile":"secrets"}\n' >"${XDG_CONFIG_HOME:-$HOME/.config}/antigravity/plugin-secrets.json"
printf 'profile\n' >"$gemini_home/config/skills/gemini-skill.md"
printf 'profile\n' >"$agents_root/agents-skill.md"

# No inherited variable may point into the synthetic host home: for agy, HOME
# is the whole redirection and nothing else may address host configuration.
leaks=""
for name in $(env | cut -d= -f1); do
  case "$name" in
    HOME | PWD | OLDPWD | _ | SHLVL | AP_HOST_HOME) continue ;;
  esac
  value="${!name}"
  case "$value" in
    "$AP_HOST_HOME" | "$AP_HOST_HOME"/*) leaks="$leaks $name" ;;
  esac
done

printf 'HOME=%s\n' "$HOME"
printf 'GEMINI_HOME=%s\n' "$gemini_home"
printf 'XDG_CONFIG_HOME=%s\n' "${XDG_CONFIG_HOME:-}"
printf 'AGENTS_ROOT=%s\n' "$agents_root"
printf 'HOST_SETTINGS_VISIBLE=%s\n' "$host_settings"
printf 'HOST_HOME_LEAKS=%s\n' "${leaks:-none}"
STUB
  chmod +x "$STUB_BIN/agy"
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

@test "darwin agy: HOME resolves .gemini and .agents inside profile while host canary remains unchanged" {
  local repo="$TEST_TMPDIR/repo-agy-darwin"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile agy-darwin
  assert_success

  local prof_dir="$repo/.agent-profiles/agy-darwin"

  # Synthetic host ~/.gemini and ~/.agents trees, including a host-only settings
  # file and a credential file agy would read from HOME on an unredirected host.
  mkdir -p "$HOME/.gemini/antigravity-cli" "$HOME/.gemini/config/skills" "$HOME/.agents/skills"
  printf '{"host":"settings"}\n' >"$HOME/.gemini/antigravity-cli/host-only-settings.json"
  printf '{"token":"host-agy-credential-marker-603"}\n' >"$HOME/.gemini/antigravity-cli/oauth_creds.json"
  printf 'host\n' >"$HOME/.gemini/config/skills/host-skill.md"
  printf 'host\n' >"$HOME/.agents/skills/host-skill.md"

  local host_before
  host_before=$(hash_tree "$HOME")

  run env PATH="$STUB_BIN:$NO_BWRAP_BIN" AP_TEST_PLATFORM_OS=Darwin \
    AP_HOST_HOME="$HOME" \
    bash "$AP_HELPER" run --profile agy-darwin -- agy
  assert_success
  assert_output_not_contains "created empty host mountpoint"

  # HOME is the profile root, so both Home-relative roots are profile-local.
  assert_output_contains "HOME=$prof_dir"
  assert_output_contains "GEMINI_HOME=$prof_dir/.gemini"
  assert_output_contains "XDG_CONFIG_HOME=$prof_dir/.config"
  assert_output_contains "AGENTS_ROOT=$prof_dir/.agents/skills"
  # The synthetic host settings and credentials were never resolved.
  assert_output_contains "HOST_SETTINGS_VISIBLE=no"
  # No inherited variable addresses the host home: HOME is the only mechanism.
  assert_output_contains "HOST_HOME_LEAKS=none"

  assert_file_exists "$prof_dir/.gemini/antigravity-cli/settings.json"
  assert_file_exists "$prof_dir/.gemini/config/skills/gemini-skill.md"
  assert_file_exists "$prof_dir/.config/antigravity/plugin-secrets.json"
  assert_file_exists "$prof_dir/.agents/skills/agents-skill.md"
  [[ ! -e "$prof_dir/.gemini/antigravity-cli/host-only-settings.json" ]]
  [[ ! -e "$prof_dir/.gemini/antigravity-cli/oauth_creds.json" ]]

  # The synthetic host tree is byte-identical and the credential never leaked.
  assert_equal "$(hash_tree "$HOME")" "$host_before"
  assert_output_not_contains "host-agy-credential-marker-603"
}
