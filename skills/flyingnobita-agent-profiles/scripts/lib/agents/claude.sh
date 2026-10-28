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
  local auth_detail="No profile credentials stored"

  if [[ -d "$prof_dir" && -d "$prof_dir/home" ]]; then
    prof_status="initialized"
    local creds_file="$claude_dir/.credentials.json"
    if [[ -f "$creds_file" ]]; then
      logged_in="true"
      auth_status="authenticated"
      auth_detail="Profile credentials present"
    elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
      auth_status="env_inherited"
      auth_detail="ANTHROPIC_API_KEY inherited from environment (not stored in profile)"
    else
      auth_status="logged_out"
      auth_detail="Fresh profile, not signed in"
    fi
  else
    claude_dir="$prof_dir/.claude"
    prof_status="uninitialized"
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
auth_detail = sys.argv[7]

if "claude" in agents:
    agents["claude"]["profile"] = {
        "name": prof_name,
        "status": prof_status,
        "config_dir": claude_dir,
        "auth": {
            "logged_in": logged_in,
            "status": auth_status,
            "detail": auth_detail
        }
    }

print(json.dumps(agents))
' "$AGENTS_JSON" "$prof_name" "$prof_status" "$claude_dir" "$logged_in" "$auth_status" "$auth_detail")
}
