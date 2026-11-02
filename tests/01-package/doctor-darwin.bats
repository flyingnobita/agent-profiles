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

setup_file() {
  # A PATH that holds every host command except GNU timeout: the Codex login
  # probe must work with the portable platform timeout only.
  NO_TIMEOUT_BIN="$BATS_FILE_TMPDIR/no-timeout-bin"
  mkdir -p "$NO_TIMEOUT_BIN"

  local dir tool name
  local old_ifs="$IFS"
  IFS=':'
  for dir in $PATH; do
    IFS="$old_ifs"
    [[ -d "$dir" ]] || continue
    for tool in "$dir"/*; do
      [[ -x "$tool" && ! -d "$tool" ]] || continue
      name="$(basename "$tool")"
      [[ "$name" == "timeout" ]] && continue
      [[ -e "$NO_TIMEOUT_BIN/$name" ]] && continue
      ln -s "$tool" "$NO_TIMEOUT_BIN/$name" 2>/dev/null || true
    done
  done
  IFS="$old_ifs"

  export NO_TIMEOUT_BIN
}

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

# hash_tree <dir>: stable content hash of every file under <dir>, so a test can
# prove a profile or host tree is byte-identical across a read-only probe.
hash_tree() {
  python3 - "$1" <<'PY'
import hashlib
import os
import sys

root = sys.argv[1]
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        print(digest, os.path.relpath(path, root))
PY
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

@test "doctor darwin: agy reports shared Keychain without D-Bus or credential values" {
  local repo="$TEST_TMPDIR/repo-doctor-darwin-agy"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile agy-darwin
  assert_success

  local prof_dir="$repo/.agent-profiles/agy-darwin"
  mkdir -p "$prof_dir/.gemini/antigravity-cli"
  printf '{"token":"host-agy-credential-marker-805"}\n' \
    >"$prof_dir/.gemini/antigravity-cli/oauth_creds.json"

  # A synthetic agent binary, and a dbus-send that records any use: Darwin
  # reports the shared Keychain without addressing a D-Bus session bus.
  cat >"$STUB_BIN/agy" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf '1.4.9\n'
fi
exit 0
STUB
  chmod +x "$STUB_BIN/agy"
  cat >"$STUB_BIN/dbus-send" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${AP_DBUS_MARKER:-}" ]]; then
  : >"$AP_DBUS_MARKER"
fi
exit 1
STUB
  chmod +x "$STUB_BIN/dbus-send"

  local marker="$TEST_TMPDIR/dbus-invoked"
  local no_bus="$TEST_TMPDIR/no-bus"
  mkdir -p "$no_bus"

  run env PATH="$STUB_BIN:$PATH" AP_TEST_PLATFORM_OS=Darwin \
    AP_DBUS_MARKER="$marker" XDG_RUNTIME_DIR="$no_bus" \
    env -u DBUS_SESSION_BUS_ADDRESS bash "$AP_HELPER" doctor --json --agent agy --profile agy-darwin
  assert_success

  # No D-Bus query was attempted on Darwin.
  [[ ! -e "$marker" ]]
  assert_output_not_contains "host-agy-credential-marker-805"

  python3 - "$output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["agy"]["profile"]
assert profile["status"] == "initialized", profile

auth = profile["auth"]
# A shared OS credential service is reported, never treated as authentication.
assert auth["authenticated"] is None, auth
assert auth["status"] == "profile_credential_files", auth
service = auth["os_credential_service"]
assert service["status"] == "present", service
detail = service["detail"]
assert "Keychain" in detail, detail
# Darwin never depends on D-Bus, and the absent bus is not the answer.
assert "D-Bus" not in detail and "dbus" not in detail.lower(), detail
shared = profile["shared"]
assert shared["session_bus"] is False, shared
assert shared["os_credential_service"] == "present", shared
PY
}

@test "doctor darwin: opencode classifies a test-owned listener without procfs" {
  local repo="$TEST_TMPDIR/repo-doctor-darwin-port"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile port-darwin
  assert_success

  local port
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  python3 - "$port" "$TEST_TMPDIR/listener.ready" <<'PY' &
import socket
import sys
import time

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", int(sys.argv[1])))
sock.listen(1)
open(sys.argv[2], "w").close()
time.sleep(20)
PY
  local listener_pid=$!
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -f "$TEST_TMPDIR/listener.ready" ]] && break
    sleep 0.1
  done

  # Real platform: /proc on Linux, lsof on Darwin, so this part is a guard that
  # the classification itself is not weakened.
  run env AP_OPENCODE_SERVICE_PORT="$port" \
    bash "$AP_HELPER" doctor --json --agent opencode --profile port-darwin
  local real_output="$output"
  assert_success
  python3 - "$real_output" "$port" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
service = data["agents"]["opencode"]["profile"]["shared"]["background_service_port"]
assert service["port"] == int(sys.argv[2]), service
assert service["status"] == "listening", service
PY

  # Darwin stand-in for lsof: a read-only socket check of the requested port,
  # with lsof's exit codes (0 found, 1 no match). No procfs is consulted.
  cat >"$STUB_BIN/lsof" <<'STUB'
#!/usr/bin/env bash
port=""
for arg in "$@"; do
  case "$arg" in
    -iTCP:*) port="${arg#-iTCP:}" ;;
  esac
done
if [[ -z "$port" ]]; then
  exit 2
fi
python3 - "$port" <<'PY'
import socket
import sys

sock = socket.socket()
sock.settimeout(1.0)
try:
    sock.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
print(f"opencode {sys.argv[1]} (LISTEN)")
PY
STUB
  chmod +x "$STUB_BIN/lsof"

  run env PATH="$STUB_BIN:$PATH" AP_TEST_PLATFORM_OS=Darwin AP_OPENCODE_SERVICE_PORT="$port" \
    bash "$AP_HELPER" doctor --json --agent opencode --profile port-darwin
  local darwin_output="$output"
  assert_success
  python3 - "$darwin_output" "$port" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
service = data["agents"]["opencode"]["profile"]["shared"]["background_service_port"]
assert service["port"] == int(sys.argv[2]), service
assert service["status"] == "listening", service
assert "lsof" in service["detail"], service
PY

  # A probe that fails is unverified, never not_listening: a silent socket
  # inspection must not be reported as "no shared service".
  cat >"$STUB_BIN/lsof" <<'STUB'
#!/usr/bin/env bash
printf 'lsof: cannot inspect the socket table\n' >&2
exit 2
STUB
  chmod +x "$STUB_BIN/lsof"

  run env PATH="$STUB_BIN:$PATH" AP_TEST_PLATFORM_OS=Darwin AP_OPENCODE_SERVICE_PORT="$port" \
    bash "$AP_HELPER" doctor --json --agent opencode --profile port-darwin
  local failed_output="$output"
  assert_success
  python3 - "$failed_output" "$port" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
service = data["agents"]["opencode"]["profile"]["shared"]["background_service_port"]
assert service["port"] == int(sys.argv[2]), service
assert service["status"] == "unverified", service
assert service["status"] != "not_listening", service
assert service["detail"], service
PY

  kill "$listener_pid" 2>/dev/null || true
  wait "$listener_pid" 2>/dev/null || true
}

@test "doctor darwin: opencode separates a real no-listener result from an incomplete lsof" {
  local repo="$TEST_TMPDIR/repo-doctor-darwin-port-complete"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile port-complete
  assert_success

  # lsof exits 1 both when no socket matched and when it could not list at all,
  # so the classification needs a completeness probe: lsof must be able to
  # describe this inspector's own process before an empty result is trusted.
  # LSOF_STUB_MODE selects which of the two exit-1 meanings the stub reports.
  cat >"$STUB_BIN/lsof" <<'STUB'
#!/usr/bin/env bash
mode="${LSOF_STUB_MODE:-complete}"
wants_pid=0
for arg in "$@"; do
  if [[ "$wants_pid" -eq 1 ]]; then
    pid="$arg"
    wants_pid=0
    continue
  fi
  case "$arg" in
    -p) wants_pid=1 ;;
    -iTCP:*) want_port="${arg#-iTCP:}" ;;
  esac
done
if [[ -n "${pid:-}" ]]; then
  if [[ "$mode" == "incomplete" ]]; then
    printf 'lsof: WARNING: can not access file system\n' >&2
    exit 1
  fi
  printf 'p%s\n' "$pid"
  exit 0
fi
# No listening socket on the requested port.
[[ -n "${want_port:-}" ]]
exit 1
STUB
  chmod +x "$STUB_BIN/lsof"

  # A complete lsof that matched no socket is a real "no listener".
  run env PATH="$STUB_BIN:$PATH" AP_TEST_PLATFORM_OS=Darwin LSOF_STUB_MODE=complete \
    AP_OPENCODE_SERVICE_PORT=49374 bash "$AP_HELPER" doctor --json --agent opencode --profile port-complete
  local complete_output="$output"
  assert_success
  python3 - "$complete_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
service = data["agents"]["opencode"]["profile"]["shared"]["background_service_port"]
assert service["port"] == 49374, service
assert service["status"] == "not_listening", service
assert service["detail"], service
PY

  # The same exit status from an lsof that cannot list its own process is an
  # unverified probe, never "no shared service".
  run env PATH="$STUB_BIN:$PATH" AP_TEST_PLATFORM_OS=Darwin LSOF_STUB_MODE=incomplete \
    AP_OPENCODE_SERVICE_PORT=49374 bash "$AP_HELPER" doctor --json --agent opencode --profile port-complete
  local incomplete_output="$output"
  assert_success
  python3 - "$incomplete_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
service = data["agents"]["opencode"]["profile"]["shared"]["background_service_port"]
assert service["port"] == 49374, service
assert service["status"] == "unverified", service
assert service["status"] != "not_listening", service
assert service["detail"], service
PY
}

@test "doctor darwin: codex login probe uses portable timeout and disposable snapshot" {
  local repo="$TEST_TMPDIR/repo-doctor-darwin-codex"
  create_fixture_repo "$repo"
  cd "$repo"

  run bash "$AP_HELPER" init --profile codex-darwin
  assert_success

  local codex_dir="$repo/.agent-profiles/codex-darwin/.codex"
  printf '{"token":"host-codex-login-marker-906"}\n' >"$codex_dir/auth.json"
  printf 'model = "synthetic"\n' >"$codex_dir/config.toml"

  local mode_file="$TEST_TMPDIR/codex-mode"
  local home_log="$TEST_TMPDIR/codex-probe-homes"
  printf 'logged_in\n' >"$mode_file"
  : >"$home_log"

  cat >"$STUB_BIN/codex" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  printf 'codex-cli 0.165.0\n'
  exit 0
fi
if [[ "\${1:-}" == "login" && "\${2:-}" == "status" ]]; then
  # The snapshot the doctor hands the probe must be disposable, never the
  # profile's own config directory.
  printf '%s\n' "\${CODEX_HOME:-}" >>"$home_log"
  case "\$(cat "$mode_file" 2>/dev/null || printf 'logged_in')" in
    hang)
      sleep 10
      exit 0
      ;;
    logged_out)
      printf 'Not logged in\n'
      exit 1
      ;;
    *)
      printf 'Logged in using ChatGPT\n'
      if [[ -f "\${CODEX_HOME:-}/auth.json" ]]; then
        cat "\${CODEX_HOME}/auth.json"
      fi
      exit 0
      ;;
  esac
fi
exit 0
STUB
  chmod +x "$STUB_BIN/codex"

  # GNU timeout is genuinely unavailable in the PATH used below.
  run env PATH="$STUB_BIN:$NO_TIMEOUT_BIN" bash -c 'command -v timeout'
  assert_failure

  local before
  before=$(hash_tree "$codex_dir")

  run env PATH="$STUB_BIN:$NO_TIMEOUT_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" doctor --json --agent codex --profile codex-darwin
  local reported_output="$output"
  assert_success
  assert_output_not_contains "host-codex-login-marker-906"
  python3 - "$reported_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
auth = data["agents"]["codex"]["profile"]["auth"]
assert auth["status"] == "login_reported", auth
assert auth["logged_in"] is None, "a status report must not mean authenticated"
assert auth["probe_exit"] == 0, auth
assert "not validated" in auth["detail"], auth
PY

  # A reported logout stays a reported logout.
  printf 'logged_out\n' >"$mode_file"
  run env PATH="$STUB_BIN:$NO_TIMEOUT_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" doctor --json --agent codex --profile codex-darwin
  local logged_out_output="$output"
  assert_success
  python3 - "$logged_out_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
auth = data["agents"]["codex"]["profile"]["auth"]
assert auth["status"] == "logged_out", auth
assert auth["logged_in"] is False, auth
assert auth["probe_exit"] == 1, auth
PY

  # A hanging probe is a portable timeout, not a failure and not a login.
  printf 'hang\n' >"$mode_file"
  run env PATH="$STUB_BIN:$NO_TIMEOUT_BIN" AP_TEST_PLATFORM_OS=Darwin \
    bash "$AP_HELPER" doctor --json --agent codex --profile codex-darwin
  local hang_output="$output"
  assert_success
  python3 - "$hang_output" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
auth = data["agents"]["codex"]["profile"]["auth"]
assert auth["status"] == "unverified", auth
assert auth["logged_in"] is None, auth
assert auth["probe_exit"] == 124, auth
assert "timed out" in auth["detail"], auth
PY

  # The probe only read a disposable snapshot: the profile is byte-identical
  # and every snapshot directory is gone.
  assert_equal "$(hash_tree "$codex_dir")" "$before"
  local snapshot
  while IFS= read -r snapshot; do
    [[ -n "$snapshot" ]] || continue
    [[ "$snapshot" != "$codex_dir" ]]
    [[ ! -e "$snapshot" ]] || {
      echo "snapshot directory was not removed: $snapshot" >&2
      false
    }
  done <"$home_log"
}
