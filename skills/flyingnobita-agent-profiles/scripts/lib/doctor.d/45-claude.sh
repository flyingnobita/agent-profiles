#!/usr/bin/env bash
# Doctor section: Claude Code profile diagnostics (ticket 04)
# shellcheck disable=SC2034

# Agent modules register their own diagnostics when sourced. Doctor sources
# this section before running the section list, so the registration is visible
# to the current loop.
ap_claude_agent_module="$LIB_DIR/agents/claude.sh"
if [[ -f "$ap_claude_agent_module" ]]; then
  # shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/agents/claude.sh
  source "$ap_claude_agent_module"
  if declare -F ap_doctor_check_claude_profile >/dev/null 2>&1; then
    ap_register_doctor_section "ap_doctor_check_claude_profile"
  fi
fi
unset ap_claude_agent_module
