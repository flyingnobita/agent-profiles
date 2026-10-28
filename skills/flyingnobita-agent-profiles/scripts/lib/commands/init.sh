#!/usr/bin/env bash
# Command: init
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/runtime.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/locks.sh

source "$LIB_DIR/runtime.sh"
source "$LIB_DIR/locks.sh"

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

  ap_validate_profile_name "$profile"

  # Preflight first: legacy layouts and stale journals are refused before any
  # storage or lock directory is created.
  ap_run_preflight "$repo_root" "$profile"

  ap_ensure_storage_dir "$repo_root"
  ap_ensure_locks_dir "$repo_root"
  ap_check_profile_aliasing "$repo_root" "$profile"

  # Short storage lock and profile lease during initialization
  local prof_dir="$repo_root/.agent-profiles/$profile"
  if [[ -d "$prof_dir" ]]; then
    ap_lock_storage_shared "$repo_root"
  else
    ap_lock_storage_exclusive "$repo_root"
  fi

  ap_lease_profile_shared "$repo_root" "$profile"

  ap_init_profile "$repo_root" "$profile"

  ap_unlock_storage
}
