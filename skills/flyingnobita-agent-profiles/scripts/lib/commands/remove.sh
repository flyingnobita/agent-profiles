#!/usr/bin/env bash
# Command: remove - delete an existing agent profile
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/runtime.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/locks.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/procscan.sh

source "$LIB_DIR/runtime.sh"
source "$LIB_DIR/locks.sh"
source "$LIB_DIR/procscan.sh"

ap_cmd_remove() {
  local profile=""
  local profile_specified=0
  local assume_unrelated=""
  local yes_flag=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        [[ $# -ge 2 ]] || ap_die "$EX_USAGE" "--profile requires a profile name argument"
        profile="$2"
        profile_specified=1
        shift 2
        ;;
      --profile=*)
        profile="${1#*=}"
        profile_specified=1
        shift
        ;;
      --assume-unrelated)
        [[ $# -ge 2 ]] || ap_die "$EX_USAGE" "--assume-unrelated requires a PID list argument"
        assume_unrelated="$2"
        shift 2
        ;;
      --assume-unrelated=*)
        assume_unrelated="${1#*=}"
        shift
        ;;
      --yes | -y)
        yes_flag=1
        shift
        ;;
      *)
        ap_die "$EX_USAGE" "unknown option for remove: '$1'"
        ;;
    esac
  done

  if [[ $profile_specified -eq 0 || -z "$profile" ]]; then
    ap_die "$EX_USAGE" "remove requires --profile NAME"
  fi

  local repo_root
  repo_root=$(ap_find_repo_root)

  ap_validate_profile_name "$profile"
  ap_check_profile_aliasing "$repo_root" "$profile"

  # Refuse if executed from inside a live profile context
  local live_context
  live_context=$(ap_check_live_profile_context "$repo_root" "$profile")
  if [[ "$live_context" != "NONE" ]]; then
    ap_die "$EX_BUSY" "cannot run lifecycle operations from inside an active agent profile (run from a host shell)"
  fi

  local prof_dir="$repo_root/.agent-profiles/$profile"
  if [[ ! -d "$prof_dir/home" ]]; then
    ap_die "$EX_NOINPUT" "profile '$profile' is not initialized in this checkout"
  fi

  # Run preflight
  ap_run_preflight "$repo_root" "$profile"

  # Process scan check
  ap_scan_processes "$repo_root" "$profile" "$assume_unrelated"

  if [[ $yes_flag -eq 0 ]]; then
    printf "Remove preview for profile '%s':\n" "$profile"
    printf "  Path: %s\n" "$prof_dir"
    printf "  Consequences: profile directory and all stored settings, transcripts, credentials, and installed tools will be deleted\n"
    printf "Pass --yes to proceed with remove.\n"
    return 0
  fi

  # Mutating logic will be implemented in subsequent slice
}
