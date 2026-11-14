#!/usr/bin/env bash
# Agent module: pi (Pi coding agent)
# shellcheck disable=SC2034

ap_agent_pi_info() {
  AGENT_ID="pi"
  AGENT_BINARY="pi"
  AGENT_DISPLAY_NAME="Pi"
  AGENT_PROBE_ARGS=("--version")
  # Pi reads PI_CODING_AGENT_DIR, but oh-my-pi reads the same variable for a
  # different directory, so the profile redirects both by HOME instead and
  # clears an inherited value (see references/agents/pi.md).
  AGENT_CONFIG_DIR_VAR="PI_CODING_AGENT_DIR"
}

ap_agent_pi_detect() {
  command -v "pi" 2>/dev/null || true
}

ap_doctor_check_pi_profile() {
  if [[ "${PROFILE_SPECIFIED:-0}" -ne 1 || -z "${SELECTED_PROFILE:-}" ]]; then
    return 0
  fi

  if [[ ${#SELECTED_AGENTS[@]} -gt 0 ]]; then
    local matched=0
    for ag in ${SELECTED_AGENTS[@]+"${SELECTED_AGENTS[@]}"}; do
      if [[ "$ag" == "pi" ]]; then
        matched=1
        break
      fi
    done
    [[ "$matched" -eq 1 ]] || return 0
  fi

  local prof_name="$SELECTED_PROFILE"
  local repo_root=""
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -z "$repo_root" ]]; then
    return 0
  fi

  local prof_dir="$repo_root/.agent-profiles/$prof_name"
  local config_dir="$prof_dir/.pi/agent"
  local prof_status="uninitialized"
  local initialized="false"
  local agent_dir="false"
  local settings_json="false"
  local auth_json="false"
  local sessions="false"
  local skills="false"
  local auth_status="uninitialized"
  local auth_detail="Profile '$prof_name' not initialized"
  local profile_files_str=""
  local env_names_str=""
  local var=""
  local -a profile_files=()
  local -a env_names=()

  for var in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY ZAI_API_KEY OPENCODE_API_KEY; do
    if [[ -n "${!var:-}" ]]; then
      env_names+=("$var")
    fi
  done
  env_names_str="${env_names[*]:-}"

  if [[ -d "$prof_dir" && -d "$prof_dir/home" ]]; then
    prof_status="initialized"
    initialized="true"

    [[ -d "$config_dir" ]] && agent_dir="true"
    [[ -f "$config_dir/settings.json" ]] && settings_json="true"
    [[ -d "$config_dir/sessions" ]] && sessions="true"
    [[ -d "$config_dir/skills" ]] && skills="true"
    if [[ -f "$config_dir/auth.json" ]]; then
      auth_json="true"
      profile_files+=(".pi/agent/auth.json")
    fi
  fi
  profile_files_str="${profile_files[*]:-}"

  if [[ "$prof_status" == "uninitialized" ]]; then
    auth_status="uninitialized"
  elif [[ ${#profile_files[@]} -gt 0 ]]; then
    auth_status="profile_credential_files"
    auth_detail="Profile-stored credentials are present; account state was not validated"
  else
    auth_status="no_profile_credentials"
    auth_detail="No profile-stored credentials were found; account state was not validated"
  fi

  AGENTS_JSON=$(
    python3 - "$AGENTS_JSON" "$prof_name" "$prof_status" "$initialized" \
      "$config_dir" "$agent_dir" "$settings_json" "$auth_json" "$sessions" \
      "$skills" "$auth_status" "$auth_detail" "$profile_files_str" \
      "$env_names_str" <<'PY'
import json
import sys

agents = json.loads(sys.argv[1])
if "pi" not in agents:
    print(json.dumps(agents))
    raise SystemExit(0)

profile_files = sys.argv[13].split() if sys.argv[13] else []
env_names = sys.argv[14].split() if sys.argv[14] else []

agents["pi"]["profile"] = {
    "name": sys.argv[2],
    "status": sys.argv[3],
    "initialized": sys.argv[4] == "true",
    "config_dir": sys.argv[5],
    "artifacts": {
        "agent_dir": sys.argv[6] == "true",
        "settings": sys.argv[7] == "true",
        "auth_json": sys.argv[8] == "true",
        "sessions": sys.argv[9] == "true",
        "skills": sys.argv[10] == "true",
    },
    "auth": {
        "status": sys.argv[11],
        "authenticated": None,
        "detail": sys.argv[12],
        "profile_files": profile_files,
        "env_credentials": env_names,
        "note": (
            "Profile files, inherited environment credentials and model responses "
            "are separate evidence; file presence is not proof of account separation."
        ),
    },
}
print(json.dumps(agents))
PY
  )
}
