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

@test "migrate recovery: fault before verification keeps originals and recover discards untrusted staging" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"
  echo "legacy content" >"$fixture_repo/.agent-sandbox/home/file.txt"

  local backup_root="$TEST_TMPDIR/safe_backups"
  mkdir -m 0700 -p "$backup_root"

  local hash_before
  hash_before=$(find "$fixture_repo/.agent-sandbox" -type f -exec sha256sum {} + | sort | sha256sum)

  run env AP_FORCE_COPY=1 AP_FAULT_AFTER=staged bash "$AP_HELPER" migrate --yes --backup-root "$backup_root"
  assert_failure 137

  local journal_file="$fixture_repo/.agent-profiles/.journal/migrate-all.json"
  assert_file_exists "$journal_file"
  python3 -c '
import json, sys
with open(sys.argv[1], "r") as handle:
    data = json.load(handle)
assert data["op"] == "migrate"
assert data["state"] == "staged"
' "$journal_file"

  # Originals are untouched while the journal is below verified.
  local hash_after
  hash_after=$(find "$fixture_repo/.agent-sandbox" -type f -exec sha256sum {} + | sort | sha256sum)
  assert_equal "$hash_before" "$hash_after"

  # Mutating commands are blocked by the stale migrate journal.
  run bash "$AP_HELPER" init --profile otherprof
  assert_failure 77
  assert_output_contains "interrupted migrate"

  run bash "$AP_HELPER" recover --yes
  assert_success
  assert_output_contains "interrupted 'migrate'"

  # The untrusted staging copy is discarded and originals stay intact.
  hash_after=$(find "$fixture_repo/.agent-sandbox" -type f -exec sha256sum {} + | sort | sha256sum)
  assert_equal "$hash_before" "$hash_after"
  [[ ! -f "$journal_file" ]]
  [[ ! -d "$fixture_repo/.agent-profiles/default" ]]
  local run_backup
  run_backup=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ -n "$run_backup" ]]
  [[ ! -d "$run_backup/staged" ]]
}

@test "migrate recovery: recover rolls forward a verified cross-device migration" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"
  echo "legacy content" >"$fixture_repo/.agent-sandbox/home/file.txt"

  local backup_root="$TEST_TMPDIR/safe_backups"
  mkdir -m 0700 -p "$backup_root"

  run env AP_FORCE_COPY=1 AP_FAULT_AFTER=verified bash "$AP_HELPER" migrate --yes --backup-root "$backup_root"
  assert_failure 137

  local journal_file="$fixture_repo/.agent-profiles/.journal/migrate-all.json"
  assert_file_exists "$journal_file"
  python3 -c '
import json, sys
with open(sys.argv[1], "r") as handle:
    data = json.load(handle)
assert data["op"] == "migrate"
assert data["state"] == "verified"
' "$journal_file"

  # The verified copy is staged and the original is still in place.
  assert_dir_exists "$fixture_repo/.agent-sandbox"
  local run_backup
  run_backup=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  assert_dir_exists "$run_backup/staged/agent-sandbox"

  run bash "$AP_HELPER" recover --yes
  assert_success
  assert_output_contains "interrupted 'migrate'"

  # Roll forward completes the migration from the verified backup.
  [[ ! -d "$fixture_repo/.agent-sandbox" ]]
  assert_dir_exists "$fixture_repo/.agent-profiles/default/home"
  assert_file_exists "$run_backup/legacy/agent-sandbox/home/file.txt"
  assert_file_exists "$run_backup/manifest.json"
  [[ ! -f "$journal_file" ]]
}

@test "migrate recovery: refuses a journal whose backup path is inside the checkout" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"
  echo "legacy content" >"$fixture_repo/.agent-sandbox/home/file.txt"
  mkdir -p "$fixture_repo/.agent-profiles/default/home"
  echo "keep me" >"$fixture_repo/.agent-profiles/default/home/keep.txt"

  local fake_backup="$fixture_repo/fake-backup"
  mkdir -m 0700 -p "$fake_backup/staged/agent-sandbox"
  echo "staged marker" >"$fake_backup/staged/agent-sandbox/marker.txt"

  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  cat <<EOF >"$fixture_repo/.agent-profiles/.journal/migrate-all.json"
{
  "op": "migrate",
  "profile": "all",
  "state": "verified",
  "profile_dir": "$fixture_repo",
  "trash_path": "",
  "assume_unrelated": [],
  "boot_id": "00000000-0000-0000-0000-000000000000",
  "backup_dir": "$fake_backup",
  "staged_dir": "$fake_backup/staged",
  "legacy_dir": "$fake_backup/legacy",
  "migrated_profiles": ["default"],
  "sources": [
    {"path": "$fixture_repo/.agent-sandbox", "label": "agent-sandbox", "mode": "copy"}
  ]
}
EOF

  run bash "$AP_HELPER" recover --yes
  assert_failure 73
  assert_output_contains "inside the git checkout"

  # Nothing was moved or deleted.
  assert_file_exists "$fixture_repo/.agent-sandbox/home/file.txt"
  assert_file_exists "$fixture_repo/.agent-profiles/default/home/keep.txt"
  assert_file_exists "$fake_backup/staged/agent-sandbox/marker.txt"
}

