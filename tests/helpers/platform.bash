#!/usr/bin/env bash
# macOS test-tier support.
#
# Two things live here and nothing else:
#
# 1. The single named guard for the Linux-only tests, so every Darwin skip
#    carries a mandatory reason that names the Linux-only seam and where the
#    Darwin coverage lives instead. A reason-free skip is refused.
# 2. Portable fixtures for tests that need a terminal, a detached lock holder or
#    an availability probe the BSD userland can also run.
#
# The platform decision itself, and every path/stat/hash/timeout primitive, come
# from the shipped internal adapter (scripts/lib/platform.sh + platform.py). This
# file never reimplements them, so a test cannot drift away from the behaviour it
# is qualifying.

AP_TEST_HELPERS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "${AP_SKILL_DIR:-}" ]]; then
  AP_SKILL_DIR="$(cd -P "$AP_TEST_HELPERS_DIR/../../skills/agent-profiles" && pwd -P)"
fi
export AP_SKILL_DIR

# platform.sh reaches ap_die only when python3 is missing from PATH, and the test
# harness reports that as a failing test rather than aborting the suite.
if ! declare -F ap_die >/dev/null 2>&1; then
  ap_die() {
    local code="${1:-69}"
    shift || true
    printf 'agent-profiles tests: error: %s\n' "$*" >&2
    exit "$code"
  }
fi

# shellcheck source=/dev/null
source "$AP_SKILL_DIR/scripts/lib/platform.sh"

ap_test_platform_os() {
  ap_platform_os
}

ap_test_is_darwin() {
  [[ "$(ap_test_platform_os)" == "Darwin" ]]
}

ap_test_is_linux() {
  [[ "$(ap_test_platform_os)" != "Darwin" ]]
}

# ap_test_skip_darwin <reason>
#
# The only permitted way to skip a test on Darwin. The reason is mandatory: it
# must start with the seam id ("Linux-only S3", "Linux-only S9"), say which
# Linux-only mechanism the test exercises, and name the Darwin test file that
# covers the same behaviour instead. On Linux the guard is inert, so nothing in
# the suite can skip on the Linux gate.
ap_test_skip_darwin() {
  local reason="${1:-}"
  if [[ -z "$reason" ]]; then
    printf 'ap_test_skip_darwin: a named reason is required\n' >&2
    return 1
  fi
  if ap_test_is_darwin; then
    # shellcheck disable=SC2317  # skip() comes from the Bats test runner
    skip "$reason"
  fi
  return 0
}

# Prints the body of the one macOS job in .github/workflows/ci.yml. The block is
# selected structurally (the job whose runs-on label starts with "macos-"), so
# the contract tests never hard-code a job key or a line number.
ap_test_ci_macos_job() {
  python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
lines = open(path).read().splitlines()
starts = [i for i, line in enumerate(lines) if re.match(r"^jobs:\s*$", line)]
if len(starts) != 1:
    sys.stderr.write("ci.yml: expected exactly one top-level jobs: block\n")
    raise SystemExit(1)

blocks = {}
current = None
for line in lines[starts[0] + 1:]:
    header = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
    if header:
        current = header.group(1)
        blocks[current] = []
        continue
    if line and not line[0].isspace():
        current = None
        continue
    if current is not None:
        blocks[current].append(line)

macos = []
for name, body in blocks.items():
    if any(re.search(r"runs-on:\s*macos-", line) for line in body):
        macos.append((name, body))
if len(macos) != 1:
    sys.stderr.write("ci.yml: expected exactly one macOS job, found %d\n" % len(macos))
    raise SystemExit(1)
for line in macos[0][1]:
    sys.stdout.write(line + "\n")
PY
}

# Every "uses: owner/repo@ref" entry in a workflow, one per line.
ap_test_ci_action_uses() {
  grep -E '^[[:space:]]*uses:' "$1" || true
}

