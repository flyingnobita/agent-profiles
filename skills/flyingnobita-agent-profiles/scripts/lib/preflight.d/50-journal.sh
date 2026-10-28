#!/usr/bin/env bash
# Preflight hook: Stale journal detection and enforcement
# shellcheck disable=SC2154

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

  for jf in "$journal_dir"/*.json; do
    [[ -f "$jf" ]] || continue

    if [[ -L "$jf" ]]; then
      ap_die "$EX_LAYOUT" "journal file '$jf' is a symbolic link"
    fi

    # Probe exclusive lock non-blocking to check if journal is stale
    local is_stale=0
    local ret=0
    (
      exec {probe_fd}<>"$jf"
      if flock -x -n "$probe_fd"; then
        exit 10
      else
        exit 20
      fi
    ) 2>/dev/null || ret=$?

    if [[ $ret -eq 10 ]]; then
      is_stale=1
    fi

    if [[ $is_stale -eq 1 ]]; then
      local j_op="" j_prof=""
      # Read op and profile from JSON safely
      j_op=$(python3 -c 'import json, sys; d=json.load(open(sys.argv[1])); print(d.get("op", ""))' "$jf" 2>/dev/null || true)
      j_prof=$(python3 -c 'import json, sys; d=json.load(open(sys.argv[1])); print(d.get("profile", ""))' "$jf" 2>/dev/null || true)

      if [[ "$current_cmd" == "doctor" ]]; then
        # Doctor records stale journal in diagnostics; does not abort
        continue
      fi

      if [[ "$current_cmd" == "list" ]]; then
        printf "agent-profiles: notice: stale journal detected for profile '%s' (run 'agent-profiles recover')\n" "$j_prof" >&2
        continue
      fi

      if [[ "$current_cmd" == "recover" ]]; then
        # Recover command is meant to handle stale journals
        continue
      fi

      if [[ "$j_op" == "migrate" ]]; then
        ap_die "$EX_REFUSED" "interrupted migrate operation in checkout; run 'agent-profiles recover' to resolve"
      fi

      if [[ -n "$target_profile" && "$j_prof" == "$target_profile" ]]; then
        ap_die "$EX_REFUSED" "interrupted $j_op for profile '$target_profile'; run 'agent-profiles recover' to resolve"
      fi
    fi
  done
}

ap_preflight_check_journals "$repo_root" "$profile"
