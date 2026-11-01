#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup_file() {
  load 'lib.bash'

  # A PATH holding every host command except bubblewrap, so a Darwin execution
  # adapter is proven not to need it and the Linux refusal is proven with it
  # genuinely absent rather than masked by a failing stub.
  NO_BWRAP_BIN="$BATS_FILE_TMPDIR/no-bwrap-bin"
  make_restricted_bin "$NO_BWRAP_BIN" bwrap
  export NO_BWRAP_BIN
}

# write_uname_stub <dir> <system>: a uname that reports <system> for -s and
# delegates every other flag. The suite pins the platform probe to Linux for
# its os-release fixtures; the kernel is what really decides whether a profile
# can execute, so a test scopes the two together with this stub.
write_uname_stub() {
  local dir="$1" system="$2" real_uname
  real_uname=$(command -v uname)
  mkdir -p "$dir"
  cat >"$dir/uname" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  -s) printf '%s\n' "$system" ;;
  *) exec "$real_uname" "\$@" ;;
esac
STUB
  chmod +x "$dir/uname"
}

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  load 'lib.bash'
  setup_isolation
  setup_mise_env
  write_os_release arch arch "Arch Linux"
  mkdir -p "$TEST_TMPDIR/work"
  cd "$TEST_TMPDIR/work" || exit 1
}

teardown() {
  teardown_isolation
}

@test "setup apply: deploys a versioned release with a sha256 manifest" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local release
  release=$(sed -n 's/^# release: //p' "$MISE_CONFIG_DIR/tasks/agent-profiles")
  assert_dir_exists "$release"
  [[ "$release" == "$XDG_DATA_HOME/flyingnobita-agent-profiles/releases/"* ]]
  [[ "$(basename "$release")" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{8}$ ]]
  assert_file_exists "$release/scripts/agent-profiles"
  assert_file_exists "$release/VERSION"
  assert_file_exists "$release/manifest.sha256"
  ap_test_manifest_verify "$release" "$release/manifest.sha256"
}

@test "setup apply: installs exactly one executable global file task using the released helper" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local task="$MISE_CONFIG_DIR/tasks/agent-profiles" release
  assert_file_exists "$task"
  [[ -x "$task" ]]
  [[ "$(find "$MISE_CONFIG_DIR/tasks" -type f | wc -l)" -eq 1 ]]
  grep -Fq '#MISE dir="{{cwd}}"' "$task"
  grep -Eq '^# managed-by: flyingnobita-agent-profiles [0-9]+\.[0-9]+\.[0-9]+ sha256:[0-9a-f]{64}$' "$task"
  release=$(sed -n 's/^# release: //p' "$task")
  grep -Fq "$release/scripts/agent-profiles" "$task"
}

@test "setup apply: mise ap new creates a profile through mise" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run mise ap new demo
  assert_success
  assert_dir_exists "$repo/.agent-profiles/demo/home"
}

@test "setup apply: agent-profiles task forwards arguments through mise to the helper" {
  run bash "$AP_HELPER" setup --apply
  assert_success

  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run mise ap new demo
  assert_success

  run mise run agent-profiles -- --profile demo printf '%s\n' 'a b'
  assert_success
  assert_output_contains "a b"

  # shellcheck disable=SC2016
  run mise run agent-profiles -- --profile demo sh -c 'printf "%s\n" "$AGENT_PROFILES_NAME"'
  assert_success
  assert_output_contains "demo"
}

@test "setup apply: a copied installed skill deploys durable tasks that survive its removal" {
  local installed="$TEST_TMPDIR/installed/skills/flyingnobita-agent-profiles"
  mkdir -p "$(dirname "$installed")"
  cp -a "$AP_SKILL_DIR" "$installed"

  run bash "$installed/scripts/agent-profiles" setup --apply
  assert_success

  local release
  release=$(sed -n 's/^# release: //p' "$MISE_CONFIG_DIR/tasks/agent-profiles")
  [[ "$release" == "$XDG_DATA_HOME/flyingnobita-agent-profiles/releases/"* ]]
  [[ "$release" != "$installed"* ]]

  rm -rf "$TEST_TMPDIR/installed"

  local repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run mise ap new demo
  assert_success
  assert_dir_exists "$repo/.agent-profiles/demo/home"
}

@test "setup apply: a deployed task runs on a Darwin host with no bubblewrap" {
  # macOS has no bubblewrap anywhere and this suite pins the platform probe to
  # Linux for its os-release fixtures. Both are true in the same process, so the
  # kernel has to win: a Darwin host never takes the Linux execution path, and a
  # deployed task that expects to execute must not consult bubblewrap readiness.
  local platform="$TEST_TMPDIR/platform-bin"
  write_uname_stub "$platform" Darwin
  export PATH="$platform:$NO_BWRAP_BIN"

  run bash "$AP_HELPER" setup --apply
  assert_success

  local repo="$TEST_TMPDIR/darwin-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run mise ap new demo
  assert_success
  assert_dir_exists "$repo/.agent-profiles/demo/home"

  # shellcheck disable=SC2016
  run mise run agent-profiles -- --profile demo sh -c 'printf "name=%s\n" "$AGENT_PROFILES_NAME"'
  assert_success
  assert_output_contains "name=demo"

  # The Darwin adapter, not only a skipped readiness gate: the run redirects
  # HOME into profile storage instead of mounting it, so nothing is required
  # from the host but environment redirection.
  # shellcheck disable=SC2016
  run mise run agent-profiles -- --profile demo sh -c 'printf "home=%s\n" "$HOME"'
  assert_success
  assert_output_contains "home=$repo/.agent-profiles/demo"
}

@test "setup apply: the same deployed task still refuses on Linux without bubblewrap" {
  # The Linux refusal is untouched: without bubblewrap no profile run happens,
  # and the hint names the package. The stub reports Linux on both gates, so
  # this assertion holds on a macOS test host as well.
  local platform="$TEST_TMPDIR/platform-bin"
  write_uname_stub "$platform" Linux
  export PATH="$platform:$NO_BWRAP_BIN"

  run bash "$AP_HELPER" setup --apply
  assert_success

  local repo="$TEST_TMPDIR/linux-repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run mise ap new demo
  assert_success

  run mise run agent-profiles -- --profile demo true
  assert_failure 69
  assert_output_contains "bubblewrap (bwrap) is required but not found on PATH"
  assert_output_contains "Install bubblewrap via your system package manager."
}
