#!/usr/bin/env bash
# Doctor section: Lifecycle and journal diagnostics
# shellcheck disable=SC2154
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/lifecycle.sh
# shellcheck source=skills/flyingnobita-agent-profiles/scripts/lib/locks.sh

source "$LIB_DIR/lifecycle.sh"
source "$LIB_DIR/locks.sh"

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
      if ap_journal_is_stale "$jf"; then
        stale_journals+=("$(basename "$jf")")
      fi
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

  local legacy_layouts
  legacy_layouts=$(ap_detect_legacy_layouts "$repo_root")
  if [[ -n "$legacy_layouts" ]]; then
    CHECKS_JSON=$(python3 -c '
import json, sys
checks = json.loads(sys.argv[1])
checks.append({
    "id": "legacy_storage",
    "status": "warning",
    "detail": f"legacy profile storage detected ({sys.argv[2]}); run agent-profiles migrate",
    "hint": "Run '\''agent-profiles migrate'\'' to safely migrate legacy storage to current profile format."
})
print(json.dumps(checks))
' "$CHECKS_JSON" "$legacy_layouts")
  fi
}

ap_register_doctor_section "ap_doctor_check_lifecycle"
