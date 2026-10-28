#!/usr/bin/env bash
# Agent module: agy (Antigravity CLI)
# shellcheck disable=SC2034

ap_agent_agy_info() {
  AGENT_ID="agy"
  AGENT_BINARY="agy"
  AGENT_DISPLAY_NAME="Antigravity CLI"
  AGENT_PROBE_ARGS=("--version")
  AGENT_CONFIG_DIR_VAR=""
}

ap_agent_agy_detect() {
  if command -v mise >/dev/null 2>&1; then
    local p
    p=$(mise which agy 2>/dev/null || true)
    if [[ -n "$p" && -x "$p" ]]; then
      local rp
      rp=$(readlink -f "$p" 2>/dev/null || echo "$p")
      if [[ "$rp" != *"/bin/mise" && "$rp" != "/usr/bin/mise" ]]; then
        printf "%s\n" "$rp"
        return 0
      fi
    fi
  fi

  local old_ifs="$IFS"
  IFS=":"
  for dir in $PATH; do
    [[ -z "$dir" ]] && continue
    local cand="$dir/agy"
    if [[ -x "$cand" && ! -d "$cand" ]]; then
      local rcand
      rcand=$(readlink -f "$cand" 2>/dev/null || echo "$cand")
      if [[ "$rcand" != *"/bin/mise" && "$rcand" != "/usr/bin/mise" ]]; then
        IFS="$old_ifs"
        printf "%s\n" "$rcand"
        return 0
      fi
    fi
  done
  IFS="$old_ifs"

  command -v "agy" 2>/dev/null || true
}

# Antigravity CLI has no configuration-directory environment variable in the
# tested version: it resolves its configuration from HOME (~/.gemini) and the
# XDG config root for plugin secrets. Profile isolation therefore comes from the
# .gemini bind mount plus the XDG redirect, not from an agent variable.
ap_agy_os_credential_service() {
  local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local bus_desc=""
  local out=""
  local rc=0

  if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    bus_desc="DBUS_SESSION_BUS_ADDRESS"
  elif [[ -e "$runtime_dir/bus" ]]; then
    bus_desc="$runtime_dir/bus"
  else
    AGY_SECRET_SERVICE_STATUS="absent"
    AGY_SECRET_SERVICE_DETAIL="no D-Bus session bus socket at $runtime_dir/bus; no OS credential service is reachable"
    AGY_SESSION_BUS_PRESENT="false"
    return 0
  fi

  AGY_SESSION_BUS_PRESENT="true"

  if ! command -v dbus-send >/dev/null 2>&1; then
    AGY_SECRET_SERVICE_STATUS="unverified"
    AGY_SECRET_SERVICE_DETAIL="session bus present but dbus-send is unavailable; OS credential service not queried"
    return 0
  fi

  out=$(timeout 3 dbus-send --session --print-reply --dest=org.freedesktop.DBus \
    /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
    string:org.freedesktop.secrets 2>/dev/null) || rc=$?

  if [[ "$rc" -eq 0 && "$out" == *"boolean true"* ]]; then
    AGY_SECRET_SERVICE_STATUS="present"
    AGY_SECRET_SERVICE_DETAIL="D-Bus session ($bus_desc) offers org.freedesktop.secrets; OS credential storage is shared with the host environment"
  elif [[ "$rc" -eq 0 && "$out" == *"boolean false"* ]]; then
    AGY_SECRET_SERVICE_STATUS="absent"
    AGY_SECRET_SERVICE_DETAIL="D-Bus session ($bus_desc) has no org.freedesktop.secrets owner"
  else
    AGY_SECRET_SERVICE_STATUS="unverified"
    AGY_SECRET_SERVICE_DETAIL="session bus ($bus_desc) did not answer the secret-service name query"
  fi
}

