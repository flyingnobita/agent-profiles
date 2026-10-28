#!/usr/bin/env bash
# Command: remove - delete an existing agent profile
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/runtime.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/locks.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/procscan.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/lifecycle.sh

source "$LIB_DIR/runtime.sh"
source "$LIB_DIR/locks.sh"
source "$LIB_DIR/procscan.sh"
source "$LIB_DIR/lifecycle.sh"

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

  # 1. Preflight
  ap_run_preflight "$repo_root" "$profile"

  # 2. Acquire shared storage lock and exclusive profile lock in lock order
  ap_lock_storage_shared "$repo_root"
  ap_lock_profile_exclusive "$repo_root" "$profile"

  # 3. Process scan check
  ap_scan_processes "$repo_root" "$profile" "$assume_unrelated"

  if [[ $yes_flag -eq 0 ]]; then
    printf "Remove preview for profile '%s':\n" "$profile"
    printf "  Path: %s\n" "$prof_dir"
    printf "  Consequences: profile directory and all stored settings, transcripts, credentials, and installed tools will be deleted\n"
    ap_preview_profile_categories "$prof_dir"
    printf "Pass --yes to proceed with remove.\n"
    ap_unlock_profile
    ap_unlock_storage
    return 0
  fi

  # 4. Mutating state machine with atomic journal
  ap_ensure_journal_dir "$repo_root"
  local journal_file="$repo_root/.agent-profiles/.journal/remove-$profile.json"
  (umask 077 && touch "$journal_file" && chmod 600 "$journal_file")
  ap_lock_journal "$journal_file"

  ap_ensure_trash_dir "$repo_root"
  local ts
  ts=$(date +%s%N 2>/dev/null || date +%s)
  local trash_path="$repo_root/.agent-profiles/.trash/$profile.$ts"
  if [[ -e "$trash_path" || -L "$trash_path" ]]; then
    ap_die "$EX_LAYOUT" "trash destination '$trash_path' already exists"
  fi

  # Record the intended trash path before moving anything so recovery can roll
  # forward when the process dies between the rename and the next checkpoint.
  ap_record_journal "$journal_file" "remove" "$profile" "planned" "$prof_dir" "$trash_path" "$assume_unrelated"

  mv "$prof_dir" "$trash_path"

  ap_record_journal "$journal_file" "remove" "$profile" "trashed" "$prof_dir" "$trash_path" "$assume_unrelated"

  # Delete trash path without dereferencing symlinks
  rm -rf "$trash_path"
  ap_record_journal "$journal_file" "remove" "$profile" "trash-deleted" "$prof_dir" "" "$assume_unrelated"

  # Done: clear journal and release locks
  ap_unlock_journal
  rm -f "$journal_file"

  ap_unlock_profile
  ap_unlock_storage

  printf "Removed profile '%s' successfully.\n" "$profile"
}
