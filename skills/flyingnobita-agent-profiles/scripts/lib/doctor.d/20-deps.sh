#!/usr/bin/env bash
# Doctor section: Host dependencies and namespace readiness
# shellcheck disable=SC2034

ap_doctor_check_deps() {
  CHECKS_JSON="[]"

  # 1. bash
  local bash_path bash_ver bash_status bash_hint
  bash_path=$(command -v bash 2>/dev/null || true)
  if [[ -n "$bash_path" ]]; then
    bash_path=$(readlink -f "$bash_path" 2>/dev/null || echo "$bash_path")
    bash_ver=$(bash --version 2>/dev/null | head -n 1 | cut -d' ' -f4 || echo "unknown")
    bash_status="available"
    bash_hint=""
  else
    bash_ver="none"
    bash_status="missing"
    bash_hint="Bash shell is required"
  fi
  CHECKS_JSON=$(python3 -c '
import json, sys
checks = json.loads(sys.argv[1])
checks.append({
    "id": "bash",
    "status": sys.argv[2],
    "detail": f"{sys.argv[3]} ({sys.argv[4]})" if sys.argv[2] == "available" else "not found on PATH",
    "hint": sys.argv[5]
})
print(json.dumps(checks))
' "$CHECKS_JSON" "$bash_status" "$bash_ver" "$bash_path" "$bash_hint")

  # 2. git
  local git_path git_ver git_status git_hint
  git_path=$(command -v git 2>/dev/null || true)
  if [[ -n "$git_path" ]]; then
    git_path=$(readlink -f "$git_path" 2>/dev/null || echo "$git_path")
    git_ver=$(git --version 2>/dev/null | cut -d' ' -f3 || echo "unknown")
    git_status="available"
    git_hint=""
  else
    git_ver="none"
    git_status="missing"
    git_hint="Git is required for repository resolution and profile exclusions"
  fi
  CHECKS_JSON=$(python3 -c '
import json, sys
checks = json.loads(sys.argv[1])
checks.append({
    "id": "git",
    "status": sys.argv[2],
    "detail": f"{sys.argv[3]} ({sys.argv[4]})" if sys.argv[2] == "available" else "not found on PATH",
    "hint": sys.argv[5]
})
print(json.dumps(checks))
' "$CHECKS_JSON" "$git_status" "$git_ver" "$git_path" "$git_hint")

  # 3. python3
  local py_path py_ver py_status py_hint
  py_path=$(command -v python3 2>/dev/null || true)
  if [[ -n "$py_path" ]]; then
    py_path=$(readlink -f "$py_path" 2>/dev/null || echo "$py_path")
    py_ver=$(python3 --version 2>/dev/null | cut -d' ' -f2 || echo "unknown")
    py_status="available"
    py_hint=""
  else
    py_ver="none"
    py_status="missing"
    py_hint="Python 3 standard library is required for JSON processing and directory parsing"
  fi
  CHECKS_JSON=$(python3 -c '
import json, sys
checks = json.loads(sys.argv[1])
checks.append({
    "id": "python3",
    "status": sys.argv[2],
    "detail": f"{sys.argv[3]} ({sys.argv[4]})" if sys.argv[2] == "available" else "not found on PATH",
    "hint": sys.argv[5]
})
print(json.dumps(checks))
' "$CHECKS_JSON" "$py_status" "$py_ver" "$py_path" "$py_hint")

  # 4. mise
  local mise_path mise_ver mise_status mise_hint
  mise_path=$(command -v mise 2>/dev/null || true)
  if [[ -n "$mise_path" ]]; then
    mise_path=$(readlink -f "$mise_path" 2>/dev/null || echo "$mise_path")
    mise_ver=$(mise --version 2>/dev/null | grep -E '^[0-9]' | head -n 1 | cut -d' ' -f1 || echo "installed")
    mise_status="available"
    mise_hint=""
  else
    mise_ver="none"
    mise_status="missing"
    mise_hint="Install mise to manage tool versions and global tasks: https://mise.jdx.dev"
  fi
  CHECKS_JSON=$(python3 -c '
import json, sys
checks = json.loads(sys.argv[1])
checks.append({
    "id": "mise",
    "status": sys.argv[2],
    "detail": f"{sys.argv[3]} ({sys.argv[4]})" if sys.argv[2] == "available" else "not found on PATH",
    "hint": sys.argv[5]
})
print(json.dumps(checks))
' "$CHECKS_JSON" "$mise_status" "$mise_ver" "$mise_path" "$mise_hint")

  # 5. bwrap (bubblewrap)
  local bwrap_path bwrap_ver bwrap_status bwrap_hint
  bwrap_path=$(command -v bwrap 2>/dev/null || true)
  if [[ -n "$bwrap_path" ]]; then
    bwrap_path=$(readlink -f "$bwrap_path" 2>/dev/null || echo "$bwrap_path")
    bwrap_ver=$(bwrap --version 2>/dev/null | cut -d' ' -f2 || echo "unknown")
    bwrap_status="available"
    bwrap_hint=""
  else
    bwrap_ver="none"
    bwrap_status="missing"
    bwrap_hint="Install bubblewrap (bwrap) via package manager (e.g. pacman -S bubblewrap or apt install bubblewrap)"
  fi
  CHECKS_JSON=$(python3 -c '
import json, sys
checks = json.loads(sys.argv[1])
checks.append({
    "id": "bwrap",
    "status": sys.argv[2],
    "detail": f"{sys.argv[3]} ({sys.argv[4]})" if sys.argv[2] == "available" else "not found on PATH",
    "hint": sys.argv[5]
})
print(json.dumps(checks))
' "$CHECKS_JSON" "$bwrap_status" "$bwrap_ver" "$bwrap_path" "$bwrap_hint")

  # 6. userns (user namespaces)
  local userns_status userns_detail userns_hint
  if [[ "$bwrap_status" == "available" ]]; then
    if bwrap --dev-bind / / true 2>/dev/null; then
      userns_status="available"
      userns_detail="unprivileged user namespaces working with bubblewrap"
      userns_hint=""
    else
      userns_status="warning"
      userns_detail="bubblewrap test failed; unprivileged user namespaces may be restricted"
      userns_hint="Check sysctl kernel.unprivileged_userns_clone or AppArmor restrictions"
    fi
  else
    userns_status="unverified"
    userns_detail="bubblewrap missing; namespace support unverified"
    userns_hint="Install bubblewrap to test namespace capability"
  fi
  CHECKS_JSON=$(python3 -c '
import json, sys
checks = json.loads(sys.argv[1])
checks.append({
    "id": "userns",
    "status": sys.argv[2],
    "detail": sys.argv[3],
    "hint": sys.argv[4]
})
print(json.dumps(checks))
' "$CHECKS_JSON" "$userns_status" "$userns_detail" "$userns_hint")
}
