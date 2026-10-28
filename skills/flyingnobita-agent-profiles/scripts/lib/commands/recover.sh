#!/usr/bin/env bash
# Command: recover - recover interrupted lifecycle operations
# shellcheck disable=SC2034
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/runtime.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/locks.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/procscan.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/lifecycle.sh

source "$LIB_DIR/runtime.sh"
source "$LIB_DIR/locks.sh"
source "$LIB_DIR/procscan.sh"
source "$LIB_DIR/lifecycle.sh"

ap_recover_validate_trash_path() {
  local repo_root="$1"
  local trash_path="$2"

  [[ -n "$trash_path" ]] || return 0

  local trash_base="$repo_root/.agent-profiles/.trash"
  if [[ "$trash_path" != "$trash_base"/* ]]; then
    ap_die "$EX_LAYOUT" "unsafe journal trash path '$trash_path' (not under $trash_base)"
  fi
  ap_assert_no_symlink_components "$repo_root" "$trash_path"

  if [[ -L "$trash_path" ]]; then
    ap_die "$EX_LAYOUT" "journal trash path '$trash_path' is a symbolic link"
  fi
}

ap_recover_profile_operation() {
  local repo_root="$1"
  local op="$2"
  local profile="$3"
  local state="$4"
  local profile_dir="$5"
  local trash_path="$6"

  ap_validate_profile_name "$profile"

  local expected_dir="$repo_root/.agent-profiles/$profile"
  if [[ "$profile_dir" != "$expected_dir" ]]; then
    ap_die "$EX_LAYOUT" "unsafe journal profile path '$profile_dir' (expected '$expected_dir')"
  fi
  ap_assert_no_symlink_components "$repo_root" "$expected_dir"
  if [[ -L "$expected_dir" ]]; then
    ap_die "$EX_LAYOUT" "profile path '$expected_dir' is a symbolic link"
  fi
  ap_recover_validate_trash_path "$repo_root" "$trash_path"

  local profile_present=0
  local trash_present=0
  [[ -d "$expected_dir" ]] && profile_present=1
  if [[ -n "$trash_path" && (-e "$trash_path" || -L "$trash_path") ]]; then
    trash_present=1
  fi

  case "$state" in
    planned)
      if [[ $profile_present -eq 1 ]]; then
        # The move never happened; abort the interrupted operation.
        return 0
      fi
      if [[ $trash_present -eq 0 ]]; then
        ap_die "$EX_LAYOUT" "interrupted $op for '$profile' has neither a profile nor a trash path to recover"
      fi
      if [[ "$op" == "reset" ]]; then
        ap_init_profile "$repo_root" "$profile"
      fi
      rm -rf "$trash_path"
      ;;
    trashed)
      if [[ "$op" == "reset" && $profile_present -eq 0 ]]; then
        ap_init_profile "$repo_root" "$profile"
      fi
      if [[ $trash_present -eq 1 ]]; then
        rm -rf "$trash_path"
      fi
      ;;
    rebuilt)
      if [[ "$op" != "reset" ]]; then
        ap_die "$EX_LAYOUT" "unexpected rebuilt state in interrupted $op journal for '$profile'"
      fi
      if [[ $trash_present -eq 1 ]]; then
        rm -rf "$trash_path"
      fi
      ;;
    trash-deleted)
      ;;
    *)
      ap_die "$EX_LAYOUT" "unknown journal state '$state' in interrupted $op for '$profile'"
      ;;
  esac
}

ap_recover_validate_migrate_source() {
  local repo_root="$1"
  local source_path="$2"
  local label="$3"
  local mode="$4"

  if [[ "$source_path" != /* ]]; then
    ap_die "$EX_LAYOUT" "unsafe migration source path '$source_path' (must be absolute)"
  fi
  ap_assert_no_symlink_components "$repo_root" "$source_path"

  if [[ "$source_path" == "$repo_root/.agent-sandbox" ]]; then
    if [[ "$label" != "agent-sandbox" ]]; then
      ap_die "$EX_LAYOUT" "unsafe migration label '$label' for '$source_path'"
    fi
  elif [[ "$source_path" == "$repo_root/.agent-profiles/"* ]]; then
    local relative="${source_path#"$repo_root/.agent-profiles/"}"
    if [[ "$relative" == */* ]]; then
      ap_die "$EX_LAYOUT" "unsafe migration source path '$source_path'"
    fi
    ap_migrate_is_agent_entry "$relative" \
      || ap_die "$EX_LAYOUT" "unsafe migration source path '$source_path'"
    if [[ "$label" != "unnamed-profiles/$relative" ]]; then
      ap_die "$EX_LAYOUT" "unsafe migration label '$label' for '$source_path'"
    fi
  else
    ap_die "$EX_LAYOUT" "unsafe migration source path '$source_path' (outside known legacy locations)"
  fi

  case "$mode" in
    rename | copy) ;;
    *)
      ap_die "$EX_LAYOUT" "unknown migration source mode '$mode' for '$source_path'"
      ;;
  esac
}

