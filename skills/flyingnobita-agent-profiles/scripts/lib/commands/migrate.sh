#!/usr/bin/env bash
# Command: migrate - migrate legacy profile storage to current format
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/runtime.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/locks.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/procscan.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/lifecycle.sh

source "$LIB_DIR/runtime.sh"
source "$LIB_DIR/locks.sh"
source "$LIB_DIR/procscan.sh"
source "$LIB_DIR/lifecycle.sh"

# Reads the legacy layout and the profiles a migration would create. Sets
# MIG_LAYOUTS, MIG_SANDBOX, MIG_UNNAMED, and MIG_TARGETS. Read-only.
ap_migrate_compute_plan() {
  local repo_root="$1"
  local storage_dir="$repo_root/.agent-profiles"
  local sandbox_dir="$repo_root/.agent-sandbox"

  MIG_LAYOUTS=$(ap_detect_legacy_layouts "$repo_root")
  MIG_SANDBOX=0
  MIG_UNNAMED=()
  MIG_TARGETS=()

  [[ -n "$MIG_LAYOUTS" ]] || return 0

  case ",$MIG_LAYOUTS," in
    *,symlink-sandbox,*)
      ap_die "$EX_LAYOUT" "legacy directory '$sandbox_dir' is a symbolic link (must be a real directory)"
      ;;
    *,invalid-sandbox,*)
      ap_die "$EX_LAYOUT" "legacy path '$sandbox_dir' exists but is not a directory"
      ;;
    *,symlink-profiles,*)
      ap_die "$EX_LAYOUT" "profile storage directory '$storage_dir' is a symbolic link (must be a real directory)"
      ;;
    *,unknown-sandbox,*)
      ap_die "$EX_REFUSED" "unrecognized contents in '$sandbox_dir'; inspect and move the data manually before migrating"
      ;;
  esac

  local has_unnamed_sandbox=0
  local has_named_sandbox=0
  local has_unnamed_profiles=0

  case ",$MIG_LAYOUTS," in
    *,unnamed-sandbox,*) has_unnamed_sandbox=1 ;;
  esac
  case ",$MIG_LAYOUTS," in
    *,named-sandbox,*) has_named_sandbox=1 ;;
  esac
  case ",$MIG_LAYOUTS," in
    *,unnamed-profiles,*) has_unnamed_profiles=1 ;;
  esac

  local named_targets=()
  if [[ $has_named_sandbox -eq 1 ]]; then
    local entry base
    for entry in "$sandbox_dir"/*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      base=$(basename "$entry")
      if [[ -L "$entry" || ! -d "$entry" ]]; then
        ap_die "$EX_REFUSED" "named legacy entry '$entry' is not a real directory"
      fi
      if [[ ! "$base" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
        ap_die "$EX_REFUSED" "named legacy entry '$base' is not a valid profile name (refusing to merge)"
      fi
      if [[ -e "$storage_dir/$base" || -L "$storage_dir/$base" ]]; then
        ap_die "$EX_REFUSED" "ambiguous profile layout: name collision for profile '$base' (already exists under '$storage_dir')"
      fi
      named_targets+=("$base")
    done
  fi

  case ",$MIG_LAYOUTS," in
    *,mixed-sandbox,*)
      ap_die "$EX_REFUSED" "ambiguous legacy layout: '$sandbox_dir' contains both unnamed agent directories and named profiles"
      ;;
  esac

  if [[ $has_unnamed_sandbox -eq 1 && $has_unnamed_profiles -eq 1 ]]; then
    ap_die "$EX_REFUSED" "ambiguous profile layout: both '$sandbox_dir' and unnamed data under '$storage_dir' map to the default profile"
  fi

  if [[ $has_unnamed_sandbox -eq 1 || $has_named_sandbox -eq 1 ]]; then
    MIG_SANDBOX=1
  fi

  if [[ $has_unnamed_sandbox -eq 1 ]]; then
    if [[ -e "$storage_dir/default" || -L "$storage_dir/default" ]]; then
      ap_die "$EX_REFUSED" "ambiguous profile layout: unnamed legacy data maps to profile 'default', which already exists"
    fi
    MIG_TARGETS+=("default")
  fi

  if [[ $has_named_sandbox -eq 1 ]]; then
    local named_target
    for named_target in "${named_targets[@]}"; do
      MIG_TARGETS+=("$named_target")
    done
  fi

  if [[ $has_unnamed_profiles -eq 1 ]]; then
    if [[ -e "$storage_dir/default" || -L "$storage_dir/default" ]]; then
      ap_die "$EX_REFUSED" "ambiguous profile layout: unnamed data under '$storage_dir' maps to profile 'default', which already exists"
    fi
    MIG_TARGETS+=("default")

    local entry base
    mapfile -t MIG_UNNAMED < <(ap_list_unnamed_legacy_entries "$storage_dir")

    for entry in "${MIG_UNNAMED[@]:-}"; do
      [[ -n "$entry" ]] || continue
      base="$entry"
      ap_migrate_is_agent_entry "$base" \
        || ap_die "$EX_REFUSED" "unrecognized legacy entry '$base' under '$storage_dir'"
    done

    if [[ ${#MIG_UNNAMED[@]} -eq 0 ]]; then
      ap_die "$EX_REFUSED" "unnamed legacy layout under '$storage_dir' has no recognizable agent directories"
    fi
  fi

  if [[ ${#MIG_TARGETS[@]} -eq 0 ]]; then
    ap_die "$EX_REFUSED" "legacy layout detected but no migration targets were identified"
  fi

  mapfile -t MIG_TARGETS < <(printf "%s\n" "${MIG_TARGETS[@]}" | sort -u)
}

ap_migrate_build_sources() {
  local repo_root="$1"
  local storage_dir="$repo_root/.agent-profiles"
  local sandbox_dir="$repo_root/.agent-sandbox"

  MIG_SOURCE_PATHS=()
  MIG_SOURCE_LABELS=()
  MIG_SOURCE_MODES=()

  if [[ $MIG_SANDBOX -eq 1 ]]; then
    MIG_SOURCE_PATHS+=("$sandbox_dir")
    MIG_SOURCE_LABELS+=("agent-sandbox")
  fi

  local base
  for base in "${MIG_UNNAMED[@]:-}"; do
    [[ -n "$base" ]] || continue
    MIG_SOURCE_PATHS+=("$storage_dir/$base")
    MIG_SOURCE_LABELS+=("unnamed-profiles/$base")
  done
}

ap_migrate_build_extra_json() {
  local backup_dir="$1"
  local staged_dir="$2"
  local legacy_dir="$3"

  local profiles_json=""
  local profile
  for profile in "${MIG_TARGETS[@]}"; do
    [[ -n "$profiles_json" ]] && profiles_json+=","
    profiles_json+="\"$(ap_json_escape "$profile")\""
  done

  local sources_json=""
  local index
  for index in "${!MIG_SOURCE_PATHS[@]}"; do
    [[ -n "$sources_json" ]] && sources_json+=","
    sources_json+="{\"path\":\"$(ap_json_escape "${MIG_SOURCE_PATHS[index]}")\",\"label\":\"$(ap_json_escape "${MIG_SOURCE_LABELS[index]}")\",\"mode\":\"${MIG_SOURCE_MODES[index]}\"}"
  done

  printf '{"backup_dir":"%s","staged_dir":"%s","legacy_dir":"%s","content_manifest":"%s","migrated_profiles":[%s],"sources":[%s]}' \
    "$(ap_json_escape "$backup_dir")" \
    "$(ap_json_escape "$staged_dir")" \
    "$(ap_json_escape "$legacy_dir")" \
    "$(ap_json_escape "$backup_dir/content-manifest.json")" \
    "$profiles_json" \
    "$sources_json"
}

ap_migrate_abort_copy() {
  local run_backup="$1"
  local journal_file="$2"
  local message="$3"

  rm -f "$journal_file"
  rm -rf "$run_backup"
  ap_die "$EX_REFUSED" "$message"
}

ap_cmd_migrate() {
  local yes_flag=0
  local backup_root=""
  local assume_unrelated=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes | -y)
        yes_flag=1
        shift
        ;;
      --backup-root)
        [[ $# -ge 2 ]] || ap_die "$EX_USAGE" "--backup-root requires a directory argument"
        backup_root="$2"
        shift 2
        ;;
      --backup-root=*)
        backup_root="${1#*=}"
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
      *)
        ap_die "$EX_USAGE" "unknown option for migrate: '$1'"
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

  ap_run_preflight "$repo_root" ""

  if [[ -z "$backup_root" ]]; then
    backup_root="${XDG_STATE_HOME:-$HOME/.local/state}/flyingnobita-agent-profiles/backups"
  fi
  if [[ "$backup_root" != /* ]]; then
    ap_die "$EX_LAYOUT" "backup root '$backup_root' must be an absolute path"
  fi

  ap_migrate_compute_plan "$repo_root"

  if [[ -z "$MIG_LAYOUTS" ]]; then
    printf "No legacy profile storage detected in this checkout.\n"
    return 0
  fi

  local planned_targets="${MIG_TARGETS[*]}"
  local planned_layouts="$MIG_LAYOUTS"

  if [[ $yes_flag -eq 0 ]]; then
    local validated_backup_root
    validated_backup_root=$(ap_validate_private_backup_path "$repo_root" "$backup_root")
    local candidate
    candidate=$(ap_candidate_backup_path "$repo_root" "$validated_backup_root")
    printf "Migration preview:\n"
    printf "  Detected legacy layout: %s\n" "$planned_layouts"
    printf "  Backup destination: %s\n" "$candidate"
    printf "  Profiles to create: %s\n" "${MIG_TARGETS[*]}"
    printf "  The original data is kept outside the checkout before any profile is rebuilt.\n"
    printf "Pass --yes to proceed with migration.\n"
    return 0
  fi

  # Mutating path: storage lock first, then affected profiles in name order.
  ap_lock_storage_exclusive "$repo_root"
  ap_lock_profiles_exclusive "$repo_root" "${MIG_TARGETS[@]}"

  # Re-validate while holding the locks: layout and targets may have changed.
  ap_migrate_compute_plan "$repo_root"
  if [[ -z "$MIG_LAYOUTS" ]]; then
    ap_die "$EX_REFUSED" "legacy layout disappeared while waiting for locks; rerun migrate"
  fi
  if [[ "${MIG_TARGETS[*]}" != "$planned_targets" ]]; then
    ap_die "$EX_REFUSED" "affected profiles changed while waiting for locks; rerun migrate"
  fi

  ap_migrate_build_sources "$repo_root"

  # Refuse while any owned process still uses an actual legacy source, such as
  # cwd, open files, exe or environment markers under .agent-sandbox or unnamed
  # storage. Target-profile storage is scanned as well.
  local index
  ap_scan_legacy_processes "$repo_root" "legacy storage" "$assume_unrelated" \
    "${MIG_SOURCE_PATHS[@]}"
  for index in "${!MIG_TARGETS[@]}"; do
    ap_scan_processes "$repo_root" "${MIG_TARGETS[index]}" "$assume_unrelated"
  done

  for index in "${!MIG_SOURCE_PATHS[@]}"; do
    ap_assert_tree_has_no_special_files "${MIG_SOURCE_PATHS[index]}" \
      || ap_die "$EX_LAYOUT" "refusing to migrate legacy data containing sockets, device nodes, or FIFOs"
  done

  local resolved_root
  resolved_root=$(ap_prepare_private_backup_root "$repo_root" "$backup_root")

  local real_storage
  real_storage=$(realpath -m "$repo_root/.agent-profiles")
  if ap_path_within "$resolved_root" "$real_storage"; then
    ap_die "$EX_LAYOUT" "backup path resolves into profile storage ($resolved_root)"
  fi
  if [[ $MIG_SANDBOX -eq 1 ]]; then
    local real_sandbox
    real_sandbox=$(realpath -m "$repo_root/.agent-sandbox")
    if ap_path_within "$resolved_root" "$real_sandbox"; then
      ap_die "$EX_LAYOUT" "backup path resolves into legacy storage ($resolved_root)"
    fi
  fi

  local run_backup
  run_backup=$(ap_create_per_run_backup "$repo_root" "$resolved_root")

  local staged_dir="$run_backup/staged"
  local legacy_dir="$run_backup/legacy"
  (umask 077 && mkdir -m 700 "$staged_dir" "$legacy_dir")

  local backup_dev
  backup_dev=$(stat -c "%d" "$run_backup")
  for index in "${!MIG_SOURCE_PATHS[@]}"; do
    local source_dev
    source_dev=$(stat -c "%d" "${MIG_SOURCE_PATHS[index]}")
    if [[ "$source_dev" == "$backup_dev" && "${AP_FORCE_COPY:-0}" != "1" ]]; then
      MIG_SOURCE_MODES+=("rename")
    else
      MIG_SOURCE_MODES+=("copy")
    fi
  done

  ap_ensure_journal_dir "$repo_root"
  local journal_file="$repo_root/.agent-profiles/.journal/migrate-all.json"
  if [[ -L "$journal_file" ]]; then
    ap_die "$EX_LAYOUT" "journal file '$journal_file' is a symbolic link"
  fi
  ap_lock_journal "$journal_file"

  local extra_json
  extra_json=$(ap_migrate_build_extra_json "$run_backup" "$staged_dir" "$legacy_dir")

  ap_record_journal "$journal_file" "migrate" "all" "planned" "$repo_root" "" "$assume_unrelated" "$extra_json"
  ap_copy_journal_to_backup "$journal_file" "$run_backup"

  for index in "${!MIG_SOURCE_PATHS[@]}"; do
    [[ "${MIG_SOURCE_MODES[index]}" == "copy" ]] || continue
    local source="${MIG_SOURCE_PATHS[index]}"
    local destination="$staged_dir/${MIG_SOURCE_LABELS[index]}"

    (umask 077 && mkdir -p "$(dirname "$destination")")
    if ! cp -a --no-dereference "$source" "$destination"; then
      ap_migrate_abort_copy "$run_backup" "$journal_file" "copy of legacy data failed; original data preserved"
    fi

    if [[ "${AP_CORRUPT_STAGED:-0}" == "1" ]]; then
      local first_file
      first_file=$(find "$destination" -type f | head -n 1)
      if [[ -n "$first_file" ]]; then
        printf "corrupt\n" >>"$first_file"
      fi
    fi

    local verify_status=0
    ap_verify_tree_copy "$source" "$destination" >/dev/null 2>&1 || verify_status=$?
    if [[ $verify_status -ne 0 ]]; then
      ap_migrate_abort_copy "$run_backup" "$journal_file" "checksum mismatch during cross-device migration verification (original data preserved)"
    fi
    printf "Cross-device copy verified with SHA-256 digests.\n"
  done

  ap_fsync_tree "$staged_dir" \
    || ap_migrate_abort_copy "$run_backup" "$journal_file" "unable to flush staged legacy data to disk; original data preserved"

  local content_manifest="$run_backup/content-manifest.json"
  local manifest_pairs=()
  local index
  for index in "${!MIG_SOURCE_PATHS[@]}"; do
    local manifest_tree
    if [[ "${MIG_SOURCE_MODES[index]}" == "copy" ]]; then
      manifest_tree="$staged_dir/${MIG_SOURCE_LABELS[index]}"
    else
      manifest_tree="${MIG_SOURCE_PATHS[index]}"
    fi
    manifest_pairs+=("${MIG_SOURCE_LABELS[index]}" "$manifest_tree")
  done
  ap_write_content_manifest "$content_manifest" "${manifest_pairs[@]}" \
    || ap_migrate_abort_copy "$run_backup" "$journal_file" "unable to write durable content manifest; original data preserved"

  ap_record_journal "$journal_file" "migrate" "all" "staged" "$repo_root" "" "$assume_unrelated" "$extra_json"
  ap_copy_journal_to_backup "$journal_file" "$run_backup"

  # Mark verified BEFORE moving same-device originals. Cross-device copies are
  # already verified; recovery at this state rolls forward and completes moves.
  ap_record_journal "$journal_file" "migrate" "all" "verified" "$repo_root" "" "$assume_unrelated" "$extra_json"
  ap_copy_journal_to_backup "$journal_file" "$run_backup"

  for index in "${!MIG_SOURCE_PATHS[@]}"; do
    [[ "${MIG_SOURCE_MODES[index]}" == "rename" ]] || continue
    local source="${MIG_SOURCE_PATHS[index]}"
    local destination="$legacy_dir/${MIG_SOURCE_LABELS[index]}"
    (umask 077 && mkdir -p "$(dirname "$destination")")
    mv "$source" "$destination"
  done

  for index in "${!MIG_SOURCE_PATHS[@]}"; do
    [[ "${MIG_SOURCE_MODES[index]}" == "copy" ]] || continue
    local destination="$legacy_dir/${MIG_SOURCE_LABELS[index]}"
    (umask 077 && mkdir -p "$(dirname "$destination")")
    mv "$staged_dir/${MIG_SOURCE_LABELS[index]}" "$destination"
  done
  rmdir "$staged_dir" 2>/dev/null || true

  for index in "${!MIG_SOURCE_PATHS[@]}"; do
    [[ "${MIG_SOURCE_MODES[index]}" == "copy" ]] || continue
    rm -rf "${MIG_SOURCE_PATHS[index]}"
  done

  ap_record_journal "$journal_file" "migrate" "all" "originals-removed" "$repo_root" "" "$assume_unrelated" "$extra_json"
  ap_copy_journal_to_backup "$journal_file" "$run_backup"

  ap_write_backup_manifest "$run_backup" \
    || ap_die "$EX_BROKEN" "unable to write backup manifest; run 'agent-profiles recover' after fixing the backup path"

  for target in "${MIG_TARGETS[@]}"; do
    ap_init_profile "$repo_root" "$target"
  done

  ap_record_journal "$journal_file" "migrate" "all" "rebuilt" "$repo_root" "" "$assume_unrelated" "$extra_json"
  ap_copy_journal_to_backup "$journal_file" "$run_backup"

  ap_unlock_journal
  rm -f "$journal_file"
  ap_unlock_profiles
  ap_unlock_storage

  printf "Migration completed successfully.\n"
  printf "  Original data preserved in private backup: %s\n" "$run_backup"
  printf "  Clean profile(s) initialized: %s\n" "${MIG_TARGETS[*]}"
  printf "  Note: reinstalling tools is required because shims, caches and symlinks store absolute paths; run installers again inside the new profiles (for example 'npm install -g', 'uv tool install', 'cargo install') and relink anything that pointed into the legacy directories.\n"
}
