#!/usr/bin/env bash
# Command: doctor - host, dependency, and agent readiness diagnostics
# shellcheck disable=SC2154

ap_cmd_doctor() {
  local OUTPUT_JSON=0
  local SELECTED_AGENTS=()
  local SELECTED_PROFILE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        OUTPUT_JSON=1
        shift
        ;;
      --agent)
        [[ $# -ge 2 ]] || ap_die "$EX_USAGE" "--agent requires an argument"
        SELECTED_AGENTS+=("$2")
        shift 2
        ;;
      --agent=*)
        SELECTED_AGENTS+=("${1#*=}")
        shift
        ;;
      --profile)
        [[ $# -ge 2 ]] || ap_die "$EX_USAGE" "--profile requires an argument"
        SELECTED_PROFILE="$2"
        shift 2
        ;;
      --profile=*)
        SELECTED_PROFILE="${1#*=}"
        shift
        ;;
      *)
        ap_die "$EX_USAGE" "unknown doctor option: $1"
        ;;
    esac
  done

  # Run pluggable doctor checks
  local doctor_d="$LIB_DIR/doctor.d"
  if [[ -d "$doctor_d" ]]; then
    for script in "$doctor_d"/*.sh; do
      if [[ -f "$script" ]]; then
        # shellcheck source=/dev/null
        source "$script"
      fi
    done
  fi

  ap_doctor_check_os
  ap_doctor_check_deps
  ap_doctor_check_agents

  local ver="0.1.0"
  if [[ -f "$VERSION_FILE" ]]; then
    ver=$(tr -d '[:space:]' <"$VERSION_FILE")
  fi

  if [[ $OUTPUT_JSON -eq 1 ]]; then
    python3 -c '
import json, sys
data = {
    "version": sys.argv[1],
    "os": {
        "name": sys.argv[2],
        "distro": sys.argv[3],
        "kernel": sys.argv[4],
        "arch": sys.argv[5]
    },
    "checks": json.loads(sys.argv[6]),
    "agents": json.loads(sys.argv[7])
}
print(json.dumps(data, indent=2))
' "$ver" "$OS_NAME" "$OS_DISTRO" "$OS_KERNEL" "$OS_ARCH" "$CHECKS_JSON" "$AGENTS_JSON"
    return 0
  fi

  # Text output
  printf "flyingnobita-agent-profiles doctor v%s\n\n" "$ver"

  printf "OS:\n"
  printf "  System: %s (%s)\n" "$OS_NAME" "$OS_DISTRO"
  printf "  Kernel: %s\n" "$OS_KERNEL"
  printf "  Architecture: %s\n\n" "$OS_ARCH"

  printf "Dependencies:\n"
  python3 -c '
import json, sys
checks = json.loads(sys.argv[1])
for c in checks:
    st = c.get("status", "unknown")
    tag = "[OK]" if st == "available" else f"[{st.upper()}]"
    cid = c.get("id", "")
    dt = c.get("detail", "")
    print(f"  {tag} {cid}: {dt}")
    h = c.get("hint", "")
    if h:
        print(f"    Hint: {h}")
' "$CHECKS_JSON"
  echo

  printf "Agents:\n"
  python3 -c '
import json, sys
agents = json.loads(sys.argv[1])
for name, info in sorted(agents.items()):
    st = info.get("status", "unknown")
    tag = "[OK]" if st == "available" else "[MISSING]"
    if st == "available":
        v = info.get("version") or "unknown"
        p = info.get("path") or "on PATH"
        print(f"  {tag} {name}: {v} ({p})")
        probe = info.get("version_probe")
        if probe:
            print(f"    Version probe: {probe} (informational)")
    else:
        print(f"  {tag} {name}: not found on PATH")
' "$AGENTS_JSON"
  echo

  printf "Security & Secrets:\n"
  printf "  No credential values or secret environments inspected or exposed.\n"
  if [[ -n "$SELECTED_PROFILE" ]]; then
    printf "  Profile diagnostics requested for: %s\n" "$SELECTED_PROFILE"
  fi
}
