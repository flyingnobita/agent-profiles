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

@test "ordering: stale journal recovery refusal takes priority over a missing profile" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile gone
  assert_success

  # An interrupted operation already moved the profile away, and its journal is
  # stale (no live lock). Recovery must be the actionable answer, not exit 66.
  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  cat >"$fixture_repo/.agent-profiles/.journal/remove-gone.json" <<'JOURNAL'
{
  "op": "remove",
  "profile": "gone",
  "state": "trashed",
  "profile_dir": "/tmp/placeholder/gone",
  "trash_path": "/tmp/placeholder/trash",
  "assume_unrelated": [],
  "boot_id": "00000000-0000-0000-0000-000000000000"
}
JOURNAL
  rm -rf "$fixture_repo/.agent-profiles/gone"

  run bash "$AP_HELPER" remove --profile gone --yes
  assert_failure 77
  assert_output_contains "recover"

  run bash "$AP_HELPER" reset --profile gone --yes
  assert_failure 77
  assert_output_contains "recover"

  run bash "$AP_HELPER" run --profile gone -- echo ok
  assert_failure 77
  assert_output_contains "recover"
}

@test "ordering: an incomplete journal is refused, then cleared by recover without touching data" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile intp
  assert_success
  echo "keep me" >"$fixture_repo/.agent-profiles/intp/home/keep.txt"

  # Simulate the crash window between journal creation and the first atomic
  # write: an empty journal file with no live lock.
  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  : >"$fixture_repo/.agent-profiles/.journal/reset-intp.json"

  run bash "$AP_HELPER" run --profile intp -- true
  assert_failure 77
  assert_output_contains "recover"

  run bash "$AP_HELPER" recover --yes
  assert_success
  assert_output_contains "incomplete journal"

  # Original data is intact and the checkout works again.
  assert_file_exists "$fixture_repo/.agent-profiles/intp/home/keep.txt"
  run bash "$AP_HELPER" run --profile intp -- sh -c 'printf "%s\n" "$AGENT_PROFILES_NAME"'
  assert_success
  assert_output_contains "intp"
}

@test "ordering: init refuses legacy layouts before creating storage or lock directories" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  mkdir -p "$fixture_repo/.agent-sandbox/home"

  run bash "$AP_HELPER" init --profile other
  assert_failure 77
  assert_output_contains "legacy profile storage"

  [[ ! -e "$fixture_repo/.agent-profiles" ]]
}

@test "ordering: lifecycle journal creation is atomic and never leaves an empty journal" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile atomic
  assert_success
  echo "data" >"$fixture_repo/.agent-profiles/atomic/home/data.txt"

  # Fault exactly after the journal lock is held and before the first atomic
  # write: no journal record may exist afterwards.
  run env AP_FAULT_AFTER=journal-locked bash "$AP_HELPER" reset --profile atomic --yes
  assert_failure 137
  assert_dir_exists "$fixture_repo/.agent-profiles/atomic/home"
  run bash -c 'find "$1" -name "*.json" | grep .' _ "$fixture_repo/.agent-profiles/.journal"
  assert_failure

  # The next operation succeeds without a recovery step.
  run bash "$AP_HELPER" reset --profile atomic --yes
  assert_success
  assert_dir_exists "$fixture_repo/.agent-profiles/atomic/home"
}

@test "ordering: the exclude lock is acquired without blocking indefinitely" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile first
  assert_success

  local lock_file="$fixture_repo/.agent-profiles/.locks/.exclude.lock"
  assert_file_exists "$lock_file"

  setsid bash -c 'exec 9<>"$1"; flock -x 9; sleep 30' _ "$lock_file" &
  local holder_pid=$!
  local i=0
  while flock -n "$lock_file" true 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
    [[ $i -lt 100 ]] || break
  done

  run timeout 40 bash "$AP_HELPER" init --profile second
  assert_failure 75
  assert_output_contains "lock"

  kill -TERM -"$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
}

@test "ordering: a profile that disappears before the lock is refused without leaving a journal" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile raceprof
  assert_success
  echo "keep" >"$fixture_repo/.agent-profiles/raceprof/home/keep.txt"

  # A PATH wrapper interleaves a competing removal exactly when the first
  # command is about to acquire the profile lock, after its pre-checks.
  local wrap_dir="$TEST_TMPDIR/flock-wrap"
  mkdir -p "$wrap_dir"
  local real_flock
  real_flock=$(command -v flock)
  cat >"$wrap_dir/flock" <<WRAP
