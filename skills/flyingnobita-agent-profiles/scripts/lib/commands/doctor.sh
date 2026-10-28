#!/usr/bin/env bash
# Command: doctor - host, dependency, and agent readiness diagnostics
# shellcheck disable=SC2154

# Doctor section registration mechanism
AP_DOCTOR_SECTIONS=()

ap_register_doctor_section() {
  local func="$1"
  AP_DOCTOR_SECTIONS+=("$func")
}

ap_cmd_doctor() {
  ap_require_python "$@"

  local OUTPUT_JSON=0
  local SELECTED_AGENTS=()
  local SELECTED_PROFILE=""
  local PROFILE_SPECIFIED=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        OUTPUT_JSON=1
        shift
        ;;
      --agent)
        [[ $# -ge 2 ]] || ap_die "$EX_USAGE" "--agent requires an argument"
        local agent_arg="$2"
        case "$agent_arg" in
          claude | codex | agy | opencode)
            SELECTED_AGENTS+=("$agent_arg")
            ;;
          *)
            ap_die "$EX_USAGE" "unsupported agent: $agent_arg. Supported agents: claude, codex, agy, opencode"
            ;;
        esac
        shift 2
        ;;
      --agent=*)
        local agent_arg="${1#*=}"
        case "$agent_arg" in
          claude | codex | agy | opencode)
            SELECTED_AGENTS+=("$agent_arg")
            ;;
          *)
            ap_die "$EX_USAGE" "unsupported agent: $agent_arg. Supported agents: claude, codex, agy, opencode"
            ;;
        esac
        shift
        ;;
      --profile)
        [[ $# -ge 2 ]] || ap_die "$EX_USAGE" "--profile requires an argument"
        PROFILE_SPECIFIED=1
        SELECTED_PROFILE="$2"
        shift 2
        ;;
      --profile=*)
        PROFILE_SPECIFIED=1
        SELECTED_PROFILE="${1#*=}"
        shift
        ;;
      *)
        ap_die "$EX_USAGE" "unknown doctor option: $1"
        ;;
    esac
  done

  if [[ $PROFILE_SPECIFIED -eq 1 ]]; then
    if [[ -z "$SELECTED_PROFILE" ]]; then
      ap_die "$EX_USAGE" "--profile requires a non-empty profile name"
    fi
    if [[ ! "$SELECTED_PROFILE" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
      ap_die "$EX_DATAERR" "invalid profile name: $SELECTED_PROFILE. Names must match ^[a-z][a-z0-9_-]{0,31}$"
    fi
  fi

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

  for section_fn in "${AP_DOCTOR_SECTIONS[@]}"; do
    "$section_fn"
  done

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
    tag = "[OK]" if st == "available" else (f"[{st.upper()}]" if st != "missing" else "[MISSING]")
    if st == "available":
        v = info.get("version") or "unknown"
        p = info.get("path") or "on PATH"
        print(f"  {tag} {name}: {v} ({p})")
        probe = info.get("version_probe")
        if probe:
            print(f"    Version probe: {probe} (informational)")
    elif st == "unverified":
        p = info.get("path") or "on PATH"
        print(f"  {tag} {name}: capability unverified ({p})")
        hint = info.get("hint")
        if hint:
            print(f"    Hint: {hint}")
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
