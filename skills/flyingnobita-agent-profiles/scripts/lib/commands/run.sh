#!/usr/bin/env bash
# Command: run
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/runtime.sh

source "$LIB_DIR/runtime.sh"

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
  local prof_dir="$repo_root/.agent-profiles/$profile"

  if [[ ! -d "$prof_dir/home" ]]; then
    ap_die "$EX_NOINPUT" "profile '$profile' is not initialized in this checkout (run 'agent-profiles init --profile $profile' first)"
  fi

  ap_check_bwrap_readiness
  ap_prepare_profile_env "$repo_root" "$profile"
  ap_build_bwrap_mounts "$repo_root" "$profile"

  exec bwrap --dev-bind / / "${BWRAP_MOUNT_ARGS[@]}" --die-with-parent -- "$@"
}