# ap_test_pty <command...>
#
# Runs a command attached to a pseudo-terminal, forwarding the caller's stdin, so
# an interactive prompt can be exercised on both platforms. util-linux
# ``script -qec`` does not exist on macOS; the standard-library driver the live
# harness already uses does.
ap_test_pty() {
  python3 "${AP_TEST_PTY_EXEC:-$AP_TEST_HELPERS_DIR/../live/pty-exec.py}" -- "$@"
}
# ap_test_sha256 <file>: bare lowercase hex digest, exactly what
# `sha256sum <file> | cut -d' ' -f1` returned.
ap_test_sha256() {
  ap_platform_sha256sum "$1" | cut -d' ' -f1
}

# ap_test_sha256_files <file...>: "hash  path" lines in byte order, the portable
# replacement for `sha256sum <glob> | LC_ALL=C sort`.
ap_test_sha256_files() {
  local file
  for file in "$@"; do
    [[ -e "$file" ]] || continue
    printf '%s  %s\n' "$(ap_test_sha256 "$file")" "$file"
  done | LC_ALL=C sort
}

# ap_test_snapshot_tree <path...>: deterministic description of directory
# entries, modes, symlink targets and regular-file hashes. GNU find -printf,
# sort -z and xargs -r all misbehave on BSD, so the traversal is Python.
ap_test_snapshot_tree() {
  python3 - "$@" <<'PY'
import hashlib
import os
import stat
import sys

lines = []


def describe(path):
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode):
        kind = "l"
    elif stat.S_ISDIR(info.st_mode):
        kind = "d"
    elif stat.S_ISREG(info.st_mode):
        kind = "f"
    else:
        kind = "?"
    lines.append("%s %o %s" % (kind, stat.S_IMODE(info.st_mode), path))
    if kind == "l":
        lines.append("target %s %s" % (path, os.readlink(path)))
    elif kind == "f":
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
        lines.append("%s  %s" % (digest.hexdigest(), path))


for root in sys.argv[1:]:
    if not os.path.lexists(root):
        lines.append("MISSING %s" % root)
        continue
    describe(root)
    for current, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(dirs) + sorted(files):
            describe(os.path.join(current, name))

sys.stdout.write("\n".join(sorted(lines, key=lambda value: value.encode())) + "\n")
PY
}

# ap_test_stat_mode <path>: octal permission bits, like `stat -c %a`.
ap_test_stat_mode() {
  ap_platform_stat_mode "$1"
}

# ap_test_lower <text>: lowercase without the Bash 4 ${var,,} expansion.
ap_test_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# ap_test_timeout <seconds> <command...>: GNU timeout replacement with the same
# 124 exit status, so callers keep their existing assertions.
ap_test_timeout() {
  local seconds="$1"
  shift
  ap_platform_timeout "$seconds" "$@"
}

# ap_test_try_lock <file> [shared|exclusive]: 0 when the lock was acquired and
# the file is free, 1 when another process holds it. Uses the shipped descriptor
# allocator and lock primitive, so no flock(1) binary is needed.
ap_test_try_lock() {
  local file="$1"
  local mode="${2:-exclusive}"
  local fd=""
  local rc=0
  if ! ap_lock_fd_open_into fd "$file"; then
    printf 'ap_test_try_lock: cannot open %s\n' "$file" >&2
    return 2
  fi
  ap_platform_lock "$mode" "$fd" || rc=$?
  ap_lock_fd_release "$fd"
  return "$rc"
}

# ap_test_hold_lock <file> [seconds]: holds an exclusive lock in a detached
# session for the given time and prints its pid (also its process-group id).
# Run it in the background, then wait for ap_test_try_lock to report contention
# before exercising the helper. Only call it with `&`: it execs python3, so the
# background job's $! is the holder itself and `kill -TERM -"$!"` reaches its
# session. Without the exec, $! named the bash subshell, the group kill missed,
# and every caller waited out the full hold time.
ap_test_hold_lock() {
  local file="$1"
  local seconds="${2:-30}"
  exec python3 - "$file" "$seconds" <<'PY'
import fcntl
import os
import sys
import time

path, seconds = sys.argv[1], float(sys.argv[2])
try:
    os.setsid()
except PermissionError:
    # Under job control the background job already leads its own process
    # group, which is all the caller's group kill needs.
    pass
with open(path, "r+") as handle:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    sys.stdout.write("%d\n" % os.getpid())
    sys.stdout.flush()
    time.sleep(seconds)
PY
}

