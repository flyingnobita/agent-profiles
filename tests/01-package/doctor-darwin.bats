#!/usr/bin/env bats
# Darwin doctor diagnostics: platform qualification, Linux-only namespace
# checks reported as not_applicable, the shared macOS credential service, an
# lsof-based shared-port classification without procfs, and a portable Codex
# login probe.
#
# A Linux host cannot run Darwin, so these tests select the platform probe
# through the internal AP_TEST_PLATFORM_OS seam (see platform.sh) and stub the
# Darwin-only tools (sw_vers, lsof). The seam is honoured only inside the test
# suite and is not a supported user option, so a green run here proves branch
# selection and the diagnostic contract only. It is never evidence of stock
# macOS bash 3.2 or of a real Darwin host.
# shellcheck disable=SC2030,SC2031

setup() {
  load '../helpers/common.bash'
  load '../helpers/assert.bash'
  load '../helpers/fixtures.bash'
  load '../helpers/isolation.bash'
  setup_isolation

  STUB_BIN="$TEST_TMPDIR/darwin-bin"
  mkdir -p "$STUB_BIN"

  # Real uname, used for the flags the Darwin stub does not model.
  local real_uname
  real_uname=$(command -v uname)
  cat >"$STUB_BIN/uname" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  -s) printf '%s\n' "\${STUB_UNAME_S:-Darwin}" ;;
  -m) printf '%s\n' "\${STUB_UNAME_M:-arm64}" ;;
  *) exec "$real_uname" "\$@" ;;
esac
STUB
  chmod +x "$STUB_BIN/uname"

  cat >"$STUB_BIN/sw_vers" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -productVersion) printf '15.1.1\n' ;;
  -buildVersion) printf '24B91\n' ;;
  *) printf 'ProductName:\t\tmacOS\nProductVersion:\t\t15.1.1\nBuildVersion:\t\t24B91\n' ;;
esac
STUB
  chmod +x "$STUB_BIN/sw_vers"

  # A bwrap that records every invocation: Darwin must never run it. It stays
  # silent for the namespace probe, exactly like the real binary.
  cat >"$STUB_BIN/bwrap" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${AP_BWRAP_MARKER:-}" ]]; then
  : >"$AP_BWRAP_MARKER"
fi
case "${1:-}" in
  --version) printf 'bubblewrap 0.11.0\n' ;;
esac
exit 0
STUB
  chmod +x "$STUB_BIN/bwrap"
}

teardown() {
  teardown_isolation
}

@test "doctor darwin: arm64 is qualified and bwrap namespace checks are not applicable" {
  local repo="$TEST_TMPDIR/repo-doctor-darwin"
  create_fixture_repo "$repo"
  cd "$repo"

  local marker="$TEST_TMPDIR/bwrap-invoked"

  run env PATH="$STUB_BIN:$PATH" AP_TEST_PLATFORM_OS=Darwin AP_BWRAP_MARKER="$marker" \
    bash "$AP_HELPER" doctor --json
  assert_success

  # Darwin has no mounted or namespaced profile, so no bwrap probe may run even
  # though a bwrap binary is on PATH.
  [[ ! -e "$marker" ]]

  python3 - "$output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
os_info = data["os"]
assert os_info["name"] == "Darwin", os_info
assert os_info["arch"] == "arm64", os_info
assert "15.1.1" in os_info["distro"], os_info
assert os_info["status"] == "available", os_info
assert os_info["hint"] == "", os_info

checks = {c["id"]: c for c in data["checks"]}
for check_id in ("bwrap", "userns", "namespaces"):
    check = checks[check_id]
    # not_applicable is the truthful Darwin result, never available/missing.
    assert check["status"] == "not_applicable", check
    assert check["detail"], check
    assert check["status"] != "missing", check
PY

  # The qualification is visible in text mode as well.
  run env PATH="$STUB_BIN:$PATH" AP_TEST_PLATFORM_OS=Darwin bash "$AP_HELPER" doctor
  assert_success
  assert_output_contains "System: Darwin (macOS 15.1.1)"
  assert_output_contains "Architecture: arm64"
  assert_output_contains "Status: available"

  # Non-arm64 Darwin stays unqualified.
  run env PATH="$STUB_BIN:$PATH" AP_TEST_PLATFORM_OS=Darwin STUB_UNAME_M=x86_64 \
    bash "$AP_HELPER" doctor --json
  assert_success
  python3 - "$output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
os_info = data["os"]
assert os_info["arch"] == "x86_64", os_info
assert os_info["status"] == "warning", os_info
assert "arm64" in os_info["hint"], os_info
checks = {c["id"]: c for c in data["checks"]}
assert checks["bwrap"]["status"] == "not_applicable", checks["bwrap"]
assert checks["namespaces"]["status"] == "not_applicable", checks["namespaces"]
PY

  # Any other operating system stays unqualified with a Linux hint.
  run env PATH="$STUB_BIN:$PATH" AP_TEST_PLATFORM_OS=FreeBSD STUB_UNAME_S=FreeBSD \
    STUB_UNAME_M=x86_64 bash "$AP_HELPER" doctor --json
  assert_success
  python3 - "$output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
os_info = data["os"]
assert os_info["name"] == "FreeBSD", os_info
assert os_info["status"] == "warning", os_info
assert "Linux" in os_info["hint"], os_info
PY
}
