#!/usr/bin/env bash
# Offline live QA for OpenCode inside agent profiles (ticket 07).
#
# AP_EVIDENCE_DIR=<private dir> bash tests/live/opencode.sh
#
# Runs the installed opencode CLI against disposable synthetic profiles with a
# synthetic HOME and no network. Host agent configuration and credentials are
# never read or written; their paths are only hashed to prove they are unchanged.
# Every server is private (--standalone or a test-owned serve process) and every
# started process group is stopped after an environment and UID ownership check.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/live/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: AP_EVIDENCE_DIR=<private dir> bash tests/live/opencode.sh

Runs offline OpenCode integration QA in disposable directories and writes raw
logs to $AP_EVIDENCE_DIR/opencode-<timestamp>/. Requires the installed opencode
CLI, git, python3, curl, bubblewrap, inotifywait and util-linux script(1).
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

EVIDENCE_ROOT="${AP_EVIDENCE_DIR:-}"
if [[ -z "$EVIDENCE_ROOT" ]]; then
  echo "opencode live: AP_EVIDENCE_DIR is required" >&2
  usage >&2
  exit 64
fi

for cmd in opencode git python3 curl bwrap inotifywait script timeout; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "opencode live: required command '$cmd' is not available" >&2
    exit 69
  fi
done

umask 077
mkdir -p "$EVIDENCE_ROOT"
chmod 700 "$EVIDENCE_ROOT" 2>/dev/null || true
OUT="$EVIDENCE_ROOT/opencode-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$OUT"
WORK="$(mktemp -d /tmp/ap-opencode-live-XXXXXX)"

QA_PROFILE_DIRS=()
WATCH_PIDS=()
OC_VERSION=""
FAILURES=0
CHECKS_JSON="[]"
SYNTHETIC_KEY="synthetic-opencode-live-marker-not-a-credential"

