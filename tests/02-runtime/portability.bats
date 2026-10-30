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

@test "portability: profile init and sorted list work without mapfile or GNU stat" {
  local repo="$TEST_TMPDIR/repo-stat"
  create_fixture_repo "$repo"
  cd "$repo"

  # BSD/macOS stat has no -c format option, so every GNU format string must go.
  local shim="$TEST_TMPDIR/bsd-bin"
  reject_gnu_options "$shim" stat
  export PATH="$shim:$AP_HOST_PATH"

  run bash "$AP_HELPER" init --profile zulu
  assert_success
  run bash "$AP_HELPER" init --profile alpha
  assert_success
  run bash "$AP_HELPER" init --profile mike
  assert_success

  run bash "$AP_HELPER" list
  assert_success
  assert_output_equals "$(printf '%s\n' alpha mike zulu)"

  # Profile identity is still enforced. A second path that resolves to an
  # existing profile is an inode alias: it must be refused, never skipped
  # because an empty stat result looked like "no alias found".
  ln -s "$repo/.agent-profiles/zulu" "$repo/.agent-profiles/alias-zulu"

  run bash "$AP_HELPER" init --profile zulu
  assert_failure 73
  assert_output_contains "aliases existing profile"
}

@test "portability: canonical path checks resolve existing and missing symlink ancestors" {
  local shim="$TEST_TMPDIR/bsd-bin"
  reject_gnu_options "$shim" realpath
  export PATH="$shim:$AP_HOST_PATH"

  # Storage and the not-yet-created host mount targets are canonicalized before
  # the profile runs.
  local repo_run="$TEST_TMPDIR/repo-realpath-run"
  create_fixture_repo "$repo_run"
  cd "$repo_run"
  run bash "$AP_HELPER" init --profile default
  assert_success
  run bash "$AP_HELPER" run -- true
  assert_success

  # A backup root whose tail does not exist yet is resolved through its real
  # ancestors and created outside the checkout.
  local repo_migrate="$TEST_TMPDIR/repo-realpath-migrate"
  create_fixture_repo "$repo_migrate"
  cd "$repo_migrate"
  mkdir -p "$repo_migrate/.agent-sandbox/home"
  printf 'legacy\n' >"$repo_migrate/.agent-sandbox/home/legacy.txt"

  local backups="$TEST_TMPDIR/backups/nested/deep"
  run bash "$AP_HELPER" migrate --yes --backup-root "$backups"
  assert_success
  assert_output_contains "Migration completed successfully"

  local run_dir
  run_dir=$(find "$backups" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ -n "$run_dir" ]]
  assert_file_exists "$run_dir/legacy/agent-sandbox/home/legacy.txt"

  # An existing symlink ancestor that resolves inside the checkout must be
  # refused even though the backup path itself does not exist.
  local repo_link="$TEST_TMPDIR/repo-realpath-link"
  create_fixture_repo "$repo_link"
  cd "$repo_link"
  mkdir -p "$repo_link/.agent-sandbox/home"
  printf 'legacy\n' >"$repo_link/.agent-sandbox/home/legacy.txt"
  ln -s "$repo_link" "$TEST_TMPDIR/repo-link"

  run bash "$AP_HELPER" migrate --backup-root "$TEST_TMPDIR/repo-link/backups"
  assert_failure 73
  assert_output_contains "inside the git checkout"
}

@test "portability: shared and exclusive locks retain contention and descendant leases without flock or dynamic descriptors" {
  local repo="$TEST_TMPDIR/repo-locks"
  create_fixture_repo "$repo"
  cd "$repo"

  local shim="$TEST_TMPDIR/no-flock-bin"
  mask_command "$shim" flock
  export PATH="$shim:$AP_HOST_PATH"

  run bash "$AP_HELPER" init --profile default
  assert_success

  local lock_file="$repo/.agent-profiles/.locks/default.lock"
  assert_file_exists "$lock_file"
  local lock_inode_before
  lock_inode_before=$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$lock_file")

  # Two shared leases are compatible: a run starts while the first is running.
  bash "$AP_HELPER" run -- sleep 2 &
  local first=$!
  sleep 0.6
  run bash "$AP_HELPER" run -- true
  assert_success
  wait "$first"

  # An exclusive lifecycle lock is refused while a shared lease is held.
  bash "$AP_HELPER" run -- sleep 2 &
  local holder=$!
  sleep 0.6
  run bash "$AP_HELPER" reset --profile default --yes
  assert_failure 75
  assert_output_contains "in use"
  wait "$holder"

  # A background descendant keeps the inherited lease after the direct parent
  # exits, and the persistent lock inode is never replaced.
  local pid_file="$TEST_TMPDIR/lease-child.pid"
  bash "$AP_HELPER" run -- sh -c 'sleep 5 & echo $! >"$1"' sh "$pid_file"
  assert_file_exists "$pid_file"
  local child
  child=$(cat "$pid_file")
  [[ -n "$child" ]]

  local lock_inode_after
  lock_inode_after=$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$lock_file")
  assert_equal "$lock_inode_after" "$lock_inode_before"

  run bash "$AP_HELPER" reset --profile default --yes
  assert_failure 75
  assert_output_contains "in use"

  kill -9 "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  sleep 0.4

  run bash "$AP_HELPER" reset --profile default --yes
  assert_success
}
