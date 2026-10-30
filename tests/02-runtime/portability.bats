#!/usr/bin/env bats
# Portability kernel: the helper is exercised through its public CLI with the
# GNU-only tools a stock macOS host does not ship masked out of PATH. A masked
# command reproduces the BSD/macOS behaviour: it rejects the GNU-only flag (or
# is absent altogether) instead of returning a useful answer.
# shellcheck disable=SC2030,SC2031

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  AP_HOST_PATH="$PATH"
}

teardown() {
  teardown_isolation
}

# mask_command <dir> <name>: the command is not available at all, so a test can
# prove the helper no longer depends on it.
mask_command() {
  local dir="$1"
  local name="$2"
  mkdir -p "$dir"
  cat >"$dir/$name" <<SHIM
#!/usr/bin/env bash
printf 'portability: %s is masked in this test\n' "$name" >&2
exit 127
SHIM
  chmod +x "$dir/$name"
}

# reject_gnu_options <dir> <name>: the command exists but rejects an option
# argument, which is how BSD/macOS userland answers a GNU-only flag.
reject_gnu_options() {
  local dir="$1"
  local name="$2"
  mkdir -p "$dir"
  cat >"$dir/$name" <<SHIM
#!/usr/bin/env bash
case "\${1:-}" in
  -*) printf '${name}: illegal option -- %s\\n' "\${1#-}" >&2; exit 1 ;;
esac
exec /usr/bin/${name} "\$@"
SHIM
  chmod +x "$dir/$name"
}

@test "portability: helper resolves its installed path without GNU readlink" {
  local repo="$TEST_TMPDIR/repo-readlink"
  create_fixture_repo "$repo"

  # An installed skill lives in its own directory; the two supported
  # installation modes either link to the entrypoint or run it in place.
  local skill="$TEST_TMPDIR/installed-skill"
  mkdir -p "$skill"
  cp -a "$AP_SKILL_DIR/." "$skill/"
  local linked="$TEST_TMPDIR/bin/agent-profiles"
  mkdir -p "$TEST_TMPDIR/bin"
  ln -s "$skill/scripts/agent-profiles" "$linked"

  local shim="$TEST_TMPDIR/bsd-bin"
  reject_gnu_options "$shim" readlink
  export PATH="$shim:$AP_HOST_PATH"

  cd "$repo"

  run bash "$linked" --version
  assert_success
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]

  # The skill must also be usable from its real path, not only through a link.
  run bash "$skill/scripts/agent-profiles" --version
  assert_success

  run bash "$linked" init --profile bounded
  assert_success
  assert_dir_exists "$repo/.agent-profiles/bounded/home"
  assert_file_exists "$repo/.agent-profiles/bounded/.agent-profile"

  run bash "$linked" list
  assert_success
  assert_output_contains "bounded"
}
