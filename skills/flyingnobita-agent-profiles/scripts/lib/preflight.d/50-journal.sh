#!/usr/bin/env bash
# Preflight hook: Stale journal detection and enforcement
# shellcheck disable=SC2154
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/locks.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/lifecycle.sh

source "$LIB_DIR/locks.sh"
source "$LIB_DIR/lifecycle.sh"

ap_preflight_check_journals() {
  local repo_root="$1"
  local target_profile="$2"

  local journal_dir="$repo_root/.agent-profiles/.journal"
  if [[ ! -d "$journal_dir" ]]; then
    return 0
  fi

  if [[ -L "$journal_dir" ]]; then
    ap_die "$EX_LAYOUT" "journal directory '$journal_dir' is a symbolic link"
  fi

  local current_cmd="${cmd:-}"
  local journal_file

  for journal_file in "$journal_dir"/*.json; do
    [[ -f "$journal_file" ]] || continue

    if [[ -L "$journal_file" ]]; then
      ap_die "$EX_LAYOUT" "journal file '$journal_file' is a symbolic link"
    fi

    ap_journal_is_stale "$journal_file" || continue

    local fields=()
    mapfile -d '' -t fields < <(ap_read_journal_fields "$journal_file")
    if [[ ${#fields[@]} -eq 0 ]]; then
      ap_die "$EX_REFUSED" "unreadable journal '$journal_file'; run 'agent-profiles recover'"
    fi
    local journal_op="${fields[0]:-}"
    local journal_profile="${fields[1]:-}"

    case "$current_cmd" in
      doctor)
        continue
        ;;
      list)
        printf "agent-profiles: notice: stale journal detected for profile '%s' (run 'agent-profiles recover')\n" "$journal_profile" >&2
        continue
        ;;
      recover)
        continue
        ;;
    esac

    if [[ "$journal_op" == "migrate" ]]; then
      ap_die "$EX_REFUSED" "interrupted migrate operation in checkout; run 'agent-profiles recover' to resolve"
    fi

    if [[ -n "$target_profile" && "$journal_profile" == "$target_profile" ]]; then
      ap_die "$EX_REFUSED" "interrupted $journal_op for profile '$target_profile'; run 'agent-profiles recover' to resolve"
    fi
  done
}

ap_preflight_check_journals "$repo_root" "$profile"
