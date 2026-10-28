#!/usr/bin/env bash
# Doctor section: Operating system and kernel details
# shellcheck disable=SC2034

ap_doctor_check_os() {
  OS_NAME=$(uname -s)
  OS_KERNEL=$(uname -r)
  OS_ARCH=$(uname -m)
  OS_DISTRO="unknown"

  if [[ -f /etc/os-release ]]; then
    OS_DISTRO=$(grep -E '^PRETTY_NAME=' /etc/os-release | head -n 1 | cut -d= -f2- | tr -d '"' || echo "unknown")
  fi

  if [[ "$OS_NAME" != "Linux" ]]; then
    OS_STATUS="warning"
    OS_HINT="macOS and other operating systems are not qualified. Linux is required for profile redirection."
  else
    OS_STATUS="available"
    OS_HINT=""
  fi
}
