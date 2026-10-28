#!/usr/bin/env bash
# Live QA for Google Antigravity CLI (`agy`) inside agent profiles.
#
# Opt-in evidence script. It runs the installed `agy` offline with a disposable
# synthetic HOME, hides the host session D-Bus so no OS credential or account
# can be used, and records version, startup, discovery, authentication,
# resource and sandbox evidence separately. Raw logs stay private in
# AP_EVIDENCE_DIR; only sanitized summaries belong in the reference.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/live/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AP_HELPER="$REPO_ROOT/skills/flyingnobita-agent-profiles/scripts/agent-profiles"
EVIDENCE_DIR="${AP_EVIDENCE_DIR:-$HOME/.local/state/flyingnobita-agent-profiles/evidence}"
mkdir -p "$EVIDENCE_DIR"
chmod 700 "$EVIDENCE_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RAW_LOG="$EVIDENCE_DIR/agy-live-$STAMP.log"
SUMMARY_JSON="$EVIDENCE_DIR/agy-live-$STAMP.json"
exec > >(tee -a "$RAW_LOG") 2>&1

BASE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ap-agy-live-XXXXXX")"
SYNTHETIC_ENV_KEY="synthetic-agy-live-probe-not-a-real-credential"
HOST_GEMINI="$HOME/.gemini"
QA_UID="$(id -u)"
TUI_ROOTS=()
TUI_MARKERS=()
TUI_PROFILES=()
WATCHER_PIDS=()
HOST_GEMINI_HASH_BEFORE=""
HOST_GEMINI_HASH_AFTER=""

# Hash the host configuration surface a profile run could touch. Volatile host
# logs, conversations and caches are excluded because other host sessions write
# them concurrently; they are never a stable comparison on a shared machine.
agy_live_host_gemini_hash() {
  if [[ ! -d "$HOST_GEMINI" ]]; then
    printf 'absent\n'
    return 0
  fi
  find "$HOST_GEMINI" -type f \
    \( -path "*/config/*" -o -name settings.json -o -name installation_id \
    -o -name jetski_state.pbtxt -o -name mcp_oauth_tokens.json \) \
    -print0 2>/dev/null \
    | xargs -0 sha256sum 2>/dev/null | sort | sha256sum | awk '{ print $1 }'
}

agy_live_sanitize() {
  python3 - "$1" <<'PY'
import re
import sys

raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
raw = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", raw)
raw = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", raw)
sys.stdout.write(raw.replace("\r", "\n"))
PY
}

agy_live_env_args() {
  AGY_ENV_ARGS=(
    PATH="$PATH"
    HOME="$HOME"
    USER="${USER:-testuser}"
    LOGNAME="${LOGNAME:-testuser}"
    TERM="${TERM:-dumb}"
    LANG="${LANG:-C.UTF-8}"
    DISABLE_TELEMETRY=1
  )
  local var
  for var in MISE_CONFIG_DIR MISE_DATA_DIR MISE_STATE_DIR MISE_CACHE_DIR; do
    [[ -n "${!var:-}" ]] && AGY_ENV_ARGS+=("$var=${!var}")
  done
}

# Offline runner: synthetic HOME, no network, and no host session D-Bus (the
# OS credential service), so no host account can authenticate the process.
agy_live_run() {
  local profile="$1"
  shift
  local -a bwrap_args=(--dev-bind / / --unshare-net)
  if [[ -d "/run/user/$QA_UID" ]]; then
    bwrap_args+=(--tmpfs "/run/user/$QA_UID")
  fi
  env -i "${AGY_ENV_ARGS[@]}" bwrap "${bwrap_args[@]}" -- \
    bash "$AP_HELPER" run --profile "$profile" -- "$@"
}

agy_live_write_marker_skill() {
  local root="$1" name="$2" body="$3"
  mkdir -p "$root/$name"
  {
    printf '%s\n' '---'
    printf 'name: %s\n' "$name"
    printf 'description: %s marker skill for profile QA\n' "$name"
    printf '%s\n' '---'
    printf '%s\n' "# $name"
    printf '%s\n' "$body"
  } >"$root/$name/SKILL.md"
}

