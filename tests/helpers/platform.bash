#!/usr/bin/env bash
# macOS test-tier support.
#
# Two things live here and nothing else:
#
# 1. The single named guard for the Linux-only tests, so every Darwin skip
#    carries a mandatory reason that names the Linux-only seam and where the
#    Darwin coverage lives instead. A reason-free skip is refused.
# 2. Small readers for the CI contract test.
#
# The platform decision itself, and every path/stat/hash/timeout primitive, come
# from the shipped internal adapter (scripts/lib/platform.sh + platform.py). This
# file never reimplements them, so a test cannot drift away from the behaviour it
# is qualifying.

if [[ -z "${AP_SKILL_DIR:-}" ]]; then
  AP_TEST_PLATFORM_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  AP_SKILL_DIR="$(cd -P "$AP_TEST_PLATFORM_DIR/../../skills/flyingnobita-agent-profiles" && pwd -P)"
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
