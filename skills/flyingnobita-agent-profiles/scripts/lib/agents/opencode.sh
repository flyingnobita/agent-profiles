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
