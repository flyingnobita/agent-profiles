#!/usr/bin/env bash
# Command: recover - recover interrupted lifecycle operations
# shellcheck disable=SC2034
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/runtime.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/locks.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/lifecycle.sh

source "$LIB_DIR/runtime.sh"
source "$LIB_DIR/locks.sh"
source "$LIB_DIR/lifecycle.sh"

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

  # Refuse if executed from inside a live profile context
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

  # Acquire exclusive storage lock during recovery
  ap_lock_storage_exclusive "$repo_root"

  local stale_journals=()
  for jf in "$journal_dir"/*.json; do
    [[ -f "$jf" ]] || continue

    if [[ -L "$jf" ]]; then
      ap_die "$EX_LAYOUT" "journal file '$jf' is a symbolic link"
    fi

    # Probe exclusive flock non-blocking
    local is_stale=0
    local ret=0
    (
      exec {probe_fd}<>"$jf"
      if flock -x -n "$probe_fd"; then
        exit 10
      fi
    ) 2>/dev/null || ret=$?

    if [[ $ret -eq 10 ]]; then
      is_stale=1
    fi

    if [[ $is_stale -eq 1 ]]; then
      stale_journals+=("$jf")
    fi
  done

  if [[ ${#stale_journals[@]} -eq 0 ]]; then
    printf "No interrupted operations found to recover.\n"
    ap_unlock_storage
    return 0
  fi

  if [[ $yes_flag -eq 0 ]]; then
    printf "Interrupted operation journals found for recovery:\n"
    for jf in "${stale_journals[@]}"; do
      printf "  %s\n" "$(basename "$jf")"
    done
    printf "Pass --yes to perform recovery.\n"
    ap_unlock_storage
    return 0
  fi

  for jf in "${stale_journals[@]}"; do
    ap_lock_journal "$jf"

    # Read journal fields via python
    local j_op j_prof j_state j_prof_dir j_trash_path
    eval "$(python3 -c '
import json, sys

with open(sys.argv[1], "r") as f:
    d = json.load(f)

op = d.get("op", "")
prof = d.get("profile", "")
state = d.get("state", "")
prof_dir = d.get("profile_dir", "")
trash_path = d.get("trash_path", "")

print(f"j_op=\"{op}\"")
print(f"j_prof=\"{prof}\"")
print(f"j_state=\"{state}\"")
print(f"j_prof_dir=\"{prof_dir}\"")
print(f"j_trash_path=\"{trash_path}\"")
' "$jf")"

    # Path safety validation
    if [[ -n "$j_trash_path" ]]; then
      local trash_dir="$repo_root/.agent-profiles/.trash"
      local real_tp
      real_tp=$(readlink -f "$j_trash_path" 2>/dev/null || echo "$j_trash_path")
      local real_td
      real_td=$(readlink -f "$trash_dir" 2>/dev/null || echo "$trash_dir")
      if [[ "$real_tp" != "$real_td"/* ]]; then
        ap_die "$EX_LAYOUT" "unsafe journal trash path '$j_trash_path' (not under $trash_dir)"
      fi
    fi

    case "$j_op" in
      reset)
        case "$j_state" in
          planned)
            # Profile intact: abort and clear
            ;;
          trashed)
            ap_init_profile "$repo_root" "$j_prof"
            if [[ -n "$j_trash_path" && -d "$j_trash_path" ]]; then
              rm -rf "$j_trash_path"
            fi
            ;;
          rebuilt)
            if [[ -n "$j_trash_path" && -d "$j_trash_path" ]]; then
              rm -rf "$j_trash_path"
            fi
            ;;
          trash-deleted) ;;
        esac
        ;;
      remove)
        case "$j_state" in
          planned) ;;
          trashed | rebuilt)
            if [[ -n "$j_trash_path" && -d "$j_trash_path" ]]; then
              rm -rf "$j_trash_path"
            fi
            ;;
          trash-deleted) ;;
        esac
        ;;
      migrate)
        local j_staged_dir j_backup_dir
        eval "$(python3 -c '
import json, sys
with open(sys.argv[1], "r") as f:
    d = json.load(f)
print(f"j_staged_dir=\"{d.get(\"staged_dir\", \"\")}\"")
print(f"j_backup_dir=\"{d.get(\"backup_dir\", \"\")}\"")
' "$jf")"
        case "$j_state" in
          planned | staged)
            if [[ -n "$j_staged_dir" && -d "$j_staged_dir" ]]; then
              rm -rf "$j_staged_dir"
            fi
            ;;
          verified | originals-removed | rebuilt)
            # Finish migration
            local targets
            targets=$(python3 -c 'import json, sys; d=json.load(open(sys.argv[1])); print(" ".join(d.get("migrated_profiles", [])))' "$jf" 2>/dev/null || true)
            for tp in $targets; do
              ap_init_profile "$repo_root" "$tp"
            done
            ;;
        esac
        ;;
    esac

    ap_unlock_journal
    rm -f "$jf"
    printf "Recovered interrupted '%s' operation for profile '%s'.\n" "$j_op" "$j_prof"
  done

  ap_unlock_storage
  printf "All interrupted operations recovered successfully.\n"
}
