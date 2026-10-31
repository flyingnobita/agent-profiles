#!/usr/bin/env bats
# Canonical path identity at the public seam.
#
# A checkout, a storage root or a journal path can legitimately be named through
# a symbolic link in an ancestor directory. macOS does this for every temporary
# directory (/var/folders is /private/var/folders), and a dotfiles checkout or a
# backup root reached through a link does it on Linux too. The product must
# compare canonical to canonical so such a path is not mistaken for a layout
# violation, while a storage root, profile root or lock file that is itself a
# symlink stays refused.
# shellcheck disable=SC2030,SC2031

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation
}

teardown() {
  teardown_isolation
}

@test "canonical paths: a checkout beneath a symlinked ancestor supports init list run reset and migrate" {
  local real="$TEST_TMPDIR/real"
  local real_backups="$TEST_TMPDIR/real-backups"
  mkdir -p "$real" "$real_backups"
  ln -s "$real" "$TEST_TMPDIR/link"
  ln -s "$real_backups" "$TEST_TMPDIR/link-backups"

  local repo="$real/repo"
  local logical="$TEST_TMPDIR/link/repo"
  create_fixture_repo "$repo"

  # Every command is driven through the symlinked ancestor, exactly as a user in
  # that directory would.
  cd "$logical"

  run bash "$AP_HELPER" init --profile linky
  assert_success
  assert_dir_exists "$repo/.agent-profiles/linky/home"
  assert_file_exists "$repo/.agent-profiles/linky/.agent-profile"

  run bash "$AP_HELPER" list
  assert_success
  assert_output_contains "linky"

  run bash "$AP_HELPER" run --profile linky -- sh -c 'printf "ran=%s\n" "$AGENT_PROFILES_NAME"'
  assert_success
  assert_output_contains "ran=linky"

  run bash "$AP_HELPER" reset --profile linky --yes
  assert_success
  assert_dir_exists "$repo/.agent-profiles/linky/home"

  # The legacy layout is migrated from the same symlinked ancestor, and the
  # backup root is only reachable through a link as well.
  mkdir -p "$repo/.agent-sandbox/home"
  printf 'legacy\n' >"$repo/.agent-sandbox/home/legacy.txt"

  run bash "$AP_HELPER" migrate --yes --backup-root "$TEST_TMPDIR/link-backups/run"
  assert_success
  assert_output_contains "Migration completed successfully"
  local backup
  backup=$(find "$real_backups" -mindepth 2 -maxdepth 2 -type d | head -n 1)
  [[ -n "$backup" ]]
  assert_file_exists "$backup/legacy/agent-sandbox/home/legacy.txt"
  [[ ! -e "$repo/.agent-sandbox" ]]
}

@test "canonical paths: recovery accepts a journal recorded through a symlinked ancestor" {
  local real="$TEST_TMPDIR/real"
  mkdir -p "$real"
  ln -s "$real" "$TEST_TMPDIR/link"

  local repo="$real/repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile faultprof
  assert_success

  local prof_dir="$repo/.agent-profiles/faultprof"
  local trash_dir="$repo/.agent-profiles/.trash/faultprof.12345"
  mkdir -p "$trash_dir/home"
  printf 'old data\n' >"$trash_dir/home/old.txt"
  rm -rf "$prof_dir"

  # The journal was recorded while the checkout was reached through the link, so
  # it names the profile and its trash through that ancestor. That is the same
  # directory tree; refusing it would refuse a correct journal.
  local logical_repo="$TEST_TMPDIR/link/repo"
  mkdir -p "$repo/.agent-profiles/.journal"
  cat >"$repo/.agent-profiles/.journal/reset-faultprof.json" <<EOF
{
  "op": "reset",
  "profile": "faultprof",
  "state": "trashed",
  "profile_dir": "$logical_repo/.agent-profiles/faultprof",
  "trash_path": "$logical_repo/.agent-profiles/.trash/faultprof.12345",
  "assume_unrelated": [],
  "boot_id": "00000000-0000-0000-0000-000000000000"
}
EOF

  run bash "$AP_HELPER" recover --yes
  assert_success
  assert_output_contains "recovered"

  # The interruption is finished: the trash entry is gone, the profile is
  # re-initialized and the journal is cleared.
  [[ ! -d "$trash_dir" ]]
  assert_dir_exists "$prof_dir/home"
  [[ ! -f "$repo/.agent-profiles/.journal/reset-faultprof.json" ]]

  run bash "$AP_HELPER" run --profile faultprof -- printf 'working\n'
  assert_success
  assert_output_contains "working"
}

@test "canonical paths: a journal that resolves outside the profile storage is still refused" {
  local real="$TEST_TMPDIR/real"
  mkdir -p "$real"
  ln -s "$real" "$TEST_TMPDIR/link"

  local repo="$real/repo"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile victim
  assert_success
  run bash "$AP_HELPER" init --profile decoy
  assert_success

  # A journal that points at another profile's directory keeps failing closed,
  # even when it is written through a symlinked ancestor.
  local logical_repo="$TEST_TMPDIR/link/repo"
  mkdir -p "$repo/.agent-profiles/.journal"
  cat >"$repo/.agent-profiles/.journal/reset-victim.json" <<EOF
{
  "op": "reset",
  "profile": "victim",
  "state": "trashed",
  "profile_dir": "$logical_repo/.agent-profiles/decoy",
  "trash_path": "",
  "assume_unrelated": [],
  "boot_id": "00000000-0000-0000-0000-000000000000"
}
EOF

  run bash "$AP_HELPER" recover --yes
  assert_failure 73
  assert_output_contains "unsafe journal profile path"

  # Both profiles are untouched.
  assert_dir_exists "$repo/.agent-profiles/victim/home"
  assert_dir_exists "$repo/.agent-profiles/decoy/home"
}

@test "canonical paths: a symlinked profile storage root is still refused with exit 73" {
  local repo="$TEST_TMPDIR/repo-storage-link"
  create_fixture_repo "$repo"
  cd "$repo"

  mkdir -p "$TEST_TMPDIR/elsewhere"
  ln -s "$TEST_TMPDIR/elsewhere" "$repo/.agent-profiles"

  # A symlinked storage root is never written through. `list` reports the layout
  # violation directly (exit 73); the write path refuses it as well, after its
  # legacy-layout preflight has run.
  run bash "$AP_HELPER" list
  assert_failure 73
  assert_output_contains "is a symbolic link"

  run bash "$AP_HELPER" init --profile default
  assert_failure
  assert_output_contains "agent-profiles: error"
  [[ -z "$(ls -A "$TEST_TMPDIR/elsewhere")" ]]
  [[ -L "$repo/.agent-profiles" ]]
}

@test "canonical paths: a symlinked profile root is still refused with exit 73" {
  local repo="$TEST_TMPDIR/repo-profile-link"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile linked
  assert_success

  local prof_dir="$repo/.agent-profiles/linked"
  mkdir -p "$TEST_TMPDIR/elsewhere"
  rm -rf "$prof_dir"
  ln -s "$TEST_TMPDIR/elsewhere" "$prof_dir"

  run bash "$AP_HELPER" init --profile linked
  assert_failure 73
  assert_output_contains "is a symbolic link"
  [[ -z "$(ls -A "$TEST_TMPDIR/elsewhere")" ]]
}
