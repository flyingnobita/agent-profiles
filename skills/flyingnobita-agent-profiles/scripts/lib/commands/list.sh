#!/usr/bin/env bash
# Command: list
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/runtime.sh

source "$LIB_DIR/runtime.sh"

ap_cmd_list() {
  local json_mode=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json_mode=1
        shift
        ;;
      *)
        ap_die "$EX_USAGE" "unknown option for list: '$1'"
        ;;
    esac
  done

  local repo_root
  repo_root=$(ap_find_repo_root)

  ap_list_profiles "$repo_root" "$json_mode"
}