# ap_test_spawn_detached <seconds> [NAME=VALUE...]: a daemon-like process in its
# own session with every standard descriptor closed, so process scanning sees it
# only through its environment. Prints its pid (also its process-group id).
ap_test_spawn_detached() {
  local seconds="$1"
  shift
  python3 - "$seconds" "$@" <<'PY'
import os
import subprocess
import sys

seconds = sys.argv[1]
environment = dict(os.environ)
for pair in sys.argv[2:]:
    name, _, value = pair.partition("=")
    environment[name] = value
devnull = os.open(os.devnull, os.O_RDWR)
process = subprocess.Popen(
    ["/bin/sh", "-c", 'exec 0<&- 1>&- 2>&-; exec sleep "$1"', "_", seconds],
    start_new_session=True,
    stdin=devnull,
    stdout=devnull,
    stderr=devnull,
    env=environment,
)
sys.stdout.write("%d\n" % process.pid)
PY
}

# ap_test_spawn_in_dir <dir> <marker> [seconds]: a process whose working
# directory is <dir>, in its own session, that writes <marker> once it is there.
# Prints its pid (also its process-group id) without reading procfs.
ap_test_spawn_in_dir() {
  local dir="$1"
  local marker="$2"
  local seconds="${3:-60}"
  python3 - "$dir" "$marker" "$seconds" <<'PY'
import os
import subprocess
import sys

directory, marker, seconds = sys.argv[1], sys.argv[2], sys.argv[3]
devnull = os.open(os.devnull, os.O_RDWR)
process = subprocess.Popen(
    ["/bin/sh", "-c", 'printf "started\\n" >"$1"; exec sleep "$2"', "_", marker, seconds],
    cwd=directory,
    start_new_session=True,
    stdin=devnull,
    stdout=devnull,
    stderr=devnull,
)
sys.stdout.write("%d\n" % process.pid)
PY
}

# ap_test_wait_for_file <path> [attempts]: waits until a fixture process has
# signalled that it reached its state.
ap_test_wait_for_file() {
  local path="$1"
  local limit="${2:-50}"
  local i=0
  while [[ ! -e "$path" ]]; do
    i=$((i + 1))
    [[ $i -lt $limit ]] || return 1
    sleep 0.1
  done
}

# --- Test-owned fixture registry -------------------------------------------
# A lease holder is a deliberately long-lived process, so every fixture started
# here is recorded and a test's teardown stops exactly those processes. An
# assertion failure, an interrupted test or a readiness timeout would otherwise
# leave a holder alive forever - most visibly on Darwin, where there is no
# bubblewrap sandbox and nothing else ends it. Bash 3.2: indexed arrays only.
AP_TEST_OWNED_PIDS=()
AP_TEST_OWNED_RELEASES=()

# ap_test_register_owned_pid <pid>: records a process this test started.
ap_test_register_owned_pid() {
  local pid="$1"
  [[ -n "$pid" ]] && AP_TEST_OWNED_PIDS+=("$pid")
  return 0
}

# ap_test_register_owned_release <path>: records a release path whose creation
# lets a registered holder exit by itself.
ap_test_register_owned_release() {
  local release="$1"
  [[ -n "$release" ]] && AP_TEST_OWNED_RELEASES+=("$release")
  return 0
}

ap_test_unregister_owned_pid() {
  local pid="$1"
  local kept=()
  local candidate
  for candidate in ${AP_TEST_OWNED_PIDS[@]+"${AP_TEST_OWNED_PIDS[@]}"}; do
    [[ "$candidate" == "$pid" ]] || kept+=("$candidate")
  done
  AP_TEST_OWNED_PIDS=(${kept[@]+"${kept[@]}"})
}

