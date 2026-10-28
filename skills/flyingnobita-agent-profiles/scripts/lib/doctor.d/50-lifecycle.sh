#!/usr/bin/env bash
# Doctor section: Lifecycle and journal diagnostics
# shellcheck disable=SC2154

ap_doctor_check_lifecycle() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -z "$repo_root" ]]; then
    return 0
  fi

  local journal_dir="$repo_root/.agent-profiles/.journal"
  local stale_journals=()

  if [[ -d "$journal_dir" ]]; then
    for jf in "$journal_dir"/*.json; do
      [[ -f "$jf" ]] || continue
      (
        exec {probe_fd}<>"$jf"
        flock -x -n "$probe_fd"
      ) 2>/dev/null && stale_journals+=("$(basename "$jf")") || true
    done
  fi

  local lc_status="available"
  local lc_detail="clean (no interrupted operations)"
  local lc_hint=""

  if [[ ${#stale_journals[@]} -gt 0 ]]; then
    lc_status="warning"
    lc_detail="stale journal(s) detected: ${stale_journals[*]}"
    lc_hint="Run 'agent-profiles recover' to roll forward or clean up interrupted lifecycle operations."
  fi

  CHECKS_JSON=$(python3 -c '
import json, sys
checks = json.loads(sys.argv[1])
checks.append({
    "id": "lifecycle",
    "status": sys.argv[2],
    "detail": sys.argv[3],
    "hint": sys.argv[4]
})
print(json.dumps(checks))
' "$CHECKS_JSON" "$lc_status" "$lc_detail" "$lc_hint")
}

ap_register_doctor_section "ap_doctor_check_lifecycle"