#!/usr/bin/env bash
last="\${*: -1}"
if [[ "\$last" =~ ^[0-9]+\$ ]]; then
  target=\$(readlink "/proc/self/fd/\$last" 2>/dev/null || true)
  if [[ -n "\${RACE_TRIGGER:-}" && "\$target" == *"/.locks/\${RACE_PROFILE}.lock" && ! -e "\$RACE_TRIGGER" ]]; then
    : >"\$RACE_TRIGGER"
    rm -rf "\$RACE_REPO/.agent-profiles/\$RACE_PROFILE"
  fi
fi
exec "$real_flock" "\$@"
WRAP
  chmod +x "$wrap_dir/flock"

  local trigger="$TEST_TMPDIR/race-triggered"
  run env PATH="$wrap_dir:$PATH" \
    RACE_REPO="$fixture_repo" RACE_PROFILE="raceprof" RACE_TRIGGER="$trigger" \
    bash "$AP_HELPER" remove --profile raceprof --yes
  assert_failure 66
  assert_output_contains "not initialized"
  assert_file_exists "$trigger"

  # No journal and no trash were created for the vanished profile, so the
  # checkout stays usable instead of blocking on an unrecoverable operation.
  run bash -c 'find "$1" -name "*.json" | grep .' _ "$fixture_repo/.agent-profiles/.journal"
  assert_failure
  [[ -z "$(ls -A "$fixture_repo/.agent-profiles/.trash" 2>/dev/null)" ]]

  run bash "$AP_HELPER" init --profile raceprof
  assert_success
  run bash "$AP_HELPER" run --profile raceprof -- true
  assert_success
}

@test "journal sidecar: a symlinked lock file is refused and never treated as a live operation" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile sidecar
  assert_success

  # Interrupted remove leaves a real journal and sidecar lock file.
  run env AP_FAULT_AFTER=planned bash "$AP_HELPER" remove --profile sidecar --yes
  assert_failure 137
  local journal="$fixture_repo/.agent-profiles/.journal/remove-sidecar.json"
  local sidecar="$fixture_repo/.agent-profiles/.journal/remove-sidecar.lock"
  assert_file_exists "$journal"
  assert_file_exists "$sidecar"

  # A symlinked sidecar would let the reader follow a path outside the checkout.
  local sentinel="$TEST_TMPDIR/outside-sentinel.lock"
  printf 'sentinel-content\n' >"$sentinel"
  local sentinel_hash_before
  sentinel_hash_before=$(sha256sum "$sentinel" | cut -d' ' -f1)
  rm -f "$sidecar"
  ln -s "$sentinel" "$sidecar"

  # Even while the outside lock is held, this must be a refusal, not "live".
  setsid bash -c 'exec 9<>"$1"; flock -x 9; sleep 30' _ "$sentinel" &
  local holder_pid=$!
  local i=0
  while flock -n "$sentinel" true 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
    [[ $i -lt 100 ]] || break
  done

  run bash "$AP_HELPER" run --profile sidecar -- true
  assert_failure 73
  assert_output_contains "journal lock"

  run bash "$AP_HELPER" recover --yes
  assert_failure 73
  assert_output_contains "journal lock"

  assert_equal "$sentinel_hash_before" "$(sha256sum "$sentinel" | cut -d' ' -f1)"
  assert_file_exists "$journal"

  kill -TERM -"$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
}

@test "journal sidecar: a non-regular lock file is refused instead of skipped" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile nosidecar
  assert_success

  run env AP_FAULT_AFTER=planned bash "$AP_HELPER" reset --profile nosidecar --yes
  assert_failure 137
  local journal="$fixture_repo/.agent-profiles/.journal/reset-nosidecar.json"
  local sidecar="$fixture_repo/.agent-profiles/.journal/reset-nosidecar.lock"
  assert_file_exists "$journal"

  rm -f "$sidecar"
  mkdir "$sidecar"

  run bash "$AP_HELPER" run --profile nosidecar -- true
  assert_failure 73
  assert_output_contains "journal lock"

  run bash "$AP_HELPER" recover --yes
  assert_failure 73
  assert_file_exists "$journal"
}

@test "ordering: a journal that appears under the locks is refused before mutation" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile concurrent
  assert_success
  echo "keep" >"$fixture_repo/.agent-profiles/concurrent/home/keep.txt"

  # The wrapper plants a concurrent crash journal exactly when the profile lock
  # is acquired, after the first preflight already ran.
  local wrap_dir="$TEST_TMPDIR/flock-wrap"
  mkdir -p "$wrap_dir"
  local real_flock
  real_flock=$(command -v flock)
  cat >"$wrap_dir/flock" <<WRAP