@test "recovery: refuses a journal profile path outside the selected profile" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-profiles/someprof/home"
  echo "keep me" >"$fixture_repo/.agent-profiles/someprof/home/keep.txt"
  mkdir -p "$TEST_TMPDIR/outside-profile"
  echo "outside" >"$TEST_TMPDIR/outside-profile/important.txt"

  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  cat <<EOF >"$fixture_repo/.agent-profiles/.journal/reset-someprof.json"
{
  "op": "reset",
  "profile": "someprof",
  "state": "trashed",
  "profile_dir": "$TEST_TMPDIR/outside-profile",
  "trash_path": "",
  "assume_unrelated": [],
  "boot_id": "00000000-0000-0000-0000-000000000000"
}
EOF

  run bash "$AP_HELPER" recover --yes
  assert_failure 73
  assert_output_contains "unsafe journal profile path"

  assert_file_exists "$TEST_TMPDIR/outside-profile/important.txt"
  assert_file_exists "$fixture_repo/.agent-profiles/someprof/home/keep.txt"
  assert_file_exists "$fixture_repo/.agent-profiles/.journal/reset-someprof.json"
}

@test "migrate recovery: refuses a corrupted verified backup and preserves the original and journal" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"
  echo "correct original" >"$fixture_repo/.agent-sandbox/home/file.txt"

  local backup_root="$TEST_TMPDIR/safe_backups"
  mkdir -m 0700 -p "$backup_root"

  run env AP_FORCE_COPY=1 AP_FAULT_AFTER=verified bash "$AP_HELPER" migrate --yes --backup-root "$backup_root"
  assert_failure 137

  local journal_file="$fixture_repo/.agent-profiles/.journal/migrate-all.json"
  assert_file_exists "$journal_file"
  local run_backup
  run_backup=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  echo "corrupted after verification" >"$run_backup/staged/agent-sandbox/home/file.txt"
  assert_file_exists "$run_backup/content-manifest.json"

  run bash "$AP_HELPER" recover --yes
  assert_failure 77
  assert_output_contains "corrupt"
  assert_output_contains "preserved"

  # The original is untouched, the journal is kept, and the bad copy is retained.
  run cat "$fixture_repo/.agent-sandbox/home/file.txt"
  assert_output_contains "correct original"
  assert_file_exists "$journal_file"
  run cat "$run_backup/staged/agent-sandbox/home/file.txt"
  assert_output_contains "corrupted after verification"
  [[ ! -d "$fixture_repo/.agent-profiles/default" ]]
}

@test "migrate recovery: refuses an original changed after verification and preserves both trees" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"
  echo "correct original" >"$fixture_repo/.agent-sandbox/home/file.txt"

  local backup_root="$TEST_TMPDIR/safe_backups"
  mkdir -m 0700 -p "$backup_root"

  run env AP_FORCE_COPY=1 AP_FAULT_AFTER=verified bash "$AP_HELPER" migrate --yes --backup-root "$backup_root"
  assert_failure 137

  local journal_file="$fixture_repo/.agent-profiles/.journal/migrate-all.json"
  local run_backup
  run_backup=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  echo "changed after verification" >"$fixture_repo/.agent-sandbox/home/file.txt"

  run bash "$AP_HELPER" recover --yes
  assert_failure 77
  assert_output_contains "changed since verification"
  assert_output_contains "preserved"

  run cat "$fixture_repo/.agent-sandbox/home/file.txt"
  assert_output_contains "changed after verification"
  run cat "$run_backup/staged/agent-sandbox/home/file.txt"
  assert_output_contains "correct original"
  assert_file_exists "$journal_file"
  [[ ! -d "$fixture_repo/.agent-profiles/default" ]]
}

@test "migrate recovery: refuses missing staged backup content instead of re-copying" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"
  echo "correct original" >"$fixture_repo/.agent-sandbox/home/file.txt"

  local backup_root="$TEST_TMPDIR/safe_backups"
  mkdir -m 0700 -p "$backup_root"

  run env AP_FORCE_COPY=1 AP_FAULT_AFTER=verified bash "$AP_HELPER" migrate --yes --backup-root "$backup_root"
  assert_failure 137

  local journal_file="$fixture_repo/.agent-profiles/.journal/migrate-all.json"
  local run_backup
  run_backup=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  rm -rf "$run_backup/staged/agent-sandbox"

  run bash "$AP_HELPER" recover --yes
  assert_failure 77
  assert_output_contains "missing or partial"
  assert_output_contains "preserved"

  run cat "$fixture_repo/.agent-sandbox/home/file.txt"
  assert_output_contains "correct original"
  assert_file_exists "$journal_file"
  [[ ! -d "$fixture_repo/.agent-profiles/default" ]]
}

@test "migrate recovery: refuses a corrupted existing legacy destination" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"
  echo "correct original" >"$fixture_repo/.agent-sandbox/home/file.txt"

  local backup_root="$TEST_TMPDIR/safe_backups"
  mkdir -m 0700 -p "$backup_root"

  # Cross-device flow removes the originals before writing this checkpoint.
  run env AP_FORCE_COPY=1 AP_FAULT_AFTER=originals-removed bash "$AP_HELPER" migrate --yes --backup-root "$backup_root"
  assert_failure 137

  local journal_file="$fixture_repo/.agent-profiles/.journal/migrate-all.json"
  local run_backup
  run_backup=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  assert_file_exists "$run_backup/content-manifest.json"
  echo "corrupted destination" >"$run_backup/legacy/agent-sandbox/home/file.txt"

  run bash "$AP_HELPER" recover --yes
  assert_failure 77
  assert_output_contains "corrupt"
  assert_output_contains "preserved"

  assert_file_exists "$journal_file"
  [[ ! -d "$fixture_repo/.agent-profiles/default" ]]
  run cat "$run_backup/legacy/agent-sandbox/home/file.txt"
  assert_output_contains "corrupted destination"
}
