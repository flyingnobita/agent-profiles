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
