#!/usr/bin/env bats
# macOS platform contract (S7): the arm64 macOS CI job, the named and reasoned
# Linux-only test guards, and the stock Bash 3.2 requirement.
#
# These are static contracts over the repository plus one dynamic probe of the
# guard itself: the macOS job cannot run on a Linux host, so its YAML is read
# structurally instead of being executed here. Remote execution of that job stays
# unverified until the branch is pushed.
# shellcheck disable=SC2030,SC2031

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/isolation.bash'
  load '../helpers/platform.bash'
  setup_isolation
  CI_WORKFLOW="$AP_SUBJECT/.github/workflows/ci.yml"
}

teardown() {
  teardown_isolation
}

macos_job() {
  local job
  if ! job=$(ap_test_ci_macos_job "$CI_WORKFLOW" 2>"$TEST_TMPDIR/ci.err"); then
    cat "$TEST_TMPDIR/ci.err" >&2
    return 1
  fi
  printf '%s\n' "$job"
}

@test "platform contract: macOS CI uses an arm64 runner and runs ci and release gates" {
  local job
  job=$(macos_job) || return 1

  # A pinned macOS runner. GitHub's macos-15 and later images are arm64; if that
  # label is retired, this assertion is updated to the explicit supported arm64
  # label - the architecture requirement is never dropped.
  [[ "$job" =~ runs-on:[[:space:]]*macos-15([[:space:]]|$) ]] || {
    printf 'macOS job does not pin runs-on: macos-15\n%s\n' "$job" >&2
    return 1
  }

  # The job proves its own architecture instead of assuming the label implies it.
  [[ "$job" == *"uname -m"* ]] || {
    echo "macOS job never asserts uname -m" >&2
    return 1
  }
  [[ "$job" == *'"arm64"'* ]] || {
    echo "macOS job never asserts arm64" >&2
    return 1
  }
  [[ "$job" == *"uname -s"* && "$job" == *Darwin* ]] || {
    echo "macOS job never asserts it is running on Darwin" >&2
    return 1
  }

  # Both release gates run unchanged on the Mac.
  [[ "$job" == *"mise run ci"* ]] || {
    echo "macOS job does not run mise run ci" >&2
    return 1
  }
  [[ "$job" == *"mise run release-artifacts"* ]] || {
    echo "macOS job does not run mise run release-artifacts" >&2
    return 1
  }

  # Darwin redirects by environment only: bubblewrap is a Linux prerequisite and
  # must never be installed or probed by the macOS job.
  local forbidden
  for forbidden in bubblewrap bwrap apt-get brew; do
    if [[ "$job" == *"$forbidden"* ]]; then
      printf 'macOS job must not mention %s\n' "$forbidden" >&2
      return 1
    fi
  done

  # Tools come from the repository pins, through a pinned action.
  [[ "$job" == *"uses: jdx/mise-action@"* ]] || {
    echo "macOS job does not install the pinned project tools through mise-action" >&2
    return 1
  }

  # Every action in the workflow is pinned to a full commit sha.
  local use_line
  while IFS= read -r use_line; do
    [[ "$use_line" =~ @[0-9a-f]{40}([[:space:]]|$) ]] || {
      printf 'unpinned action: %s\n' "$use_line" >&2
      return 1
    }
  done < <(ap_test_ci_action_uses "$CI_WORKFLOW")

  # Minimal permissions: read-only contents at the top level, no write grant.
  grep -q '^permissions:$' "$CI_WORKFLOW" || {
    echo "ci.yml has no explicit permissions block" >&2
    return 1
  }
  grep -q '^  contents: read$' "$CI_WORKFLOW" || {
    echo "ci.yml does not grant read-only contents" >&2
    return 1
  }
  if grep -qE ': write(-all)?$' "$CI_WORKFLOW"; then
    echo "ci.yml grants a write permission" >&2
    return 1
  fi
  if [[ "$job" == *"permissions:"* ]]; then
    echo "macOS job overrides the read-only workflow permissions" >&2
    return 1
  fi
}

