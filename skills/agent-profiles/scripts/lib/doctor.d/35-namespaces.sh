#!/usr/bin/env bash
# Doctor section: actual bubblewrap user namespace readiness
# shellcheck disable=SC2034

ap_doctor_check_namespaces() {
  local bwrap_path status detail hint

  if ap_platform_is_darwin; then
    # Darwin has no bubblewrap-backed namespaces and no probe may be run: the
    # profile adapter redirects configuration by environment only.
    status="not_applicable"
    detail="bubblewrap user namespaces are a Linux-only mechanism; Darwin profile runs redirect by environment and no namespace probe was run"
    hint=""
  else
    bwrap_path="$(command -v bwrap 2>/dev/null || true)"
    if [[ -z "$bwrap_path" ]]; then
      status="missing"
      detail="bubblewrap is not installed; profile namespaces cannot run"
      hint="Install bubblewrap with your package manager and rerun doctor."
    elif ap_platform_timeout 10 bwrap --dev-bind / / true >/dev/null 2>&1; then
      status="available"
      detail="bubblewrap unprivileged namespaces work; the profile wrapper can run commands"
      hint=""
    else
      status="error"
      detail="bubblewrap namespace probe failed; agent-profiles run exits 69"
      hint="Check kernel.unprivileged_userns_clone, AppArmor apparmor_restrict_unprivileged_userns, and container seccomp restrictions."
    fi
  fi

  CHECKS_JSON=$(python3 -c '
import json, sys
checks = json.loads(sys.argv[1])
checks.append({
    "id": "namespaces",
    "status": sys.argv[2],
    "detail": sys.argv[3],
    "hint": sys.argv[4]
})
print(json.dumps(checks))
' "$CHECKS_JSON" "$status" "$detail" "$hint")
}

ap_register_doctor_section "ap_doctor_check_namespaces"
