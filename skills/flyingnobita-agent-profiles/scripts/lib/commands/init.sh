#!/usr/bin/env bash
# Command: init
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/runtime.sh

source "$LIB_DIR/runtime.sh"

ap_cmd_init() {
  local profile=""
  local profile_specified=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        if [[ $# -lt 2 ]]; then
          ap_die "$EX_USAGE" "--profile requires a profile name argument"
        fi
        profile="$2"
        profile_specified=1
        shift 2
        ;;
      --profile=*)
        profile="${1#*=}"
        profile_specified=1
        shift
        ;;
      *)
        ap_die "$EX_USAGE" "unknown option for init: '$1'"
        ;;
    esac
  done

  if [[ $profile_specified -eq 0 ]]; then
    profile="default"
  fi

  local repo_root
  repo_root=$(ap_find_repo_root)

  ap_init_profile "$repo_root" "$profile"
}