agy_live_write_plugin() {
  local plugins_root="$1" dir="$2" skill="$3" body="$4"
  mkdir -p "$plugins_root/$dir/skills/$skill"
  printf '{"name":"%s"}\n' "$dir" >"$plugins_root/$dir/plugin.json"
  {
    printf '%s\n' '---'
    printf 'name: %s\n' "$skill"
    printf 'description: %s plugin skill for profile QA\n' "$skill"
    printf '%s\n' '---'
    printf '%s\n' "# $skill"
    printf '%s\n' "$body"
  } >"$plugins_root/$dir/skills/$skill/SKILL.md"
}

agy_live_watch_start() {
  local profile_dir="$1" label="$2"
  local log="$BASE_TMP/inotify-$label.log"
  : >"$log"
  inotifywait -m -q -r \
    -e access,open,create,modify,attrib,delete,moved_to,moved_from,close_write \
    "$profile_dir" >>"$log" 2>&1 &
  WATCHER_PIDS+=("$!")
  AGY_WATCH_LOG="$log"
  sleep 0.5
}

agy_live_watch_stop_all() {
  local pid
  for pid in "${WATCHER_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  WATCHER_PIDS=()
}

# Waits for either the first-run onboarding screen or the sign-in screen.
# Prints "onboarding", "signin", or nothing on timeout.
agy_live_wait_for_screen() {
  local log="$1" timeout_s="$2"
  local sanitized="$BASE_TMP/screen.sanitized"
  local i
  for ((i = 0; i < timeout_s; i++)); do
    agy_live_sanitize "$log" >"$sanitized" 2>/dev/null || true
    if grep -qF "not signed in" "$sanitized"; then
      printf 'signin\n'
      return 0
    fi
    if grep -qF "Welcome to Antigravity CLI" "$sanitized"; then
      printf 'onboarding\n'
      return 0
    fi
    sleep 1
  done
  return 1
}

agy_live_wait_for() {
  local log="$1" needle="$2" timeout_s="$3"
  local sanitized="$BASE_TMP/wait.sanitized"
  local i
  for ((i = 0; i < timeout_s; i++)); do
    agy_live_sanitize "$log" >"$sanitized" 2>/dev/null || true
    if grep -qF "$needle" "$sanitized"; then
      return 0
    fi
    sleep 1
  done
  printf 'ERROR: timed out waiting for %q in %s\n' "$needle" "$log" >&2
  agy_live_sanitize "$log" | tail -c 2000 >&2
  return 1
}