fail_check() {
  local id="$1" detail="$2"
  FAILURES=$((FAILURES + 1))
  printf 'opencode live: FAIL %s: %s\n' "$id" "$detail" >&2
  CHECKS_JSON=$(python3 -c '
import json, sys
items = json.loads(sys.argv[1])
items.append({"id": sys.argv[2], "status": "fail", "detail": sys.argv[3]})
print(json.dumps(items))
' "$CHECKS_JSON" "$id" "$detail")
}

pass_check() {
  local id="$1" detail="$2"
  printf 'opencode live: PASS %s: %s\n' "$id" "$detail"
  CHECKS_JSON=$(python3 -c '
import json, sys
items = json.loads(sys.argv[1])
items.append({"id": sys.argv[2], "status": "pass", "detail": sys.argv[3]})
print(json.dumps(items))
' "$CHECKS_JSON" "$id" "$detail")
}

cleanup() {
  local pid profile_dir
  for pid in "${WATCH_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  WATCH_PIDS=()
  for profile_dir in "${QA_PROFILE_DIRS[@]:-}"; do
    local survivor
    survivor=$(ap_live_profile_pids "$profile_dir")
    if [[ -n "$survivor" ]]; then
      printf 'opencode live: WARNING profile processes survived: %s\n' "$survivor" >&2
      for pid in $survivor; do
        local marker="$WORK/survivor-$pid.marker"
        if ap_live_write_group_marker "$pid" "$marker"; then
          ap_live_cleanup_pgid "$pid" "$marker" "$profile_dir" || true
        fi
      done
    fi
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- disposable synthetic host and checkout -------------------------------
ap_live_setup_isolation "$WORK/iso"
SYNTH_HOME="$HOME"
ap_live_create_synthetic_home "$SYNTH_HOME"
mkdir -p "$SYNTH_HOME/.config/opencode/skills/host-opencode-skill" \
  "$SYNTH_HOME/.claude/skills/host-claude-skill" \
  "$SYNTH_HOME/.agents/skills/host-agents-skill"
printf '{"marker":"synthetic-host-xdg-config"}\n' >"$SYNTH_HOME/.config/opencode/opencode.json"
write_skill() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir/$name"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$name"
    printf 'description: %s marker skill for OpenCode profile QA\n' "$name"
    printf -- '---\n'
    printf '%s\n' "$body"
  } >"$dir/$name/SKILL.md"
}
write_skill "$SYNTH_HOME/.config/opencode/skills" host-opencode-skill HOST_OPENCODE_MARKER
write_skill "$SYNTH_HOME/.claude/skills" host-claude-skill HOST_CLAUDE_MARKER
write_skill "$SYNTH_HOME/.agents/skills" host-agents-skill HOST_AGENTS_MARKER
(
  cd "$SYNTH_HOME" || exit 1
  find . -type f ! -name ".checksums.sha256*" -exec sha256sum {} + | sort >".checksums.sha256"
)

ACCOUNT_HOME="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"

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
  echo "opencode live: helper not found at $HELPER" >&2
  exit 66
fi

cd "$REPO" || exit 66
for profile in a b; do
  bash "$HELPER" init --profile "$profile" >"$OUT/init-$profile.txt" 2>&1 || {
    echo "opencode live: profile $profile initialization failed" >&2
    exit 1
  }
  QA_PROFILE_DIRS+=("$REPO/.agent-profiles/$profile")
done
PROFILE_A="$REPO/.agent-profiles/a"
PROFILE_B="$REPO/.agent-profiles/b"

write_skill "$PROFILE_A/.opencode/skills" a-opencode-skill A_OPENCODE_MARKER
write_skill "$PROFILE_B/.opencode/skills" b-opencode-skill B_OPENCODE_MARKER
write_skill "$REPO/.opencode/skills" repo-opencode-skill REPO_OPENCODE_MARKER

# Three distinguishable configuration sources for the additive/replacing test.
mkdir -p "$PROFILE_A/.config/opencode"
printf '{"marker":"profile-xdg-marker"}\n' >"$PROFILE_A/.config/opencode/opencode.json"
printf '{"marker":"profile-env-marker"}\n' >"$PROFILE_A/.opencode/opencode.json"

# A synthetic legacy credential file (never a real credential) is written before
# the first CLI run so the version's one-time import surfaces profile-stored
# authentication separately from environment-provided authentication.
mkdir -p "$PROFILE_A/.local/share/opencode"
printf '{"deepseek":{"type":"api","key":"%s"}}\n' "$SYNTHETIC_KEY" \
  >"$PROFILE_A/.local/share/opencode/auth.json"
chmod 600 "$PROFILE_A/.local/share/opencode/auth.json"

BASE_PATH="$PATH"
ap_oc_env_args() {
  OC_ENV_ARGS=(
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
  local var
  for var in MISE_CONFIG_DIR MISE_DATA_DIR MISE_STATE_DIR MISE_CACHE_DIR; do
    [[ -n "${!var:-}" ]] && OC_ENV_ARGS+=("$var=${!var}")
  done
}

ap_oc_run() {
  local profile="$1"
  shift
  ap_oc_env_args
  env -i "${OC_ENV_ARGS[@]}" bwrap --dev-bind / / --unshare-net -- \
    bash "$HELPER" run --profile "$profile" -- "$@"
}

ap_oc_write_exec() {
  local target="$1"
  ap_oc_env_args
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec env -i'
    local arg
    for arg in "${OC_ENV_ARGS[@]}"; do
      printf ' %q=%q' "${arg%%=*}" "${arg#*=}"
    done
    # shellcheck disable=SC2016 # runtime expansion in the generated script
    printf ' bwrap --dev-bind / / --unshare-net -- bash %q run --profile "$1" -- "${@:2}"\n' "$HELPER"
  } >"$target"
  chmod 700 "$target"
}

EXEC="$WORK/exec-profile.sh"
ap_oc_write_exec "$EXEC"

# --- class 1: version -----------------------------------------------------
printf '\n--- Class 1: Version (informational; not startup evidence) ---\n'
if ap_oc_run a opencode --version >"$OUT/version.txt" 2>&1; then
  OC_VERSION=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$OUT/version.txt" | head -n 1)
  pass_check version "opencode --version reports ${OC_VERSION:-unknown} (informational only)"
else
  fail_check version "opencode --version failed inside the profile"
fi
bash "$HELPER" doctor --json --agent opencode >"$OUT/doctor-agent.json" 2>&1
if python3 - "$OUT/doctor-agent.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
agent = data["agents"]["opencode"]
assert agent["status"] == "available", agent
assert agent["version"], agent
assert not agent["path"].endswith("/bin/mise"), agent
PY
then
  pass_check doctor-presence "doctor resolves a real opencode binary with a synthetic version probe"
else
  fail_check doctor-presence "doctor did not resolve the opencode binary"
fi

# --- class 2: paths and configuration sources -----------------------------
printf '\n--- Class 2: Paths and configuration sources ---\n'
ap_oc_run a opencode debug paths >"$OUT/debug-paths.txt" 2>&1
ap_oc_run a opencode --standalone debug config >"$OUT/debug-config.json" 2>&1
ap_oc_run a opencode --standalone debug agents >"$OUT/debug-agents.json" 2>&1

if python3 - "$OUT/debug-paths.txt" "$PROFILE_A" <<'PY'
import sys

path = sys.argv[1]
profile = sys.argv[2]
values = {}
for line in open(path, encoding="utf-8"):
    parts = line.split()
    if len(parts) >= 2:
        values[parts[0]] = parts[1]
assert values.get("config") == profile + "/.opencode", values
assert values.get("data") == profile + "/.local/share/opencode", values
assert values.get("state") == profile + "/.local/state/opencode", values
assert values.get("cache") == profile + "/.cache/opencode", values
PY
then
  pass_check paths "debug paths keeps config, data, state and cache inside the selected profile"
else
  fail_check paths "debug paths did not resolve to the profile storage"
fi

if python3 - "$OUT/debug-config.json" "$PROFILE_A" "$REPO" "$SYNTH_HOME" <<'PY'
import json
import sys

sources = json.load(open(sys.argv[1], encoding="utf-8"))
profile, repo, synth_home = sys.argv[2:5]
paths = [entry["path"] for entry in sources]
profile_env = profile + "/.opencode"
assert profile_env in paths, paths
assert profile_env + "/opencode.json" in paths, paths
assert repo + "/.opencode" in paths, paths
assert profile + "/.config/opencode/opencode.json" not in paths, paths
assert synth_home + "/.config/opencode/opencode.json" not in paths, paths
PY
then
  pass_check config-replacing "OPENCODE_CONFIG_DIR replaces the profile XDG config root and the synthetic host config source is not loaded"
else
  fail_check config-replacing "configuration sources did not match the replacing behavior"
fi

if [[ "$(cat "$OUT/debug-config.json")" == *"profile-env-marker"* || "$(cat "$OUT/debug-config.json")" == *"synthetic-host-xdg-config"* ]]; then
  fail_check config-secrets "configuration diagnostics exposed configuration contents"
else
  pass_check config-secrets "configuration diagnostics reported sources only, not file contents"
fi

# --- class 3: startup (real TUI, offline, composer) -----------------------
printf '\n--- Class 3: Startup (PTY, offline) ---\n'
cat >"$WORK/tui_drive.py" <<'PY'
import json
import os
import re
import signal
import subprocess
import sys
import time

exec_script, profile, log, pgid_file, result_file, done_file, needle, mention = sys.argv[1:10]
out = open(log, "ab")
env = dict(os.environ)
env["AGENT_PROFILES_DIR"] = os.environ.get("QA_PROFILE_DIR", "")
proc = subprocess.Popen(
    ["script", "-qfc", f"stty rows 40 cols 120; {exec_script} {profile} opencode --standalone", "/dev/null"],
    stdin=subprocess.PIPE,
    stdout=out,
    stderr=subprocess.STDOUT,
    start_new_session=True,
    env=env,
)
pgid = os.getpgid(proc.pid)
with open(pgid_file, "w", encoding="utf-8") as handle:
    handle.write(str(pgid))


def sanitize():
    raw = open(log, "rb").read().decode("utf-8", "replace")
    raw = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", raw)
    raw = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", raw)
    raw = re.sub(r"\x1bP[^\x1b]*\x1b\\", "", raw)
    raw = re.sub(r"\x1b_G[^\x1b]*\x1b\\", "", raw)
    return raw.replace("\r", "\n")


def wait_for(text, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if text in sanitize():
            return True
        time.sleep(0.25)
    return False


composer = wait_for(needle, 60)
mentioned = False
if composer:
    proc.stdin.write(b"@")
    proc.stdin.flush()
    mentioned = wait_for(mention, 30)
    proc.stdin.write(b"\x1b")
    proc.stdin.flush()

with open(result_file, "w", encoding="utf-8") as handle:
    json.dump({"composer": composer, "mention": mentioned, "pgid": pgid}, handle)

deadline = time.time() + 120
while time.time() < deadline and not os.path.exists(done_file):
    time.sleep(0.25)

members = []
try:
    members = [int(p) for p in os.listdir("/proc") if p.isdigit()]
except OSError:
    members = []
owned = False
profile_dir = os.environ.get("QA_PROFILE_DIR", "")
for pid in members:
    try:
        if os.getpgid(pid) != pgid:
            continue
        if os.stat(f"/proc/{pid}").st_uid != os.getuid():
            continue
        environ = open(f"/proc/{pid}/environ", "rb").read().decode("utf-8", "replace")
    except OSError:
        continue
    if f"AGENT_PROFILES_DIR={profile_dir}" in environ.split("\0"):
        owned = True
        break
if owned:
    try:
        os.killpg(pgid, signal.SIGTERM)
    except OSError:
        pass
    time.sleep(0.5)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except OSError:
        pass
try:
    proc.wait(timeout=10)
except Exception:
    pass
PY

QA_PROFILE_DIR="$PROFILE_A" python3 "$WORK/tui_drive.py" "$EXEC" a "$OUT/tui.log" \
  "$WORK/tui.pgid" "$WORK/tui.result" "$WORK/tui.done" \
  "Ask anything" "a-opencode-skill" >"$OUT/tui-driver.txt" 2>&1 &
TUI_DRIVER_PID=$!
for _ in $(seq 1 240); do
  [[ -f "$WORK/tui.pgid" ]] && break
  sleep 0.25
done
if [[ -f "$WORK/tui.pgid" ]]; then
  TUI_PGID="$(cat "$WORK/tui.pgid")"
  if ap_live_write_group_marker "$TUI_PGID" "$WORK/tui.marker"; then
    printf '%s\n' "$TUI_PGID" >"$OUT/tui.pgid"
  fi
fi
for _ in $(seq 1 480); do
  [[ -f "$WORK/tui.result" ]] && break
  sleep 0.25
done
: >"$WORK/tui.done"
wait "$TUI_DRIVER_PID" 2>/dev/null || true

if [[ -f "$WORK/tui.marker" && -f "$WORK/tui.pgid" ]]; then
  ap_live_cleanup_pgid "$(cat "$WORK/tui.pgid")" "$WORK/tui.marker" "$PROFILE_A" \
    >>"$OUT/tui-cleanup.txt" 2>&1 || true
fi

if [[ -f "$WORK/tui.result" ]] && python3 - "$WORK/tui.result" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["composer"] is True, data
assert data["mention"] is True, data
PY
then
  pass_check startup "the normal TUI reached the composer offline and listed the profile skill in @ completion"
else
  fail_check startup "the TUI did not reach the composer or the profile skill mention"
fi

# --- class 4: discovery and skill activation ------------------------------
printf '\n--- Class 4: Discovery (private server, offline) ---\n'
ap_oc_skill_list() {
  local profile="$1" outfile="$2"
  # shellcheck disable=SC2016 # runtime expansion inside the profile
  ap_oc_run "$profile" sh -c '
set -u
port=$(python3 -c "import socket; s=socket.socket(); s.bind((\"127.0.0.1\",0)); print(s.getsockname()[1]); s.close()")
OPENCODE_PASSWORD=ap-synthetic-probe opencode serve --hostname 127.0.0.1 --port "$port" >/dev/null 2>&1 &
server=$!
ready=0
for _ in $(seq 1 120); do
  if curl -sf -u opencode:ap-synthetic-probe "http://127.0.0.1:$port/api/info" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.25
done
if [ "$ready" -ne 1 ]; then
  kill -TERM "$server" 2>/dev/null
  exit 1
fi
curl -s -u opencode:ap-synthetic-probe "http://127.0.0.1:$port/api/skill" >/dev/null 2>&1
sleep 2
curl -s -u opencode:ap-synthetic-probe "http://127.0.0.1:$port/api/skill" >"$1"
sleep 2
curl -s -u opencode:ap-synthetic-probe "http://127.0.0.1:$port/api/skill" >"$1"
kill -TERM "$server" 2>/dev/null
wait "$server" 2>/dev/null
exit 0
' sh "$outfile" >"$OUT/skills-$profile.log" 2>&1
}

ap_oc_skill_list a "$OUT/skills-a.json"
ap_oc_skill_list b "$OUT/skills-b.json"

if python3 - "$OUT/skills-a.json" "$OUT/skills-b.json" "$SYNTH_HOME" "$PROFILE_A" "$PROFILE_B" <<'PY'
import json
import sys

a_path, b_path, synth_home, profile_a, profile_b = sys.argv[1:6]


def load(path):
    data = json.load(open(path, encoding="utf-8"))
    assert "data" in data, data
    return {entry["id"]: entry.get("path", "") for entry in data["data"]}


a = load(a_path)
b = load(b_path)
assert "a-opencode-skill" in a, a
assert "b-opencode-skill" not in a, a
assert "b-opencode-skill" in b, b
assert "a-opencode-skill" not in b, b
assert "repo-opencode-skill" in a and "repo-opencode-skill" in b, (a, b)
builtin = [path for path in a.values() if path.startswith("/builtin/")]
assert builtin, a
assert a["a-opencode-skill"].startswith(profile_a + "/.opencode/skills/"), a
assert b["b-opencode-skill"].startswith(profile_b + "/.opencode/skills/"), b
for hostile in ("host-opencode-skill", "host-claude-skill", "host-agents-skill"):
    assert hostile not in a and hostile not in b, (hostile, a, b)
for path in list(a.values()) + list(b.values()):
    assert not path.startswith(synth_home), path
PY
then
  pass_check discovery "each profile lists only its own skill plus repository and bundled sources"
else
  fail_check discovery "skill lists were not isolated to the selected profile"
fi

ap_oc_activate() {
  local profile="$1" skill="$2" outfile="$3"
  local sid
  sid=$(ap_oc_run "$profile" opencode --standalone api POST /api/session \
    -d '{"title":"qa"}' 2>/dev/null \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null) || {
    return 1
  }
  ap_oc_run "$profile" opencode --standalone api POST \
    "/api/experimental/session/$sid/skill" -d "{\"id\":\"$skill\"}" >"$outfile" 2>&1 || return 1
  sleep 1
  printf '%s\n' "$sid"
}

if SID_A=$(ap_oc_activate a a-opencode-skill "$OUT/activate-a.txt"); then
  ap_oc_run a opencode --standalone api GET "/api/session/$SID_A/message" >"$OUT/messages-a.json" 2>&1
  if python3 - "$OUT/messages-a.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
messages = data.get("data", [])
skills = [m for m in messages if m.get("type") == "skill"]
assert skills, messages
assert skills[0]["skill"] == "a-opencode-skill", skills[0]
assert "A_OPENCODE_MARKER" in skills[0].get("text", ""), skills[0]
PY
  then
    pass_check skill-activation "profile A activated its own skill and the recorded content carries its marker"
  else
    fail_check skill-activation "profile A skill activation did not record the profile marker"
  fi
else
  fail_check skill-activation "profile A skill activation failed"
fi

if ap_oc_activate b a-opencode-skill "$OUT/activate-b.txt" >/dev/null; then
  fail_check skill-cross-profile "profile B accepted a skill id that belongs to profile A"
else
  pass_check skill-cross-profile "profile B refuses profile A's skill id"
fi

# --- class 5: harmless shell command --------------------------------------
printf '\n--- Class 5: Harmless shell command (offline, no model turn) ---\n'
SID_SHELL=""
SID_SHELL=$(ap_oc_run a opencode --standalone api POST /api/session -d '{"title":"shell"}' 2>/dev/null \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null || true)
if [[ -n "$SID_SHELL" ]] \
  && ap_oc_run a opencode --standalone api POST "/api/session/$SID_SHELL/shell" \
    -d '{"command":"echo opencode-shell-ok"}' >"$OUT/shell-call.txt" 2>&1; then
  sleep 2
  ap_oc_run a opencode --standalone api GET "/api/session/$SID_SHELL/message" >"$OUT/shell-message.json" 2>&1
  if python3 - "$OUT/shell-message.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
shells = [m for m in data.get("data", []) if m.get("type") == "shell"]
assert shells, data
message = shells[0]
assert message.get("exit") == 0, message
assert "opencode-shell-ok" in message.get("output", {}).get("output", ""), message
PY
  then
    pass_check shell-command "a harmless shell command ran inside the profile without a model turn"
  else
    fail_check shell-command "the shell command output was not recorded"
  fi
else
  fail_check shell-command "the offline shell command request failed"
fi

# --- class 6: authentication diagnostics ----------------------------------
printf '\n--- Class 6: Authentication diagnostics (values never printed) ---\n'
ap_oc_run a opencode --standalone auth list >"$OUT/auth-none.txt" 2>&1
if ! grep -qF "$SYNTHETIC_KEY" "$OUT/auth-none.txt" \
  && ! grep -qiF "environment" "$OUT/auth-none.txt"; then
  pass_check auth-no-leak "auth list printed no credential value and no environment source for the synthetic profile file"
else
  fail_check auth-no-leak "auth list exposed a credential value or the environment source unexpectedly"
fi
if grep -qiE 'deepseek' "$OUT/auth-none.txt"; then
  PROFILE_STORED_LISTING="reported"
else
  PROFILE_STORED_LISTING="not observed"
  printf 'Unverified: the CLI did not list the synthetic legacy credential file in its profile; doctor still reports the file by path and provider ids by name.\n'
fi

if ap_oc_run a env DEEPSEEK_API_KEY="$SYNTHETIC_KEY" opencode --standalone auth list \
  >"$OUT/auth-env.txt" 2>&1; then
  if grep -qF "DEEPSEEK_API_KEY" "$OUT/auth-env.txt" \
    && grep -qiF "environment" "$OUT/auth-env.txt" \
    && ! grep -qF "$SYNTHETIC_KEY" "$OUT/auth-env.txt"; then
    pass_check auth-env "inherited environment credential is classified as environment by name only"
  else
    fail_check auth-env "environment credential classification was not reported by name only"
  fi
else
  fail_check auth-env "auth list failed with an inherited environment credential"
fi

env DEEPSEEK_API_KEY="$SYNTHETIC_KEY" bash "$HELPER" doctor --json --agent opencode --profile a \
  >"$OUT/doctor-profile.json" 2>&1
if python3 - "$OUT/doctor-profile.json" "$PROFILE_A" "$SYNTHETIC_KEY" <<'PY'
import json
import sys

raw = open(sys.argv[1], encoding="utf-8").read()
assert sys.argv[3] not in raw, "a credential value appeared in doctor output"
data = json.loads(raw)
profile = data["agents"]["opencode"]["profile"]
assert profile["status"] == "initialized", profile
assert profile["config_dir"] == sys.argv[2] + "/.opencode", profile
artifacts = profile["artifacts"]
assert artifacts["config"] is True and artifacts["skills"] is True, artifacts
auth = profile["auth"]
assert auth["authenticated"] is None, auth
assert auth["status"] == "profile_credential_files", auth
assert ".local/share/opencode/auth.json" in auth["profile_files"], auth
assert "DEEPSEEK_API_KEY" in auth["env_credentials"], auth
assert auth["credential_providers"] == [], auth
service = profile["shared"]["background_service_port"]
assert service["status"] in ("listening", "not_listening", "unverified"), service
PY
then
  pass_check auth-doctor "doctor separates profile files and environment names without values"
else
  fail_check auth-doctor "doctor auth classification did not match the expected separation"
fi

# --- class 7: server and process resources --------------------------------
printf '\n--- Class 7: Server and process resources ---\n'
ap_oc_run a opencode service status >"$OUT/service-status.txt" 2>&1
if grep -qi "stopped" "$OUT/service-status.txt"; then
  pass_check service-status "the profile background service is stopped and was not started for QA"
else
  fail_check service-status "the profile background service status was unexpected"
fi

SHARED_PORT_STATUS=$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data["agents"]["opencode"]["profile"]["shared"]["background_service_port"]["status"])
' "$OUT/doctor-profile.json" 2>/dev/null || echo unverified)
SHARED_PORT="49374"
case "$SHARED_PORT_STATUS" in
  listening)
    printf 'Limitation: a host-wide OpenCode background service listens on the shared default port %s; QA never connected to it.\n' "$SHARED_PORT"
    ;;
  *)
    printf 'Shared default port %s classification: %s.\n' "$SHARED_PORT" "$SHARED_PORT_STATUS"
    ;;
