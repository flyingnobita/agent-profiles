#!/usr/bin/env bash
# Agent module: claude (Claude Code)
# shellcheck disable=SC2034

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
