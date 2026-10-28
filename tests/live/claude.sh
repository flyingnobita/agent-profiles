#!/usr/bin/env bash
# Offline live QA for Claude Code inside agent profiles (ticket 04).
#
# AP_EVIDENCE_DIR=<private dir> bash tests/live/claude.sh
#
# Uses a disposable synthetic HOME and Git checkout. Host agent configuration,
# credentials and sessions are never read or written. The only host path read
# is the installed Claude Code binary directory, bind-mounted read-only into the
# synthetic HOME so the host's mise command-wrapper can resolve its launcher.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/live/lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=tests/live/claude-cleanup.sh
source "$SCRIPT_DIR/claude-cleanup.sh"

usage() {
  cat <<'EOF'
Usage: AP_EVIDENCE_DIR=<private dir> bash tests/live/claude.sh

Runs offline Claude Code integration QA in disposable directories and writes raw
logs to $AP_EVIDENCE_DIR/claude-<timestamp>/. Requires the installed claude CLI,
git, python3, bubblewrap, inotifywait and util-linux script(1).
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

EVIDENCE_ROOT="${AP_EVIDENCE_DIR:-}"
if [[ -z "$EVIDENCE_ROOT" ]]; then
  echo "claude live: AP_EVIDENCE_DIR is required" >&2
  usage >&2
  exit 64
fi

for cmd in claude git python3 bwrap inotifywait script timeout; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "claude live: required command '$cmd' is not available" >&2
    exit 69
  fi
done

umask 077
mkdir -p "$EVIDENCE_ROOT"
chmod 700 "$EVIDENCE_ROOT" 2>/dev/null || true
OUT="$EVIDENCE_ROOT/claude-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$OUT"
QA_START_TICKS="$(ap_claude_qa_uptime_ticks)"
QA_BOOT_ID="$(ap_claude_qa_boot_id)"

HOST_HOME="$HOME"
HOST_CLAUDE_DIR="$HOST_HOME/.local/share/claude"
QA_KEY="placeholder-not-a-real-key"
WORK="$(mktemp -d /tmp/ap-claude-live-XXXXXX)"
BG_ID=""
WATCH_PID=""
QA_PROFILE_DIR=""
FAILURES=0
CHECKS_JSON="[]"

fail_check() {
  local id="$1" detail="$2"
  FAILURES=$((FAILURES + 1))
  printf 'claude live: FAIL %s: %s\n' "$id" "$detail" >&2
  CHECKS_JSON=$(python3 -c '
import json, sys
items = json.loads(sys.argv[1])
items.append({"id": sys.argv[2], "status": "fail", "detail": sys.argv[3]})
print(json.dumps(items))
' "$CHECKS_JSON" "$id" "$detail")
}

pass_check() {
  local id="$1" detail="$2"
  printf 'claude live: PASS %s: %s\n' "$id" "$detail"
  CHECKS_JSON=$(python3 -c '
import json, sys
items = json.loads(sys.argv[1])
items.append({"id": sys.argv[2], "status": "pass", "detail": sys.argv[3]})
print(json.dumps(items))
' "$CHECKS_JSON" "$id" "$detail")
}

stop_background_session() {
  [[ -n "$BG_ID" ]] || return 0
  ap_run_profile a claude stop "$BG_ID" >"$OUT/background-stop.txt" 2>&1 || true
  BG_ID=""
}

# Owned QA processes are identified by the disposable profile environment and
# their start-time identity in tests/live/claude-cleanup.sh. argv and cwd are
# not ownership evidence, so a scanner cannot detect itself.
stop_test_processes() {
  ap_claude_qa_cleanup "$QA_PROFILE_DIR" "$QA_START_TICKS" "$QA_BOOT_ID" \
    >>"$OUT/daemons-stopped.txt" 2>/dev/null || true
}

cleanup() {
  if [[ -n "$WATCH_PID" ]]; then
    kill "$WATCH_PID" 2>/dev/null || true
    WATCH_PID=""
  fi
  stop_background_session
  stop_test_processes
  rm -rf "$WORK"
  rm -f "${DENIED:-}"
}
trap cleanup EXIT

# --- disposable synthetic host and checkout -------------------------------
ap_live_setup_isolation "$WORK/iso"
SYNTH_HOME="$HOME"
ap_live_create_synthetic_home "$SYNTH_HOME"
mkdir -p "$SYNTH_HOME/.local/share/claude"

cat >"$SYNTH_HOME/.claude.json" <<'JSON'
{
  "numStartups": 1,
  "syntheticMarker": "claude-host-safe",
  "mcpServers": {
    "host-marker-mcp": {"command": "/bin/true", "args": []}
  }
}
JSON
cat >"$SYNTH_HOME/.claude/settings.json" <<'JSON'
{
  "marker": "host-settings-marker",
  "mcpServers": {"host-settings-mcp": {"command": "/bin/true"}}
}
JSON
mkdir -p "$SYNTH_HOME/.claude/skills/host-marker-skill"
cat >"$SYNTH_HOME/.claude/skills/host-marker-skill/SKILL.md" <<'MD'
---
name: host-marker-skill
description: synthetic host skill marker
---
synthetic host marker skill
MD
printf '{"marker":"synthetic-host-credential"}\n' >"$SYNTH_HOME/.claude/.credentials.json"
chmod 600 "$SYNTH_HOME/.claude/.credentials.json"

HOST_MARKERS=(
  "$SYNTH_HOME/.claude.json"
  "$SYNTH_HOME/.claude/settings.json"
  "$SYNTH_HOME/.claude/skills/host-marker-skill/SKILL.md"
  "$SYNTH_HOME/.claude/.credentials.json"
)
marker_hashes() {
  local file
  for file in "${HOST_MARKERS[@]}"; do
    sha256sum "$file"
  done
}
marker_hashes >"$OUT/host-markers.before"

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Live QA"
git -C "$REPO" config user.email "live-qa@example.invalid"
git -C "$REPO" config commit.gpgsign false
: >"$REPO/.gitkeep"
git -C "$REPO" add .gitkeep
git -C "$REPO" commit -q -m "initial commit"

HELPER="$ROOT_DIR/skills/flyingnobita-agent-profiles/scripts/agent-profiles"
if [[ ! -f "$HELPER" ]]; then
  echo "claude live: helper not found at $HELPER" >&2
  exit 66
fi

cd "$REPO" || exit 66
for profile in a b; do
  bash "$HELPER" init --profile "$profile" >"$OUT/init-$profile.txt" 2>&1 || {
    echo "claude live: profile $profile initialization failed" >&2
    exit 1
  }
  mkdir -p "$REPO/.agent-profiles/$profile/.claude/skills/$profile-marker"
  cat >"$REPO/.agent-profiles/$profile/.claude/skills/$profile-marker/SKILL.md" <<MD
---
name: $profile-marker
description: $profile profile marker skill
---
$profile profile marker skill
MD
  printf '{"marker":"%s-settings"}\n' "$profile" >"$REPO/.agent-profiles/$profile/.claude/settings.json"
done

QA_PROFILE_DIR="$REPO/.agent-profiles/a"

# Profile a is pre-trusted so the sandbox check reaches the composer without a
# human. It also carries a user-scope MCP marker for discovery.
python3 - "$REPO/.agent-profiles/a/.claude/.claude.json" "$REPO" <<'PY'
import json, sys
path, repo = sys.argv[1], sys.argv[2]
data = {
    "hasCompletedOnboarding": True,
    "theme": "dark",
    "projects": {repo: {"hasTrustDialogAccepted": True}},
    "mcpServers": {"profile-a-mcp": {"command": "/bin/true", "args": []}},
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
PY
cat >"$REPO/.agent-profiles/a/.claude/settings.json" <<'JSON'
{
  "marker": "a-settings",
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false
  }
}
JSON

# --- profile runner ------------------------------------------------------
BASE_PATH="$PATH"

ap_run_profile() {
  local profile="$1"
  shift
  local env_args=(
    PATH="$BASE_PATH"
    HOME="$SYNTH_HOME"
    USER="${USER:-live-qa}"
    LOGNAME="${LOGNAME:-live-qa}"
    TERM="dumb"
    LANG="${LANG:-C.UTF-8}"
    DISABLE_TELEMETRY=1
    XDG_CONFIG_HOME="$SYNTH_HOME/.config"
    XDG_DATA_HOME="$SYNTH_HOME/.local/share"
    XDG_STATE_HOME="$SYNTH_HOME/.local/state"
    XDG_CACHE_HOME="$SYNTH_HOME/.cache"
  )
  [[ -n "${MISE_CONFIG_DIR:-}" ]] && env_args+=(MISE_CONFIG_DIR="$MISE_CONFIG_DIR")
  [[ -n "${MISE_DATA_DIR:-}" ]] && env_args+=(MISE_DATA_DIR="$MISE_DATA_DIR")
  [[ -n "${MISE_STATE_DIR:-}" ]] && env_args+=(MISE_STATE_DIR="$MISE_STATE_DIR")
  [[ -n "${MISE_CACHE_DIR:-}" ]] && env_args+=(MISE_CACHE_DIR="$MISE_CACHE_DIR")

  local bwrap_args=(--dev-bind / /)
  if [[ -d "$HOST_CLAUDE_DIR" ]]; then
    bwrap_args+=(--ro-bind "$HOST_CLAUDE_DIR" "$SYNTH_HOME/.local/share/claude")
  fi
  bwrap_args+=(--unshare-net --)

  env -i "${env_args[@]}" bwrap "${bwrap_args[@]}" \
    bash "$HELPER" run --profile "$profile" -- "$@"
}

write_exec_script() {
  local target="$1"
  local -a gen_env=(
    PATH "$BASE_PATH"
    HOME "$SYNTH_HOME"
    USER "${USER:-live-qa}"
    LOGNAME "${LOGNAME:-live-qa}"
    TERM "xterm-256color"
    LANG "${LANG:-C.UTF-8}"
    DISABLE_TELEMETRY "1"
    XDG_CONFIG_HOME "$SYNTH_HOME/.config"
    XDG_DATA_HOME "$SYNTH_HOME/.local/share"
    XDG_STATE_HOME "$SYNTH_HOME/.local/state"
    XDG_CACHE_HOME "$SYNTH_HOME/.cache"
  )
  local var
  for var in MISE_CONFIG_DIR MISE_DATA_DIR MISE_STATE_DIR MISE_CACHE_DIR; do
    if [[ -n "${!var:-}" ]]; then
      gen_env+=("$var" "${!var}")
    fi
  done

  {
    printf '#!/usr/bin/env bash\n'
    printf 'env_args=(\n'
    local i=0
    while [[ "$i" -lt "${#gen_env[@]}" ]]; do
      printf '  %s=%q\n' "${gen_env[i]}" "${gen_env[i + 1]}"
      i=$((i + 2))
    done
    printf ')\n'
    printf 'bwrap_args=(--dev-bind / /)\n'
    if [[ -d "$HOST_CLAUDE_DIR" ]]; then
      printf 'bwrap_args+=(--ro-bind %q %q)\n' "$HOST_CLAUDE_DIR" "$SYNTH_HOME/.local/share/claude"
    fi
    printf 'bwrap_args+=(--unshare-net --)\n'
    # shellcheck disable=SC2016 # runtime expansion in the generated script
    printf 'exec env -i "${env_args[@]}" bwrap "${bwrap_args[@]}" bash %q run --profile "$1" -- "${@:2}"\n' "$HELPER"
  } >"$target"
  chmod 700 "$target"
}

EXEC="$WORK/exec-profile.sh"
write_exec_script "$EXEC"

# --- evidence: version ---------------------------------------------------
if ap_run_profile a claude --version >"$OUT/version.txt" 2>&1; then
  VERSION=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$OUT/version.txt" | head -n 1)
  pass_check version "resolved Claude Code $VERSION through the mise wrapper"
else
  VERSION=""
  fail_check version "claude --version failed"
fi

# --- evidence: auth ------------------------------------------------------
for profile in a b; do
  set +e
  ap_run_profile "$profile" claude auth status >"$OUT/auth-$profile.json" 2>&1
  AUTH_RC=$?
  set -e
  if python3 - "$OUT/auth-$profile.json" "$AUTH_RC" <<'PY'
import json, sys
path, rc = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as handle:
    text = handle.read()
try:
    data = json.loads(text)
except Exception:
    sys.exit(1)
if data.get("loggedIn") is not False or data.get("authMethod") != "none":
    sys.exit(1)
if not data.get("configDirectory", "").endswith("/.agent-profiles/%s/.claude" % ("a" if "auth-a" in path else "b")):
    sys.exit(1)
if rc not in (0, 1):
    sys.exit(1)
PY
  then
    pass_check "auth-$profile" "fresh profile reports loggedIn=false, authMethod=none, profile config directory"
  else
    fail_check "auth-$profile" "fresh profile auth state was not the expected logged-out profile state"
  fi
done

set +e
ap_run_profile a env ANTHROPIC_API_KEY=placeholder-not-a-real-key claude auth status >"$OUT/auth-env.json" 2>&1
set -e
if python3 - "$OUT/auth-env.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if data.get("loggedIn") is True and data.get("authMethod") == "api_key" and data.get("apiKeySource") == "ANTHROPIC_API_KEY" else 1)
PY
then
  pass_check auth-env "inherited placeholder API key is classified as environment-provided without exposing its value"
else
  fail_check auth-env "environment API key classification did not match claude auth status"
fi

# --- evidence: discovery, host isolation, startup ------------------------
INOTIFY_LOG="$OUT/inotify.log"
: >"$INOTIFY_LOG"
inotifywait -m -q -e access,open,modify,create,delete,moved_to,moved_from,attrib \
  "${HOST_MARKERS[@]}" >>"$INOTIFY_LOG" 2>&1 &
WATCH_PID=$!
sleep 1

ap_run_profile a claude mcp list >"$OUT/mcp-a.txt" 2>&1 || true
ap_run_profile b claude mcp list >"$OUT/mcp-b.txt" 2>&1 || true

for profile in a b; do
  ap_run_profile "$profile" bash -c \
    'ANTHROPIC_API_KEY=placeholder-not-a-real-key timeout 25 claude -p --output-format stream-json --verbose "startup probe" 2>/dev/null | head -n 1' \
    >"$OUT/init-$profile.json" 2>"$OUT/init-$profile.err" || true
done

# TUI startup on the un-seeded profile reaches the onboarding theme picker.
{
  sleep 6
  printf '\003'
  sleep 1
  printf '\003'
} \
  | timeout 25 script -qfc "$EXEC b claude --ax-screen-reader" /dev/null \
    >"$OUT/startup-tui.txt" 2>&1 || true

kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""

if [[ -s "$INOTIFY_LOG" ]]; then
  fail_check inotify "synthetic host configuration paths were accessed: $(tr '\n' ' ' <"$INOTIFY_LOG" | cut -c1-300)"
else
  pass_check inotify "no synthetic host configuration or credential file was read"
fi

if grep -q "host-marker-mcp\|host-settings-mcp\|host-marker-skill" "$OUT/mcp-a.txt" "$OUT/mcp-b.txt" "$OUT/init-a.json" "$OUT/init-b.json" 2>/dev/null; then
  fail_check host-mcp "a synthetic host MCP server or skill marker appeared in the selected profile"
else
  pass_check host-mcp "synthetic host MCP/settings/skill markers were not imported"
fi

if grep -q "profile-a-mcp" "$OUT/mcp-a.txt" && ! grep -q "profile-a-mcp" "$OUT/mcp-b.txt"; then
  pass_check discovery-mcp "profile-scoped user MCP marker appears only in profile a"
else
  fail_check discovery-mcp "profile-scoped MCP marker was not isolated to profile a"
fi

if python3 - "$OUT/init-a.json" "$OUT/init-b.json" <<'PY'
import json, sys
a = json.loads(open(sys.argv[1], encoding="utf-8").readline())
b = json.loads(open(sys.argv[2], encoding="utf-8").readline())
if a.get("subtype") != "init" or b.get("subtype") != "init":
    sys.exit(1)
if "a-marker" not in a.get("skills", []) or "b-marker" in a.get("skills", []):
    sys.exit(1)
if "b-marker" not in b.get("skills", []) or "a-marker" in b.get("skills", []):
    sys.exit(1)
if any(s.get("name") == "host-marker-mcp" for s in a.get("mcp_servers", [])):
    sys.exit(1)
plugins = {p.get("name") for p in a.get("plugins", [])}
if not {"cc-plugin-agents-md", "cc-plugin-plugin-authoring"} <= plugins:
    sys.exit(1)
PY
then
  pass_check discovery-skills "headless init events expose only the selected profile marker skill; bundled plugins remain recorded"
else
  fail_check discovery-skills "profile marker skills or bundled plugin inventory did not match"
fi

TUI_BANNER=0
grep -q "Welcome to Claude Code" "$OUT/startup-tui.txt" && TUI_BANNER=1
if python3 - "$OUT/init-b.json" <<'PY'
import json, sys
try:
    data = json.loads(open(sys.argv[1], encoding="utf-8").readline())
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("type") == "system" and data.get("subtype") == "init" else 1)
PY
then
  if [[ "$TUI_BANNER" -eq 1 ]]; then
    pass_check startup "headless init event reached; TUI printed the startup banner before the offline connection check"
  else
    pass_check startup "headless init event reached (TUI banner not captured)"
  fi
else
  fail_check startup "no startup init event was observed"
fi

# --- evidence: sandbox ---------------------------------------------------
ap_run_profile a claude sandbox status >"$OUT/sandbox-status.json" 2>&1 || true
if python3 - "$OUT/sandbox-status.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if data.get("enabled") is True and data.get("strictMode") is True else 1)
PY
then
  pass_check sandbox-status "sandbox reports enabled and strict from profile settings"
else
  fail_check sandbox-status "sandbox status did not report enabled strict mode"
fi

DENIED="$HOST_HOME/.cache/ap04-claude-live-deny.txt"
ALLOWED="$REPO/sandbox-allowed.txt"
rm -f "$DENIED" "$ALLOWED"
cat >"$WORK/sandbox-driver.py" <<'PY'
import fcntl
import json
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time

exec_script, bg_id, denied, allowed, log_path = sys.argv[1:6]
master, slave = pty.openpty()
fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
proc = subprocess.Popen(
    [
        exec_script,
        "a",
        "env",
        "ANTHROPIC_API_KEY=placeholder-not-a-real-key",
        "claude",
        "attach",
        bg_id,
    ],
    stdin=slave,
    stdout=slave,
    stderr=slave,
    start_new_session=True,
    close_fds=True,
)
os.close(slave)
data = bytearray()
log = open(log_path, "wb", buffering=0)


def pump(seconds, patterns):
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([master], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            data.extend(chunk)
            log.write(chunk)
        for pattern in patterns:
            if pattern in bytes(data):
                return True
    return False


ready = pump(40, [b"mode on", "\u276f".encode()])
time.sleep(1.5)
os.write(master, ("! touch %s\r" % denied).encode())
denied_seen = pump(25, [b"Read-only file system", b"Operation not permitted"])
time.sleep(1.5)
os.write(master, ("! touch %s\r" % allowed).encode())
time.sleep(8)
os.write(master, b"\x03")
time.sleep(0.7)
os.write(master, b"\x03")
time.sleep(0.7)
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
os.close(master)
log.close()
print(json.dumps({"ready": ready, "denied_seen": denied_seen}))
PY
BG_OUT=$(ap_run_profile a env ANTHROPIC_API_KEY="$QA_KEY" claude --bg 2>&1)
printf '%s\n' "$BG_OUT" >"$OUT/background-start.txt"
BG_ID=$(printf '%s' "$BG_OUT" | grep -oE 'backgrounded · [0-9a-f]+' | awk '{print $3}')
if [[ -n "$BG_ID" ]]; then
  timeout 90 python3 "$WORK/sandbox-driver.py" "$EXEC" "$BG_ID" "$DENIED" "$ALLOWED" \
    "$OUT/sandbox-attach.txt" >"$OUT/sandbox-driver.json" 2>&1 || true
  if [[ ! -e "$DENIED" ]] && [[ -e "$ALLOWED" ]] && grep -q "Read-only file system" "$OUT/sandbox-attach.txt"; then
    pass_check sandbox-enforcement "strict background shell-mode command was denied a controlled write outside the workspace and allowed one inside"
  else
    fail_check sandbox-enforcement "sandboxed shell-mode write denial was not observed with the expected files"
  fi
  stop_background_session
  stop_test_processes
else
  fail_check sandbox-enforcement "could not start an idle background session for the shell-mode sandbox check"
fi

# --- evidence: host unchanged and cleanup -------------------------------
marker_hashes >"$OUT/host-markers.after"
if cmp -s "$OUT/host-markers.before" "$OUT/host-markers.after"; then
  pass_check host-unchanged "synthetic host marker hashes are unchanged"
else
  fail_check host-unchanged "synthetic host marker files changed during QA"
fi

if [[ -f "$REPO/.agent-profiles/a/.claude/.credentials.json" ]]; then
  fail_check no-credential-copy "a credentials file appeared inside the disposable profile"
else
  pass_check no-credential-copy "no host credential file was copied or linked into the profile"
fi

STOPPED_SESSION=0
if grep -q "^stopped " "$OUT/background-stop.txt" 2>/dev/null; then
  STOPPED_SESSION=1
fi
DAEMONS_LEFT="$(ap_claude_qa_owned_pids "$QA_PROFILE_DIR" "$QA_START_TICKS" "$QA_BOOT_ID")"
if [[ "$STOPPED_SESSION" -eq 1 && -z "$DAEMONS_LEFT" ]]; then
  pass_check cleanup "test-owned background session and transient daemon were stopped"
elif [[ "$STOPPED_SESSION" -ne 1 ]]; then
  fail_check cleanup "the test-owned background session stop was not confirmed"
else
  printf '%s\n' "$DAEMONS_LEFT" >"$OUT/processes-left.txt" 2>/dev/null || true
  fail_check cleanup "test-owned daemon(s) remain: $DAEMONS_LEFT"
fi

python3 - "$OUT/summary.json" "$VERSION" "$FAILURES" "$CHECKS_JSON" "$OUT" <<'PY'
import json, sys
out, version, failures, checks, directory = sys.argv[1:6]
data = {
    "agent": "claude",
    "version": version,
    "evidence_directory": directory,
    "failures": int(failures),
    "checks": json.loads(checks),
    "isolation": {
        "synthetic_home": True,
        "unshare_net": True,
        "host_agent_config_reads": False,
        "host_binary_read_only_bind": True,
    },
}
with open(out, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
PY

printf '\nclaude live evidence: %s\n' "$OUT"
if [[ "$FAILURES" -ne 0 ]]; then
  printf 'claude live: %s check(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf 'claude live: all checks passed\n'
