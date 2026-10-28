#!/usr/bin/env bash
# Global mise task detection and machine setup support (ticket 03)
# shellcheck disable=SC2034

AP_SETUP_TASKS=(agent-profiles-init agent-profiles)
AP_SETUP_AGENTS=(claude codex agy opencode)
AP_SETUP_DEPS=(bash git python3 mise bwrap)

ap_setup_skill_dir() {
  printf "%s\n" "$(dirname "$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")")"
}

ap_setup_read_field() {
  local file="$1"
  local key="$2"
  if [[ ! -r "$file" ]]; then
    return 0
  fi
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1 | tr -d '"'
}

ap_setup_detect() {
  local os_name
  os_name="$(uname -s 2>/dev/null || echo unknown)"
  AP_SETUP_OS_RELEASE="${AP_OS_RELEASE:-/etc/os-release}"
  AP_SETUP_OS_ID="$(ap_setup_read_field "$AP_SETUP_OS_RELEASE" ID)"
  AP_SETUP_OS_ID_LIKE="$(ap_setup_read_field "$AP_SETUP_OS_RELEASE" ID_LIKE)"
  AP_SETUP_OS_PRETTY="$(ap_setup_read_field "$AP_SETUP_OS_RELEASE" PRETTY_NAME)"

  [[ -n "$AP_SETUP_OS_ID" ]] || AP_SETUP_OS_ID="unknown"
  [[ -n "$AP_SETUP_OS_PRETTY" ]] || AP_SETUP_OS_PRETTY="unknown"

  AP_SETUP_FAMILY="unsupported"
  if [[ "$os_name" == "Linux" ]]; then
    case " $AP_SETUP_OS_ID $AP_SETUP_OS_ID_LIKE " in
      *" arch "* | *" archlinux "*) AP_SETUP_FAMILY="arch" ;;
      *" debian "* | *" ubuntu "*) AP_SETUP_FAMILY="debian" ;;
    esac
  fi

  AP_SETUP_PKG_MANAGER=""
  case "$AP_SETUP_FAMILY" in
    arch) command -v pacman >/dev/null 2>&1 && AP_SETUP_PKG_MANAGER="pacman" ;;
    debian) command -v apt-get >/dev/null 2>&1 && AP_SETUP_PKG_MANAGER="apt-get" ;;
  esac

  if [[ -z "$AP_SETUP_PKG_MANAGER" ]]; then
    local candidate
    for candidate in pacman apt-get dnf zypper apk; do
      if command -v "$candidate" >/dev/null 2>&1; then
        AP_SETUP_PKG_MANAGER="$candidate"
        break
      fi
    done
  fi
}

ap_setup_resolve() {
  local name="$1"
  local found
  found="$(command -v "$name" 2>/dev/null || true)"
  [[ -n "$found" ]] || return 1
  readlink -f "$found" 2>/dev/null || printf "%s\n" "$found"
}

ap_setup_package_for() {
  local dep="$1"
  case "$AP_SETUP_FAMILY:$dep" in
    arch:bwrap) printf "bubblewrap\n" ;;
    debian:bwrap) printf "bubblewrap\n" ;;
    arch:python3) printf "python\n" ;;
    debian:python3) printf "python3\n" ;;
    *:bash | *:git) printf "%s\n" "$dep" ;;
    *) return 1 ;;
  esac
}

ap_setup_package_command() {
  local dep="$1"
  local package
  if ! package="$(ap_setup_package_for "$dep")"; then
    return 1
  fi
  if [[ -z "$AP_SETUP_PKG_MANAGER" ]]; then
    return 1
  fi
  case "$AP_SETUP_PKG_MANAGER" in
    pacman) printf "pacman -S %s\n" "$package" ;;
    apt-get) printf "apt-get install %s\n" "$package" ;;
    *) return 1 ;;
  esac
}

ap_setup_mise_registry_has() {
  local tool="$1"
  command -v mise >/dev/null 2>&1 || return 1
  mise registry 2>/dev/null | awk '{print $1}' | grep -Fxq "$tool"
}

ap_mise_config_dir() {
  if [[ -n "${MISE_CONFIG_DIR:-}" ]]; then
    printf "%s\n" "$MISE_CONFIG_DIR"
    return 0
  fi
  if command -v mise >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    local resolved
    resolved="$(
      mise doctor --json 2>/dev/null | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get("dirs", {}).get("config")
    if value and value.startswith("/"):
        print(value)
except Exception:
    pass
' 2>/dev/null || true
    )"
    if [[ -n "$resolved" ]]; then
      printf "%s\n" "$resolved"
      return 0
    fi
  fi
  printf "%s\n" "${XDG_CONFIG_HOME:-$HOME/.config}/mise"
}

ap_setup_task_path() {
  local config_dir="$1"
  local task="$2"
  printf "%s\n" "$config_dir/tasks/$task"
}

ap_setup_print_detection() {
  local id_like="none"
  [[ -n "$AP_SETUP_OS_ID_LIKE" ]] && id_like="$AP_SETUP_OS_ID_LIKE"
  printf "OS: %s (ID=%s, ID_LIKE=%s, %s family)\n" \
    "$AP_SETUP_OS_PRETTY" "$AP_SETUP_OS_ID" "$id_like" "$AP_SETUP_FAMILY"

  if [[ -n "$AP_SETUP_PKG_MANAGER" ]]; then
    printf "Package manager: %s (%s family)\n" "$AP_SETUP_PKG_MANAGER" "$AP_SETUP_FAMILY"
  else
    printf "Package manager: none detected\n"
  fi
  if [[ "$AP_SETUP_FAMILY" == "unsupported" ]]; then
    printf "  [UNSUPPORTED] unsupported automatic path: distribution family '%s' is not supported\n" \
      "$AP_SETUP_OS_ID"
  fi
  printf "\n"

  printf "Dependencies:\n"
  local dep path install_command
  for dep in "${AP_SETUP_DEPS[@]}"; do
    if path="$(ap_setup_resolve "$dep")"; then
      printf "  [OK] %s: %s\n" "$dep" "$path"
    elif [[ "$dep" == "mise" ]]; then
      printf "  [MANUAL] mise: unsupported automatic path (install mise manually; no curl installation)\n"
    elif install_command="$(ap_setup_package_command "$dep")"; then
      printf "  [MISSING] %s: not found (install: %s)\n" "$dep" "$install_command"
    else
      printf "  [MISSING] %s: not found (unsupported automatic path)\n" "$dep"
    fi
  done
  printf "\n"

  printf "Agents:\n"
  local agent
  for agent in "${AP_SETUP_AGENTS[@]}"; do
    if path="$(ap_setup_resolve "$agent")"; then
      printf "  [FOUND] %s: %s\n" "$agent" "$path"
    elif ap_setup_mise_registry_has "$agent"; then
      printf "  [MISSING] %s: not found (optional; install with --agent %s via the mise registry)\n" \
        "$agent" "$agent"
    else
      printf "  [MISSING] %s: not found (unsupported automatic path)\n" "$agent"
    fi
  done
  printf "\n"

  local config_dir task
  config_dir="$(ap_mise_config_dir)"
  printf "Global tasks:\n"
  printf "  config dir: %s\n" "$config_dir"
  for task in "${AP_SETUP_TASKS[@]}"; do
    if [[ -f "$(ap_setup_task_path "$config_dir" "$task")" ]]; then
      printf "  %s: present\n" "$task"
    else
      printf "  %s: absent\n" "$task"
    fi
  done
}
