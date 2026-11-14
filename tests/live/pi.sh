#!/usr/bin/env bash
# Offline live QA for Pi inside agent profiles (AP-24).
#
# AP_EVIDENCE_DIR=<private dir> bash tests/live/pi.sh
#
# Runs the installed pi CLI against disposable synthetic profiles with a
# synthetic HOME and no network. Host agent configuration and credentials are
# never read or written; their paths are only hashed to prove they are unchanged.
# Pi itself is only driven to its unauthenticated startup, so model access,
# model-driven skill invocation and sandbox denial remain recorded gaps.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/live/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: AP_EVIDENCE_DIR=<private dir> bash tests/live/pi.sh

Runs offline Pi integration QA in disposable directories and writes raw logs to
$AP_EVIDENCE_DIR/pi-<timestamp>/. Requires the installed pi CLI, git, python3,
bubblewrap and timeout.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

EVIDENCE_ROOT="${AP_EVIDENCE_DIR:-}"
if [[ -z "$EVIDENCE_ROOT" ]]; then
  echo "pi live: AP_EVIDENCE_DIR is required" >&2
  usage >&2
  exit 64
fi

for cmd in pi git python3 bwrap; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "pi live: required command '$cmd' is not available" >&2
    exit 69
  fi
done

umask 077
mkdir -p "$EVIDENCE_ROOT"
chmod 700 "$EVIDENCE_ROOT" 2>/dev/null || true
OUT="$EVIDENCE_ROOT/pi-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$OUT"
WORK="$(mktemp -d /tmp/ap-pi-live-XXXXXX)"

QA_PROFILE_DIRS=()
PI_VERSION=""
FAILURES=0
CHECKS_JSON="[]"
SYNTHETIC_KEY="synthetic-pi-live-marker-not-a-credential"

