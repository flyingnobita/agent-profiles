#!/usr/bin/env bash
# Doctor section: Antigravity CLI profile diagnostics (ticket 06)
# shellcheck disable=SC2034

# Agent modules register their own diagnostics when sourced. Doctor sources
# this section before running the section list, so the registration is visible
# to the current loop.
ap_agy_agent_module="$LIB_DIR/agents/agy.sh"
if [[ -f "$ap_agy_agent_module" ]]; then
  # shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/agents/agy.sh
  source "$ap_agy_agent_module"
  if declare -F ap_doctor_check_agy_profile >/dev/null 2>&1; then
    ap_register_doctor_section "ap_doctor_check_agy_profile"
  fi
fi
unset ap_agy_agent_module
