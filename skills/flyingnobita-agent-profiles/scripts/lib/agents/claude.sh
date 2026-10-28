#!/usr/bin/env bash
# Agent module: claude (Claude Code)
# shellcheck disable=SC2034,SC2154,SC2153

ap_agent_claude_info() {
  AGENT_ID="claude"
  AGENT_BINARY="claude"
  AGENT_DISPLAY_NAME="Claude Code"
  AGENT_PROBE_ARGS=("--version")
  AGENT_CONFIG_DIR_VAR="CLAUDE_CONFIG_DIR"
}

ap_agent_claude_detect() {
  command -v "claude" 2>/dev/null || true
}

ap_agent_env_claude() {
  local prof_dir="$1"
  local claude_dir="$prof_dir/.claude"

  if [[ ! -d "$claude_dir" ]]; then
    (umask 077 && mkdir -p "$claude_dir")
  fi

  export CLAUDE_CONFIG_DIR="$claude_dir"
  unset CLAUDE_SECURESTORAGE_CONFIG_DIR
}

ap_doctor_check_claude_profile() {
  if [[ "${PROFILE_SPECIFIED:-0}" -ne 1 || -z "${SELECTED_PROFILE:-}" ]]; then
    return 0
  fi

  if [[ ${#SELECTED_AGENTS[@]} -gt 0 ]]; then
    local matched=0
    for ag in "${SELECTED_AGENTS[@]}"; do
      if [[ "$ag" == "claude" ]]; then
        matched=1
        break
      fi
    done
    [[ "$matched" -eq 0 ]] && return 0
  fi

  local prof_name="$SELECTED_PROFILE"
  local repo_root=""
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -z "$repo_root" ]]; then
    return 0
  fi

  local prof_dir="$repo_root/.agent-profiles/$prof_name"
  local claude_dir="$prof_dir/.claude"
  local prof_status="uninitialized"
  local logged_in="false"
  local auth_status="logged_out"
  local auth_method="none"
  local auth_detail="No profile credentials stored"

  if [[ -d "$prof_dir" && -d "$prof_dir/home" ]]; then
    prof_status="initialized"
    local creds_file="$claude_dir/.credentials.json"
    local settings_file="$claude_dir/settings.json"
    local env_cred_names=()
    local env_var
    for env_var in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do
      if [[ -n "${!env_var:-}" ]]; then
        env_cred_names+=("$env_var")
      fi
    done

    # A configured apiKeyHelper is a supported credential source. Classify it by
    # name only; never execute the helper or read credential values.
    local api_key_helper="false"
    local helper_flag=""
    if [[ -f "$settings_file" ]]; then
      helper_flag=$(
        python3 - "$settings_file" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(1)
print("true" if isinstance(data, dict) and data.get("apiKeyHelper") else "false")
PY
      ) || helper_flag="false"
    fi
    if [[ "$helper_flag" == "true" ]]; then
      api_key_helper="true"
    fi

    if [[ -f "$creds_file" ]]; then
      logged_in="true"
      auth_status="profile_stored"
      auth_method="profile_stored"
      auth_detail="Profile credential file present (OS keyring not inspected)"
    elif [[ ${#env_cred_names[@]} -gt 0 ]]; then
      local joined_names=""
      for env_var in "${env_cred_names[@]}"; do
        if [[ -n "$joined_names" ]]; then
          joined_names+=", "
        fi
        joined_names+="$env_var"
      done
      logged_in="true"
      auth_status="env_inherited"
      auth_method="environment"
      auth_detail="Credentials inherited from environment: $joined_names (not stored in profile)"
    elif [[ "$api_key_helper" == "true" ]]; then
      logged_in="true"
      auth_status="api_key_helper"
      auth_method="api_key_helper"
      auth_detail="apiKeyHelper configured in profile settings (helper not executed; session state unverified)"
    else
      auth_status="logged_out"
      auth_method="none"
      auth_detail="Fresh profile, not signed in (OS keyring not inspected)"
    fi
  else
    claude_dir="$prof_dir/.claude"
    prof_status="uninitialized"
    auth_status="logged_out"
    auth_method="none"
    auth_detail="Profile '$prof_name' not initialized"
  fi

  AGENTS_JSON=$(python3 -c '
import json, sys

agents = json.loads(sys.argv[1])
prof_name = sys.argv[2]
prof_status = sys.argv[3]
claude_dir = sys.argv[4]
logged_in = (sys.argv[5] == "true")
auth_status = sys.argv[6]
auth_method = sys.argv[7]
auth_detail = sys.argv[8]

if "claude" in agents:
    agents["claude"]["profile"] = {
        "name": prof_name,
        "status": prof_status,
        "config_dir": claude_dir,
        "auth": {
            "logged_in": logged_in,
            "status": auth_status,
            "method": auth_method,
            "detail": auth_detail
        }
    }

print(json.dumps(agents))
' "$AGENTS_JSON" "$prof_name" "$prof_status" "$claude_dir" "$logged_in" "$auth_status" "$auth_method" "$auth_detail")
}
