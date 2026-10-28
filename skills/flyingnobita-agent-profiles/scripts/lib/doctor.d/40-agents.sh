#!/usr/bin/env bash
# Doctor section: Supported agent CLI detection and synthetic version probes
# shellcheck disable=SC2034

ap_probe_agent_synthetic() {
  local agent_cmd="$1"
  local temp_dir
  temp_dir=$(mktemp -d)
  local probe_out=""
  local probe_status=0

  # Preserved MISE dirs if present in caller environment
  local mise_env=()
  for v in $(env | grep -E '^MISE_' | cut -d= -f1 || true); do
    mise_env+=("$v=${!v}")
  done

  probe_out=$(
    cd "$temp_dir" \
      && env -i PATH="$PATH" \
        "${mise_env[@]}" \
        HOME="$temp_dir" \
        XDG_CONFIG_HOME="$temp_dir/.config" \
        XDG_DATA_HOME="$temp_dir/.local/share" \
        XDG_STATE_HOME="$temp_dir/.local/state" \
        XDG_CACHE_HOME="$temp_dir/.cache" \
        CLAUDE_CONFIG_DIR="$temp_dir/.claude" \
        CODEX_HOME="$temp_dir/.codex" \
        OPENCODE_CONFIG_DIR="$temp_dir/.opencode" \
        timeout 3 "$agent_cmd" --version 2>&1
  ) || probe_status=$?

  rm -rf "$temp_dir"

  if [[ $probe_status -eq 0 ]]; then
    echo "$probe_out" | head -n 1 | tr -d '\r'
  else
    echo "probe failed (exit $probe_status)"
  fi
}

ap_doctor_check_agents() {
  AGENTS_JSON="{}"
  local target_agents=("claude" "codex" "agy" "opencode")

  if [[ ${#SELECTED_AGENTS[@]} -gt 0 ]]; then
    target_agents=("${SELECTED_AGENTS[@]}")
  fi

  for agent in "${target_agents[@]}"; do
    local agent_path agent_status agent_ver agent_probe
    agent_path=$(command -v "$agent" 2>/dev/null || true)
    if [[ -n "$agent_path" ]]; then
      agent_path=$(readlink -f "$agent_path" 2>/dev/null || echo "$agent_path")
      agent_status="available"
      agent_probe=$(ap_probe_agent_synthetic "$agent")
      # Extract semver/version if possible
      agent_ver=$(echo "$agent_probe" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)?' | head -n 1 || echo "unknown")
    else
      agent_path=""
      agent_status="missing"
      agent_ver=""
      agent_probe="not found on PATH"
    fi

    AGENTS_JSON=$(python3 -c '
import json, sys
agents = json.loads(sys.argv[1])
agents[sys.argv[2]] = {
    "status": sys.argv[3],
    "path": sys.argv[4] if sys.argv[4] else None,
    "version": sys.argv[5] if sys.argv[5] else None,
    "version_probe": sys.argv[6],
    "profile": None
}
print(json.dumps(agents))
' "$AGENTS_JSON" "$agent" "$agent_status" "$agent_path" "$agent_ver" "$agent_probe")
  done
}
