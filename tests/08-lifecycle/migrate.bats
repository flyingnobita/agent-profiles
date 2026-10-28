#!/usr/bin/env bats

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

@test "migrate: preview displays detected legacy layouts and backup path without mutating" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"
  echo "legacy home file" >"$fixture_repo/.agent-sandbox/home/test.txt"

  local hash_before
  hash_before=$(find "$fixture_repo/.agent-sandbox" -type f -exec sha256sum {} + | sort | sha256sum)

  run bash "$AP_HELPER" migrate
  assert_success
  assert_output_contains "Migration preview:"
  assert_output_contains "Backup destination:"
  assert_output_contains "Pass --yes to proceed"

  local hash_after
  hash_after=$(find "$fixture_repo/.agent-sandbox" -type f -exec sha256sum {} + | sort | sha256sum)
  assert_equal "$hash_before" "$hash_after"
}

@test "migrate: refuses ambiguous layouts with name clashes or multiple unnamed variants" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  # Case 1: Both unnamed layouts present
  mkdir -p "$fixture_repo/.agent-sandbox/home"
  mkdir -p "$fixture_repo/.agent-profiles/home"
  run bash "$AP_HELPER" migrate
  assert_failure 77
  assert_output_contains "ambiguous"

  # Clean up fixture
  rm -rf "$fixture_repo/.agent-profiles/home"

  # Case 2: Name collision between .agent-sandbox/worker1 and .agent-profiles/worker1
  mkdir -p "$fixture_repo/.agent-sandbox/worker1/home"
  mkdir -p "$fixture_repo/.agent-profiles/worker1/home"
  run bash "$AP_HELPER" migrate
  assert_failure 77
  assert_output_contains "name collision"

  # Case 3: Symlinked legacy root
  rm -rf "$fixture_repo/.agent-sandbox"
  mkdir -p "$TEST_TMPDIR/outside_sandbox"
  ln -s "$TEST_TMPDIR/outside_sandbox" "$fixture_repo/.agent-sandbox"
  run bash "$AP_HELPER" migrate
  assert_failure 73
  assert_output_contains "symbolic link"
}

@test "migrate: rejects backup root inside git checkout or group-writable parent" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"

  # Reject backup root inside git checkout
  run bash "$AP_HELPER" migrate --backup-root "$fixture_repo/my_backup"
  assert_failure 73
  assert_output_contains "backup path cannot be inside the git checkout"

  # Reject group/world-writable backup root
  local bad_backup_root="$TEST_TMPDIR/insecure_backups"
  mkdir -m 0777 -p "$bad_backup_root"
  run bash "$AP_HELPER" migrate --backup-root "$bad_backup_root"
  assert_failure 73
  assert_output_contains "insecure permissions"
}

@test "migrate: migrates unnamed legacy layout into private backup and initializes clean default profile" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"
  mkdir -p "$fixture_repo/.agent-sandbox/.config"
  echo "legacy config" >"$fixture_repo/.agent-sandbox/.config/settings.json"
  echo "legacy home" >"$fixture_repo/.agent-sandbox/home/file.txt"

  local backup_root="$TEST_TMPDIR/safe_backups"
  mkdir -m 0700 -p "$backup_root"

  run bash "$AP_HELPER" migrate --yes --backup-root "$backup_root"
  assert_success
  assert_output_contains "Migration completed successfully"
  assert_output_contains "reinstalling tools"

  # Legacy .agent-sandbox should be moved
  [[ ! -d "$fixture_repo/.agent-sandbox" ]]

  # Fresh default profile should exist and be initialized
  assert_dir_exists "$fixture_repo/.agent-profiles/default/home"
  assert_dir_exists "$fixture_repo/.agent-profiles/default/.config"
  assert_file_exists "$fixture_repo/.agent-profiles/default/.agent-profile"
  # Default profile starts clean
  [[ ! -f "$fixture_repo/.agent-profiles/default/.config/settings.json" ]]

  # Backup dir must exist under backup_root and contain manifest.json (mode 0600)
  local run_backup
  run_backup=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ -n "$run_backup" ]]
  assert_file_exists "$run_backup/manifest.json"

  # Check permissions of backup directory (0700) and manifest (0600)
  local backup_mode
  backup_mode=$(stat -c "%a" "$run_backup")
  assert_equal "$backup_mode" "700"
  local manifest_mode
  manifest_mode=$(stat -c "%a" "$run_backup/manifest.json")
  assert_equal "$manifest_mode" "600"
}

@test "migrate: mixed layout preserves already working named profiles" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  # Working named profile in .agent-profiles
  run bash "$AP_HELPER" init --profile workingprof
  assert_success
  echo "pre-existing data" >"$fixture_repo/.agent-profiles/workingprof/home/important.txt"

  local working_hash_before
  working_hash_before=$(find "$fixture_repo/.agent-profiles/workingprof" -type f -exec sha256sum {} + | sort | sha256sum)

  # Legacy named profile in .agent-sandbox
  mkdir -p "$fixture_repo/.agent-sandbox/oldworker/home"
  echo "old data" >"$fixture_repo/.agent-sandbox/oldworker/home/old.txt"

  run bash "$AP_HELPER" migrate --yes
  assert_success

  # Working profile must remain 100% byte-for-byte identical
  local working_hash_after
  working_hash_after=$(find "$fixture_repo/.agent-profiles/workingprof" -type f -exec sha256sum {} + | sort | sha256sum)
  assert_equal "$working_hash_before" "$working_hash_after"

  # Legacy oldworker profile must be reinitialized empty under .agent-profiles/oldworker
  assert_dir_exists "$fixture_repo/.agent-profiles/oldworker/home"
  [[ ! -f "$fixture_repo/.agent-profiles/oldworker/home/old.txt" ]]
}

