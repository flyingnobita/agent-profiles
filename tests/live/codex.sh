#!/usr/bin/env bash
# Live QA for OpenAI Codex CLI inside agent profiles.
#
# Opt-in evidence script. It runs the installed Codex CLI offline in disposable
# profiles with a synthetic HOME, and records version, startup, discovery, auth
# and sandbox evidence separately. Raw logs stay in the private evidence dir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/live/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AP_HELPER="$REPO_ROOT/skills/flyingnobita-agent-profiles/scripts/agent-profiles"
EVIDENCE_DIR="${AP_EVIDENCE_DIR:-/home/omarchy/.local/state/flyingnobita-deliver/4efade3f099f42f991db984676edec70/evidence}"
mkdir -p "$EVIDENCE_DIR"
chmod 700 "$EVIDENCE_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RAW_LOG="$EVIDENCE_DIR/codex-live-$STAMP.log"
SUMMARY_JSON="$EVIDENCE_DIR/codex-live-$STAMP.json"
exec > >(tee -a "$RAW_LOG") 2>&1

BASE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ap-codex-live-XXXXXX")"
STARTUP_ROOT_PID=""
STARTUP_MARKER=""
STARTUP_PROFILE_DIR=""
INOTIFY_PIDS=()
INOTIFY_LOG=""
SYNTHETIC_ENV_KEY="sk-synthetic-live-probe-not-a-real-credential"

codex_live_stop_startup() {
  [[ -n "$STARTUP_ROOT_PID" ]] || return 0

  local root_pid="$STARTUP_ROOT_PID"
  local profile_dir="$STARTUP_PROFILE_DIR"
  local marker="$STARTUP_MARKER"
  local pgid="" child_marker="" i=0

  if [[ -n "$profile_dir" ]]; then
    while IFS= read -r pgid; do
      [[ -n "$pgid" && "$pgid" != "$root_pid" ]] || continue
      child_marker="$BASE_TMP/owned-pgid-$i.marker"
      if ap_live_write_group_marker "$pgid" "$child_marker"; then
        ap_live_cleanup_pgid "$pgid" "$child_marker" "$profile_dir" || true
      else
        printf 'WARNING: could not record identity for owned process group %s\n' "$pgid" >&2
        rm -f "$child_marker"
      fi
      i=$((i + 1))
    done < <(ap_live_owned_pgids "$root_pid" "$profile_dir")
  fi

  if [[ -n "$marker" && -f "$marker" ]]; then
    ap_live_cleanup_pgid "$root_pid" "$marker" "$profile_dir" || true
  fi

  local survivors=""
  if [[ -n "$profile_dir" ]]; then
    survivors=$(ap_live_profile_pids "$profile_dir")
  fi
  if [[ -n "$survivors" ]]; then
    printf 'ERROR: profile processes survived owned cleanup: %s\n' "$survivors" >&2
    # Keep the state so the EXIT trap can retry once.
    return 1
  fi

  STARTUP_ROOT_PID=""
  STARTUP_MARKER=""
  STARTUP_PROFILE_DIR=""
  return 0
}

codex_live_start_inotify() {
  local target
  INOTIFY_LOG="$BASE_TMP/host-inotify.log"
  : >"$INOTIFY_LOG"
  for target in "$HOME/.codex" "$HOME/.agents"; do
    [[ -d "$target" ]] || continue
    inotifywait -m -q -r \
      -e access,open,create,modify,attrib,delete,moved_to,moved_from,close_write \
      "$target" >>"$INOTIFY_LOG" 2>&1 &
    INOTIFY_PIDS+=("$!")
  done
  sleep 0.5
}

codex_live_stop_inotify() {
  local pid
  for pid in "${INOTIFY_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  INOTIFY_PIDS=()
}

codex_live_run_with_synthetic_env_key() {
  local helper="$1" profile="$2"
  shift 2
  local env_args=(
    PATH="$PATH"
    HOME="$HOME"
    USER="${USER:-testuser}"
    LOGNAME="${LOGNAME:-testuser}"
    TERM="${TERM:-dumb}"
    LANG="${LANG:-C.UTF-8}"
    DISABLE_TELEMETRY=1
    OPENAI_API_KEY="$SYNTHETIC_ENV_KEY"
  )
  local var
  for var in MISE_CONFIG_DIR MISE_DATA_DIR MISE_STATE_DIR MISE_CACHE_DIR; do
    [[ -n "${!var:-}" ]] && env_args+=("$var=${!var}")
  done
  env -i "${env_args[@]}" \
    bwrap --dev-bind / / --unshare-net -- bash "$helper" run --profile "$profile" -- "$@"
}

