#!/usr/bin/env bash
# Doctor section: Supported agent CLI detection and synthetic version probes
# shellcheck disable=SC2034

ap_probe_agent_synthetic() {
  local agent_cmd="$1"
  shift
  local agent_args=("$@")
  local temp_dir
  if ! temp_dir=$(mktemp -d 2>/dev/null) || [[ -z "$temp_dir" ]]; then
    # Never fall back to a predictable path, and never delete a path we did not
    # create. The probe is reported as unverified instead.
    PROBE_EXIT=125
    PROBE_PARSED_VERSION=""
    PROBE_FAILURE="temporary directory unavailable"
    return 0
  fi
  local probe_raw=""
  local probe_exit=0

  # Safe extraction of mise dirs: only config/data/state/cache, no arbitrary env vars
  local safe_mise_env=()
  for var in MISE_CONFIG_DIR MISE_DATA_DIR MISE_STATE_DIR MISE_CACHE_DIR; do
    if [[ -n "${!var:-}" ]]; then
      safe_mise_env+=("$var=${!var}")
    fi
  done

  if [[ -z "${MISE_DATA_DIR:-}" ]] && command -v mise >/dev/null 2>&1; then
    local extracted_dirs
    extracted_dirs=$(
      cd "$temp_dir" && env -i PATH="$PATH" HOME="$temp_dir" timeout 2 mise doctor --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin).get("dirs", {})
    for k in ["config", "data", "state", "cache"]:
        v = d.get(k)
        if v and v.startswith("/"):
            print(f"MISE_{k.upper()}_DIR={v}")
except Exception:
    pass
' 2>/dev/null || true
    )
    if [[ -n "$extracted_dirs" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && safe_mise_env+=("$line")
      done <<<"$extracted_dirs"
    fi
  fi

  probe_raw=$(
    cd "$temp_dir" \
      && env -i PATH="$PATH" \
        "${safe_mise_env[@]}" \
        HOME="$temp_dir" \
        XDG_CONFIG_HOME="$temp_dir/.config" \
        XDG_DATA_HOME="$temp_dir/.local/share" \
        XDG_STATE_HOME="$temp_dir/.local/state" \
        XDG_CACHE_HOME="$temp_dir/.cache" \
        CLAUDE_CONFIG_DIR="$temp_dir/.claude" \
        CODEX_HOME="$temp_dir/.codex" \
        OPENCODE_CONFIG_DIR="$temp_dir/.opencode" \
        timeout 3 "$agent_cmd" "${agent_args[@]}" 2>&1
  ) || probe_exit=$?

  rm -rf "$temp_dir"

  PROBE_EXIT="$probe_exit"
  PROBE_PARSED_VERSION=$(echo "$probe_raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)?' | head -n 1 || true)
}

ap_doctor_check_agents() {
  AGENTS_JSON="{}"

  # Source all agent modules under $LIB_DIR/agents
  local agents_dir="$LIB_DIR/agents"
  if [[ -d "$agents_dir" ]]; then
    for script in "$agents_dir"/*.sh; do
      if [[ -f "$script" ]]; then
        # shellcheck source=/dev/null
        source "$script"
      fi
    done
  fi

  local target_agents=("claude" "codex" "agy" "opencode")
  if [[ ${#SELECTED_AGENTS[@]} -gt 0 ]]; then
    target_agents=("${SELECTED_AGENTS[@]}")
  fi

  for agent in "${target_agents[@]}"; do
    local agent_path="" agent_status="" agent_ver="" agent_probe="" agent_hint=""
    local binary="$agent"
    local probe_args=("--version")

    if declare -f "ap_agent_${agent}_info" >/dev/null 2>&1; then
      local AGENT_ID AGENT_BINARY AGENT_DISPLAY_NAME AGENT_PROBE_ARGS AGENT_CONFIG_DIR_VAR
      "ap_agent_${agent}_info"
      binary="${AGENT_BINARY:-$agent}"
      if [[ ${#AGENT_PROBE_ARGS[@]} -gt 0 ]]; then
        probe_args=("${AGENT_PROBE_ARGS[@]}")
      fi
    fi

    if declare -f "ap_agent_${agent}_detect" >/dev/null 2>&1; then
      agent_path=$("ap_agent_${agent}_detect")
    else
      agent_path=$(command -v "$binary" 2>/dev/null || true)
    fi

    if [[ -n "$agent_path" ]]; then
      agent_path=$(readlink -f "$agent_path" 2>/dev/null || echo "$agent_path")

      PROBE_EXIT=0
      PROBE_PARSED_VERSION=""
      ap_probe_agent_synthetic "$agent_path" "${probe_args[@]}"

      if [[ "$PROBE_EXIT" -eq 125 ]]; then
        agent_status="unverified"
        agent_ver=""
        agent_probe="probe_environment"
        agent_hint="temporary directory unavailable; version probe skipped"
      elif [[ "$PROBE_EXIT" -eq 124 ]]; then
        agent_status="unverified"
        agent_ver=""
        agent_probe="timeout"
        agent_hint="version probe timed out after 3 seconds"
      elif [[ "$PROBE_EXIT" -ne 0 ]]; then
        agent_status="unverified"
        agent_ver=""
        agent_probe="probe_failed"
        agent_hint="version probe failed with exit $PROBE_EXIT"
      elif [[ -n "$PROBE_PARSED_VERSION" ]]; then
        agent_status="available"
        agent_ver="$PROBE_PARSED_VERSION"
        agent_probe="verified"
        agent_hint=""
      else
        agent_status="unverified"
        agent_ver=""
        agent_probe="probe_failed"
        agent_hint="could not parse version from probe output"
      fi
    else
      agent_path=""
      agent_status="missing"
      agent_ver=""
      agent_probe="not_found"
      agent_hint="agent binary '$binary' not found on PATH"
    fi

    AGENTS_JSON=$(python3 -c '
import json, sys
agents = json.loads(sys.argv[1])
agents[sys.argv[2]] = {
    "status": sys.argv[3],
    "path": sys.argv[4] if sys.argv[4] else None,
    "version": sys.argv[5] if sys.argv[5] else None,
    "version_probe": sys.argv[6],
    "profile": None,
    "hint": sys.argv[7]
}
print(json.dumps(agents))
' "$AGENTS_JSON" "$agent" "$agent_status" "$agent_path" "$agent_ver" "$agent_probe" "$agent_hint")
  done
}

ap_register_doctor_section "ap_doctor_check_agents"
