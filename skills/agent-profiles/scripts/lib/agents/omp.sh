#!/usr/bin/env bash
# Agent module: omp (oh-my-pi)
# shellcheck disable=SC2034

ap_agent_omp_info() {
  AGENT_ID="omp"
  AGENT_BINARY="omp"
  AGENT_DISPLAY_NAME="oh-my-pi"
  AGENT_PROBE_ARGS=("--version")
  # oh-my-pi reads PI_CODING_AGENT_DIR, the same variable Pi reads for a
  # different directory, so the profile redirects both by HOME instead and
  # clears an inherited value (see references/agents/omp.md).
  AGENT_CONFIG_DIR_VAR="PI_CODING_AGENT_DIR"
}

ap_agent_omp_detect() {
  command -v "omp" 2>/dev/null || true
}

ap_doctor_check_omp_profile() {
  if [[ "${PROFILE_SPECIFIED:-0}" -ne 1 || -z "${SELECTED_PROFILE:-}" ]]; then
    return 0
  fi

  if [[ ${#SELECTED_AGENTS[@]} -gt 0 ]]; then
    local matched=0
    for ag in ${SELECTED_AGENTS[@]+"${SELECTED_AGENTS[@]}"}; do
      if [[ "$ag" == "omp" ]]; then
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
  local config_dir="$prof_dir/.omp"
  local agent_dir="$config_dir/agent"
  local prof_status="uninitialized"
  local initialized="false"
  local agent_dir_present="false"
  local agent_db="false"
  local models_db="false"
  local sessions="false"
  local skills="false"
  local logs="false"
  local natives="false"
  local runtime="false"
  local auth_status="uninitialized"
  local auth_detail="Profile '$prof_name' not initialized"
  local credential_store=""
  local env_names_str=""
  local var=""
  local -a env_names=()

  for var in ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY COPILOT_GITHUB_TOKEN ZAI_API_KEY OPENCODE_API_KEY; do
    if [[ -n "${!var:-}" ]]; then
      env_names+=("$var")
    fi
  done
  env_names_str="${env_names[*]:-}"

  if [[ -d "$prof_dir" && -d "$prof_dir/home" ]]; then
    prof_status="initialized"
    initialized="true"

    [[ -d "$agent_dir" ]] && agent_dir_present="true"
    [[ -f "$agent_dir/agent.db" ]] && agent_db="true"
    [[ -f "$agent_dir/models.db" ]] && models_db="true"
    [[ -d "$agent_dir/sessions" ]] && sessions="true"
    [[ -d "$agent_dir/skills" ]] && skills="true"
    [[ -d "$config_dir/logs" ]] && logs="true"
    [[ -d "$config_dir/natives" ]] && natives="true"
    [[ -d "$config_dir/run" ]] && runtime="true"

    if [[ "$agent_db" == "true" ]]; then
      credential_store=".omp/agent/agent.db"
      auth_status="profile_credential_store"
      auth_detail="Profile credential database present; login state was not validated"
    else
      auth_status="no_profile_credentials"
      auth_detail="No profile credential database was found; login state was not validated"
    fi
  fi

  AGENTS_JSON=$(
    python3 - "$AGENTS_JSON" "$prof_name" "$prof_status" "$initialized" \
      "$config_dir" "$agent_dir" "$agent_dir_present" "$agent_db" \
      "$models_db" "$sessions" "$skills" "$logs" "$natives" "$runtime" \
      "$auth_status" "$auth_detail" "$credential_store" "$env_names_str" <<'PY'
import json
import sys

agents = json.loads(sys.argv[1])
if "omp" not in agents:
    print(json.dumps(agents))
    raise SystemExit(0)

env_names = sys.argv[18].split() if sys.argv[18] else []

agents["omp"]["profile"] = {
    "name": sys.argv[2],
    "status": sys.argv[3],
    "initialized": sys.argv[4] == "true",
    "config_dir": sys.argv[5],
    "agent_dir": sys.argv[6],
    "artifacts": {
        "agent_dir": sys.argv[7] == "true",
        "agent_db": sys.argv[8] == "true",
        "models_db": sys.argv[9] == "true",
        "sessions": sys.argv[10] == "true",
        "skills": sys.argv[11] == "true",
        "logs": sys.argv[12] == "true",
        "natives": sys.argv[13] == "true",
        "runtime": sys.argv[14] == "true",
    },
    "auth": {
        "status": sys.argv[15],
        "authenticated": None,
        "detail": sys.argv[16],
        "credential_store": sys.argv[17] or None,
        "env_credentials": env_names,
        "note": (
            "The profile database stores logins beside other agent state; its "
            "presence is not proof of account separation or of a successful login."
        ),
    },
}
print(json.dumps(agents))
PY
  )
}
