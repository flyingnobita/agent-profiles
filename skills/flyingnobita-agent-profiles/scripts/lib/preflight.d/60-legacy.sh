#!/usr/bin/env bash
# Preflight hook: Legacy storage layout detection and refusal
# shellcheck disable=SC2154
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/lifecycle.sh

source "$LIB_DIR/lifecycle.sh"

ap_preflight_check_legacy() {
  local repo_root="$1"
  local legacy_layouts
  legacy_layouts=$(ap_detect_legacy_layouts "$repo_root")

  if [[ -n "$legacy_layouts" ]]; then
    local current_cmd="${cmd:-}"
    if [[ "$current_cmd" == "init" || "$current_cmd" == "run" ]]; then
      ap_die "$EX_REFUSED" "legacy profile storage detected in this checkout (run 'agent-profiles migrate' to migrate legacy data)"
    fi
    if [[ "$current_cmd" == "list" ]]; then
      printf "agent-profiles: notice: legacy profile storage detected in this checkout (run 'agent-profiles migrate')\n" >&2
    fi
  fi
}

ap_preflight_check_legacy "$repo_root"