@test "migrate: cross-device copy verifies SHA-256 digests before removing originals" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"
  echo "content to hash" >"$fixture_repo/.agent-sandbox/home/file.txt"

  # Force copy verification path via AP_FORCE_COPY=1
  run env AP_FORCE_COPY=1 bash "$AP_HELPER" migrate --yes
  assert_success
  assert_output_contains "verified"
  assert_output_contains "Migration completed successfully"

  # Originals must be removed after successful verification
  [[ ! -d "$fixture_repo/.agent-sandbox" ]]
  assert_dir_exists "$fixture_repo/.agent-profiles/default/home"
}

@test "migrate: cross-device mismatch aborts and preserves original legacy data intact" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"
  echo "original data" >"$fixture_repo/.agent-sandbox/home/file.txt"

  local hash_before
  hash_before=$(find "$fixture_repo/.agent-sandbox" -type f -exec sha256sum {} + | sort | sha256sum)

  # Simulate digest mismatch using AP_CORRUPT_STAGED=1
  run env AP_FORCE_COPY=1 AP_CORRUPT_STAGED=1 bash "$AP_HELPER" migrate --yes
  assert_failure 77
  assert_output_contains "checksum mismatch"

  # Original legacy data must remain completely intact
  assert_dir_exists "$fixture_repo/.agent-sandbox/home"
  local hash_after
  hash_after=$(find "$fixture_repo/.agent-sandbox" -type f -exec sha256sum {} + | sort | sha256sum)
  assert_equal "$hash_before" "$hash_after"
}

@test "migrate: migrates unnamed data under .agent-profiles and preserves named profiles" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile workingprof
  assert_success
  echo "pre-existing data" >"$fixture_repo/.agent-profiles/workingprof/home/important.txt"
  local working_hash_before
  working_hash_before=$(find "$fixture_repo/.agent-profiles/workingprof" -type f -exec sha256sum {} + | sort | sha256sum)

  # Unnamed default-profile data directly under the new storage directory.
  mkdir -p "$fixture_repo/.agent-profiles/home"
  mkdir -p "$fixture_repo/.agent-profiles/.codex"
  echo "unnamed home" >"$fixture_repo/.agent-profiles/home/unnamed.txt"
  echo "unnamed codex" >"$fixture_repo/.agent-profiles/.codex/auth.json"

  local backup_root="$TEST_TMPDIR/safe_backups"
  mkdir -m 0700 -p "$backup_root"

  run bash "$AP_HELPER" migrate --yes --backup-root "$backup_root"
  assert_success
  assert_output_contains "Migration completed successfully"

  # Unnamed data moved to the backup, default rebuilt empty, named profile intact.
  [[ ! -d "$fixture_repo/.agent-profiles/home" ]]
  [[ ! -d "$fixture_repo/.agent-profiles/.codex" ]]
  assert_dir_exists "$fixture_repo/.agent-profiles/default/home"
  [[ ! -f "$fixture_repo/.agent-profiles/default/home/unnamed.txt" ]]

  local working_hash_after
  working_hash_after=$(find "$fixture_repo/.agent-profiles/workingprof" -type f -exec sha256sum {} + | sort | sha256sum)
  assert_equal "$working_hash_before" "$working_hash_after"

  local run_backup
  run_backup=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  assert_file_exists "$run_backup/legacy/unnamed-profiles/home/unnamed.txt"
  assert_file_exists "$run_backup/legacy/unnamed-profiles/.codex/auth.json"
  assert_file_exists "$run_backup/manifest.json"
}

@test "migrate: unnamed legacy entries do not capture valid named profiles with agent directory names" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  # Named profiles whose names match legacy agent directory names.
  run bash "$AP_HELPER" init --profile bin
  assert_success
  run bash "$AP_HELPER" init --profile home
  assert_success
  echo "bin data" >"$fixture_repo/.agent-profiles/bin/home/keep.txt"
  echo "home data" >"$fixture_repo/.agent-profiles/home/home/keep.txt"

  # Genuine unnamed legacy data next to them.
  mkdir -p "$fixture_repo/.agent-profiles/.claude/projects/p1"
  printf '{"legacy":true}\n' >"$fixture_repo/.agent-profiles/.claude/projects/p1/session.jsonl"

  local bin_hash home_hash
  bin_hash=$(find "$fixture_repo/.agent-profiles/bin" -type f -exec sha256sum {} + | sort | sha256sum)
  home_hash=$(find "$fixture_repo/.agent-profiles/home" -type f -exec sha256sum {} + | sort | sha256sum)

  run bash "$AP_HELPER" migrate --yes
  assert_success

  local bin_hash_after home_hash_after
  bin_hash_after=$(find "$fixture_repo/.agent-profiles/bin" -type f -exec sha256sum {} + | sort | sha256sum)
  home_hash_after=$(find "$fixture_repo/.agent-profiles/home" -type f -exec sha256sum {} + | sort | sha256sum)
  assert_equal "$bin_hash" "$bin_hash_after"
  assert_equal "$home_hash" "$home_hash_after"

  # The unnamed legacy data became the default profile, and the backups keep it.
  assert_dir_exists "$fixture_repo/.agent-profiles/default/home"
  [[ ! -e "$fixture_repo/.agent-profiles/.claude" ]]
  grep -q "legacy" "$(find "${XDG_STATE_HOME:-$HOME/.local/state}/flyingnobita-agent-profiles/backups" -path '*legacy*' -name 'session.jsonl' | head -1)"

  # No legacy notice remains and new profiles can be created.
  run bash "$AP_HELPER" init --profile later
  assert_success
}
