#!/usr/bin/env bash
# Command: recover - recover interrupted lifecycle operations
# shellcheck disable=SC2034
# shellcheck source=skills/agent-profiles/scripts/lib/runtime.sh
# shellcheck source=skills/agent-profiles/scripts/lib/locks.sh
# shellcheck source=skills/agent-profiles/scripts/lib/procscan.sh
# shellcheck source=skills/agent-profiles/scripts/lib/lifecycle.sh

source "$LIB_DIR/runtime.sh"
source "$LIB_DIR/locks.sh"
source "$LIB_DIR/procscan.sh"
source "$LIB_DIR/lifecycle.sh"

# Resolves a path that a journal recorded, so identity checks compare canonical
# to canonical. The product records physical paths, but a journal can also be
# reached through a symlinked ancestor (macOS serves /var/folders as
# /private/var/folders) or survive a checkout move, and a lexical comparison
# between a recorded path and a resolved one refuses a journal that is correct.
# Nothing is trusted because of this: every caller still refuses a recorded path
# that resolves anywhere other than the location it expects.
ap_recover_canonical() {
  local path="$1"
  local resolved
  if ! resolved=$(ap_platform_realpath_missing "$path"); then
    ap_die "$EX_LAYOUT" "recorded path '$path' could not be resolved to a physical path"
  fi
  printf "%s\n" "$resolved"
}

