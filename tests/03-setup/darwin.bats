#!/usr/bin/env bats
# Darwin machine setup: macOS detection without an os-release file, the
# configuration-redirection prerequisite set (bash, git, python3, mise and no
# bubblewrap), a real mise deploy that stays byte-identical on repeat, and the
# preserved conflict/backup/prepare-dir behaviour.
#
# A Linux host cannot run Darwin, so these tests select the platform probe
# through the internal AP_TEST_PLATFORM_OS seam (see platform.sh) and stub the
# Darwin-only tools (uname, sw_vers). The seam is honoured only inside the test
# suite and is not a supported user option, so a green run here proves branch
# selection and the setup contract only. It is never evidence of stock macOS
# bash 3.2 or of a real Darwin host.
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

setup_file() {
  load 'lib.bash'

  # A PATH holding every host command except bubblewrap, the Linux package
  # managers, curl, sudo, Homebrew and the four agents. Every Darwin setup
  # command runs with it, so a green test proves setup installs none of them.
  NO_INSTALL_BIN="$BATS_FILE_TMPDIR/no-install-bin"
  make_restricted_bin "$NO_INSTALL_BIN" bwrap pacman apt-get apt sudo curl dnf zypper apk brew \
    claude codex agy opencode

  export NO_INSTALL_BIN
}

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  load 'lib.bash'
  setup_isolation
  # setup_mise_env pins the platform probe to Linux for the existing Arch and
  # Debian fixtures; this file selects Darwin explicitly.
  export AP_TEST_PLATFORM_OS=Darwin
  setup_mise_env
  mkdir -p "$TEST_TMPDIR/work"

  DARWIN_BIN="$TEST_TMPDIR/darwin-bin"
  mkdir -p "$DARWIN_BIN"

  local real_uname
  real_uname="$(command -v uname)"
  cat >"$DARWIN_BIN/uname" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  -s) printf 'Darwin\n' ;;
  -m) printf 'arm64\n' ;;
  *) exec "$real_uname" "\$@" ;;
esac
STUB
  chmod +x "$DARWIN_BIN/uname"

  cat >"$DARWIN_BIN/sw_vers" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -productVersion) printf '15.1.1\n' ;;
  -buildVersion) printf '24B91\n' ;;
  *) printf 'ProductName:\t\tmacOS\nProductVersion:\t\t15.1.1\nBuildVersion:\t\t24B91\n' ;;
esac
STUB
  chmod +x "$DARWIN_BIN/sw_vers"

  # Spies record any attempt to reach a package manager or installer. They live
  # ahead of the restricted PATH, so a bug that tries to install is observed
  # instead of merely failing with "command not found".
  export AP_SPY_LOG="$TEST_TMPDIR/spy.log"
  local spy
  for spy in brew pacman apt-get apt sudo curl dnf zypper apk; do
    make_spy "$DARWIN_BIN" "$spy"
  done
}

teardown() {
  teardown_isolation
}

# hash_tree <path...>: stable description of every entry under each path using
# the python3 standard library only, so it runs on BSD and GNU userlands alike.
hash_tree() {
  python3 - "$@" <<'PY'
import hashlib
import os
import sys

for root in sys.argv[1:]:
    print("root", root)
    if not os.path.exists(root):
        print("missing")
        continue
    if os.path.islink(root):
        print("link", os.readlink(root))
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            if os.path.islink(path):
                print("link", rel, "->", os.readlink(path))
                continue
            mode = oct(os.stat(path).st_mode & 0o777)
            with open(path, "rb") as handle:
                digest = hashlib.sha256(handle.read()).hexdigest()
            print(digest, mode, rel)
PY
}

@test "setup preview darwin: requires only bash git python3 and mise and never offers bwrap" {
  cd "$TEST_TMPDIR/work" || exit 1

  local bin="$DARWIN_BIN:$NO_INSTALL_BIN"
  local roots=("$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" \
    "$MISE_CONFIG_DIR" "$MISE_DATA_DIR" "$MISE_STATE_DIR" "$MISE_CACHE_DIR" "$TEST_TMPDIR/work")

  # No /etc/os-release equivalent exists on macOS: the identity must come from
  # sw_vers and a missing os-release file must not be a requirement.
  export AP_OS_RELEASE="$TEST_TMPDIR/absent-os-release"
  local before
  before="$(hash_tree "${roots[@]}")"

  run env PATH="$bin" AP_TEST_PLATFORM_OS=Darwin bash "$AP_HELPER" setup --preview
  assert_success
  assert_output_contains "macOS 15.1.1"
  assert_output_contains "darwin family"
  assert_output_contains "Package manager: none"
  assert_output_contains "only bash, git, python3 and mise are required"
  assert_output_contains "[OK] mise:"
  assert_output_contains "No changes made"
  assert_output_not_contains "bwrap"
  assert_output_not_contains "bubblewrap"
  assert_output_not_contains "brew"

  # A Linux os-release fixture must not change the Darwin identity, so no Linux
  # distribution or package-manager path is guessed on macOS.
  write_os_release arch arch "Arch Linux"
  run env PATH="$bin" AP_TEST_PLATFORM_OS=Darwin bash "$AP_HELPER" setup --preview
  assert_success
  assert_output_contains "darwin family"
  assert_output_not_contains "arch family"
  assert_output_not_contains "Arch Linux"
  assert_output_not_contains "pacman"
  assert_output_not_contains "bwrap"

  local after
  after="$(hash_tree "${roots[@]}")"
  assert_equal "$after" "$before"
  [[ ! -s "$AP_SPY_LOG" ]]
  [[ ! -e "$MISE_CONFIG_DIR/tasks/agent-profiles" ]]
}

