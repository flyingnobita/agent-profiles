#!/usr/bin/env bash
# Doctor section: Codex CLI profile diagnostics (ticket 05)
# shellcheck disable=SC2034

# Agent modules register their own diagnostics when sourced. Doctor sources
# this section before running the section list, so the registration is visible
# to the current loop.
ap_codex_agent_module="$LIB_DIR/agents/codex.sh"
if [[ -f "$ap_codex_agent_module" ]]; then
  # shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/agents/codex.sh
  source "$ap_codex_agent_module"
  if declare -F ap_doctor_check_codex_profile >/dev/null 2>&1; then
    ap_register_doctor_section "ap_doctor_check_codex_profile"
  fi
fi
unset ap_codex_agent_module