codex_live_sanitize() {
  python3 - "$1" <<'PY'
import re
import sys

raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
raw = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", raw)
raw = re.sub(r"\x1b[@-Z\\-_]|\x1b\[[0-?]*[ -/]*[@-~]", "", raw)
raw = raw.replace("\r", "")
sys.stdout.write(raw)
PY
}

cleanup() {
  codex_live_stop_inotify || true
  codex_live_stop_startup || true
  rm -rf "$BASE_TMP"
}
trap cleanup EXIT HUP INT TERM

printf '=== Codex Live QA Probe ===\n'
printf 'Time: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Subject: %s\n' "$REPO_ROOT"
printf 'Codex CLI: %s\n\n' "$(command -v codex 2>/dev/null || echo not-found)"

# Disposable synthetic host and fixture repository.
ap_live_setup_isolation "$BASE_TMP"
mkdir -p "$HOME/.codex"
printf '{\n  "syntheticAuthMarker": "codex-host-auth-must-not-be-read"\n}\n' \
  >"$HOME/.codex/auth.json"
ap_live_create_synthetic_home "$HOME"

FIXTURE_REPO="$BASE_TMP/project-repo"
mkdir -p "$FIXTURE_REPO"
git -C "$FIXTURE_REPO" init --quiet
git -C "$FIXTURE_REPO" config user.name "Test User"
git -C "$FIXTURE_REPO" config user.email "test@example.com"

codex_live_start_inotify

# ---------------------------------------------------------------------------
# Class 1: version (informational; --version is not startup evidence)
# ---------------------------------------------------------------------------
printf '%s\n' '--- Class 1: Version Probe (informational) ---'
DOCTOR_JSON=$(cd "$FIXTURE_REPO" && bash "$AP_HELPER" doctor --json --agent codex)
CODEX_VERSION=$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
agent = data["agents"]["codex"]
print(agent.get("version") or "unknown")
' "$DOCTOR_JSON")
CODEX_PATH=$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
agent = data["agents"]["codex"]
print(agent.get("path") or "unknown")
' "$DOCTOR_JSON")