@test "setup apply darwin: managed config and optional agents stay untouched without bwrap installation" {
  cd "$TEST_TMPDIR/work" || exit 1

  # Record every mise call; only read-only queries pass through to the real
  # binary, so an unrequested `mise use` install is observed rather than run.
  local mise_bin="$TEST_TMPDIR/mise-bin"
  mkdir -p "$mise_bin"
  local real_mise
  real_mise="$(command -v mise)"
  cat >"$mise_bin/mise" <<MISE_WRAPPER
#!/usr/bin/env bash
printf 'mise %s\n' "\$*" >>"\$AP_SPY_LOG"
case "\${1:-}" in
  use | install) exit 0 ;;
esac
exec "$real_mise" "\$@"
MISE_WRAPPER
  chmod +x "$mise_bin/mise"

  local bin="$DARWIN_BIN:$mise_bin:$NO_INSTALL_BIN"

  # A managed (dotfiles) global mise config: the target must stay untouched and
  # the prepared source change must carry the ap-aliased task.
  mkdir -p "$TEST_TMPDIR/dotfiles/mise"
  printf '[tools]\nnode = "lts"\n' >"$TEST_TMPDIR/dotfiles/mise/config.toml"
  rmdir "$MISE_CONFIG_DIR"
  ln -s "$TEST_TMPDIR/dotfiles/mise" "$MISE_CONFIG_DIR"
  local managed_before
  managed_before="$(hash_tree "$TEST_TMPDIR/dotfiles")"

  run env PATH="$bin" AP_TEST_PLATFORM_OS=Darwin bash "$AP_HELPER" setup --apply \
    --prepare-dir "$TEST_TMPDIR/prepared"
  assert_success
  assert_output_contains "darwin family"
  assert_output_contains "managed configuration detected"
  assert_output_contains "prepared: $TEST_TMPDIR/prepared/tasks/agent-profiles"
  assert_output_not_contains "bwrap"
  assert_output_not_contains "brew"

  [[ -L "$MISE_CONFIG_DIR" ]]
  assert_equal "$managed_before" "$(hash_tree "$TEST_TMPDIR/dotfiles")"
  assert_file_exists "$TEST_TMPDIR/prepared/tasks/agent-profiles"
  grep -Fqx '#MISE alias="ap"' "$TEST_TMPDIR/prepared/tasks/agent-profiles"
  [[ ! -e "$MISE_CONFIG_DIR/tasks/agent-profiles" ]]

  # An unmanaged target keeps the existing conflict and backup behaviour: a
  # foreign task is preserved byte-identically and the retired managed task is
  # backed up before removal.
  rm -f "$MISE_CONFIG_DIR"
  mkdir -p "$MISE_CONFIG_DIR/tasks"
  printf '#!/usr/bin/env bash\necho foreign\n' >"$MISE_CONFIG_DIR/tasks/agent-profiles"
  printf '#!/usr/bin/env bash\n# managed-by: flyingnobita-agent-profiles 0.1.0 sha256:%064d\n' 0 \
    >"$MISE_CONFIG_DIR/tasks/agent-profiles-init"

  run env PATH="$bin" AP_TEST_PLATFORM_OS=Darwin bash "$AP_HELPER" setup --apply --tasks-only
  assert_success
  assert_output_contains "conflict: foreign task file"
  assert_output_contains "removed retired task"
  assert_output_not_contains "bwrap"
  grep -Fq 'echo foreign' "$MISE_CONFIG_DIR/tasks/agent-profiles"
  [[ ! -e "$MISE_CONFIG_DIR/tasks/agent-profiles-init" ]]
  [[ -n "$(find "$XDG_STATE_HOME/flyingnobita-agent-profiles/backups" -type f \
    -name agent-profiles-init 2>/dev/null)" ]]

  # No package manager, installer or unrequested agent install ran on Darwin.
  run ! grep -Eq '^(brew|pacman|apt-get|apt|sudo|curl|dnf|zypper|apk)\b' "$AP_SPY_LOG"
  run ! grep -Eq '^mise (use|install)\b' "$AP_SPY_LOG"
  run ! grep -Fq 'bubblewrap' "$MISE_CONFIG_DIR/tasks/agent-profiles"
}
