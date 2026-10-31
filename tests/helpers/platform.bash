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
  AP_SKILL_DIR="$(cd -P "$AP_TEST_HELPERS_DIR/../../skills/flyingnobita-agent-profiles" && pwd -P)"
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
# before exercising the helper.
ap_test_hold_lock() {
  local file="$1"
  local seconds="${2:-30}"
  python3 - "$file" "$seconds" <<'PY'
import fcntl
import os
import sys
import time

path, seconds = sys.argv[1], float(sys.argv[2])
os.setsid()
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