printf 'Codex version (doctor): %s\n' "$CODEX_VERSION"
printf 'Codex resolved binary (doctor/mise): %s\n' "$CODEX_PATH"
[[ "$CODEX_VERSION" != "unknown" ]] || {
  printf 'ERROR: could not determine Codex version\n' >&2
  exit 1
}
[[ "$CODEX_PATH" != "unknown" ]] || {
  printf 'ERROR: could not resolve a Codex binary\n' >&2
  exit 1
}
[[ "$CODEX_PATH" != *"/bin/mise" && "$CODEX_PATH" != "/usr/bin/mise" ]] || {
  printf 'ERROR: doctor resolved the mise launcher instead of the Codex binary\n' >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Class 2: startup (real TUI launch in a PTY, offline, then owned cleanup)
# ---------------------------------------------------------------------------
printf '\n%s\n' '--- Class 2: Startup Probe (PTY, offline) ---'
cd "$FIXTURE_REPO"
bash "$AP_HELPER" init --profile qa-startup
STARTUP_PROFILE_DIR="$FIXTURE_REPO/.agent-profiles/qa-startup"
STARTUP_LOG="$BASE_TMP/codex-startup.log"
STARTUP_MARKER="$BASE_TMP/codex-startup.pgid"
STARTUP_INNER="$BASE_TMP/codex-startup-inner.sh"

{
  printf '#!/usr/bin/env bash\nexec env -i '
  printf 'PATH=%q HOME=%q USER=%q LOGNAME=%q TERM=xterm-256color LANG=C.UTF-8 DISABLE_TELEMETRY=1 ' \
    "$PATH" "$HOME" "${USER:-testuser}" "${LOGNAME:-testuser}"
  for var in MISE_CONFIG_DIR MISE_DATA_DIR MISE_STATE_DIR MISE_CACHE_DIR; do
    [[ -n "${!var:-}" ]] && printf '%s=%q ' "$var" "${!var}"
  done
  printf 'bwrap --dev-bind / / --unshare-net -- bash %q run --profile qa-startup -- codex\n' \
    "$AP_HELPER"
} >"$STARTUP_INNER"
chmod 700 "$STARTUP_INNER"

(
  cd "$FIXTURE_REPO"
  export AGENT_PROFILES_DIR="$STARTUP_PROFILE_DIR"
  exec setsid script -qfc "stty rows 40 cols 120; bash '$STARTUP_INNER'" /dev/null
) >"$STARTUP_LOG" 2>&1 </dev/null &
STARTUP_ROOT_PID=$!
if ! ap_live_write_group_marker "$STARTUP_ROOT_PID" "$STARTUP_MARKER"; then
  printf 'ERROR: could not record the startup process identity\n' >&2
  kill -TERM -"$STARTUP_ROOT_PID" 2>/dev/null || true
  exit 1
fi

STARTUP_READY=0
STARTUP_SANITIZED="$BASE_TMP/codex-startup.sanitized"
STARTUP_NORMALIZED="$BASE_TMP/codex-startup.normalized"
for _ in $(seq 1 60); do
  # Ratatui may render spaces as cursor moves and may bold part of a word, so
  # strip terminal control sequences before comparing without whitespace.
  codex_live_sanitize "$STARTUP_LOG" >"$STARTUP_SANITIZED" 2>/dev/null || true
  tr -d '[:space:]' <"$STARTUP_SANITIZED" >"$STARTUP_NORMALIZED" 2>/dev/null || true
  if grep -q 'WelcometoCodex' "$STARTUP_NORMALIZED" \
    && grep -qE 'Signinwith(ChatGPT|DeviceCode)|ProvideyourownAPIkey|UseanOpenAIAPIkey' "$STARTUP_NORMALIZED"; then
    STARTUP_READY=1
    break
  fi
  sleep 1
done

if [[ "$STARTUP_READY" -eq 1 ]]; then
  printf 'Startup ready marker found: "Welcome to Codex" with a sign-in/onboarding option.\n'
  printf '%s\n' 'Rendered screen (sanitized):'
  codex_live_sanitize "$STARTUP_LOG" | tail -c 4000
  printf '\n'
else
  printf 'ERROR: Codex TUI did not reach the login/onboarding ready marker\n' >&2
  codex_live_sanitize "$STARTUP_LOG" | tail -c 4000 >&2
  exit 1
fi

STARTUP_OWNED_PIDS=""
while IFS= read -r pid; do
  [[ -n "$pid" ]] || continue
  STARTUP_OWNED_PIDS+="$pid:$(ps -o comm= -p "$pid" 2>/dev/null || echo unknown) "
done < <(ap_live_profile_pids "$STARTUP_PROFILE_DIR")
[[ -n "$STARTUP_OWNED_PIDS" ]] || {
  printf 'ERROR: no descendant carried AGENT_PROFILES_DIR for the QA profile\n' >&2
  exit 1
}
printf 'Profile-owned startup processes: %s\n' "$STARTUP_OWNED_PIDS"
printf 'Startup ran offline under bwrap --unshare-net through the profile wrapper.\n'

codex_live_stop_startup
STARTUP_SURVIVORS=$(ap_live_profile_pids "$STARTUP_PROFILE_DIR")
[[ -z "$STARTUP_SURVIVORS" ]] || {
  printf 'ERROR: profile processes survived owned cleanup: %s\n' "$STARTUP_SURVIVORS" >&2
  exit 1
}
printf 'Owned shutdown verified: no Codex processes remain for qa-startup.\n'

STARTUP_DOCTOR=$(ap_live_run_offline_in_profile \
  "$AP_HELPER" qa-startup codex doctor --json 2>/dev/null || true)
STARTUP_APPSERVER=$(python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
    print(data["checks"]["app_server.status"]["summary"])
except Exception:
    print("unparseable")
' "$STARTUP_DOCTOR")
printf 'App-server state after startup: %s\n' "$STARTUP_APPSERVER"

# ---------------------------------------------------------------------------
# Class 3: discovery (two profiles, repo scope, bundled sources, boundaries)
# ---------------------------------------------------------------------------
printf '\n%s\n' '--- Class 3: Discovery Probe (offline) ---'
cd "$FIXTURE_REPO"
bash "$AP_HELPER" init --profile prof-a
bash "$AP_HELPER" init --profile prof-b
PROFILE_A_DIR="$FIXTURE_REPO/.agent-profiles/prof-a"
PROFILE_B_DIR="$FIXTURE_REPO/.agent-profiles/prof-b"

write_marker_skill() {
  local root="$1" name="$2" description="$3" body="$4"
  mkdir -p "$root/$name"
  {
    printf '%s\n' '---'
    printf 'name: %s\n' "$name"
    printf 'description: %s\n' "$description"
    printf '%s\n' '---'
    printf '%s\n' "# $name"
    printf '%s\n' "$body"
  } >"$root/$name/SKILL.md"
}

# Both user-scope surfaces Codex reads: CODEX_HOME skills and home .agents skills.
write_marker_skill "$PROFILE_A_DIR/.codex/skills" a-codex-home \
  "Profile A marker in CODEX_HOME skills" "A_CODEX_HOME_BODY_MARKER"
write_marker_skill "$PROFILE_A_DIR/.agents/skills" a-agents-home \
  "Profile A marker in home .agents skills" "A_AGENTS_HOME_BODY_MARKER"
write_marker_skill "$PROFILE_B_DIR/.codex/skills" b-codex-home \
  "Profile B marker in CODEX_HOME skills" "B_CODEX_HOME_BODY_MARKER"
write_marker_skill "$PROFILE_B_DIR/.agents/skills" b-agents-home \
  "Profile B marker in home .agents skills" "B_AGENTS_HOME_BODY_MARKER"

# Repository-scope skills on both repository surfaces.
write_marker_skill "$FIXTURE_REPO/.codex/skills" repo-codex-skill \
  "Repository marker in .codex skills" "REPO_CODEX_BODY_MARKER"
write_marker_skill "$FIXTURE_REPO/.agents/skills" repo-agents-skill \
  "Repository marker in .agents skills" "REPO_AGENTS_BODY_MARKER"

printf '%s\n' '# Repository Root Instructions' 'Marker: REPO_ROOT_INSTRUCTION' \
  >"$FIXTURE_REPO/AGENTS.md"
mkdir -p "$FIXTURE_REPO/subdir"
printf '%s\n' '# Subdirectory Instructions' 'Marker: SUBDIR_INSTRUCTION' \
  >"$FIXTURE_REPO/subdir/AGENTS.md"
printf '%s\n' '# Parent Outside Instructions' 'Marker: PARENT_OUTSIDE_INSTRUCTION' \
  >"$BASE_TMP/AGENTS.md"

OUT_A="$BASE_TMP/discovery-a.json"
OUT_B="$BASE_TMP/discovery-b.json"
(cd "$FIXTURE_REPO/subdir" \
  && ap_live_run_offline_in_profile "$AP_HELPER" prof-a codex debug prompt-input "discovery-test" \
    >"$OUT_A" 2>"$BASE_TMP/discovery-a.err")
(cd "$FIXTURE_REPO/subdir" \
  && ap_live_run_offline_in_profile "$AP_HELPER" prof-b codex debug prompt-input "discovery-test" \
    >"$OUT_B" 2>"$BASE_TMP/discovery-b.err")

python3 - "$OUT_A" "$OUT_B" "$HOME" "$FIXTURE_REPO" "$PROFILE_A_DIR" "$PROFILE_B_DIR" <<'PY'
import json
import re
import sys

out_a_path, out_b_path, home, repo, profile_a, profile_b = sys.argv[1:7]

def prompt_text(path):
    data = json.load(open(path))
    chunks = []
    for entry in data:
        for content in entry.get("content", []):
            if isinstance(content, dict) and "text" in content:
                chunks.append(content["text"])
    return "\n".join(chunks)

def skills_section(text):
    match = re.search(r"<skills_instructions>(.*?)</skills_instructions>", text, re.S)
    return match.group(1) if match else ""

def parse(path):
    text = prompt_text(path)
    section = skills_section(text)
    roots = {rid: root for rid, root in re.findall(r"- `r(\d+)` = `([^`]+)`", section)}
    skills = re.findall(r"^- ([a-z0-9][a-z0-9-]*): [^\n]*\(file: r(\d+)/([^)]+)\)", section, re.M)
    return text, roots, skills

def classify(root, profile_dir):
    clean = root.rstrip("/")
    table = {
        profile_dir + "/.codex/skills": "user-codex",
        profile_dir + "/.codex/skills/.system": "bundled",
        home + "/.agents/skills": "user-agents",
        repo + "/.codex/skills": "repo-codex",
        repo + "/.agents/skills": "repo-agents",
    }
    return table.get(clean, "other")

text_a, roots_a, skills_a = parse(out_a_path)
text_b, roots_b, skills_b = parse(out_b_path)

def skill_names(skills):
    return {name for name, _rid, _path in skills}

names_a = skill_names(skills_a)
names_b = skill_names(skills_b)
classes_a = {rid: classify(root, profile_a) for rid, root in roots_a.items()}
classes_b = {rid: classify(root, profile_b) for rid, root in roots_b.items()}

for name in ("a-codex-home", "a-agents-home"):
    assert name in names_a, f"missing profile A marker: {name}"
for name in ("b-codex-home", "b-agents-home"):
    assert name in names_b, f"missing profile B marker: {name}"
for name in ("b-codex-home", "b-agents-home"):
    assert name not in names_a, f"profile B marker leaked into profile A: {name}"
for name in ("a-codex-home", "a-agents-home"):
    assert name not in names_b, f"profile A marker leaked into profile B: {name}"
for name in ("repo-codex-skill", "repo-agents-skill"):
    assert name in names_a, f"repository skill missing in profile A: {name}"
    assert name in names_b, f"repository skill missing in profile B: {name}"

for marker in (
    "A_CODEX_HOME_BODY_MARKER",
    "A_AGENTS_HOME_BODY_MARKER",
    "B_CODEX_HOME_BODY_MARKER",
    "B_AGENTS_HOME_BODY_MARKER",
    "REPO_CODEX_BODY_MARKER",
    "REPO_AGENTS_BODY_MARKER",
):
    assert marker not in text_a and marker not in text_b, (
        f"skill body leaked into model-visible prompt input: {marker}"
    )

for marker in ("REPO_ROOT_INSTRUCTION", "SUBDIR_INSTRUCTION"):
    assert marker in text_a, f"instruction missing in profile A: {marker}"
    assert marker in text_b, f"instruction missing in profile B: {marker}"
assert "PARENT_OUTSIDE_INSTRUCTION" not in text_a, "parent AGENTS.md crossed the repository boundary"
assert "PARENT_OUTSIDE_INSTRUCTION" not in text_b, "parent AGENTS.md crossed the repository boundary"

expected = {"user-codex", "user-agents", "bundled", "repo-codex", "repo-agents"}
assert set(classes_a.values()) == expected, f"unexpected profile A skill roots: {classes_a} roots={roots_a} home={home} repo={repo}"
assert set(classes_b.values()) == expected, f"unexpected profile B skill roots: {classes_b} roots={roots_b} home={home} repo={repo}"

bundled = sorted(name for name, rid, _path in skills_a if classes_a.get(rid) == "bundled")
assert "skill-creator" in bundled, "bundled system skills were not reported"
assert "skill-installer" in bundled, "bundled system skills were not reported"

print("Skill roots (profile A): " + ", ".join(
    f"{rid}={classes_a[rid]}({roots_a[rid]})" for rid in sorted(roots_a)))
print("Bundled system skills: " + ", ".join(bundled))
print("Admin/managed skill roots: none configured (no extra roots observed)")
print("Skill bodies are not included in model-visible prompt input (metadata only).")
print("Instructions: repo root and subdirectory present; parent outside repo absent.")
print("DISCOVERY_VERIFIED profiles-a/b, repo scope, bundled sources, boundary.")
PY

# ---------------------------------------------------------------------------
# Class 4: authentication diagnostics (fresh state, no host import)
# ---------------------------------------------------------------------------
printf '\n%s\n' '--- Class 4: Authentication Diagnostics (offline) ---'
cd "$FIXTURE_REPO"
bash "$AP_HELPER" init --profile qa-auth
AUTH_PROFILE_DIR="$FIXTURE_REPO/.agent-profiles/qa-auth"

AUTH_OUT=""
AUTH_EXIT=0
AUTH_OUT=$(ap_live_run_offline_in_profile "$AP_HELPER" qa-auth codex login status 2>&1) || AUTH_EXIT=$?
printf 'Fresh login status exit: %s\n' "$AUTH_EXIT"
printf 'Fresh login status: %s\n' "$AUTH_OUT"
[[ "$AUTH_EXIT" -ne 0 ]] || {
  printf 'ERROR: fresh profile unexpectedly reported a successful login\n' >&2
  exit 1
}
[[ "$AUTH_OUT" == *"Not logged in"* ]] || {
  printf 'ERROR: fresh profile did not report a logged-out state\n' >&2
  exit 1
}

AUTH_DOCTOR=""
AUTH_DOCTOR=$(ap_live_run_offline_in_profile "$AP_HELPER" qa-auth codex doctor --json 2>/dev/null || true)
python3 - "$AUTH_DOCTOR" "$AUTH_PROFILE_DIR" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
profile_dir = sys.argv[2]
auth = data["checks"]["auth.credentials"]
config = data["checks"]["config.load"]["details"]
assert auth["status"] == "fail", f"unexpected auth status: {auth}"
assert "no Codex credentials" in auth["summary"], f"unexpected auth summary: {auth}"
assert config["CODEX_HOME"] == profile_dir + "/.codex", (
    f"CODEX_HOME was not profile storage: {config['CODEX_HOME']}"
)
assert auth["details"]["auth file"] == profile_dir + "/.codex/auth.json", (
    "auth file was not profile storage"
)
print("Doctor auth: no credentials in fresh profile.")
print(f"Doctor CODEX_HOME: {config['CODEX_HOME']}")
PY

ENV_AUTH_DOCTOR=""
ENV_AUTH_DOCTOR=$(codex_live_run_with_synthetic_env_key \
  "$AP_HELPER" qa-auth codex doctor --json 2>/dev/null || true)
python3 - "$ENV_AUTH_DOCTOR" "$SYNTHETIC_ENV_KEY" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
secret = sys.argv[2]
auth = data["checks"]["auth.credentials"]
text = json.dumps(data)
assert auth["status"] == "ok", f"unexpected env-auth status: {auth}"
assert "environment" in auth["summary"], f"unexpected env-auth summary: {auth}"
assert "OPENAI_API_KEY" in auth["details"]["auth env vars present"], (
    "environment auth variable was not reported"
)
assert secret not in text, "synthetic credential value was exposed in doctor output"
print("Doctor auth with a synthetic environment key: provided by environment.")
print("Credential variable name reported; value is not exposed.")
PY

ENV_LOGIN_EXIT=0
ENV_LOGIN_OUT=$(codex_live_run_with_synthetic_env_key \
  "$AP_HELPER" qa-auth codex login status 2>&1) || ENV_LOGIN_EXIT=$?
[[ "$ENV_LOGIN_EXIT" -ne 0 && "$ENV_LOGIN_OUT" == *"Not logged in"* ]] || {
  printf 'ERROR: environment auth changed reported file login state\n' >&2
  exit 1
}
printf 'Environment-key login status remains: Not logged in (file auth separate).\n'

# ---------------------------------------------------------------------------
# Class 5: read-only sandbox execution inside the profile wrapper
# ---------------------------------------------------------------------------
printf '\n%s\n' '--- Class 5: Sandbox Probe (offline) ---'
cd "$FIXTURE_REPO"
bash "$AP_HELPER" init --profile qa-sandbox
SANDBOX_PROFILE_DIR="$FIXTURE_REPO/.agent-profiles/qa-sandbox"
SANDBOX_PIDS_BEFORE=$(ap_live_profile_pids "$SANDBOX_PROFILE_DIR")

SANDBOX_TARGET="$BASE_TMP/sandbox-denied-$$.txt"
rm -f "$SANDBOX_TARGET"
SANDBOX_OUT=""
SANDBOX_EXIT=0
SANDBOX_OUT=$(ap_live_run_offline_in_profile "$AP_HELPER" qa-sandbox \
  codex sandbox -- sh -c "echo SANDBOX_OK; touch '$SANDBOX_TARGET'" 2>&1) || SANDBOX_EXIT=$?

printf 'Sandbox exit: %s\n' "$SANDBOX_EXIT"
printf 'Sandbox output:\n%s\n' "$SANDBOX_OUT"
[[ "$SANDBOX_EXIT" -ne 0 ]] || {
  printf 'ERROR: sandboxed write denial returned success\n' >&2
  exit 1
}
[[ "$SANDBOX_OUT" == *"SANDBOX_OK"* ]] || {
  printf 'ERROR: harmless sandbox command did not run\n' >&2
  exit 1
}
[[ "$SANDBOX_OUT" == *"Read-only file system"* || "$SANDBOX_OUT" == *"cannot touch"* ]] || {
  printf 'ERROR: no read-only denial was reported\n' >&2
  exit 1
}
[[ ! -f "$SANDBOX_TARGET" ]] || {
  printf 'ERROR: sandboxed command wrote the controlled file\n' >&2
  exit 1
}
SANDBOX_PIDS_AFTER=$(ap_live_profile_pids "$SANDBOX_PROFILE_DIR")
[[ -z "$SANDBOX_PIDS_AFTER" ]] || {
  printf 'ERROR: sandbox left profile processes behind: %s\n' "$SANDBOX_PIDS_AFTER" >&2
  exit 1
}
printf 'Process audit: %s before, 0 after the sandbox probe.\n' "${SANDBOX_PIDS_BEFORE:-0}"

# ---------------------------------------------------------------------------
# Host isolation and final audit
# ---------------------------------------------------------------------------
printf '\n%s\n' '--- Host Isolation Audit ---'
codex_live_stop_inotify
if [[ -s "$INOTIFY_LOG" ]]; then
  printf 'ERROR: synthetic host files were touched:\n' >&2
  cat "$INOTIFY_LOG" >&2
  exit 1
fi
printf 'inotify: no access/open/create/modify/delete events under synthetic host .codex/.agents.\n'
ap_live_verify_host_untouched "$HOME"
printf 'Synthetic host sha256 snapshot unchanged.\n'

for profile_dir in "$STARTUP_PROFILE_DIR" "$PROFILE_A_DIR" "$PROFILE_B_DIR" "$AUTH_PROFILE_DIR" "$SANDBOX_PROFILE_DIR"; do
  [[ -n "$profile_dir" ]] || continue
  leftovers=$(ap_live_profile_pids "$profile_dir")
  [[ -z "$leftovers" ]] || {
    printf 'ERROR: processes remain for %s: %s\n' "$profile_dir" "$leftovers" >&2
    exit 1
  }
done
printf 'Process audit: no profile-owned Codex processes remain.\n'

python3 - "$SUMMARY_JSON" "$REPO_ROOT" "$CODEX_VERSION" "$CODEX_PATH" "$STARTUP_APPSERVER" <<'PY'
import json
import sys

path, subject, version, binary, appserver = sys.argv[1:6]
summary = {
    "subject": subject,
    "codex_version": version,
    "codex_binary": binary,
    "classes": {
        "version": {"status": "pass", "note": "doctor report; --version is not startup"},
        "startup": {
            "status": "pass",
            "mode": "TUI in PTY via script -qfc, offline with bwrap --unshare-net",
            "ready_marker": "Welcome to Codex with sign-in/onboarding options",
            "app_server_after": appserver,
            "cleanup": "owned PGID shutdown; no survivors",
        },
        "discovery": {
            "status": "pass",
            "surfaces": [
                "CODEX_HOME skills",
                "home .agents skills",
                "repo .codex skills",
                "repo .agents skills",
                "bundled .system skills",
            ],
            "instructions": "repo root and subdirectory present; parent outside repo absent",
            "admin_roots": [],
        },
        "auth": {
            "status": "pass",
            "fresh_profile": "Not logged in",
            "doctor_no_credentials": "fail: no Codex credentials were found",
            "doctor_environment_key": "ok: auth is provided by environment (name only)",
            "host_auth_config_imported": False,
        },
        "sandbox": {
            "status": "pass",
            "surface": "codex sandbox -- sh -c (default read-only policy)",
            "denial": "Read-only file system",
            "controlled_file_absent": True,
        },
    },
    "credential_gap": (
        "Approved gap: no live model response or explicit profile-skill invocation was run; "
        "that requires separately authorized credentials."
    ),
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2)
    handle.write("\n")
print(f"Summary: {path}")
PY

printf '\n%s\n' '--- Credential-Dependent Model Checks ---'
printf 'STATUS: approved gap: live model response and explicit profile-skill invocation not run\n'
printf '(no authorized credentials were provisioned for disposable QA).\n'

printf '\n=== All Codex Live QA Probes PASSED ===\n'
printf 'Raw log: %s\n' "$RAW_LOG"