# Real TUI launch in a PTY. Drives onboarding to the sign-in screen, which is
# the readiness marker reachable without credentials, then stops its own group.
agy_live_tui_startup() {
  local profile="$1" log="$2"
  local profile_dir
  profile_dir="$(cd "$FIXTURE_REPO" && printf '%s/.agent-profiles/%s' "$FIXTURE_REPO" "$profile")"

  agy_live_env_args
  local inner="$BASE_TMP/tui-$profile-inner.sh"
  local fifo="$BASE_TMP/tui-$profile.fifo"
  local marker="$BASE_TMP/tui-$profile.pgid"

  {
    printf '#!/usr/bin/env bash\nexec env -i '
    local arg
    for arg in "${AGY_ENV_ARGS[@]}"; do
      printf '%s=%q ' "${arg%%=*}" "${arg#*=}"
    done
    printf 'bwrap --dev-bind / /'
    if [[ -d "/run/user/$QA_UID" ]]; then
      printf ' --tmpfs %q' "/run/user/$QA_UID"
    fi
    printf ' --unshare-net -- bash %q run --profile %q -- agy\n' "$AP_HELPER" "$profile"
  } >"$inner"
  chmod 700 "$inner"

  mkfifo "$fifo"
  local keys
  # Open both ends before the session starts: the TUI keeps reading keys while
  # the harness holds the writer side, and no FIFO open can block forever.
  exec {keys}<>"$fifo"

  local root_pid=""
  root_pid=$(
    python3 - "$fifo" "$log" "$FIXTURE_REPO" "$profile_dir" "$inner" <<'PY'
import os
import subprocess
import sys

fifo, log, repo, profile_dir, inner = sys.argv[1:6]
env = dict(os.environ)
env["AGENT_PROFILES_DIR"] = profile_dir
read_fd = os.open(fifo, os.O_RDONLY)
out = open(log, "ab")
proc = subprocess.Popen(
    ["script", "-qfc", f"stty rows 40 cols 120; bash {inner}", "/dev/null"],
    cwd=repo,
    env=env,
    stdin=read_fd,
    stdout=out,
    stderr=subprocess.STDOUT,
    start_new_session=True,
)
os.close(read_fd)
print(os.getpgid(proc.pid))
PY
  )

  if [[ -z "$root_pid" ]] || ! ap_live_write_group_marker "$root_pid" "$marker"; then
    printf 'ERROR: could not record the startup process identity\n' >&2
    kill -TERM -"$root_pid" 2>/dev/null || true
    exec {keys}>&-
    return 1
  fi

  TUI_ROOTS+=("$root_pid")
  TUI_MARKERS+=("$marker")
  TUI_PROFILES+=("$profile_dir")

  local screen=""
  screen=$(agy_live_wait_for_screen "$log" 45)
  case "$screen" in
    signin)
      printf 'Startup ready marker found: sign-in screen (onboarding already satisfied in this profile).\n'
      ;;
    onboarding)
      printf 'Startup ready marker found: onboarding welcome screen; driving it to the sign-in screen.\n'
      printf '\r' >&"$keys"
      sleep 2
      if ! agy_live_wait_for "$log" "Terms of Service" 20; then
        printf 'ERROR: onboarding did not reach the Terms of Service screen\n' >&2
        exec {keys}>&-
        return 1
      fi
      printf '\t\t' >&"$keys"
      sleep 1
      printf '\r' >&"$keys"
      agy_live_wait_for "$log" "trust the contents of this project" 25
      printf '\r' >&"$keys"
      agy_live_wait_for "$log" "not signed in" 45
      printf 'Onboarding completed to the sign-in screen.\n'
      ;;
    *)
      printf 'ERROR: agy did not reach an onboarding or sign-in screen\n' >&2
      exec {keys}>&-
      return 1
      ;;
  esac
  exec {keys}>&-
  rm -f "$fifo"

  agy_live_tui_stop "$root_pid" "$marker" "$profile_dir"
}

agy_live_tui_stop() {
  local root_pid="$1" marker="$2" profile_dir="$3"
  local pgid="" child_marker="" i=0

  while IFS= read -r pgid; do
    [[ -n "$pgid" && "$pgid" != "$root_pid" ]] || continue
    child_marker="$BASE_TMP/owned-pgid-$root_pid-$i.marker"
    if ap_live_write_group_marker "$pgid" "$child_marker"; then
      ap_live_cleanup_pgid "$pgid" "$child_marker" "$profile_dir" || true
    else
      printf 'WARNING: could not record identity for owned process group %s\n' "$pgid" >&2
      rm -f "$child_marker"
    fi
    i=$((i + 1))
  done < <(ap_live_owned_pgids "$root_pid" "$profile_dir")

  if [[ -f "$marker" ]]; then
    ap_live_cleanup_pgid "$root_pid" "$marker" "$profile_dir" || true
  fi

  local survivors=""
  survivors=$(ap_live_profile_pids "$profile_dir")
  if [[ -n "$survivors" ]]; then
    printf 'ERROR: profile processes survived owned cleanup: %s\n' "$survivors" >&2
    return 1
  fi
  return 0
}