ap_recover_validate_trash_path() {
  local repo_root="$1"
  local trash_path="$2"

  [[ -n "$trash_path" ]] || return 0

  local trash_base="$repo_root/.agent-profiles/.trash"
  local real_base real_trash
  real_base=$(ap_recover_canonical "$trash_base")
  real_trash=$(ap_recover_canonical "$trash_path")
  if [[ "$real_trash" != "$real_base"/* ]]; then
    ap_die "$EX_LAYOUT" "unsafe journal trash path '$trash_path' (not under $trash_base)"
  fi
  ap_assert_no_symlink_components "$repo_root" "$real_base"
  ap_assert_no_symlink_components "$repo_root" "$real_trash"

  if [[ -L "$real_trash" ]]; then
    ap_die "$EX_LAYOUT" "journal trash path '$trash_path' is a symbolic link"
  fi

  printf "%s\n" "$real_trash"
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
  local real_profile_dir real_expected_dir
  real_profile_dir=$(ap_recover_canonical "$profile_dir")
  real_expected_dir=$(ap_recover_canonical "$expected_dir")
  if [[ "$real_profile_dir" != "$real_expected_dir" ]]; then
    ap_die "$EX_LAYOUT" "unsafe journal profile path '$profile_dir' (expected '$expected_dir')"
  fi
  ap_assert_no_symlink_components "$repo_root" "$expected_dir"
  if [[ -L "$expected_dir" ]]; then
    ap_die "$EX_LAYOUT" "profile path '$expected_dir' is a symbolic link"
  fi
  trash_path=$(ap_recover_validate_trash_path "$repo_root" "$trash_path")

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
  local real_source
  real_source=$(ap_recover_canonical "$source_path")
  ap_assert_no_symlink_components "$repo_root" "$real_source"

  if [[ "$real_source" == "$repo_root/.agent-sandbox" ]]; then
    if [[ "$label" != "agent-sandbox" ]]; then
      ap_die "$EX_LAYOUT" "unsafe migration label '$label' for '$source_path'"
    fi
  elif [[ "$real_source" == "$repo_root/.agent-profiles/"* ]]; then
    local relative="${real_source#"$repo_root/.agent-profiles/"}"
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

ap_recover_validate_content_manifest() {
  local manifest="$1"
  local backup_dir="$2"

  if [[ -z "$manifest" ]]; then
    ap_die "$EX_REFUSED" "interrupted migrate journal has no durable content manifest; original data and journal preserved for manual recovery"
  fi
  if [[ "$manifest" != "$backup_dir"/* ]]; then
    ap_die "$EX_LAYOUT" "unsafe content manifest path '$manifest' (not under '$backup_dir')"
  fi
  ap_assert_no_symlink_components "$backup_dir" "$manifest"

  if [[ -L "$manifest" || ! -f "$manifest" ]]; then
    ap_die "$EX_REFUSED" "durable content manifest '$manifest' is missing; original data and journal preserved for manual recovery"
  fi

  local owner mode
  if ! owner=$(ap_platform_stat_owner "$manifest"); then
    ap_die "$EX_LAYOUT" "cannot read the ownership of content manifest '$manifest'"
  fi
  if [[ "$owner" != "$(id -u)" ]]; then
    ap_die "$EX_LAYOUT" "content manifest '$manifest' is not owned by the current user"
  fi
  if ! mode=$(ap_platform_stat_mode "$manifest"); then
    ap_die "$EX_LAYOUT" "cannot read the permissions of content manifest '$manifest'"
  fi
  if [[ -n "$mode" ]] && ((8#$mode & 8#022)); then
    ap_die "$EX_LAYOUT" "content manifest '$manifest' is group or world writable (mode $mode)"
  fi

  if ! python3 - "$manifest" <<'PY'
import json, sys

with open(sys.argv[1], "r") as handle:
    data = json.load(handle)
if data.get("version") != 1 or not isinstance(data.get("sources"), dict):
    raise SystemExit(1)
PY
  then
    ap_die "$EX_REFUSED" "durable content manifest '$manifest' is unreadable; original data and journal preserved for manual recovery"
  fi
}

ap_recover_verify_backup_content() {
  local manifest="$1"
  local label="$2"
  local tree="$3"
  local context="$4"

  local verify_status=0
  ap_verify_tree_matches_manifest "$manifest" "$label" "$tree" >/dev/null 2>&1 || verify_status=$?

  case "$verify_status" in
    0) return 0 ;;
    2)
      ap_die "$EX_REFUSED" "durable content manifest has no usable record for '$label' ($context); original data and journal preserved for manual recovery"
      ;;
    *)
      ap_die "$EX_REFUSED" "verified backup content for '$label' is corrupt or does not match the durable content manifest ($context); original data and journal preserved for manual recovery"
      ;;
  esac
}

ap_recover_migrate_operation() {
  local repo_root="$1"
  local journal_file="$2"
  local state="$3"
  local backup_dir="$4"
  local raw_staged_dir="${5:-}"
  local raw_legacy_dir="${6:-}"
  local profiles_csv="$7"
  local content_manifest="$8"
  local staged_dir=""
  local legacy_dir=""
  if [[ -z "$backup_dir" ]]; then
    ap_die "$EX_LAYOUT" "interrupted migrate journal has no recorded backup directory"
  fi

  local resolved_backup
  resolved_backup=$(ap_validate_existing_private_dir "$backup_dir" "backup directory")

  local real_repo
  real_repo=$(ap_platform_realpath_existing "$repo_root" 2>/dev/null || printf '%s\n' "$repo_root")
  if ap_path_within "$resolved_backup" "$real_repo"; then
    ap_die "$EX_LAYOUT" "recorded backup directory '$resolved_backup' is inside the git checkout"
  fi

  local recorded_dir real_recorded
  local -a recorded_dirs=()
  for recorded_dir in "$raw_staged_dir" "$raw_legacy_dir"; do
    if [[ -z "$recorded_dir" ]]; then
      ap_die "$EX_LAYOUT" "interrupted migrate journal is missing a staging or legacy directory"
    fi
    real_recorded=$(ap_recover_canonical "$recorded_dir")
    if [[ "$real_recorded" != "$resolved_backup"/* ]]; then
      ap_die "$EX_LAYOUT" "unsafe journal directory '$recorded_dir' (not under '$backup_dir')"
    fi
    ap_assert_no_symlink_components "$resolved_backup" "$real_recorded"
    recorded_dirs+=("$real_recorded")
  done
  staged_dir="${recorded_dirs[0]}"
  legacy_dir="${recorded_dirs[1]}"

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
      # The state string alone is not integrity proof. Validate the durable
      # content manifest and every tree that will be kept or deleted before
      # any move or removal.
      ap_recover_validate_content_manifest "$content_manifest" "$backup_dir"

      (umask 077 && mkdir -p "$legacy_dir" && chmod 700 "$legacy_dir")

      local destination_present=()
      local source_present=()
      local staged_present=()
      local final_destinations=()
      local index

      # Phase 1: verify first, mutate second.
      for index in "${!source_paths[@]}"; do
        local source="${source_paths[index]}"
        local label="${source_labels[index]}"
        local mode="${source_modes[index]}"
        local destination="$legacy_dir/$label"
        local staged="$staged_dir/$label"

        local has_source=0
        local has_staged=0
        local has_destination=0
        [[ -e "$source" || -L "$source" ]] && has_source=1
        [[ -e "$staged" || -L "$staged" ]] && has_staged=1
        [[ -e "$destination" || -L "$destination" ]] && has_destination=1

        source_present+=("$has_source")
        staged_present+=("$has_staged")
        destination_present+=("$has_destination")
        final_destinations+=("$destination")

        if [[ $has_destination -eq 1 ]]; then
          ap_recover_verify_backup_content "$content_manifest" "$label" "$destination" "existing legacy destination"
          if [[ "$mode" == "rename" && $has_source -eq 1 ]]; then
            ap_die "$EX_REFUSED" "cannot recover migrate: both source '$source' and destination '$destination' exist; original data and journal preserved for manual recovery"
          fi
        elif [[ "$mode" == "rename" ]]; then
          if [[ $has_source -eq 0 ]]; then
            ap_die "$EX_REFUSED" "cannot recover migrate: source and destination for '$label' are both missing; original data and journal preserved for manual recovery"
          fi
          ap_recover_verify_backup_content "$content_manifest" "$label" "$source" "source tree"
        elif [[ $has_staged -eq 1 ]]; then
          ap_recover_verify_backup_content "$content_manifest" "$label" "$staged" "staged backup copy"
        else
          ap_die "$EX_REFUSED" "cannot recover migrate: verified backup content for '$label' is missing or partial; original data and journal preserved for manual recovery"
        fi

        if [[ $has_source -eq 1 && "$mode" == "copy" ]]; then
          ap_recover_verify_backup_content "$content_manifest" "$label" "$source" "original changed since verification"
        fi
      done

      # Phase 2: every tree matched. Complete moves and remove verified originals.
      for index in "${!source_paths[@]}"; do
        if [[ "${destination_present[index]}" == "1" ]]; then
          continue
        fi

        local label="${source_labels[index]}"
        local mode="${source_modes[index]}"
        local destination="${final_destinations[index]}"
        local source="${source_paths[index]}"
        local staged="$staged_dir/$label"

        (umask 077 && mkdir -p "$(dirname "$destination")")

        if [[ "$mode" == "rename" ]]; then
          mv "$source" "$destination"
        elif [[ "${staged_present[index]}" == "1" ]]; then
          mv "$staged" "$destination"
        else
          ap_die "$EX_REFUSED" "cannot recover migrate: verified backup content for '$label' is missing or partial; original data and journal preserved for manual recovery"
        fi
      done

      for index in "${!source_paths[@]}"; do
        if [[ "${source_modes[index]}" == "copy" && "${source_present[index]}" == "1" ]]; then
          rm -rf "${source_paths[index]}"
        fi
      done
      rm -rf "$staged_dir"

      ap_recover_finish_migrate "$repo_root" "$backup_dir" ${profiles[@]+"${profiles[@]}"}
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
    for journal_file in ${stale_journals[@]+"${stale_journals[@]}"}; do
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
  local valid_journals=()
  local incomplete_journals=()

  # Phase 1: classify journals without mutating anything.
  for journal_file in ${stale_journals[@]+"${stale_journals[@]}"}; do
    if [[ ! -s "$journal_file" ]]; then
      incomplete_journals+=("$journal_file")
      continue
    fi
    fields=()
    read_journal_fields_into fields "$journal_file"
    if [[ ${#fields[@]} -eq 0 ]]; then
      ap_die "$EX_LAYOUT" "malformed journal '$(basename "$journal_file")'; inspect it manually instead of deleting data"
    fi
    journal_op="${fields[0]:-}"
    case "$journal_op" in
      reset | remove)
        ap_validate_profile_name "${fields[1]:-}"
        ;;
      migrate)
        for target in ${fields[9]:-}; do
          ap_validate_profile_name "$target"
        done
        ;;
      *)
        ap_die "$EX_LAYOUT" "unknown operation '$journal_op' in journal '$(basename "$journal_file")'"
        ;;
    esac
    valid_journals+=("$journal_file")
  done

  # Phase 2: an incomplete journal records no state, so clearing it is safe, but
  # it still mutates profile storage: hold the exclusive storage lock first so a
  # concurrent init or reset cannot race the clear.
  if [[ ${#incomplete_journals[@]} -gt 0 ]]; then
    ap_lock_storage_exclusive "$repo_root"
    for journal_file in ${incomplete_journals[@]+"${incomplete_journals[@]}"}; do
      ap_journal_is_stale "$journal_file" \
        || ap_die "$EX_BUSY" "journal '$(basename "$journal_file")' became active during recovery"
      if [[ -s "$journal_file" ]]; then
        ap_die "$EX_BUSY" "journal '$(basename "$journal_file")' changed during recovery; rerun recover"
      fi
      ap_lock_journal "$journal_file"
      rm -f "$journal_file"
      ap_unlock_journal
      printf "Cleared incomplete journal '%s' (no operation state was recorded; profile data untouched).\n" \
        "$(basename "$journal_file")"
    done
    ap_unlock_storage
  fi

  stale_journals=()
  if [[ ${#valid_journals[@]} -gt 0 ]]; then
    stale_journals=(${valid_journals[@]+"${valid_journals[@]}"})
  fi

  if [[ ${#stale_journals[@]} -eq 0 ]]; then
    printf "No recoverable interrupted operations remained after clearing incomplete journals.\n"
    return 0
  fi

  # Collect the locks needed by every remaining journal before mutating anything.
  local needs_exclusive_storage=0
  local all_targets=()
  for journal_file in ${stale_journals[@]+"${stale_journals[@]}"}; do
    fields=()
    read_journal_fields_into fields "$journal_file"
    if [[ ${#fields[@]} -eq 0 ]]; then
      ap_die "$EX_REFUSED" "unreadable journal '$(basename "$journal_file")'; inspect it manually"
    fi
    journal_op="${fields[0]:-}"
    journal_profile="${fields[1]:-}"
    migrated_profiles="${fields[9]:-}"

    case "$journal_op" in
      reset | remove)
        all_targets+=("$journal_profile")
        ;;
      migrate)
        needs_exclusive_storage=1
        local target
        for target in $migrated_profiles; do
          all_targets+=("$target")
        done
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
    local target_name
    while IFS= read -r target_name; do
      [[ -n "$target_name" ]] || continue
      deduped_targets+=("$target_name")
    done < <(printf "%s\n" ${all_targets[@]+"${all_targets[@]}"} | LC_ALL=C sort -u)
    ap_lock_profiles_exclusive "$repo_root" ${deduped_targets[@]+"${deduped_targets[@]}"}
  fi

  local target
  for journal_file in ${stale_journals[@]+"${stale_journals[@]}"}; do
    ap_journal_is_stale "$journal_file" \
      || ap_die "$EX_BUSY" "journal '$(basename "$journal_file")' became active during recovery"

    ap_lock_journal "$journal_file"

    fields=()
    read_journal_fields_into fields "$journal_file"
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
    local journal_content_manifest="${fields[10]:-}"

    case "$journal_op" in
      reset | remove)
        # The data may already have been moved into trash by the interrupted
        # operation, so scan both the profile path and the recorded trash path.
        local scan_paths=("$repo_root/.agent-profiles/$journal_profile")
        if [[ -n "$journal_trash_path" && (-d "$journal_trash_path" || -L "$journal_trash_path") ]]; then
          scan_paths+=("$journal_trash_path")
        fi
        ap_scan_legacy_processes "$repo_root" "interrupted $journal_op data" \
          "$journal_assume" ${scan_paths[@]+"${scan_paths[@]}"}
        ap_recover_profile_operation "$repo_root" "$journal_op" "$journal_profile" \
          "$journal_state" "$journal_profile_dir" "$journal_trash_path"
        ;;
      migrate)
        # Every actual recorded source can still be in use by a non-wrapper or
        # fd-closing process, so scan the recorded sources as well as targets.
        local migrate_scan_paths=()
        local source_path source_label source_mode
        while IFS=$'\t' read -r source_path source_label source_mode; do
          [[ -n "$source_path" ]] || continue
          migrate_scan_paths+=("$source_path")
        done < <(ap_read_journal_sources "$journal_file")
        if [[ -n "$journal_trash_path" ]]; then
          migrate_scan_paths+=("$journal_trash_path")
        fi
        if [[ -n "$journal_backup_dir" ]]; then
          migrate_scan_paths+=("$journal_backup_dir/staged" "$journal_backup_dir/legacy")
        fi
        if [[ ${#migrate_scan_paths[@]} -gt 0 ]]; then
          ap_scan_legacy_processes "$repo_root" "legacy migration data" \
            "$journal_assume" ${migrate_scan_paths[@]+"${migrate_scan_paths[@]}"}
        fi
        for target in $migrated_profiles; do
          ap_scan_processes "$repo_root" "$target" "$journal_assume"
        done
        ap_recover_migrate_operation "$repo_root" "$journal_file" "$journal_state" \
          "$journal_backup_dir" "$journal_staged_dir" "$journal_legacy_dir" "$migrated_profiles" \
          "$journal_content_manifest"
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
