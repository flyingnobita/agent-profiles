#!/usr/bin/env bats
# Darwin process safety for destructive lifecycle operations.
#
# macOS has no procfs, so the process scan must come from stock /bin/ps,
# /usr/sbin/sysctl and /usr/sbin/lsof through the platform adapter, and it must
# fail closed when that inspection is not available. A Linux host cannot run
# Darwin, so these tests select the Darwin inspector through the internal
# AP_TEST_PLATFORM_OS seam (see platform.sh) and move the Darwin inspection
# tools through the internal AP_DARWIN_LSOF/AP_DARWIN_PS seams. The seams are
# honoured only inside the test suite, are not user-facing options and are not
# documented supported variables. A green run on Linux therefore proves branch
# selection and the ps/lsof contract only; it is never evidence of stock macOS
# bash 3.2, BSD userland or the Darwin kernel. That evidence belongs to the
# macOS job and the MBP-M4 run.
# shellcheck disable=SC2030,SC2031

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation
  TEST_BG_PIDS=()
  # A path that never exists: with the Darwin inspector selected, procfs must
  # not be consulted at all.
  AP_DARWIN_TEST_NO_PROCFS="$TEST_TMPDIR/no-procfs"
}

teardown() {
  local pid
  if [[ ${#TEST_BG_PIDS[@]} -gt 0 ]]; then
    for pid in "${TEST_BG_PIDS[@]}"; do
      [[ -n "$pid" ]] || continue
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
  teardown_isolation
}

# spawn_lease_session <repo> <profile> <pid-file> <holder-var>:
# Starts a profile run session whose direct parent exits at once, so only the
# inherited profile lease descriptor keeps the session marker alive.
spawn_lease_session() {
  local repo="$1" profile="$2" pid_file="$3"
  (
    cd "$repo" || exit 1
    # shellcheck disable=SC2016
    AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" \
      bash "$AP_HELPER" run --profile "$profile" -- \
      sh -c 'sleep 30 >/dev/null 2>&1 & echo $! >"$1"' _ "$pid_file"
  )
}

@test "darwin procscan: an inherited profile lease blocks reset and unrelated processes do not" {
  local repo="$TEST_TMPDIR/repo-darwin-lease"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile leased
  assert_success
  run bash "$AP_HELPER" init --profile other
  assert_success
  run bash "$AP_HELPER" init --profile free
  assert_success

  local lease_file="$repo/.agent-profiles/.locks/leased.lock"
  local holder_pid_file="$TEST_TMPDIR/leased-holder.pid"
  run spawn_lease_session "$repo" leased "$holder_pid_file"
  assert_success
  assert_file_exists "$holder_pid_file"
  local holder_pid
  holder_pid=$(cat "$holder_pid_file")
  [[ "$holder_pid" =~ ^[0-9]+$ ]]
  TEST_BG_PIDS+=("$holder_pid")

  # The descendant outlived the direct parent, so the shared lease can only
  # still be open in the inherited descriptor. The Darwin inspector must name
  # that holder instead of reporting an anonymous busy profile.
  run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" bash "$AP_HELPER" reset --profile leased --yes
  assert_failure 75
  assert_output_contains "cannot acquire exclusive lock for profile 'leased'"
  assert_output_contains "PID $holder_pid"
  assert_output_contains "$lease_file"
  # The refused mutation changed nothing.
  assert_dir_exists "$repo/.agent-profiles/leased/home"

  # A second profile's live lease is unrelated and must not refuse this one.
  local other_pid_file="$TEST_TMPDIR/other-holder.pid"
  run spawn_lease_session "$repo" other "$other_pid_file"
  assert_success
  local other_pid
  other_pid=$(cat "$other_pid_file")
  TEST_BG_PIDS+=("$other_pid")

  run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" bash "$AP_HELPER" reset --profile free --yes
  assert_success
  assert_output_contains "Reset profile 'free' successfully"
  assert_output_not_contains "$other_pid"

  # Once the lease holder exits the lock is released and reset proceeds.
  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  local attempt=0
  while [[ "$attempt" -lt 60 ]]; do
    run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" bash "$AP_HELPER" reset --profile leased --yes
    [[ "$status" -eq 0 ]] && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  assert_success
  assert_output_contains "Reset profile 'leased' successfully"
}

# Waits until the Darwin inspector classifies a live holder. Leaves the refusal
# of the last probe in $output, so the caller asserts on it. Polling replaces a
# sleeps-based guess at how long an open descriptor takes to become visible.
wait_for_scan_refusal() {
  local attempt=0
  while [[ "$attempt" -lt 80 ]]; do
    run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" bash "$AP_HELPER" "$@"
    if [[ "$status" -eq 75 && "$output" == *"PID "* ]]; then
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  printf '%s\n' "no Darwin process refusal observed; last status $status: $output" >&2
  return 1
}

@test "darwin procscan: open profile files and legacy working directories refuse mutation without leaking values" {
  local repo="$TEST_TMPDIR/repo-darwin-open"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile target
  assert_success
  local prof_dir="$repo/.agent-profiles/target"
  local marker_file="$prof_dir/home/activity.marker"
  local secret="DARWIN_PROCSCAN_SECRET_7182"

  # An open descriptor inside the profile with a secret in the environment and
  # in argv: the refusal may print the PID and command name only.
  (
    exec 8>"$marker_file"
    SECRET_TOKEN="$secret" exec python3 -c 'import time; time.sleep(30)' "$secret"
  ) </dev/null >/dev/null 2>&1 &
  local holder_pid=$!
  TEST_BG_PIDS+=("$holder_pid")

  wait_for_scan_refusal reset --profile target
  assert_output_contains "refused: active process"
  assert_output_contains "profile 'target'"
  assert_output_contains "PID $holder_pid"
  # The refusal names the holder's command and nothing else. The command name a
  # process reports is platform-specific - macOS reports the Python framework
  # executable where Linux reports python3 - so the expected label is derived
  # from the live process instead of hard-coding the Linux spelling. A printed
  # label must be a prefix of the real command name, which tolerates the
  # truncation lsof applies and still fails if no name, or a wrong one, is shown.
  local holder_comm printed_label
  holder_comm=$(ps -o comm= -p "$holder_pid" 2>/dev/null || true)
  holder_comm=$(printf '%s' "$holder_comm" | sed 's#.*/##; s/^[[:space:]]*//; s/[[:space:]]*$//')
  [[ -n "$holder_comm" ]]
  printed_label=$(printf '%s\n' "$output" | sed -n "s/.*PID $holder_pid (\([^)]*\)).*/\1/p" | head -n 1)
  [[ -n "$printed_label" ]]
  case "$(printf '%s' "$holder_comm" | tr '[:upper:]' '[:lower:]')" in
    "$(printf '%s' "$printed_label" | tr '[:upper:]' '[:lower:]')"*) ;;
    *)
      printf 'refusal label %s does not name the holder command %s\n' \
        "$printed_label" "$holder_comm" >&2
      return 1
      ;;
  esac
  assert_output_not_contains "$secret"
  # Nothing was mutated and the profile is still complete.
  assert_dir_exists "$prof_dir/home"
  assert_file_exists "$marker_file"

  wait_for_scan_refusal remove --profile target --yes
  assert_output_contains "PID $holder_pid"
  assert_output_not_contains "$secret"
  assert_dir_exists "$prof_dir"

  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  # A legacy working directory is refused for migrate, and the legacy data is
  # left exactly where it was.
  mkdir -p "$repo/.agent-sandbox/home" "$repo/.agent-sandbox/.claude"
  printf 'legacy content\n' >"$repo/.agent-sandbox/home/file.txt"
  (
    cd "$repo/.agent-sandbox/.claude" || exit 1
    exec python3 -c 'import time; time.sleep(60)' "$secret"
  ) </dev/null >/dev/null 2>&1 &
  local legacy_pid=$!
  TEST_BG_PIDS+=("$legacy_pid")

  wait_for_scan_refusal migrate --yes
  assert_output_contains "legacy storage"
  assert_output_contains "PID $legacy_pid"
  assert_output_not_contains "$secret"
  assert_file_exists "$repo/.agent-sandbox/home/file.txt"
  [[ ! -e "$repo/.agent-profiles/default" ]]

  kill -9 "$legacy_pid" 2>/dev/null || true
  wait "$legacy_pid" 2>/dev/null || true

  # An interrupted operation leaves data in trash: recover must refuse while a
  # process still uses that data instead of rolling the journal forward.
  mkdir -p "$repo/.agent-profiles/.trash"
  local trash_path="$repo/.agent-profiles/.trash/target.12345"
  mv "$prof_dir" "$trash_path"
  mkdir -p "$repo/.agent-profiles/.journal"
  python3 - "$repo/.agent-profiles/.journal/remove-target.json" "$trash_path" "$prof_dir" <<'PY'
import json, sys
journal, trash, profile_dir = sys.argv[1:4]
with open(journal, "w") as handle:
    json.dump({
        "op": "remove",
        "profile": "target",
        "state": "trashed",
        "profile_dir": profile_dir,
        "trash_path": trash,
        "assume_unrelated": [],
        "boot_id": "00000000-0000-0000-0000-000000000000",
    }, handle)
PY
  (
    cd "$trash_path/home" || exit 1
    exec python3 -c 'import time; time.sleep(60)' "$secret"
  ) </dev/null >/dev/null 2>&1 &
  local trash_pid=$!
  TEST_BG_PIDS+=("$trash_pid")

  wait_for_scan_refusal recover --yes
  assert_output_contains "PID $trash_pid"
  assert_output_not_contains "$secret"
  # The journal and the trashed data are untouched by the refusal.
  assert_file_exists "$repo/.agent-profiles/.journal/remove-target.json"
  assert_dir_exists "$trash_path/home"

  kill -9 "$trash_pid" 2>/dev/null || true
  wait "$trash_pid" 2>/dev/null || true
}

# hash_tree <dir>: stable content hash of every file under <dir>, so a refused
# mutation can be proven byte-identical afterwards.
hash_tree() {
  python3 - "$1" <<'PY'
import hashlib
import os
import sys

root = sys.argv[1]
digest = hashlib.sha256()
for current, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(files):
        path = os.path.join(current, name)
        rel = os.path.relpath(path, root)
        digest.update(rel.encode("utf-8", "surrogateescape") + b"\0")
        try:
            with open(path, "rb") as handle:
                digest.update(hashlib.sha256(handle.read()).digest())
        except OSError:
            digest.update(b"<unreadable>")
print(digest.hexdigest())
PY
}

@test "darwin procscan: unavailable process inspection fails closed before mutation" {
  local repo="$TEST_TMPDIR/repo-darwin-unavailable"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile target
  assert_success
  local prof_dir="$repo/.agent-profiles/target"
  printf 'profile sentinel\n' >"$prof_dir/home/keep.txt"
  mkdir -p "$repo/.agent-sandbox/home"
  printf 'legacy sentinel\n' >"$repo/.agent-sandbox/home/keep.txt"

  # A live profile holder: without a working inspector the operation must not
  # assume the profile is free.
  (
    exec 8>"$prof_dir/home/activity.marker"
    exec sleep 30
  ) </dev/null >/dev/null 2>&1 &
  local holder_pid=$!
  TEST_BG_PIDS+=("$holder_pid")

  local profile_before legacy_before
  profile_before=$(hash_tree "$prof_dir")
  legacy_before=$(hash_tree "$repo/.agent-sandbox")

  local stub_dir="$TEST_TMPDIR/inspector-stubs"
  mkdir -p "$stub_dir"

  # 1. The inspector binary is missing entirely.
  run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" \
    AP_DARWIN_LSOF="$stub_dir/does-not-exist" \
    bash "$AP_HELPER" reset --profile target --yes
  assert_failure 69
  assert_output_contains "refused: process inspection is unavailable"
  assert_equal "$(hash_tree "$prof_dir")" "$profile_before"

  # 2. The inspector exists but cannot complete its listing.
  printf '#!/bin/sh\nexit 2\n' >"$stub_dir/lsof-failing"
  chmod 700 "$stub_dir/lsof-failing"
  run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" \
    AP_DARWIN_LSOF="$stub_dir/lsof-failing" \
    bash "$AP_HELPER" remove --profile target --yes
  assert_failure 69
  assert_output_contains "process inspection is unavailable"
  assert_equal "$(hash_tree "$prof_dir")" "$profile_before"

  # 3. The inspector reports success but lists nothing at all: a silent empty
  # probe is incomplete inspection, never "no process".
  printf '#!/bin/sh\nexit 0\n' >"$stub_dir/lsof-empty"
  chmod 700 "$stub_dir/lsof-empty"
  run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" \
    AP_DARWIN_LSOF="$stub_dir/lsof-empty" \
    bash "$AP_HELPER" reset --profile target --yes
  assert_failure 69
  assert_output_contains "process inspection is unavailable"
  assert_equal "$(hash_tree "$prof_dir")" "$profile_before"

  # 4. Legacy mutation refuses the same way and leaves the legacy data alone.
  run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" \
    AP_DARWIN_LSOF="$stub_dir/does-not-exist" \
    bash "$AP_HELPER" migrate --yes
  assert_failure 69
  assert_output_contains "process inspection is unavailable"
  assert_equal "$(hash_tree "$repo/.agent-sandbox")" "$legacy_before"
  [[ ! -e "$repo/.agent-profiles/default" ]]

  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  # With a working inspector and no holder left the same mutation proceeds, so
  # the refusals above came from the probe and not from the fixture.
  run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" \
    bash "$AP_HELPER" reset --profile target --yes
  assert_success
  [[ "$(hash_tree "$prof_dir")" != "$profile_before" ]]
}

@test "darwin procscan: a process that exits between the ps and lsof snapshots is not a holder" {
  load '../helpers/platform.bash'
  local repo="$TEST_TMPDIR/repo-darwin-exited"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile target
  assert_success

  # A PID that has already exited, so it cannot hold anything. The ps stub adds
  # it to the full process listing as an orphan of this user, which is what the
  # inspector sees when a short-lived process such as Spotlight's
  # mdworker_shared exits after ps runs and before lsof does.
  sleep 0 &
  local ghost=$!
  wait "$ghost" 2>/dev/null || true
  local stub_dir="$TEST_TMPDIR/inspector-stubs"
  mkdir -p "$stub_dir"
  local real_ps
  real_ps=$(command -v /bin/ps /usr/bin/ps ps 2>/dev/null | head -n 1)
  [[ -n "$real_ps" ]]
  cat >"$stub_dir/ps" <<STUB
#!/bin/sh
"$real_ps" "\$@" || exit \$?
case " \$* " in
  *" -axo "*)
    printf '%s 1 %s %s S Fri Nov 13 22:00:00 2026 /usr/libexec/ghost-exited\n' \
      "$ghost" "$ghost" "\$(id -u)"
    ;;
esac
STUB
  chmod 700 "$stub_dir/ps"

  run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" \
    AP_DARWIN_PS="$stub_dir/ps" \
    bash "$AP_HELPER" reset --profile target --yes
  assert_success
  assert_output_not_contains "ghost-exited"

  # A live orphan that lsof cannot describe is still relevant-unknown: the
  # re-check drops only processes that are gone, never ones that are alive.
  local live
  live=$(ap_test_spawn_detached 30)
  TEST_BG_PIDS+=("$live")
  # Wait until the fixture has exec'd sleep and been reparented, so the scan
  # sees the final command name and a parentless orphan.
  local attempt=0 live_comm="" live_ppid=""
  while [[ "$attempt" -lt 100 ]]; do
    live_comm=$("$real_ps" -o comm= -p "$live" 2>/dev/null | sed 's#.*/##; s/[[:space:]]*$//')
    live_ppid=$("$real_ps" -o ppid= -p "$live" 2>/dev/null | tr -d '[:space:]')
    [[ "$live_comm" == "sleep" && "$live_ppid" == "1" ]] && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [[ "$live_comm" == "sleep" ]]
  # The scan treats only a parentless orphan as relevant-unknown. A host whose
  # child subreaper adopts the fixture instead of PID 1 fails here, loudly,
  # rather than skipping: the platform contract allows no skips in this suite.
  [[ "$live_ppid" == "1" ]]
  local real_lsof
  real_lsof=$(command -v /usr/sbin/lsof /usr/bin/lsof lsof 2>/dev/null | head -n 1)
  [[ -n "$real_lsof" ]]
  cat >"$stub_dir/lsof" <<STUB
#!/bin/sh
"$real_lsof" "\$@" | awk -v hide="p$live" '/^p/ { skip = (\$0 == hide) } !skip'
STUB
  chmod 700 "$stub_dir/lsof"

  run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" \
    AP_DARWIN_LSOF="$stub_dir/lsof" \
    bash "$AP_HELPER" reset --profile target --yes
  assert_failure 75
  assert_output_contains "PID $live (sleep) [relevant-unknown"

  # The re-check itself failing proves nothing about the process, so the live
  # orphan must still refuse. This ps lists the full table but fails the
  # per-PID re-check with no rows.
  cat >"$stub_dir/ps-recheck-fails" <<STUB
#!/bin/sh
case " \$* " in
  *" -p "*) exit 1 ;;
esac
exec "$real_ps" "\$@"
STUB
  chmod 700 "$stub_dir/ps-recheck-fails"
  run env AP_TEST_PLATFORM_OS=Darwin AP_PROC_ROOT="$AP_DARWIN_TEST_NO_PROCFS" \
    AP_DARWIN_LSOF="$stub_dir/lsof" AP_DARWIN_PS="$stub_dir/ps-recheck-fails" \
    bash "$AP_HELPER" reset --profile target --yes
  assert_failure 75
  assert_output_contains "PID $live (sleep) [relevant-unknown"

  kill -TERM -"$live" 2>/dev/null || kill -TERM "$live" 2>/dev/null || true
}