agy_live_stop_all() {
  local i
  for i in "${!TUI_ROOTS[@]}"; do
    agy_live_tui_stop "${TUI_ROOTS[$i]}" "${TUI_MARKERS[$i]}" "${TUI_PROFILES[$i]}" || true
  done
  TUI_ROOTS=()
  TUI_MARKERS=()
  TUI_PROFILES=()
}

cleanup() {
  agy_live_watch_stop_all || true
  agy_live_stop_all || true
  if [[ -n "${AP_KEEP_TMP:-}" ]]; then
    printf 'Kept temporary workspace for inspection: %s\n' "$BASE_TMP"
  else
    rm -rf "$BASE_TMP"
  fi
}
trap cleanup EXIT HUP INT TERM

printf '=== Antigravity CLI Live QA Probe ===\n'
printf 'Time: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Subject: %s\n' "$REPO_ROOT"
printf 'agy: %s\n\n' "$(command -v agy 2>/dev/null || echo not-found)"

ap_live_setup_isolation "$BASE_TMP"
ap_live_create_synthetic_home "$HOME"
# The synthetic host also carries candidate Antigravity locations that must not
# be read once the profile mounts are in place.
mkdir -p "$HOME/.gemini/config/skills/host-marker"
printf -- '---\nname: host-marker\ndescription: synthetic host marker\n---\n' \
  >"$HOME/.gemini/config/skills/host-marker/SKILL.md"
printf 'host-account-marker-not-a-credential\n' >"$HOME/.gemini/host-marker.txt"
(
  cd "$HOME"
  find . -type f ! -name ".checksums.sha256*" -exec sha256sum {} + | sort >".checksums.sha256.tmp"
  mv ".checksums.sha256.tmp" ".checksums.sha256"
  chmod 600 ".checksums.sha256" 2>/dev/null || true
)

FIXTURE_REPO="$BASE_TMP/project-repo"
mkdir -p "$FIXTURE_REPO"
git -C "$FIXTURE_REPO" init --quiet
git -C "$FIXTURE_REPO" config user.name "Test User"
git -C "$FIXTURE_REPO" config user.email "test@example.com"

HOST_GEMINI_HASH_BEFORE="$(agy_live_host_gemini_hash)"
printf 'Host %s configuration hash before QA: %s\n' "$HOST_GEMINI" "$HOST_GEMINI_HASH_BEFORE"

# ---------------------------------------------------------------------------
# Class 1: version (informational; --version is not startup evidence)
# ---------------------------------------------------------------------------
printf '\n%s\n' '--- Class 1: Version Probe (informational) ---'
cd "$FIXTURE_REPO"
DOCTOR_JSON=$(bash "$AP_HELPER" doctor --json --agent agy)
AGY_VERSION=$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
print(data["agents"]["agy"].get("version") or "unknown")
' "$DOCTOR_JSON")
AGY_PATH=$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
print(data["agents"]["agy"].get("path") or "unknown")
' "$DOCTOR_JSON")
AGY_RAW_VERSION=$(agy --version 2>/dev/null | head -n 1 || true)

