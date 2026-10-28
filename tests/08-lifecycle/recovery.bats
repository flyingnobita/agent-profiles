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

@test "recovery: stale profile journal causes init and run on that profile to refuse with exit 77" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile targetprof
  run bash "$AP_HELPER" init --profile otherprof
  assert_success

  # Plant an unlocked (stale) journal file for targetprof
  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  cat <<'EOF' >"$fixture_repo/.agent-profiles/.journal/reset-targetprof.json"
{
  "op": "reset",
  "profile": "targetprof",
  "state": "trashed",
  "profile_dir": "/dummy/path",
  "trash_path": "/dummy/trash",
  "assume_unrelated": [],
  "boot_id": "00000000-0000-0000-0000-000000000000"
}
EOF

  # init on targetprof must exit 77
  run bash "$AP_HELPER" init --profile targetprof
  assert_failure 77
  assert_output_contains "interrupted reset"
  assert_output_contains "recover"

  # run on targetprof must exit 77
  run bash "$AP_HELPER" run --profile targetprof -- echo ok
  assert_failure 77
  assert_output_contains "interrupted reset"

  # commands on otherprof must succeed
  run bash "$AP_HELPER" run --profile otherprof -- echo other_ok
  assert_success
  assert_output_contains "other_ok"
}

@test "recovery: doctor and list report stale journal but do not fail" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile targetprof
  assert_success

  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  cat <<'EOF' >"$fixture_repo/.agent-profiles/.journal/reset-targetprof.json"
{
  "op": "reset",
  "profile": "targetprof",
  "state": "trashed",
  "profile_dir": "/dummy/path",
  "trash_path": "/dummy/trash",
  "assume_unrelated": [],
  "boot_id": "00000000-0000-0000-0000-000000000000"
}
EOF

  # list should succeed (exit 0) and report the stale journal warning
  run bash "$AP_HELPER" list
  assert_success
  assert_output_contains "targetprof"
  assert_output_contains "stale journal"

  # doctor should succeed (exit 0)
  run bash "$AP_HELPER" doctor --json
  assert_success
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert "checks" in data
# Verify a lifecycle check exists reporting the stale journal
stale_found = any("stale journal" in str(c).lower() or c.get("id") == "lifecycle" for c in data["checks"])
assert stale_found
' "$output"
}

@test "recovery: recover rolls forward interrupted reset from trashed state" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile faultprof
  assert_success

  local prof_dir="$fixture_repo/.agent-profiles/faultprof"
  local trash_dir="$fixture_repo/.agent-profiles/.trash/faultprof.12345"
  mkdir -p "$trash_dir/home"
  echo "old data" >"$trash_dir/home/old.txt"

  # Profile directory was moved to trash before crash
  rm -rf "$prof_dir"

  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  cat <<EOF >"$fixture_repo/.agent-profiles/.journal/reset-faultprof.json"
{
  "op": "reset",
  "profile": "faultprof",
  "state": "trashed",
  "profile_dir": "$prof_dir",
  "trash_path": "$trash_dir",
  "assume_unrelated": [],
  "boot_id": "00000000-0000-0000-0000-000000000000"
}
EOF

  # Recover should complete reset: re-init empty profile, delete trash, clear journal
  run bash "$AP_HELPER" recover --yes
  assert_success
  assert_output_contains "recovered"

  # Trash must be deleted
  [[ ! -d "$trash_dir" ]]

  # Journal must be removed
  [[ ! -f "$fixture_repo/.agent-profiles/.journal/reset-faultprof.json" ]]

  # Profile must be re-initialized and functional
  assert_dir_exists "$prof_dir/home"
  run bash "$AP_HELPER" run --profile faultprof -- echo working
  assert_success
  assert_output_contains "working"
}

