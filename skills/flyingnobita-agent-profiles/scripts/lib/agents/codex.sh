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