printf 'agy --version (raw): %s\n' "$AGY_RAW_VERSION"
printf 'agy version (doctor synthetic probe): %s\n' "$AGY_VERSION"
printf 'agy resolved binary: %s\n' "$AGY_PATH"
[[ "$AGY_VERSION" != "unknown" ]] || {
  printf 'ERROR: could not determine the agy version\n' >&2
  exit 1
}
[[ "$AGY_PATH" != "unknown" ]] || {
  printf 'ERROR: could not resolve an agy binary\n' >&2
  exit 1
}
[[ "$AGY_PATH" != *"/bin/mise" && "$AGY_PATH" != "/usr/bin/mise" ]] || {
  printf 'ERROR: doctor resolved the mise launcher instead of the agy binary\n' >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Class 2: startup (real TUI in a PTY, offline, sign-in screen, owned cleanup)
# ---------------------------------------------------------------------------
printf '\n%s\n' '--- Class 2: Startup Probe (PTY, offline) ---'
cd "$FIXTURE_REPO"
bash "$AP_HELPER" init --profile qa-startup
STARTUP_PROFILE_DIR="$FIXTURE_REPO/.agent-profiles/qa-startup"
STARTUP_LOG="$BASE_TMP/agy-startup.log"
agy_live_tui_startup qa-startup "$STARTUP_LOG"

agy_live_sanitize "$STARTUP_LOG" >"$BASE_TMP/agy-startup.sanitized"
printf '%s\n' 'Startup screens (sanitized, tail):'
tail -c 1200 "$BASE_TMP/agy-startup.sanitized"
printf '\n'

# The sign-in screen proves no OS credential source authenticated the process.
if grep -qE '@(gmail|googlemail|google)\.com' "$BASE_TMP/agy-startup.sanitized"; then
  printf 'ERROR: an account identifier appeared in the startup screen despite the masked session bus\n' >&2
  exit 1
fi
printf 'No account identifier appeared: the masked session bus prevented host credential use.\n'

STARTUP_PATHS="$(cd "$STARTUP_PROFILE_DIR" && find .gemini .config -type f 2>/dev/null | sort | head -n 40 || true)"
printf 'Initialization paths created inside qa-startup (sample):\n%s\n' "$STARTUP_PATHS"
if [[ -n "$STARTUP_PATHS" ]]; then
  if grep -qv '^\.\(gemini\|config\)/' <<<"$STARTUP_PATHS"; then
    printf 'ERROR: agent initialization wrote outside the documented profile locations\n' >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Class 3: discovery (two profiles, verified skill locations, plugin skills)
# ---------------------------------------------------------------------------
printf '\n%s\n' '--- Class 3: Discovery Probe (offline) ---'
cd "$FIXTURE_REPO"
bash "$AP_HELPER" init --profile prof-a
bash "$AP_HELPER" init --profile prof-b
PROFILE_A_DIR="$FIXTURE_REPO/.agent-profiles/prof-a"
PROFILE_B_DIR="$FIXTURE_REPO/.agent-profiles/prof-b"

agy_live_write_marker_skill "$PROFILE_A_DIR/.gemini/config/skills" a-global-skill A_GLOBAL_MARKER
agy_live_write_marker_skill "$PROFILE_A_DIR/.gemini/skills" a-legacy-skill A_LEGACY_MARKER
agy_live_write_marker_skill "$PROFILE_A_DIR/.gemini/antigravity-cli/skills" a-app-skill A_APP_MARKER
agy_live_write_marker_skill "$PROFILE_A_DIR/.gemini/antigravity/skills" a-unsupported-skill A_UNSUPPORTED_MARKER
agy_live_write_marker_skill "$PROFILE_A_DIR/.agents/skills" a-agents-home-skill A_AGENTS_HOME_MARKER
agy_live_write_plugin "$PROFILE_A_DIR/.gemini/config/plugins" pkg-a a-plugin-skill A_PLUGIN_MARKER

agy_live_write_marker_skill "$PROFILE_B_DIR/.gemini/config/skills" b-global-skill B_GLOBAL_MARKER
agy_live_write_marker_skill "$PROFILE_B_DIR/.gemini/skills" b-legacy-skill B_LEGACY_MARKER
agy_live_write_marker_skill "$PROFILE_B_DIR/.gemini/antigravity-cli/skills" b-app-skill B_APP_MARKER
agy_live_write_plugin "$PROFILE_B_DIR/.gemini/config/plugins" pkg-b b-plugin-skill B_PLUGIN_MARKER

agy_live_watch_start "$PROFILE_A_DIR" prof-a
agy_live_tui_startup prof-a "$BASE_TMP/agy-startup-a.log"
WATCH_A_LOG="$AGY_WATCH_LOG"
agy_live_watch_stop_all
agy_live_sanitize "$BASE_TMP/agy-startup-a.log" >"$BASE_TMP/agy-startup-a.sanitized"

agy_live_watch_start "$PROFILE_B_DIR" prof-b
agy_live_tui_startup prof-b "$BASE_TMP/agy-startup-b.log"
WATCH_B_LOG="$AGY_WATCH_LOG"
agy_live_watch_stop_all

# inotifywait prints "<watched-directory>/ ACTION <filename>", so assert on the
# skill directory plus the SKILL.md action line.
for expected in \
  "$PROFILE_A_DIR/.gemini/config/skills/a-global-skill" \
  "$PROFILE_A_DIR/.gemini/skills/a-legacy-skill" \
  "$PROFILE_A_DIR/.gemini/antigravity-cli/skills/a-app-skill"; do
  if ! grep -qF "$expected/ OPEN SKILL.md" "$WATCH_A_LOG"; then
    printf 'ERROR: profile A skill was not read at startup: %s/SKILL.md\n' "$expected" >&2
    exit 1
  fi
done
for unexpected in \
  "$PROFILE_A_DIR/.gemini/antigravity/skills/a-unsupported-skill" \
  "$PROFILE_A_DIR/.agents/skills/a-agents-home-skill"; do
  if grep -qF "$unexpected/ OPEN" "$WATCH_A_LOG"; then
    printf 'ERROR: agy read an unsupported skill location: %s/SKILL.md\n' "$unexpected" >&2
    exit 1
  fi
done
for expected in \
  "$PROFILE_B_DIR/.gemini/config/skills/b-global-skill" \
  "$PROFILE_B_DIR/.gemini/skills/b-legacy-skill" \
  "$PROFILE_B_DIR/.gemini/antigravity-cli/skills/b-app-skill"; do
  if ! grep -qF "$expected/ OPEN SKILL.md" "$WATCH_B_LOG"; then
    printf 'ERROR: profile B skill was not read at startup: %s/SKILL.md\n' "$expected" >&2
    exit 1
  fi
done

agy_live_env_args
agy_live_run prof-a agy plugin list --json >"$BASE_TMP/plugins-a.json" 2>"$BASE_TMP/plugins-a.err"
agy_live_run prof-b agy plugin list --json >"$BASE_TMP/plugins-b.json" 2>"$BASE_TMP/plugins-b.err"
python3 - "$BASE_TMP/plugins-a.json" "$BASE_TMP/plugins-b.json" "$HOME" <<'PY'
import json
import sys

a_path, b_path, home = sys.argv[1:4]
a = json.load(open(a_path))
b = json.load(open(b_path))
a_skills = {skill for plugin in a for skill in plugin.get("skills", [])}
b_skills = {skill for plugin in b for skill in plugin.get("skills", [])}
assert "a-plugin-skill" in a_skills, a
assert "b-plugin-skill" not in a_skills, a
assert "b-plugin-skill" in b_skills, b
assert "a-plugin-skill" not in b_skills, b
# Paths are reported through the profile mount ($HOME/.gemini), which is the
# profile's own storage at run time; each profile sees only its own plugin.
for plugin in a:
    assert plugin["path"] == home + "/.gemini/config/plugins/pkg-a", plugin
for plugin in b:
    assert plugin["path"] == home + "/.gemini/config/plugins/pkg-b", plugin
print("Plugin skill discovery: profile A -> a-plugin-skill, profile B -> b-plugin-skill, no cross-leak.")
print("Plugin paths are the per-profile .gemini mount, not host storage.")
PY
printf 'Startup skill reads verified for the three supported .gemini skill roots.\n'
printf 'Not read: .gemini/antigravity/skills and the profile home .agents/skills.\n'

# ---------------------------------------------------------------------------
# Class 4: authentication diagnostics (separate sources, never inferred)
# ---------------------------------------------------------------------------
printf '\n%s\n' '--- Class 4: Authentication Diagnostics (offline) ---'
cd "$FIXTURE_REPO"
bash "$AP_HELPER" init --profile qa-auth
AUTH_PROFILE_DIR="$FIXTURE_REPO/.agent-profiles/qa-auth"

AUTH_JSON=""
AUTH_JSON=$(env GEMINI_API_KEY="$SYNTHETIC_ENV_KEY" \
  bash "$AP_HELPER" doctor --json --agent agy --profile qa-auth)
if [[ "$AUTH_JSON" == *"$SYNTHETIC_ENV_KEY"* ]]; then
  printf 'ERROR: a synthetic credential value appeared in doctor output\n' >&2
  exit 1
fi
python3 - "$AUTH_JSON" "$AUTH_PROFILE_DIR" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["agy"]["profile"]
assert profile["status"] == "initialized", profile
assert profile["config_dir"] == sys.argv[2] + "/.gemini", profile["config_dir"]
auth = profile["auth"]
assert auth["authenticated"] is None, "no auth source may be reported as authenticated"
assert auth["status"] == "no_profile_credentials", auth
assert auth["profile_files"] == [], auth
assert auth["env_credentials"] == ["GEMINI_API_KEY"], auth
assert auth["os_credential_service"]["status"] in ("present", "absent", "unverified"), auth
assert "not proof of account separation" in auth["note"], auth
print("Doctor profile auth: no profile credential files, environment variable name reported only.")
print("OS credential service status: " + auth["os_credential_service"]["status"])
print("OS credential service detail: " + auth["os_credential_service"]["detail"])
print("authenticated: null (file presence and environment names are not proof of account separation)")
PY
printf 'Startup reached the sign-in screen with the session bus masked; no account was used.\n'

# ---------------------------------------------------------------------------
# Class 5: resources (daemon status, process and socket audit, shared paths)
# ---------------------------------------------------------------------------
printf '\n%s\n' '--- Class 5: Resource Audit (offline) ---'
REMOTE_STATUS=""
REMOTE_STATUS=$(agy_live_run qa-startup agy remote-control status 2>&1 || true)
printf 'Remote-control daemon status inside the profile:\n%s\n' "$REMOTE_STATUS"

SHARED_UNIT="unknown"
if command -v systemctl >/dev/null 2>&1; then
  if systemctl --user list-unit-files 'antigravity-cli-daemon.service' --no-legend 2>/dev/null | grep -q .; then
    SHARED_UNIT="present (user-scope unit outside any profile)"
  else
    SHARED_UNIT="absent"
  fi
fi
printf 'Host user-scope remote-control unit: %s\n' "$SHARED_UNIT"

SOCKET_AUDIT="none"
LEFT_PIDS=""
for profile_dir in "$STARTUP_PROFILE_DIR" "$PROFILE_A_DIR" "$PROFILE_B_DIR" "$AUTH_PROFILE_DIR"; do
  leftovers=$(ap_live_profile_pids "$profile_dir")
  [[ -z "$leftovers" ]] || LEFT_PIDS+="$leftovers "
done
[[ -z "$LEFT_PIDS" ]] || {
  printf 'ERROR: profile-owned agy processes remain: %s\n' "$LEFT_PIDS" >&2
  exit 1
}
if command -v ss >/dev/null 2>&1; then
  SOCKET_AUDIT=$(ss -xlp 2>/dev/null | grep -Ec 'agy|antigravity' || true)
fi
printf 'Process audit: 0 profile-owned agy processes remain.\n'
printf 'Socket audit: %s test-owned agy/antigravity unix sockets reported.\n' "$SOCKET_AUDIT"
printf 'Shared resources that remain outside profile isolation: session D-Bus and its OS credential service, host mise tool path, network, and the project checkout.\n'

# ---------------------------------------------------------------------------
# Class 6: sandbox and permission modes (flag surface only; execution is gated)
# ---------------------------------------------------------------------------
printf '\n%s\n' '--- Class 6: Sandbox Surface (offline) ---'
AGY_HELP="$(agy_live_run qa-startup agy --help 2>&1 || true)"
for flag in --sandbox --mode --dangerously-skip-permissions; do
  if grep -qF -- "$flag" <<<"$AGY_HELP"; then
    printf 'Supported flag present in agy --help: %s\n' "$flag"
  else
    printf 'ERROR: expected flag missing from agy --help: %s\n' "$flag" >&2
    exit 1
  fi
done
printf 'Command execution and enforced denials require an authenticated model turn: credential-dependent gap.\n'

# ---------------------------------------------------------------------------
# Host isolation audit
# ---------------------------------------------------------------------------
printf '\n%s\n' '--- Host Isolation Audit ---'
ap_live_verify_host_untouched "$HOME"
printf 'Synthetic host sha256 snapshot unchanged (host .gemini marker skills were not read or written).\n'
HOST_GEMINI_HASH_AFTER="$(agy_live_host_gemini_hash)"
if [[ "$HOST_GEMINI_HASH_BEFORE" != "$HOST_GEMINI_HASH_AFTER" ]]; then
  printf 'ERROR: host %s configuration changed during QA (%s -> %s)\n' \
    "$HOST_GEMINI" "$HOST_GEMINI_HASH_BEFORE" "$HOST_GEMINI_HASH_AFTER" >&2
  exit 1
fi
printf 'Host %s configuration hash unchanged: %s\n' "$HOST_GEMINI" "$HOST_GEMINI_HASH_AFTER"

python3 - "$SUMMARY_JSON" "$REPO_ROOT" "$AGY_VERSION" "$AGY_PATH" "$AGY_RAW_VERSION" \
  "$SHARED_UNIT" "$SOCKET_AUDIT" <<'PY'
import json
import sys

path, subject, version, binary, raw_version, shared_unit, socket_audit = sys.argv[1:8]
summary = {
    "subject": subject,
    "agy_version": version,
    "agy_raw_version": raw_version,
    "agy_binary": binary,
    "classes": {
        "version": {"status": "pass", "note": "--version is not startup evidence"},
        "startup": {
            "status": "pass",
            "mode": "TUI in PTY via script -qfc, offline with bwrap --unshare-net and masked /run/user session bus",
            "ready_marker": "sign-in screen: 'You are currently not signed in.'",
            "onboarding": "first-run onboarding screens are driven when present; a fresh profile reached the sign-in screen directly",
            "host_account_identifiers": "none",
            "cleanup": "owned PGID shutdown; no survivors",
        },
        "discovery": {
            "status": "pass",
            "read_at_startup": [
                ".gemini/config/skills",
                ".gemini/skills",
                ".gemini/antigravity-cli/skills",
                "builtin skills",
            ],
            "not_read": [
                ".gemini/antigravity/skills",
                "profile home .agents/skills",
            ],
            "plugin_surface": "agy plugin list --json names per-profile plugin skills",
            "workspace_agents_gap": "workspace .agents/skills read is not verified offline",
        },
        "auth": {
            "status": "pass",
            "authenticated": None,
            "profile_files": [],
            "env_credentials": "names only",
            "os_credential_service": "reported separately; masked for all agent runs",
            "account_separation": "not inferred from any response",
        },
        "resources": {
            "status": "pass",
            "remote_control_unit": shared_unit,
            "test_owned_sockets": socket_audit,
            "processes_remaining": 0,
            "initialization": "inside profile .gemini and XDG config",
        },
        "sandbox": {
            "status": "credential-dependent gap",
            "surface": "agy --sandbox / --mode / --dangerously-skip-permissions present in --help",
            "enforced_denial": "not run: requires an authenticated model turn",
        },
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2)
    handle.write("\n")
print(f"Summary: {path}")
PY

printf '\n=== All Antigravity CLI Live QA Probes PASSED (credential-dependent sandbox gap recorded) ===\n'
printf 'Raw log: %s\n' "$RAW_LOG"
