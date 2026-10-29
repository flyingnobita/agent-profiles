#!/usr/bin/env bash
# Agent module: opencode (OpenCode)
# shellcheck disable=SC2034

ap_agent_opencode_info() {
  AGENT_ID="opencode"
  AGENT_BINARY="opencode"
  AGENT_DISPLAY_NAME="OpenCode"
  AGENT_PROBE_ARGS=("--version")
  AGENT_CONFIG_DIR_VAR="OPENCODE_CONFIG_DIR"
}

ap_agent_opencode_detect() {
  command -v "opencode" 2>/dev/null || true
}

# OpenCode 2.2.0 treats OPENCODE_CONFIG_DIR as a replacement for the XDG
# configuration root, not an additional source: with both roots populated only
# the OPENCODE_CONFIG_DIR document is loaded (see references/agents/opencode.md).
# Data, state and cache stay on the profile XDG redirect.
ap_agent_env_opencode() {
  local prof_dir="$1"
  local opencode_dir="$prof_dir/.opencode"

  if [[ ! -d "$opencode_dir" ]]; then
    (umask 077 && mkdir -p "$opencode_dir")
  fi

  export OPENCODE_CONFIG_DIR="$opencode_dir"
}

# OpenCode 2.2 starts a detached background service on a fixed host-wide port
# (49374). Started from a profile it outlives the session, keeps the profile
# environment and blocks the host's own service on that port. Profile runs
# therefore get a private --standalone server, inserted right after the binary,
# for the TUI and for each command that accepts the flag in OpenCode 2.2. Other
# commands reject it and run unchanged, as does a command line that already
# chooses --standalone or --server.
ap_agent_args_opencode() {
  local arg skip_value=0
  local -a words=()

  for arg in "${@:2}"; do
    if [[ "$skip_value" -eq 1 ]]; then
      skip_value=0
      continue
    fi
    case "$arg" in
      --standalone | --server | --server=*)
        return 0
        ;;
      --log-level | --session | -s | --prompt | --completions)
        skip_value=1
        ;;
      -*) ;;
      *)
        words+=("$arg")
        ;;
    esac
  done

  case "${words[0]:-} ${words[1]:-}" in
    "run "* | "mini "* | "api "* | "auth "* | "models "* | "session "* | "stats "* | "reload "*) ;;
    "mcp list" | "mcp auth" | "mcp logout") ;;
    "debug agents" | "debug config") ;;
    "plugin list" | "plugin check" | "plugin update") ;;
    "mcp "* | "debug "* | "plugin "*)
      return 0
      ;;
    "acp "* | "service "* | "serve "* | "upgrade "* | "update "* | "uninstall "* | "pair "*)
      return 0
      ;;
  esac

  AP_COMMAND=("$1" --standalone "${@:2}")
}

# Reports whether the shared OpenCode background-service port is listening. The
# default port is fixed by the installed CLI, so a listener there belongs to a
# host-wide service outside any profile. Read-only: /proc/net is inspected and no
# service is started. AP_OPENCODE_SERVICE_PORT exists only so tests can exercise
# this classification against a test-owned socket.
ap_opencode_service_port_status() {
  local port="${1:-${AP_OPENCODE_SERVICE_PORT:-49374}}"
  local hex="" readable=0 listening=0 file status

  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    OPENCODE_SERVICE_PORT_STATUS="unverified"
    OPENCODE_SERVICE_PORT_DETAIL="service port '$port' is not numeric"
    return 0
  fi

  hex=$(printf '%04X' "$port" 2>/dev/null || true)

  for file in /proc/net/tcp /proc/net/tcp6; do
    [[ -r "$file" ]] || continue
    readable=1
    if awk -v hex="$hex" '
      NR > 1 {
        split($2, parts, ":")
        if (parts[2] == hex && $4 == "0A") { found = 1 }
      }
      END { exit found ? 0 : 1 }
    ' "$file"; then
      listening=1
    fi
  done

  if [[ "$listening" -eq 1 ]]; then
    OPENCODE_SERVICE_PORT_STATUS="listening"
    OPENCODE_SERVICE_PORT_DETAIL="a listener on the shared default port belongs to a service outside this profile"
  elif [[ "$readable" -eq 1 ]]; then
    OPENCODE_SERVICE_PORT_STATUS="not_listening"
    OPENCODE_SERVICE_PORT_DETAIL="no listener on the shared default port was observed"
  else
    OPENCODE_SERVICE_PORT_STATUS="unverified"
    OPENCODE_SERVICE_PORT_DETAIL="/proc/net/tcp is not readable; the shared service port was not classified"
  fi

  OPENCODE_SERVICE_PORT="$port"
  return 0
}