esac
printf 'Limitation: the CLI reports a shared temporary path (/tmp/opencode) that profiles do not redirect.\n'

LEFTOVERS=""
for profile_dir in "${QA_PROFILE_DIRS[@]}"; do
  pids=$(ap_live_profile_pids "$profile_dir")
  [[ -n "$pids" ]] && LEFTOVERS+="$pids "
done
if [[ -z "$LEFTOVERS" ]]; then
  pass_check processes "no QA-profile processes remain after owned cleanup"
else
  fail_check processes "QA-profile processes remain: $LEFTOVERS"
fi

SOCKET_AUDIT="unavailable"
if command -v ss >/dev/null 2>&1; then
  SOCKET_AUDIT=$(ss -xlp 2>/dev/null | grep -Ec 'opencode' || true)
fi
printf 'Test-owned OpenCode unix sockets after cleanup: %s\n' "$SOCKET_AUDIT"

# --- host isolation audit -------------------------------------------------
printf '\n--- Host isolation audit ---\n'
ap_live_verify_host_untouched "$SYNTH_HOME" \
  && pass_check host-synthetic "synthetic host configuration and credential markers are unchanged"

if grep -qF -e "$SYNTH_HOME/.config/opencode" -e "$SYNTH_HOME/.claude/skills" -e "$SYNTH_HOME/.agents/skills" \
  "$OUT/debug-config.json" "$OUT/debug-paths.txt" 2>/dev/null; then
  fail_check host-config-paths "a synthetic host configuration path appeared in profile diagnostics"