@test "recovery: recover aborts and clears interrupted operation in planned state when profile intact" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile plannedprof
  assert_success

  local prof_dir="$fixture_repo/.agent-profiles/plannedprof"
  echo "keep this data" >"$prof_dir/home/keep.txt"

  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  cat <<EOF >"$fixture_repo/.agent-profiles/.journal/reset-plannedprof.json"
{
  "op": "reset",
  "profile": "plannedprof",
  "state": "planned",
  "profile_dir": "$prof_dir",
  "trash_path": "",
  "assume_unrelated": [],
  "boot_id": "00000000-0000-0000-0000-000000000000"
}
EOF

  run bash "$AP_HELPER" recover --yes
  assert_success

  # In planned state with profile intact, recover aborts and keeps existing data
  assert_file_exists "$prof_dir/home/keep.txt"
  [[ ! -f "$fixture_repo/.agent-profiles/.journal/reset-plannedprof.json" ]]
}

@test "recovery: recover rolls forward interrupted remove from trashed state" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile victim
  run bash "$AP_HELPER" init --profile survivor
  assert_success

  local victim_dir="$fixture_repo/.agent-profiles/victim"
  local survivor_dir="$fixture_repo/.agent-profiles/survivor"
  echo "victim data" >"$victim_dir/home/data.txt"
  echo "survivor data" >"$survivor_dir/home/data.txt"

  local trash_dir="$fixture_repo/.agent-profiles/.trash/victim.98765"
  mkdir -p "$fixture_repo/.agent-profiles/.trash"
  mv "$victim_dir" "$trash_dir"

  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  cat >"$fixture_repo/.agent-profiles/.journal/remove-victim.json" <<EOF
{
  "op": "remove",
  "profile": "victim",
  "state": "trashed",
  "profile_dir": "$victim_dir",
  "trash_path": "$trash_dir",
  "assume_unrelated": [],
  "boot_id": "00000000-0000-0000-0000-000000000000"
}
EOF

  run bash "$AP_HELPER" recover --yes
  assert_success
  assert_output_contains "interrupted 'remove'"

  # The remove is completed and the survivor is untouched.
  [[ ! -d "$victim_dir" ]]
  [[ ! -d "$trash_dir" ]]
  assert_file_exists "$survivor_dir/home/data.txt"
  [[ ! -f "$fixture_repo/.agent-profiles/.journal/remove-victim.json" ]]
}

@test "recovery: refuses while a process uses the trash path of an interrupted operation" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile movedprof
  assert_success

  # Simulate an interrupted remove that already moved the profile into trash.
  mkdir -p "$fixture_repo/.agent-profiles/.trash"
  local trash_path="$fixture_repo/.agent-profiles/.trash/movedprof.12345"
  mv "$fixture_repo/.agent-profiles/movedprof" "$trash_path"
  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  python3 - "$fixture_repo/.agent-profiles/.journal/remove-movedprof.json" "$trash_path" <<'PY'
import json, sys
path, trash = sys.argv[1], sys.argv[2]
with open(path, "w") as handle:
    json.dump({
        "op": "remove",
        "profile": "movedprof",
        "state": "trashed",
        "profile_dir": path.replace("/.journal/remove-movedprof.json", "/movedprof"),
        "trash_path": trash,
        "assume_unrelated": [],
        "boot_id": "00000000-0000-0000-0000-000000000000",
    }, handle)
PY

  setsid bash -c 'cd "$1" && exec sleep 60' _ "$trash_path/home" &
  local live_pid=$!
  local i=0
  while [[ "$(readlink "/proc/$live_pid/cwd" 2>/dev/null)" != "$trash_path/home" && $i -lt 50 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
  [[ "$(readlink "/proc/$live_pid/cwd")" == "$trash_path/home" ]]

  run bash "$AP_HELPER" recover --yes
  assert_failure 75
  assert_output_contains "PID $live_pid"
  assert_dir_exists "$trash_path"

  kill -TERM -"$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true

  run bash "$AP_HELPER" recover --yes
  assert_success
  [[ ! -e "$trash_path" ]]
}