# Reads provider integration ids from the profile database in read-only mode.
# Only identifiers are printed; credential columns are never selected.
ap_opencode_credential_providers() {
  local db="$1"

  [[ -f "$db" ]] || return 0

  python3 - "$db" <<'PY' 2>/dev/null || true
import sqlite3
import sys

try:
    con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    rows = con.execute("select distinct integration_id from credential").fetchall()
    con.close()
except Exception:
    raise SystemExit(0)

for (ident,) in rows:
    if not ident:
        continue
    text = str(ident).replace("\n", " ").replace("\t", " ").strip()
    if text:
        print(text)
PY
}

ap_doctor_check_opencode_profile() {
  if [[ "${PROFILE_SPECIFIED:-0}" -ne 1 || -z "${SELECTED_PROFILE:-}" ]]; then
    return 0
  fi

  if [[ ${#SELECTED_AGENTS[@]} -gt 0 ]]; then
    local matched=0
    for ag in "${SELECTED_AGENTS[@]}"; do
      if [[ "$ag" == "opencode" ]]; then
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
  local config_dir="$prof_dir/.opencode"
  local data_dir="$prof_dir/.local/share/opencode"
  local state_dir="$prof_dir/.local/state/opencode"
  local cache_dir="$prof_dir/.cache/opencode"
  local legacy_auth="$data_dir/auth.json"
  local database="$data_dir/opencode.db"
  local prof_status="uninitialized"
  local initialized="false"
  local config_present="false"
  local config_document="false"
  local skills_present="false"
  local data_present="false"
  local database_present="false"
  local legacy_auth_present="false"
  local state_present="false"
  local cache_present="false"
  local auth_status="uninitialized"
  local auth_detail="Profile '$prof_name' not initialized"
  local env_names_str=""
  local profile_files_str=""
  local providers_str=""
  local mise_managed="false"
  local var=""
  local -a env_names=()
  local -a profile_files=()
  local -a providers=()
  local -a candidate_files=(
    ".local/share/opencode/auth.json"
  )
  local -a credential_env_names=(
    ANTHROPIC_API_KEY
    OPENAI_API_KEY
    AZURE_OPENAI_API_KEY
    GEMINI_API_KEY
    GOOGLE_GENERATIVE_AI_API_KEY
    DEEPSEEK_API_KEY
    OPENROUTER_API_KEY
    GROQ_API_KEY
    MISTRAL_API_KEY
    XAI_API_KEY
    TOGETHER_API_KEY
    CEREBRAS_API_KEY
    COHERE_API_KEY
    PERPLEXITY_API_KEY
    FIREWORKS_API_KEY
    MOONSHOT_API_KEY
    ZAI_API_KEY
    OPENCODE_API_KEY
  )

  for var in "${credential_env_names[@]}"; do
    if [[ -n "${!var:-}" ]]; then
      env_names+=("$var")
    fi
  done
  env_names_str="${env_names[*]:-}"

  if command -v mise >/dev/null 2>&1 && mise which opencode >/dev/null 2>&1; then
    mise_managed="true"
  fi

  OPENCODE_SERVICE_PORT_STATUS="unverified"
  OPENCODE_SERVICE_PORT_DETAIL="not queried"
  OPENCODE_SERVICE_PORT=""
  ap_opencode_service_port_status

  if [[ -d "$prof_dir" && -d "$prof_dir/home" ]]; then
    prof_status="initialized"
    initialized="true"

    [[ -d "$config_dir" ]] && config_present="true"
    if [[ -f "$config_dir/opencode.json" || -f "$config_dir/opencode.jsonc" ]]; then
      config_document="true"
    fi
    if [[ -d "$config_dir/skills" || -d "$config_dir/skill" ]]; then
      skills_present="true"
    fi
    [[ -d "$data_dir" ]] && data_present="true"
    [[ -f "$database" ]] && database_present="true"
    [[ -d "$state_dir" ]] && state_present="true"
    [[ -d "$cache_dir" ]] && cache_present="true"

    for var in "${candidate_files[@]}"; do
      if [[ -f "$prof_dir/$var" ]]; then
        legacy_auth_present="true"
        profile_files+=("$var")
      fi
    done

    while IFS= read -r provider; do
      [[ -n "$provider" ]] && providers+=("$provider")
    done < <(ap_opencode_credential_providers "$database")
  fi
  profile_files_str="${profile_files[*]:-}"
  providers_str="${providers[*]:-}"

  if [[ "$prof_status" == "uninitialized" ]]; then
    auth_status="uninitialized"
    auth_detail="Profile '$prof_name' not initialized"
  elif [[ ${#profile_files[@]} -gt 0 || ${#providers[@]} -gt 0 ]]; then
    auth_status="profile_credential_files"
    auth_detail="Profile-stored credentials are present; account state was not validated"
  else
    auth_status="no_profile_credentials"
    auth_detail="No profile-stored credentials were found; account state was not validated"
  fi

  if [[ ${#env_names[@]} -gt 0 ]]; then
    auth_detail="$auth_detail; authentication environment variables are set (names only)"
  fi
  if [[ "$OPENCODE_SERVICE_PORT_STATUS" == "listening" ]]; then
    auth_detail="$auth_detail; a shared background service port is listening outside the profile"
  fi

  AGENTS_JSON=$(
    python3 - "$AGENTS_JSON" "$prof_name" "$prof_status" "$initialized" \
      "$config_dir" "$config_present" "$config_document" "$skills_present" \
      "$data_present" "$database_present" "$legacy_auth_present" \
      "$state_present" "$cache_present" "$auth_status" "$auth_detail" \
      "$profile_files_str" "$env_names_str" "$providers_str" \
      "$OPENCODE_SERVICE_PORT" "$OPENCODE_SERVICE_PORT_STATUS" \
      "$OPENCODE_SERVICE_PORT_DETAIL" "$mise_managed" <<'PY'
import json
import sys

agents = json.loads(sys.argv[1])
if "opencode" not in agents:
    print(json.dumps(agents))
    raise SystemExit(0)

profile_files = sys.argv[16].split() if sys.argv[16] else []
env_names = sys.argv[17].split() if sys.argv[17] else []
providers = sys.argv[18].split() if sys.argv[18] else []
port = int(sys.argv[19]) if sys.argv[19] else None

agents["opencode"]["profile"] = {
    "name": sys.argv[2],
    "status": sys.argv[3],
    "initialized": sys.argv[4] == "true",
    "config_dir": sys.argv[5],
    "artifacts": {
        "config": sys.argv[6] == "true",
        "config_document": sys.argv[7] == "true",
        "skills": sys.argv[8] == "true",
        "data": sys.argv[9] == "true",
        "database": sys.argv[10] == "true",
        "legacy_auth_json": sys.argv[11] == "true",
        "state": sys.argv[12] == "true",
        "cache": sys.argv[13] == "true",
    },
    "auth": {
        "status": sys.argv[14],
        "authenticated": None,
        "detail": sys.argv[15],
        "profile_files": profile_files,
        "credential_providers": providers,
        "env_credentials": env_names,
        "note": (
            "Profile-stored credentials, inherited environment credentials and "
            "shared host services are separate sources; presence is not proof of "
            "account separation, and a successful model response would not be."
        ),
    },
    "shared": {
        "background_service_port": {
            "port": port,
            "status": sys.argv[20],
            "detail": sys.argv[21],
        },
        "mise_managed": sys.argv[22] == "true",
    },
}
print(json.dumps(agents))
PY
  )
}