ap_doctor_check_agy_profile() {
  if [[ "${PROFILE_SPECIFIED:-0}" -ne 1 || -z "${SELECTED_PROFILE:-}" ]]; then
    return 0
  fi

  if [[ ${#SELECTED_AGENTS[@]} -gt 0 ]]; then
    local matched=0
    for ag in "${SELECTED_AGENTS[@]}"; do
      if [[ "$ag" == "agy" ]]; then
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
  local gemini_dir="$prof_dir/.gemini"
  local cli_state="$gemini_dir/antigravity-cli"
  local config_dir="$gemini_dir/config"
  local prof_status="uninitialized"
  local initialized="false"
  local cli_state_present="false"
  local cli_settings="false"
  local config_present="false"
  local skills_dir="false"
  local plugins_dir="false"
  local mcp_config="false"
  local plugin_secrets="false"
  local auth_status="uninitialized"
  local auth_detail=""
  local env_names_str=""
  local profile_files_str=""
  local var=""
  local mise_managed="false"
  local -a env_names=()
  local -a profile_files=()
  local -a candidate_credentials=(
    ".gemini/antigravity-cli/oauth_creds.json"
    ".gemini/antigravity-cli/credentials.json"
    ".config/antigravity/plugin-secrets.json"
  )

  for var in GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CLOUD_PROJECT; do
    if [[ -n "${!var:-}" ]]; then
      env_names+=("$var")
    fi
  done
  env_names_str="${env_names[*]:-}"

  if command -v mise >/dev/null 2>&1 && mise which agy >/dev/null 2>&1; then
    mise_managed="true"
  fi

  if [[ -d "$prof_dir" && -d "$prof_dir/home" ]]; then
    prof_status="initialized"
    initialized="true"

    [[ -d "$cli_state" ]] && cli_state_present="true"
    [[ -f "$cli_state/settings.json" ]] && cli_settings="true"
    [[ -d "$config_dir" ]] && config_present="true"
    [[ -d "$config_dir/skills" ]] && skills_dir="true"
    [[ -d "$config_dir/plugins" ]] && plugins_dir="true"
    [[ -f "$config_dir/mcp_config.json" ]] && mcp_config="true"
    [[ -f "$prof_dir/.config/antigravity/plugin-secrets.json" ]] && plugin_secrets="true"

    for var in "${candidate_credentials[@]}"; do
      if [[ -f "$prof_dir/$var" ]]; then
        profile_files+=("$var")
      fi
    done
  fi
  profile_files_str="${profile_files[*]:-}"

  AGY_SECRET_SERVICE_STATUS="unverified"
  AGY_SECRET_SERVICE_DETAIL="not queried"
  AGY_SESSION_BUS_PRESENT="unknown"
  ap_agy_os_credential_service

  if [[ "$prof_status" == "uninitialized" ]]; then
    auth_status="uninitialized"
    auth_detail="Profile '$prof_name' not initialized"
  elif [[ ${#profile_files[@]} -gt 0 ]]; then
    auth_status="profile_credential_files"
    auth_detail="Profile credential files present; account state was not validated"
  else
    auth_status="no_profile_credentials"
    auth_detail="No recognized profile credential files; account state was not validated"
  fi

  if [[ ${#env_names[@]} -gt 0 ]]; then
    auth_detail="$auth_detail; authentication environment variables are set (names only)"
  fi
  if [[ "$AGY_SECRET_SERVICE_STATUS" == "present" ]]; then
    auth_detail="$auth_detail; an OS credential service is available outside profile isolation"
  fi

  AGENTS_JSON=$(
    python3 - "$AGENTS_JSON" "$prof_name" "$prof_status" "$initialized" \
      "$gemini_dir" "$cli_state_present" "$cli_settings" "$config_present" \
      "$skills_dir" "$plugins_dir" "$mcp_config" "$plugin_secrets" \
      "$auth_status" "$auth_detail" "$profile_files_str" "$env_names_str" \
      "$AGY_SECRET_SERVICE_STATUS" "$AGY_SECRET_SERVICE_DETAIL" \
      "$AGY_SESSION_BUS_PRESENT" "$mise_managed" <<'PY'
import json
import sys

agents = json.loads(sys.argv[1])
if "agy" not in agents:
    print(json.dumps(agents))
    raise SystemExit(0)

status, detail = sys.argv[13], sys.argv[14]
profile_files = sys.argv[15].split() if sys.argv[15] else []
env_names = sys.argv[16].split() if sys.argv[16] else []
service_status, service_detail = sys.argv[17], sys.argv[18]

agents["agy"]["profile"] = {
    "name": sys.argv[2],
    "status": sys.argv[3],
    "initialized": sys.argv[4] == "true",
    "config_dir": sys.argv[5],
    "artifacts": {
        "cli_state": sys.argv[6] == "true",
        "cli_settings": sys.argv[7] == "true",
        "config": sys.argv[8] == "true",
        "skills": sys.argv[9] == "true",
        "plugins": sys.argv[10] == "true",
        "mcp_config": sys.argv[11] == "true",
        "plugin_secrets": sys.argv[12] == "true",
    },
    "auth": {
        "status": status,
        "authenticated": None,
        "detail": detail,
        "profile_files": profile_files,
        "env_credentials": env_names,
        "os_credential_service": {
            "status": service_status,
            "detail": service_detail,
        },
        "note": (
            "Profile files, authentication environment variables, and OS "
            "credential services are separate sources; presence is "
            "not proof of account separation, and a successful model "
            "response would not be."
        ),
    },
    "shared": {
        "session_bus": sys.argv[19] == "true",
        "os_credential_service": service_status,
        "mise_managed": sys.argv[20] == "true",
    },
}
print(json.dumps(agents))
PY
  )
}