@test "platform contract: Linux-only tests have named reasoned guards and Linux runs without platform skips" {
  local violations
  if ! violations=$(python3 - "$AP_SUBJECT/tests" <<'PY'
import os
import re
import sys

root = sys.argv[1]
problems = []


def read(path):
    with open(path, "r") as handle:
        return handle.read()


def block_of(text, header_prefix):
    lines = text.splitlines()
    for start, line in enumerate(lines):
        if line.startswith(header_prefix):
            for end in range(start + 1, len(lines)):
                if lines[end] == "}":
                    return "\n".join(lines[start:end + 1])
            return "\n".join(lines[start:])
    return ""


guard_path = os.path.join(root, "helpers", "platform.bash")
guard = read(guard_path) if os.path.isfile(guard_path) else ""
if not guard:
    problems.append("helpers/platform.bash: the named guard file is missing")
for needle, message in (
    ("ap_test_skip_darwin() {", "the guard is not defined"),
    ('skip "$reason"', "the skip call must use the named reason"),
    ('-z "$reason"', "an empty reason must be refused"),
    ('"$(ap_test_platform_os)" == "Darwin"', "the platform decision is missing"),
):
    if guard and needle not in guard:
        problems.append("helpers/platform.bash: %s" % message)

# The only permitted Darwin guards. Each reason must name the Linux-only seam
# and the Darwin file that covers the same behaviour.
ALLOWED = {
    "02-runtime/mounts-bwrap.bats": (
        "setup() {",
        ("bubblewrap", "darwin-run.bats"),
    ),
    "08-lifecycle/procscan.bats": (
        '@test "procscan: detects uninspectable orphaned process under AP_PROC_ROOT as relevant-unknown" {',
        ("procfs", "darwin-procscan.bats"),
    ),
}

guard_call = re.compile(r'ap_test_skip_darwin[ \t]+"([^"]*)"')
raw_skip = re.compile(r'(?:^|\|\||;\s*|then\s+)\s*skip(?:[ \t]|$|;|")')
availability = re.compile(r"is not (available|installed) on this host$")
platform_words = re.compile(r"Darwin|platform|OSTYPE|uname|AP_TEST_PLATFORM_OS")

for current, _dirs, files in os.walk(root):
    for name in sorted(files):
        if not name.endswith(".bats"):
            continue
        path = os.path.join(current, name)
        relative = os.path.relpath(path, root)
        if relative == "01-package/platform-contract.bats":
            # This file defines the contract and carries the guard probe that
            # must skip on Darwin; the probe is asserted dynamically below.
            continue
        text = read(path)

        # No test may exclude a group of tests instead of naming a reason.
        if "--filter" in text:
            problems.append("%s: --filter excludes tests instead of naming a guard" % relative)
        if "skip_if" in text:
            problems.append("%s: skip_if hides the condition from the contract" % relative)

        setup_file = block_of(text, "setup_file() {")
        if setup_file and guard_call.search(setup_file):
            problems.append("%s: the guard belongs in setup(), not setup_file()" % relative)

        lines = text.splitlines()
        test_headers = [
            index for index, line in enumerate(lines) if line.startswith("@test ")
        ]

        def enclosing_test(index):
            owner = None
            for header in test_headers:
                if header <= index:
                    owner = header
            if owner is None:
                return ""
            return block_of(text, lines[owner])

        for index, line in enumerate(lines):
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped.startswith("@test "):
                continue
            if not raw_skip.search(line):
                continue
            remainder = line[raw_skip.search(line).end():].strip()
            reason = remainder.strip('"').strip("'").strip()
            if not reason:
                problems.append("%s:%d: reason-free skip" % (relative, index + 1))
                continue
            if platform_words.search(enclosing_test(index)):
                problems.append(
                    "%s:%d: platform condition outside the named guard"
                    % (relative, index + 1)
                )
                continue
            if platform_words.search(reason):
                problems.append(
                    "%s:%d: platform condition outside the named guard: %s"
                    % (relative, index + 1, reason)
                )
                continue
            if not availability.search(reason):
                problems.append(
                    "%s:%d: unnamed skip reason: %s" % (relative, index + 1, reason)
                )
                continue
            if "command -v " not in enclosing_test(index):
                problems.append(
                    "%s:%d: host-tool skip without an availability check"
                    % (relative, index + 1)
                )

        calls = guard_call.findall(text)
        if relative not in ALLOWED:
            if calls:
                problems.append("%s: Darwin skip outside the named allowlist" % relative)
            continue
        header, required = ALLOWED[relative]
        if len(calls) != 1:
            problems.append("%s: expected one named guard, found %d" % (relative, len(calls)))
            continue
        reason = calls[0]
        if not reason.startswith("Linux-only S"):
            problems.append("%s: reason must start with the seam id" % relative)
        if "Darwin" not in reason:
            problems.append("%s: reason must say why Darwin cannot run it" % relative)
        if len(reason) < 40:
            problems.append("%s: reason is too short to be useful" % relative)
        for word in required:
            if word not in reason:
                problems.append("%s: reason must name %s" % (relative, word))
        if guard_call.search(block_of(text, header)) is None:
            problems.append("%s: the guard does not cover its tests" % relative)

for relative in ALLOWED:
    if not os.path.isfile(os.path.join(root, relative)):
        problems.append("%s: guarded file disappeared" % relative)

print("\n".join(problems))
PY
  ); then
    echo "skip audit failed to run" >&2
    return 1
  fi
  if [[ -n "$violations" ]]; then
    printf 'platform contract violations:\n%s\n' "$violations" >&2
    return 1
  fi

  # Dynamic proof: the guard is inert on Linux, skips with the exact named
  # reason on Darwin, and refuses a missing reason.
  local probe="$TEST_TMPDIR/guard-probe.bats"
  cat >"$probe" <<PROBE
setup() {
  source "$AP_SUBJECT/tests/helpers/platform.bash"
}

@test "probe: the platform guard is inert on Linux and skips on Darwin" {
  ap_test_skip_darwin "Linux-only S3: probe of the mandatory-reason guard"
  printf 'guard-probe ran\n'
}

@test "probe: a missing reason is refused" {
  run ap_test_skip_darwin ""
  [[ "\$status" -eq 1 ]]
}
PROBE

  # A nested run goes through bats' real entry point. Inside a test, plain
  # `bats` resolves to libexec/bats-core/bats, which needs the exported
  # bats_readlinkf function; a parallel run starts each job through /bin/sh,
  # and dash on Linux drops exported functions.
  run env AP_TEST_PLATFORM_OS=Linux "$BATS_ROOT/bin/bats" --show-output-of-passing-tests "$probe"
  assert_success
  assert_output_contains "guard-probe ran"
  assert_output_not_contains "# skip"

  run env AP_TEST_PLATFORM_OS=Darwin "$BATS_ROOT/bin/bats" --show-output-of-passing-tests "$probe"
  assert_success
  assert_output_contains "# skip Linux-only S3: probe of the mandatory-reason guard"
  assert_output_not_contains "guard-probe ran"
}