#!/usr/bin/env bash
last="\${*: -1}"
if [[ "\$last" =~ ^[0-9]+\$ ]]; then
  target=\$(readlink "/proc/self/fd/\$last" 2>/dev/null || true)
  if [[ -n "\${RACE_TRIGGER:-}" && "\$target" == *"/.locks/\${RACE_PROFILE}.lock" && ! -e "\$RACE_TRIGGER" ]]; then
    : >"\$RACE_TRIGGER"
    cat >"\$RACE_REPO/.agent-profiles/.journal/reset-\$RACE_PROFILE.json" <<JOURNAL
{"op":"reset","profile":"\$RACE_PROFILE","state":"planned","profile_dir":"\$RACE_REPO/.agent-profiles/\$RACE_PROFILE","trash_path":"","assume_unrelated":[],"boot_id":"00000000-0000-0000-0000-000000000000"}
JOURNAL
  fi
fi
exec "$real_flock" "\$@"
WRAP
  chmod +x "$wrap_dir/flock"

  local trigger="$TEST_TMPDIR/lock-triggered"
  run env PATH="$wrap_dir:$PATH" \
    RACE_REPO="$fixture_repo" RACE_PROFILE="concurrent" RACE_TRIGGER="$trigger" \
    bash "$AP_HELPER" remove --profile concurrent --yes
  assert_failure 77
  assert_output_contains "interrupted reset"
  assert_file_exists "$trigger"

  # Nothing was mutated and the concurrent journal is preserved.
  assert_file_exists "$fixture_repo/.agent-profiles/concurrent/home/keep.txt"
  assert_file_exists "$fixture_repo/.agent-profiles/.journal/reset-concurrent.json"
  run bash -c 'find "$1" -newer "$2" -name "remove-concurrent.json" | grep .' _ \
    "$fixture_repo/.agent-profiles/.journal" "$trigger"
  assert_failure
}

@test "recovery: clearing an incomplete journal requires the storage lock" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile lockprof
  assert_success
  echo "keep" >"$fixture_repo/.agent-profiles/lockprof/home/keep.txt"
  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  : >"$fixture_repo/.agent-profiles/.journal/reset-lockprof.json"

  local storage_lock="$fixture_repo/.agent-profiles/.locks/.storage.lock"
  assert_file_exists "$storage_lock"
  setsid bash -c 'exec 9<>"$1"; flock -x 9; sleep 30' _ "$storage_lock" &
  local holder_pid=$!
  local i=0
  while flock -n "$storage_lock" true 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
    [[ $i -lt 100 ]] || break
  done

  run timeout 20 bash "$AP_HELPER" recover --yes
  assert_failure 75
  assert_file_exists "$fixture_repo/.agent-profiles/.journal/reset-lockprof.json"
  assert_file_exists "$fixture_repo/.agent-profiles/lockprof/home/keep.txt"

  kill -TERM -"$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  run bash "$AP_HELPER" recover --yes
  assert_success
  assert_output_contains "incomplete journal"
  assert_file_exists "$fixture_repo/.agent-profiles/lockprof/home/keep.txt"
}

@test "ordering: an incomplete journal is refused without a Python traceback" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile quietprof
  assert_success
  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  : >"$fixture_repo/.agent-profiles/.journal/reset-quietprof.json"

  run bash "$AP_HELPER" run --profile quietprof -- true
  assert_failure 77
  assert_output_contains "incomplete journal"
  assert_output_not_contains "Traceback"
}

@test "journal: a pre-existing temporary symlink is never followed" {
  local fixture_repo="$TEST_TMPDIR/fixture-repo"
  create_fixture_repo "$fixture_repo"
  cd "$fixture_repo"

  run bash "$AP_HELPER" init --profile tmpprof
  assert_success

  local sentinel="$TEST_TMPDIR/outside-tmp-sentinel"
  printf 'sentinel-content\n' >"$sentinel"
  local sentinel_hash_before
  sentinel_hash_before=$(sha256sum "$sentinel" | cut -d' ' -f1)
  mkdir -p "$fixture_repo/.agent-profiles/.journal"
  ln -s "$sentinel" "$fixture_repo/.agent-profiles/.journal/reset-tmpprof.json.tmp"

  run bash "$AP_HELPER" reset --profile tmpprof --yes
  assert_success

  assert_equal "$sentinel_hash_before" "$(sha256sum "$sentinel" | cut -d' ' -f1)"
}