ap_recover_finish_migrate() {
  local repo_root="$1"
  local backup_dir="$2"
  shift 2

  ap_write_backup_manifest "$backup_dir" \
    || ap_die "$EX_BROKEN" "unable to write backup manifest in '$backup_dir'"

  local profile
  for profile in "$@"; do
    ap_init_profile "$repo_root" "$profile"
  done
}

ap_recover_migrate_operation() {
  local repo_root="$1"
  local journal_file="$2"
  local state="$3"
  local backup_dir="$4"
  local staged_dir="$5"
  local legacy_dir="$6"
  local profiles_csv="$7"

  if [[ -z "$backup_dir" ]]; then
    ap_die "$EX_LAYOUT" "interrupted migrate journal has no recorded backup directory"
  fi

  local resolved_backup
  resolved_backup=$(ap_validate_existing_private_dir "$backup_dir" "backup directory")

  local real_repo
  real_repo=$(realpath -e "$repo_root" 2>/dev/null || printf '%s\n' "$repo_root")
  if ap_path_within "$resolved_backup" "$real_repo"; then
    ap_die "$EX_LAYOUT" "recorded backup directory '$resolved_backup' is inside the git checkout"
  fi

  local recorded_dir
  for recorded_dir in "$staged_dir" "$legacy_dir"; do
    if [[ -z "$recorded_dir" ]]; then
      ap_die "$EX_LAYOUT" "interrupted migrate journal is missing a staging or legacy directory"
    fi
    if [[ "$recorded_dir" != "$backup_dir"/* ]]; then
      ap_die "$EX_LAYOUT" "unsafe journal directory '$recorded_dir' (not under '$backup_dir')"
    fi
    ap_assert_no_symlink_components "$backup_dir" "$recorded_dir"
  done

  local profiles=()
  local profile
  for profile in $profiles_csv; do
    ap_validate_profile_name "$profile"
    profiles+=("$profile")
  done
  if [[ ${#profiles[@]} -eq 0 ]]; then
    ap_die "$EX_LAYOUT" "interrupted migrate journal records no target profiles"
  fi

  local source_paths=()
  local source_labels=()
  local source_modes=()
  local source_path source_label source_mode
  while IFS=$'\t' read -r source_path source_label source_mode; do
    [[ -n "$source_path" ]] || continue
    ap_recover_validate_migrate_source "$repo_root" "$source_path" "$source_label" "$source_mode"
    source_paths+=("$source_path")
    source_labels+=("$source_label")
    source_modes+=("$source_mode")
  done < <(ap_read_journal_sources "$journal_file")

  if [[ ${#source_paths[@]} -eq 0 ]]; then
    ap_die "$EX_LAYOUT" "interrupted migrate journal records no legacy sources"
  fi

  case "$state" in
    planned | staged)
      # Before the verified checkpoint, the backup copy is not trusted and the
      # originals must still be intact. Refuse if the filesystem disagrees.
      local index
      for index in "${!source_paths[@]}"; do
        if [[ ! -e "${source_paths[index]}" && ! -L "${source_paths[index]}" ]]; then
          ap_die "$EX_LAYOUT" "journal state '$state' records '$state' but legacy source '${source_paths[index]}' is already gone; inspect '$backup_dir' manually"
        fi
      done
      if [[ -e "$staged_dir" || -L "$staged_dir" ]]; then
        rm -rf "$staged_dir"
      fi
      ;;
    verified | originals-removed | rebuilt)
      (umask 077 && mkdir -p "$legacy_dir" && chmod 700 "$legacy_dir")

      local index
      for index in "${!source_paths[@]}"; do
        local source="${source_paths[index]}"
        local destination="$legacy_dir/${source_labels[index]}"
        (umask 077 && mkdir -p "$(dirname "$destination")")

        if [[ "${source_modes[index]}" == "rename" ]]; then
          if [[ -e "$source" || -L "$source" ]]; then
            if [[ -e "$destination" || -L "$destination" ]]; then
              ap_die "$EX_LAYOUT" "cannot complete migration: both '$source' and '$destination' exist"
            fi
            mv "$source" "$destination"
          elif [[ ! -e "$destination" && ! -L "$destination" ]]; then
            ap_die "$EX_LAYOUT" "cannot complete migration: '$source' and '$destination' are both missing"
          fi
        else
          if [[ -e "$destination" || -L "$destination" ]]; then
            :
          elif [[ -e "$staged_dir/${source_labels[index]}" || -L "$staged_dir/${source_labels[index]}" ]]; then
            mv "$staged_dir/${source_labels[index]}" "$destination"
          elif [[ -e "$source" || -L "$source" ]]; then
            cp -a --no-dereference "$source" "$destination"
            ap_verify_tree_copy "$source" "$destination" >/dev/null \
              || ap_die "$EX_REFUSED" "checksum mismatch while recovering '$source'; inspect '$backup_dir' manually"
          else
            ap_die "$EX_LAYOUT" "cannot complete migration: '$source' and '$destination' are both missing"
          fi
        fi
      done

      local index
      for index in "${!source_paths[@]}"; do
        if [[ "${source_modes[index]}" == "copy" ]]; then
          rm -rf "${source_paths[index]}"
        fi
      done
      rmdir "$staged_dir" 2>/dev/null || true

      ap_recover_finish_migrate "$repo_root" "$backup_dir" "${profiles[@]}"
      ;;
    *)
      ap_die "$EX_LAYOUT" "unknown journal state '$state' in interrupted migrate operation"
      ;;
  esac
}

ap_cmd_recover() {
  local yes_flag=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes | -y)
        yes_flag=1
        shift
        ;;
      *)
        ap_die "$EX_USAGE" "unknown option for recover: '$1'"
        ;;
    esac
  done

  local repo_root
  repo_root=$(ap_find_repo_root)

  local live_context
  live_context=$(ap_check_live_profile_context "$repo_root" "default")
  if [[ "$live_context" != "NONE" ]]; then
    ap_die "$EX_BUSY" "cannot run lifecycle operations from inside an active agent profile (run from a host shell)"
  fi

  local journal_dir="$repo_root/.agent-profiles/.journal"
  if [[ ! -d "$journal_dir" ]]; then
    printf "No interrupted operations found to recover.\n"
    return 0
  fi
  if [[ -L "$journal_dir" ]]; then
    ap_die "$EX_LAYOUT" "journal directory '$journal_dir' is a symbolic link"
  fi

  local stale_journals=()
  local journal_file
  for journal_file in "$journal_dir"/*.json; do
    [[ -f "$journal_file" ]] || continue
    if [[ -L "$journal_file" ]]; then
      ap_die "$EX_LAYOUT" "journal file '$journal_file' is a symbolic link"
    fi
    if ap_journal_is_stale "$journal_file"; then
      stale_journals+=("$journal_file")
    fi
  done

  if [[ ${#stale_journals[@]} -eq 0 ]]; then
    printf "No interrupted operations found to recover.\n"
    return 0
  fi

  if [[ $yes_flag -eq 0 ]]; then
    printf "Interrupted operation journals found for recovery:\n"
    for journal_file in "${stale_journals[@]}"; do
      printf "  %s\n" "$(basename "$journal_file")"
    done
    printf "Pass --yes to perform recovery.\n"
    return 0
  fi

  # Collect the locks needed by every journal before mutating anything.
  local needs_exclusive_storage=0
  local all_targets=()
  local fields=()
  local journal_op journal_profile migrated_profiles
  for journal_file in "${stale_journals[@]}"; do
    fields=()
    mapfile -d '' -t fields < <(ap_read_journal_fields "$journal_file")
    if [[ ${#fields[@]} -eq 0 ]]; then
      ap_die "$EX_REFUSED" "unreadable journal '$(basename "$journal_file")'; inspect it manually"
    fi
    journal_op="${fields[0]:-}"
    journal_profile="${fields[1]:-}"
    migrated_profiles="${fields[9]:-}"

    case "$journal_op" in
      reset | remove)
        ap_validate_profile_name "$journal_profile"
        all_targets+=("$journal_profile")
        ;;
      migrate)
        needs_exclusive_storage=1
        local target
        for target in $migrated_profiles; do
          ap_validate_profile_name "$target"
          all_targets+=("$target")
        done
        ;;
      *)
        ap_die "$EX_LAYOUT" "unknown operation '$journal_op' in journal '$(basename "$journal_file")'"
        ;;
    esac
  done

  if [[ $needs_exclusive_storage -eq 1 ]]; then
    ap_lock_storage_exclusive "$repo_root"
  else
    ap_lock_storage_shared "$repo_root"
  fi

  local deduped_targets=()
  if [[ ${#all_targets[@]} -gt 0 ]]; then
    mapfile -t deduped_targets < <(printf "%s\n" "${all_targets[@]}" | sort -u)
    ap_lock_profiles_exclusive "$repo_root" "${deduped_targets[@]}"
  fi

  local target
  for journal_file in "${stale_journals[@]}"; do
    ap_journal_is_stale "$journal_file" \
      || ap_die "$EX_BUSY" "journal '$(basename "$journal_file")' became active during recovery"

    ap_lock_journal "$journal_file"

    fields=()
    mapfile -d '' -t fields < <(ap_read_journal_fields "$journal_file")
    if [[ ${#fields[@]} -eq 0 ]]; then
      ap_die "$EX_REFUSED" "unreadable journal '$(basename "$journal_file")'; inspect it manually"
    fi
    journal_op="${fields[0]:-}"
    journal_profile="${fields[1]:-}"
    local journal_state="${fields[2]:-}"
    local journal_profile_dir="${fields[3]:-}"
    local journal_trash_path="${fields[4]:-}"
    local journal_assume="${fields[5]:-}"
    local journal_backup_dir="${fields[6]:-}"
    local journal_staged_dir="${fields[7]:-}"
    local journal_legacy_dir="${fields[8]:-}"
    migrated_profiles="${fields[9]:-}"

    case "$journal_op" in
      reset | remove)
        ap_scan_processes "$repo_root" "$journal_profile" "$journal_assume"
        ap_recover_profile_operation "$repo_root" "$journal_op" "$journal_profile" \
          "$journal_state" "$journal_profile_dir" "$journal_trash_path"
        ;;
      migrate)
        for target in $migrated_profiles; do
          ap_scan_processes "$repo_root" "$target" "$journal_assume"
        done
        ap_recover_migrate_operation "$repo_root" "$journal_file" "$journal_state" \
          "$journal_backup_dir" "$journal_staged_dir" "$journal_legacy_dir" "$migrated_profiles"
        ;;
    esac

    ap_unlock_journal
    rm -f "$journal_file"
    printf "Recovered interrupted '%s' operation for profile '%s'.\n" "$journal_op" "$journal_profile"
  done

  if [[ ${#deduped_targets[@]} -gt 0 ]]; then
    ap_unlock_profiles
  fi
  ap_unlock_storage
  printf "All interrupted operations recovered successfully.\n"
}