# ap_test_pid_uid <pid>: the owning user id, or empty when the process is gone.
ap_test_pid_uid() {
  local pid="$1"
  ps -o uid= -p "$pid" 2>/dev/null | tr -d ' '
}

# ap_test_pid_running <pid>: 0 when the process exists and is not a zombie.
ap_test_pid_running() {
  local pid="$1"
  local state
  state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ -n "$state" && "${state#Z}" == "$state" ]]
}

# ap_test_pid_owned <pid>: 0 only for a pid this test recorded AND that is still
# this user's process. Nothing outside the registry is ever signalled.
ap_test_pid_owned() {
  local pid="$1"
  local recorded=0
  local candidate
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  for candidate in ${AP_TEST_OWNED_PIDS[@]+"${AP_TEST_OWNED_PIDS[@]}"}; do
    [[ "$candidate" == "$pid" ]] && recorded=1
  done
  [[ "$recorded" -eq 1 ]] || return 1
  ap_test_pid_running "$pid" || return 1
  [[ "$(ap_test_pid_uid "$pid")" == "$(id -u)" ]]
}

# ap_test_stop_owned_pid <pid>: signals a recorded, still-owned process only.
ap_test_stop_owned_pid() {
  local pid="$1"
  ap_test_pid_owned "$pid" || return 0
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# ap_test_wait_pid_gone <pid> [attempts]: waits until a process is gone.
ap_test_wait_pid_gone() {
  local pid="$1"
  local limit="${2:-100}"
  local i=0
  while [[ $i -lt $limit ]]; do
    ap_test_pid_running "$pid" || return 0
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

# ap_test_teardown_owned: the failure-path teardown every lease fixture uses.
# It releases what can exit by itself, then stops every recorded holder or
# descendant that is still alive. Safe to call when nothing was started, and
# safe to call after a normal release.
ap_test_teardown_owned() {
  local release
  local pid
  for release in ${AP_TEST_OWNED_RELEASES[@]+"${AP_TEST_OWNED_RELEASES[@]}"}; do
    : >"$release" 2>/dev/null || true
  done
  for pid in ${AP_TEST_OWNED_PIDS[@]+"${AP_TEST_OWNED_PIDS[@]}"}; do
    ap_test_stop_owned_pid "$pid"
  done
  AP_TEST_OWNED_PIDS=()
  AP_TEST_OWNED_RELEASES=()
  return 0
}

# ap_test_run_detached <log-file> <command...>: runs a fixture command in its
# own session and sets AP_TEST_DETACHED_PID. The session keeps the fixture's
# lifetime under this test's control instead of the runner's process-group
# cleanup, and python3 is used rather than setsid(1), which stock macOS does not
# ship.
ap_test_run_detached() {
  local log="$1"
  shift
  # `python3 -c CODE -- cmd` leaves a literal "--" in sys.argv[1], so the "--"
  # separator is not passed: argv[1:] is the command itself.
  #
  # Descriptors above stderr are closed before the helper runs. The test runner
  # captures output through one of them (Bats uses fd 3), so a long-lived
  # fixture that kept it open would make the runner wait for the fixture to
  # end - which turns an uncollected holder into a false pass. The helper opens
  # the profile-lease descriptors after this point, so those still inherit
  # normally.
  python3 -c 'import os, sys
argv = sys.argv[1:]
if argv and argv[0] == "--":
    argv = argv[1:]
if not argv:
    raise SystemExit("ap_test_run_detached: no command")
try:
    os.setsid()
except OSError:
    pass
try:
    inherited = [int(name) for name in os.listdir("/dev/fd")]
except OSError:
    inherited = list(range(3, 256))
for descriptor in inherited:
    if descriptor > 2:
        try:
            os.close(descriptor)
        except OSError:
            pass
os.execvp(argv[0], argv)' "$@" </dev/null >"$log" 2>&1 &
  AP_TEST_DETACHED_PID=$!
}

# ap_test_lease_holder_script <dir>: writes a portable holder command and prints
# its path. The command signals that it is executing, then waits for a release
# file, so the caller controls its lifetime instead of betting a fixed sleep
# will outlast a slow start. The third argument is a hard lifetime bound: even
# if the owning test process is killed before teardown, the holder exits by
# itself instead of waiting forever. It runs inside the profile, so it inherits
# the shared profile lease descriptor just like a real command.
ap_test_lease_holder_script() {
  local dir="$1"
  local script="$dir/lease-holder.sh"
  mkdir -p "$dir"
  if [[ ! -f "$script" ]]; then
    cat >"$script" <<'SH'
#!/bin/sh
# args: <ready-marker> <release-file> [<max-seconds>]
printf 'ready\n' >"$1"
max="${3:-120}"
deadline=$(( $(date +%s) + max ))
while [ ! -e "$2" ]; do
  [ "$(date +%s)" -ge "$deadline" ] && exit 0
  sleep 0.2
done
exit 0
SH
    chmod +x "$script"
  fi
  printf '%s\n' "$script"
}

# ap_test_lease_wait_held <lock-file> [attempts]: waits until an exclusive probe
# of the profile lock fails, i.e. a shared lease is observably held. Probing is
# the observation: a process existing is not yet proof that it holds the lease.
ap_test_lease_wait_held() {
  local file="$1"
  local limit="${2:-300}"
  local i=0 rc=0
  while [[ $i -lt $limit ]]; do
    rc=0
    ap_test_try_lock "$file" exclusive >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 1 ]] && return 0
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

# ap_test_lease_wait_free <lock-file> [attempts]: waits until an exclusive probe
# succeeds, i.e. the shared lease was released. Replaces "kill, then sleep, then
# assume it happened".
ap_test_lease_wait_free() {
  local file="$1"
  local limit="${2:-300}"
  local i=0
  while [[ $i -lt $limit ]]; do
    ap_test_try_lock "$file" exclusive >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

# ap_test_start_lease_holder <helper> <profile> <script> <marker> <release> <log>
#   [<max-seconds>]
#
# Starts `run --profile <profile> -- sh <script> <marker> <release> <max>` from
# the current checkout root and sets AP_TEST_LEASE_PID. Returns only once the
# command is executing (marker) and the profile lease is observably held
# (exclusive probe refused), so no caller sleeps and hopes. The holder is
# registered before readiness is awaited, and a readiness failure stops it
# immediately instead of leaving it to teardown alone.
ap_test_start_lease_holder() {
  local helper="$1"
  local profile="$2"
  local script="$3"
  local marker="$4"
  local release="$5"
  local log="$6"
  local max_seconds="${7:-120}"
  local lock_file=".agent-profiles/.locks/$profile.lock"

  rm -f "$marker" "$release"
  # Own session: a holder is a long-lived stand-in for a real profile command,
  # so its lifetime must be controlled by the registry below and not by the test
  # runner's cleanup of its own process group. That is the only way a failure
  # path can actually be exercised on Linux, and it is also the Darwin shape,
  # where no bubblewrap sandbox ends the process for us.
  ap_test_run_detached "$log" bash "$helper" run --profile "$profile" -- \
    sh "$script" "$marker" "$release" "$max_seconds"
  AP_TEST_LEASE_PID=$AP_TEST_DETACHED_PID
  ap_test_register_owned_pid "$AP_TEST_LEASE_PID"
  ap_test_register_owned_release "$release"

  if ! ap_test_wait_for_file "$marker" 300 || ! ap_test_lease_wait_held "$lock_file" 300; then
    printf 'lease holder did not start and hold the profile lease:\n' >&2
    cat "$log" >&2 2>/dev/null || true
    ap_test_stop_owned_pid "$AP_TEST_LEASE_PID"
    ap_test_unregister_owned_pid "$AP_TEST_LEASE_PID"
    return 1
  fi
}

# ap_test_start_lease_descendant <helper> <profile> <script> <marker> <release>
#   <pid-file> <log> [<max-seconds>]
#
# Runs a command that starts the holder as a background descendant and exits, so
# only the inherited lease descriptor keeps the profile locked. The descendant's
# pid is recorded from the pid file and registered for teardown, which is what
# covers the failure path where the direct parent is already gone.
ap_test_start_lease_descendant() {
  local helper="$1"
  local profile="$2"
  local script="$3"
  local marker="$4"
  local release="$5"
  local pid_file="$6"
  local log="$7"
  local max_seconds="${8:-120}"
  local lock_file=".agent-profiles/.locks/$profile.lock"
  local child_pid=""

  rm -f "$marker" "$release" "$pid_file"
  # shellcheck disable=SC2016 # $1..$5 belong to the inner sh, not this shell.
  ap_test_run_detached "$log" bash "$helper" run --profile "$profile" -- \
    sh -c 'sh "$1" "$2" "$3" "$4" & echo $! >"$5"' holder \
    "$script" "$marker" "$release" "$max_seconds" "$pid_file"
  local parent_pid=$AP_TEST_DETACHED_PID
  ap_test_register_owned_pid "$parent_pid"

  # The detached run has to reach the point where it forks the descendant and
  # writes its pid; a missing pid file is a fixture failure, not readiness.
  if ! ap_test_wait_for_file "$pid_file" 300; then
    printf 'lease descendant parent did not record a pid:\n' >&2
    cat "$log" >&2 2>/dev/null || true
    ap_test_stop_owned_pid "$parent_pid"
    ap_test_unregister_owned_pid "$parent_pid"
    return 1
  fi
  child_pid=$(cat "$pid_file")
  [[ -n "$child_pid" ]] || return 1
  ap_test_register_owned_pid "$child_pid"
  ap_test_register_owned_release "$release"

  if ! ap_test_wait_for_file "$marker" 300 || ! ap_test_lease_wait_held "$lock_file" 300; then
    printf 'lease descendant did not start and hold the profile lease:\n' >&2
    cat "$log" >&2 2>/dev/null || true
    ap_test_stop_owned_pid "$child_pid"
    ap_test_unregister_owned_pid "$child_pid"
    return 1
  fi
}

# ap_test_release_lease_holder <release-file> <pid> <lock-file>: ends the
# holder's lifetime, waits, and observes the lease being released. It also
# unregisters the holder so teardown has nothing left to signal.
ap_test_release_lease_holder() {
  local release="$1"
  local pid="$2"
  local lock_file="$3"

  : >"$release"
  wait "$pid" 2>/dev/null || true
  ap_test_unregister_owned_pid "$pid"
  ap_test_lease_wait_free "$lock_file"
}

# ap_test_tree_digest <dir>: one digest over every regular file below dir, in
# sorted relative order. Replaces `find -type f -exec sha256sum {} + | sort |
# sha256sum`, which needs GNU sha256sum and makes the answer depend on absolute
# paths.
ap_test_tree_digest() {
  python3 - "$1" <<'PY'
import hashlib
import os
import sys

root = sys.argv[1]
lines = []
for current, dirs, files in os.walk(root):
    dirs.sort()
    for name in files:
        path = os.path.join(current, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
        lines.append("%s  %s" % (digest.hexdigest(), os.path.relpath(path, root)))
lines.sort(key=lambda value: value.encode())
combined = hashlib.sha256()
for line in lines:
    combined.update(line.encode())
    combined.update(b"\n")
sys.stdout.write("%s\n" % combined.hexdigest())
PY
}

# ap_test_manifest_verify <base-dir> <manifest>: the shipped verifier, so a test
# does not need `sha256sum -c` and cannot drift from the product's format.
ap_test_manifest_verify() {
  ap_platform_manifest_verify "$1" "$2"
}
