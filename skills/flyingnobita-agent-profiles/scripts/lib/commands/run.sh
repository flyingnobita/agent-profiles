#!/usr/bin/env bash
# Command: run
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/runtime.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/mise.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/locks.sh

source "$LIB_DIR/runtime.sh"
source "$LIB_DIR/mise.sh"
source "$LIB_DIR/locks.sh"

ap_cmd_run() {
  local profile="default"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        if [[ $# -lt 2 ]]; then
          ap_die "$EX_USAGE" "--profile requires a profile name argument"
        fi
        profile="$2"
        shift 2
        ;;
      --profile=*)
        profile="${1#*=}"
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        ap_die "$EX_USAGE" "unknown option for run: '$1'"
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    ap_die "$EX_USAGE" "missing command to run"
  fi

  ap_validate_profile_name "$profile"

  local repo_root
  repo_root=$(ap_find_repo_root)

  # 1. Preflight first: an interrupted operation must answer with "run recover"
  # instead of "not initialized" after the data was moved away.
  ap_run_preflight "$repo_root" "$profile"

  ap_check_profile_aliasing "$repo_root" "$profile"

  local prof_dir="$repo_root/.agent-profiles/$profile"

  if [[ ! -d "$prof_dir/home" ]]; then
    ap_die "$EX_NOINPUT" "profile '$profile' is not initialized in this checkout (run 'agent-profiles init --profile $profile' first)"
  fi

  # Nested execution detection based on live bind evidence in /proc/self/mountinfo
  local live_context
  live_context=$(ap_check_live_profile_context "$repo_root" "$profile")

  if [[ "$live_context" == "DIFFERENT" ]]; then
    ap_die "$EX_BUSY" "nested execution inside another profile or checkout is prohibited (active profile mount mismatch)"
  elif [[ "$live_context" == "SAME" ]]; then
    # Same-profile nested execution: do not re-wrap with bwrap
    # Take an additional compatible shared lease
    ap_lease_profile_shared "$repo_root" "$profile"

    # Rebuild deduped environment from preserved base path
    ap_prepare_profile_env "$repo_root" "$profile"

    exec "$@"
  fi

  ap_ensure_locks_dir "$repo_root"

  # 2. Shared storage lock
  ap_lock_storage_shared "$repo_root"

  # 3. Shared profile lease (held across command lifetime and descendants)
  ap_lease_profile_shared "$repo_root" "$profile"

  # 4. Append boot_id and start_ticks to .locks/<profile>.runs
  ap_record_run "$repo_root" "$profile"

  # 5. Release storage lock before exec (profile lease fd stays open)
  ap_unlock_storage

  ap_check_bwrap_readiness

  # Capture effective mise directories BEFORE resetting managed environment variables
  ap_capture_effective_mise_dirs

  ap_prepare_profile_env "$repo_root" "$profile"
  ap_build_bwrap_mounts "$repo_root" "$profile"

  exec bwrap --dev-bind / / "${BWRAP_MOUNT_ARGS[@]}" --die-with-parent -- "$@"
}