@test "platform contract: Darwin suite executes with stock Bash 3.2" {
  local job
  job=$(macos_job) || return 1

  # Static contract: the macOS job puts the stock userland first and proves the
  # interpreter it selected, instead of inheriting whichever bash a package
  # manager happens to have installed.
  [[ "$job" == *'PATH="/usr/bin:/bin:'* ]] || {
    echo "macOS job does not put stock /usr/bin:/bin first on PATH" >&2
    return 1
  }
  [[ "$job" == *"command -v bash"* && "$job" == *'"/bin/bash"'* ]] || {
    echo "macOS job does not require bash to resolve to /bin/bash" >&2
    return 1
  }
  [[ "$job" == *"BASH_VERSINFO"* && "$job" == *'"3.2"'* ]] || {
    echo "macOS job does not assert Bash 3.2" >&2
    return 1
  }

  # No Homebrew bash may enter the test tier anywhere in the workflow.
  if grep -qE '/opt/homebrew|/usr/local/bin/bash|brew install' "$CI_WORKFLOW"; then
    echo "ci.yml selects a Homebrew bash" >&2
    return 1
  fi

  # Dynamic half. On Darwin this is the real assertion: the shell running the
  # suite must be the stock 3.2 /bin/bash. A Linux host cannot prove Bash 3.2 -
  # its own bash is 5.x - so there this half is a plan-backed no-op and the
  # static contract above is the whole check; the macOS job executes the same
  # test with the real interpreter.
  if [[ "$(ap_test_platform_os)" == "Darwin" ]]; then
    assert_equal "$(command -v bash)" "/bin/bash"
    assert_equal "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" "3.2"
    [[ "$BASH" == "/bin/bash" ]]
  else
    assert_equal "$(ap_test_platform_os)" "Linux"
    [[ "${BASH_VERSINFO[0]}" != "3" ]]
  fi
}