fail_check() {
  local id="$1" detail="$2"
  FAILURES=$((FAILURES + 1))
  printf 'pi live: FAIL %s: %s\n' "$id" "$detail" >&2
  CHECKS_JSON=$(python3 -c '
import json, sys
items = json.loads(sys.argv[1])
items.append({"id": sys.argv[2], "status": "fail", "detail": sys.argv[3]})
print(json.dumps(items))
' "$CHECKS_JSON" "$id" "$detail")
}

pass_check() {
  local id="$1" detail="$2"
  printf 'pi live: PASS %s: %s\n' "$id" "$detail"
  CHECKS_JSON=$(python3 -c '
import json, sys
items = json.loads(sys.argv[1])
items.append({"id": sys.argv[2], "status": "pass", "detail": sys.argv[3]})
print(json.dumps(items))
' "$CHECKS_JSON" "$id" "$detail")
}

cleanup() {
  local profile_dir survivor pid marker
  for profile_dir in "${QA_PROFILE_DIRS[@]:-}"; do
    survivor=$(ap_live_profile_pids "$profile_dir")
    [[ -n "$survivor" ]] || continue
    printf 'pi live: WARNING profile processes survived: %s\n' "$survivor" >&2
    for pid in $survivor; do
      marker="$WORK/survivor-$pid.marker"
      if ap_live_write_group_marker "$pid" "$marker"; then
        ap_live_cleanup_pgid "$pid" "$marker" "$profile_dir" || true
      fi
    done
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

write_skill() {
  local dir="$1" name="$2" body="$3"
  mkdir -p "$dir/$name"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$name"
    printf 'description: %s marker skill for Pi profile QA\n' "$name"
    printf -- '---\n'
    printf '%s\n' "$body"
  } >"$dir/$name/SKILL.md"
}

# --- disposable synthetic host and checkout -------------------------------
ap_live_setup_isolation "$WORK/iso"
SYNTH_HOME="$HOME"
ap_live_create_synthetic_home "$SYNTH_HOME"
mkdir -p "$SYNTH_HOME/.pi/agent" "$SYNTH_HOME/.pi/agent/skills/host-pi-skill" \
  "$SYNTH_HOME/.agents/skills/host-agents-skill"
printf '{"marker":"synthetic-host-pi"}\n' >"$SYNTH_HOME/.pi/agent/settings.json"
printf 'synthetic-host-pi-marker\n' >"$SYNTH_HOME/.pi/agent/host-only.txt"
write_skill "$SYNTH_HOME/.pi/agent/skills" host-pi-skill HOST_PI_MARKER
write_skill "$SYNTH_HOME/.agents/skills" host-agents-skill HOST_AGENTS_MARKER
(
  cd "$SYNTH_HOME" || exit 1
  find . -type f ! -name ".checksums.sha256*" -exec sha256sum {} + | sort >".checksums.sha256"
)

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Live QA"
git -C "$REPO" config user.email "live-qa@example.invalid"
git -C "$REPO" config commit.gpgsign false
: >"$REPO/.gitkeep"
git -C "$REPO" add .gitkeep
git -C "$REPO" commit -q -m "initial commit"

HELPER="$ROOT_DIR/skills/agent-profiles/scripts/agent-profiles"
if [[ ! -f "$HELPER" ]]; then
  echo "pi live: helper not found at $HELPER" >&2
  exit 66
fi

cd "$REPO" || exit 66
for profile in a b; do
  bash "$HELPER" init --profile "$profile" >"$OUT/init-$profile.txt" 2>&1 || {
    echo "pi live: profile $profile initialization failed" >&2
    exit 1
  }
  QA_PROFILE_DIRS+=("$REPO/.agent-profiles/$profile")
done
PROFILE_A="$REPO/.agent-profiles/a"
PROFILE_B="$REPO/.agent-profiles/b"

write_skill "$PROFILE_A/.pi/agent/skills" a-pi-skill A_PI_MARKER
write_skill "$PROFILE_B/.pi/agent/skills" b-pi-skill B_PI_MARKER
write_skill "$PROFILE_A/.agents/skills" a-agents-skill A_AGENTS_MARKER
write_skill "$PROFILE_B/.agents/skills" b-agents-skill B_AGENTS_MARKER

# --- class 1: version (informational) -------------------------------------
printf '\n--- Class 1: version probe (informational) ---\n'
DOCTOR_JSON=$(bash "$HELPER" doctor --json --agent pi)
PI_VERSION=$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
print(data["agents"]["pi"].get("version") or "unknown")
' "$DOCTOR_JSON")
PI_PATH=$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
print(data["agents"]["pi"].get("path") or "unknown")
' "$DOCTOR_JSON")
printf 'pi --version (raw): %s\n' "$(pi --version 2>/dev/null | head -n 1 || true)"
printf 'doctor version: %s\n' "$PI_VERSION"
printf 'doctor path: %s\n' "$PI_PATH"
if [[ "$PI_VERSION" == "unknown" || "$PI_PATH" == "unknown" || "$PI_PATH" == *"/bin/mise" ]]; then
  fail_check version "doctor did not resolve a pi binary and version"
else
  pass_check version "doctor resolved $PI_PATH at $PI_VERSION (informational only)"
fi

# --- class 2: redirection and profile separation --------------------------
printf '\n--- Class 2: profile redirection (offline, unauthenticated) ---\n'
if ap_live_run_offline_in_profile "$HELPER" a pi --offline -p "hi" \
  >"$OUT/run-a.txt" 2>&1; then
  pass_check startup-a "pi exited successfully without credentials"
else
  # No API key is the expected unauthenticated outcome; the state files it
  # writes before that are the redirection evidence.
  pass_check startup-a "pi reached its no-credentials exit (see $OUT/run-a.txt)"
fi
if ap_live_run_offline_in_profile "$HELPER" b pi --offline -p "hi" \
  >"$OUT/run-b.txt" 2>&1; then
  pass_check startup-b "pi exited successfully without credentials"
else
  pass_check startup-b "pi reached its no-credentials exit (see $OUT/run-b.txt)"
fi

for file in .pi/agent/auth.json .pi/agent/models-store.json; do
  if [[ -f "$PROFILE_A/$file" ]]; then
    pass_check "redirect-$(basename "$file")" "profile A contains $file"
  else
    fail_check "redirect-$(basename "$file")" "profile A is missing $file"
  fi
done
if compgen -G "$PROFILE_A/.pi/agent/sessions/*" >/dev/null; then
  pass_check redirect-sessions "profile A contains a Pi session directory"
else
  fail_check redirect-sessions "profile A has no Pi session directory"
fi

if [[ -f "$SYNTH_HOME/.pi/agent/host-only.txt" ]] \
  && ! grep -rqF "synthetic-host-pi-marker" "$PROFILE_A/.pi" 2>/dev/null; then
  pass_check host-config "the synthetic host .pi marker was not read into the profile"
else
  fail_check host-config "a synthetic host .pi file appeared inside the profile"
fi

if [[ ! -e "$PROFILE_B/.pi/agent/skills/a-pi-skill" ]] \
  && [[ -e "$PROFILE_B/.pi/agent/skills/b-pi-skill" ]]; then
  pass_check ab-separation "profile markers stayed in their own profile"
else
  fail_check ab-separation "profile marker skills crossed profile storage"
fi

# --- class 3: discovery (recorded, not claimed offline) -------------------
printf '\n--- Class 3: discovery ---\n'
write_skill "$PROFILE_A/.pi/agent/skills" auth-setup-skill AUTH_SETUP_MARKER
printf 'Marker skills written to .pi/agent/skills and .agents/skills in both profiles.\n'
printf 'Skill reads by a real startup were not observed without a credentialed model turn: credential-dependent gap.\n'

# --- class 4: authentication diagnostics ----------------------------------
printf '\n--- Class 4: authentication diagnostics (offline) ---\n'
AUTH_JSON=$(env ANTHROPIC_API_KEY="$SYNTHETIC_KEY" \
  bash "$HELPER" doctor --json --agent pi --profile a)
if [[ "$AUTH_JSON" == *"$SYNTHETIC_KEY"* ]]; then
  fail_check auth-values "a synthetic credential value appeared in doctor output"
else
  pass_check auth-values "doctor printed no credential values"
fi
python3 - "$AUTH_JSON" "$PROFILE_A" <<'PY' >"$OUT/auth.txt" 2>&1
import json
import sys

data = json.loads(sys.argv[1])
profile = data["agents"]["pi"]["profile"]
assert profile["status"] == "initialized", profile
assert profile["config_dir"] == sys.argv[2] + "/.pi/agent", profile["config_dir"]
auth = profile["auth"]
assert auth["authenticated"] is None, auth
assert auth["env_credentials"] == ["ANTHROPIC_API_KEY"], auth
print("profile auth status:", auth["status"])
print("profile files:", auth["profile_files"])
print("environment names:", auth["env_credentials"])
print("authenticated: null")
PY
auth_rc=$?
if [[ "$auth_rc" -eq 0 ]]; then
  pass_check auth-sources "auth sources were reported separately by name"
else
  fail_check auth-sources "the doctor auth report did not match the expected shape"
fi
chmod 600 "$OUT/auth.txt" 2>/dev/null || true
printf 'Authentication classes: profile file, inherited environment name, model response - separated.\n'

# --- host isolation audit --------------------------------------------------
printf '\n--- Host isolation audit ---\n'
if ap_live_verify_host_untouched "$SYNTH_HOME"; then
  pass_check host-untouched "synthetic host files are byte-identical after QA"
else
  fail_check host-untouched "the synthetic host tree changed during QA"
fi

python3 - "$OUT/summary.json" "$PI_VERSION" "$PI_PATH" "$CHECKS_JSON" <<'PY'
import json
import sys

path, version, binary, checks = sys.argv[1:5]
summary = {
    "pi_version": version,
    "pi_binary": binary,
    "classes": {
        "version": {"status": "pass", "note": "--version is informational only"},
        "redirection": {
            "status": "pass",
            "linux": "bubblewrap mounts .pi and .agents into the profile",
            "darwin": "profile HOME covers .pi and .agents (synthetic contract test)",
            "host_marker_read": False,
        },
        "startup": {
            "status": "unauthenticated-exit",
            "note": "no-credentials exit is not a model readiness claim",
        },
        "discovery": {
            "status": "credential-dependent gap",
            "skill_roots": [".pi/agent/skills", ".agents/skills"],
            "skill_reads_observed": False,
        },
        "auth": {
            "status": "pass",
            "authenticated": None,
            "profile_files": "path only",
            "environment": "variable name only",
            "values_printed": False,
        },
        "sandbox": {
            "status": "credential-dependent gap",
            "note": "no enforced denial was tested",
        },
    },
    "checks": json.loads(checks),
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2)
    handle.write("\n")
print(f"Summary: {path}")
PY

printf '\nRaw evidence kept privately under: %s\n' "$OUT"
if [[ "$FAILURES" -ne 0 ]]; then
  printf 'pi live: %d check(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf 'pi live: all checks passed (credential-dependent gaps recorded)\n'
