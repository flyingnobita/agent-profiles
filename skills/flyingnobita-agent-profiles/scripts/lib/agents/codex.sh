#!/usr/bin/env bash
# Agent module: codex (Codex CLI)
# shellcheck disable=SC2034

ap_agent_codex_info() {
  AGENT_ID="codex"
  AGENT_BINARY="codex"
  AGENT_DISPLAY_NAME="Codex CLI"
  AGENT_PROBE_ARGS=("--version")
  AGENT_CONFIG_DIR_VAR="CODEX_HOME"
}

ap_agent_codex_detect() {
  if command -v mise >/dev/null 2>&1; then
    local p
    p=$(mise which codex 2>/dev/null || true)
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
    local cand="$dir/codex"
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

  command -v "codex" 2>/dev/null || true
}

ap_agent_env_codex() {
  local prof_dir="$1"
  export CODEX_HOME="$prof_dir/.codex"
}

ap_doctor_check_codex_profile() {
  if [[ "${PROFILE_SPECIFIED:-0}" -ne 1 || -z "${SELECTED_PROFILE:-}" ]]; then
    return 0
  fi

  if [[ ${#SELECTED_AGENTS[@]} -gt 0 ]]; then
    local matched=0
    for ag in "${SELECTED_AGENTS[@]}"; do
      if [[ "$ag" == "codex" ]]; then
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
  local codex_dir="$prof_dir/.codex"
  local prof_status="uninitialized"
  local initialized="false"
  local auth_json="false"
  local config_toml="false"
  local sandbox_migration="false"
  local skills_system="false"
  local auth_status="uninitialized"
  local logged_in="null"
  local auth_detail="Profile '$prof_name' not initialized"
  local probe_exit=""
  local env_names_str=""
  local var=""
  local -a env_names=()

  for var in OPENAI_API_KEY OPENAI_BASE_URL OPENAI_ORG_ID OPENAI_PROJECT CODEX_API_KEY; do
    if [[ -n "${!var:-}" ]]; then
      env_names+=("$var")
    fi
  done
  env_names_str="${env_names[*]:-}"

  if [[ -d "$prof_dir" && -d "$prof_dir/home" ]]; then
    prof_status="initialized"
    initialized="true"
    [[ -f "$codex_dir/auth.json" ]] && auth_json="true"
    [[ -f "$codex_dir/config.toml" ]] && config_toml="true"
    [[ -f "$codex_dir/.sandbox_migration" ]] && sandbox_migration="true"
    [[ -d "$codex_dir/skills/.system" ]] && skills_system="true"

    local codex_bin=""
    codex_bin=$(ap_agent_codex_detect 2>/dev/null || true)

    if [[ -z "$codex_bin" ]]; then
      auth_status="unverified"
      auth_detail="Codex binary not found; login state unverified"
    else
      local resolved_bin=""
      resolved_bin=$(readlink -f "$codex_bin" 2>/dev/null || echo "$codex_bin")
      if [[ "$resolved_bin" == *"/bin/mise" || "$resolved_bin" == "/usr/bin/mise" ]]; then
        auth_status="unverified"
        auth_detail="Codex launcher resolved to mise; login state unverified"
      else
        codex_bin="$resolved_bin"
      fi
    fi

    if [[ "$auth_status" != "unverified" ]]; then
      local snap_dir=""
      snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/ap-codex-doctor-XXXXXX" 2>/dev/null || true)

      if [[ -z "$snap_dir" ]]; then
        auth_status="unverified"
        auth_detail="Could not create a disposable login probe snapshot"
      else
        chmod 700 "$snap_dir" 2>/dev/null || true
        local snap_codex="$snap_dir/codex"
        local snap_home="$snap_dir/home"
        mkdir -p "$snap_codex" "$snap_home"

        local copy_ok=1
        if [[ "$auth_json" == "true" ]]; then
          cp -p "$codex_dir/auth.json" "$snap_codex/auth.json" 2>/dev/null || copy_ok=0
        fi
        if [[ "$config_toml" == "true" ]]; then
          cp -p "$codex_dir/config.toml" "$snap_codex/config.toml" 2>/dev/null || copy_ok=0
        fi

        if [[ "$copy_ok" -ne 1 ]]; then
          auth_status="unverified"
          auth_detail="Could not snapshot profile authentication files"
        else
          local probe_out=""
          local probe_rc=0
          local -a probe_env=(
            PATH="$PATH"
            HOME="$snap_home"
            USER="${USER:-testuser}"
            LOGNAME="${LOGNAME:-testuser}"
            TERM=dumb
            LANG="${LANG:-C.UTF-8}"
            DISABLE_TELEMETRY=1
            CODEX_HOME="$snap_codex"
          )
          for var in MISE_CONFIG_DIR MISE_DATA_DIR MISE_STATE_DIR MISE_CACHE_DIR; do
            if [[ -n "${!var:-}" ]]; then
              probe_env+=("$var=${!var}")
            fi
          done

          probe_out=$(env -i "${probe_env[@]}" timeout 5 "$codex_bin" login status 2>&1) || probe_rc=$?
          probe_exit="$probe_rc"

          if [[ "$probe_rc" -eq 124 ]]; then
            auth_status="unverified"
            auth_detail="Login status probe timed out"
          elif [[ "$probe_out" == *"Not logged in"* ]]; then
            auth_status="logged_out"
            logged_in="false"
            auth_detail="codex login status reports no login"
          elif [[ "$probe_rc" -eq 0 && "$probe_out" == *"Logged in"* ]]; then
            auth_status="login_reported"
            logged_in="null"
            auth_detail="codex login status reports a login; credentials were not validated"
          else
            auth_status="unverified"
            auth_detail="Login status probe did not report a recognized state"
          fi
        fi

        rm -rf "$snap_dir"
      fi
    fi
  fi

  AGENTS_JSON=$(
    python3 - "$AGENTS_JSON" "$prof_name" "$prof_status" "$initialized" \
      "$codex_dir" "$auth_json" "$config_toml" "$sandbox_migration" "$skills_system" \
      "$auth_status" "$logged_in" "$auth_detail" "$probe_exit" "$env_names_str" <<'PY'
import json
import sys

agents = json.loads(sys.argv[1])
if "codex" not in agents:
    print(json.dumps(agents))
    raise SystemExit(0)

logged_in = {"null": None, "false": False, "true": True}[sys.argv[11]]
probe_exit = None if sys.argv[13] == "" else int(sys.argv[13])
env_names = sys.argv[14].split() if sys.argv[14] else []
auth_detail = sys.argv[12]

agents["codex"]["profile"] = {
    "name": sys.argv[2],
    "status": sys.argv[3],
    "initialized": sys.argv[4] == "true",
    "config_dir": sys.argv[5],
    "artifacts": {
        "auth_json": sys.argv[6] == "true",
        "config_toml": sys.argv[7] == "true",
        "sandbox_migration": sys.argv[8] == "true",
        "skills_system": sys.argv[9] == "true",
    },
    "auth": {
        "logged_in": logged_in,
        "status": sys.argv[10],
        "detail": auth_detail,
        "probe_exit": probe_exit,
        "env_credentials": env_names,
    },
}
print(json.dumps(agents))
PY
  )
}
