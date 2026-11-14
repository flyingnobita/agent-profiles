#!/usr/bin/env bash
# Doctor section: oh-my-pi (omp) profile diagnostics (AP-24)
# shellcheck disable=SC2034

# Agent modules register their own diagnostics when sourced. Doctor sources
# this section before running the section list, so the registration is visible
# to the current loop.
ap_omp_agent_module="$LIB_DIR/agents/omp.sh"
if [[ -f "$ap_omp_agent_module" ]]; then
  # shellcheck source=skills/agent-profiles/scripts/lib/agents/omp.sh
  source "$ap_omp_agent_module"
  if declare -F ap_doctor_check_omp_profile >/dev/null 2>&1; then
    ap_register_doctor_section "ap_doctor_check_omp_profile"
  fi
fi
unset ap_omp_agent_module