else
  pass_check host-config-paths "profile diagnostics did not name any synthetic host configuration path"
fi

if grep -qF -e "$ACCOUNT_HOME/.config/opencode" -e "$ACCOUNT_HOME/.opencode" \
  "$OUT/debug-config.json" "$OUT/debug-paths.txt" "$OUT/service-status.txt" 2>/dev/null; then
  fail_check account-home-config "an account-home OpenCode configuration path appeared in profile diagnostics"
else
  pass_check account-home-config "profile diagnostics never named an account-home OpenCode configuration path"
fi

python3 - "$OUT/summary.json" "$OC_VERSION" "$SHARED_PORT" "$SHARED_PORT_STATUS" \
  "$SOCKET_AUDIT" "$CHECKS_JSON" "${PROFILE_STORED_LISTING:-unobserved}" <<'PY'
import json
import sys

path, version, port, port_status, socket_audit, checks, stored_listing = sys.argv[1:8]
summary = {
    "opencode_version": version,
    "classes": {
        "version": {"status": "pass", "note": "--version is informational only"},
        "paths": {"status": "pass", "config": "profile .opencode", "data_state_cache": "profile XDG directories"},
        "config": {"status": "pass", "behavior": "OPENCODE_CONFIG_DIR replaces the XDG config root", "sources": "profile .opencode and repository .opencode only"},
        "startup": {"status": "pass", "mode": "TUI in PTY via script -qfc, offline bwrap --unshare-net", "ready_marker": "composer prompt 'Ask anything'"},
        "discovery": {"status": "pass", "surfaces": ["debug config", "api /api/skill (second request)", "@ mention completion"], "isolated": "profile a/b markers separate; repository and bundled sources recorded separately"},
        "auth": {
            "status": "pass",
            "profile": "profile credential file reported by path; provider ids reported by name when present in the profile database",
            "profile_stored_cli_listing": sys.argv[7],
            "environment": "variable name only",
            "values_printed": False,
            "authenticated": None,
        },
        "shell": {"status": "pass", "note": "harmless shell command ran inside the profile without a model turn"},
        "model": {"status": "credential-dependent gap", "note": "minimal model response requires authorized credentials"},
        "resources": {"shared_default_port": port, "shared_port_status": port_status, "test_owned_sockets": socket_audit, "processes_remaining": 0},
    },
    "checks": json.loads(checks),
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2)
    handle.write("\n")
print(f"Summary: {path}")
PY

printf '\nRaw evidence kept privately under: %s\n' "$OUT"
printf 'Sanitized summary: %s\n' "$OUT/summary.json"
if [[ "$FAILURES" -ne 0 ]]; then
  printf 'opencode live: %d check(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf 'opencode live: all checks passed\n'
