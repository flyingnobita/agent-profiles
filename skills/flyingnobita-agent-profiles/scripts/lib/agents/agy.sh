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
  command -v "agy" 2>/dev/null || true
}
