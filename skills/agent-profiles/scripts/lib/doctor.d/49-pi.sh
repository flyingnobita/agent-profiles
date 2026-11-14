#!/usr/bin/env bash
# Doctor section: Pi profile diagnostics (AP-24)
# shellcheck disable=SC2034

# Agent modules register their own diagnostics when sourced. Doctor sources
# this section before running the section list, so the registration is visible
# to the current loop.
ap_pi_agent_module="$LIB_DIR/agents/pi.sh"
if [[ -f "$ap_pi_agent_module" ]]; then
  # shellcheck source=skills/agent-profiles/scripts/lib/agents/pi.sh
  source "$ap_pi_agent_module"
  if declare -F ap_doctor_check_pi_profile >/dev/null 2>&1; then
    ap_register_doctor_section "ap_doctor_check_pi_profile"
  fi
fi
unset ap_pi_agent_module
