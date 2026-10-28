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
  command -v "codex" 2>/dev/null || true
}

ap_agent_env_codex() {
  local prof_dir="$1"
  export CODEX_HOME="$prof_dir/.codex"
}
