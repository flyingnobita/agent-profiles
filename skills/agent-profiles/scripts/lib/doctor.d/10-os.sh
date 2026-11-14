#!/usr/bin/env bash
# Doctor section: Operating system and kernel details
# shellcheck disable=SC2034

# Qualification is decided per platform family and architecture. Linux keeps
# its bubblewrap-backed profiles; macOS is qualified on Apple silicon only,
# because that is the Darwin platform the environment-redirection adapter is
# tested on. Every other OS and non-arm64 Darwin stays an unqualified warning.
ap_doctor_check_os() {
  OS_NAME=$(ap_platform_os)
  OS_KERNEL=$(uname -r)
  OS_ARCH=$(uname -m)
  OS_DISTRO="unknown"
  OS_STATUS="warning"
  OS_HINT="operating system '$OS_NAME' is not qualified; Linux or macOS arm64 is required"

  if [[ "$OS_NAME" == "Linux" ]]; then
    if [[ -f /etc/os-release ]]; then
      OS_DISTRO=$(grep -E '^PRETTY_NAME=' /etc/os-release | head -n 1 | cut -d= -f2- | tr -d '"' || echo "unknown")
    fi
    OS_STATUS="available"
    OS_HINT=""
  elif [[ "$OS_NAME" == "Darwin" ]]; then
    # sw_vers is a base-system tool; when it is unavailable the identity stays
    # explicitly unknown instead of being guessed from the kernel version.
    local product_version=""
    if command -v sw_vers >/dev/null 2>&1; then
      product_version=$(sw_vers -productVersion 2>/dev/null || true)
    fi
    if [[ -n "$product_version" ]]; then
      OS_DISTRO="macOS $product_version"
    else
      OS_DISTRO="macOS (version unknown)"
    fi
    if [[ "$OS_ARCH" == "arm64" ]]; then
      OS_STATUS="available"
      OS_HINT=""
    else
      OS_STATUS="warning"
      OS_HINT="macOS on '$OS_ARCH' is not qualified; only macOS arm64 (Apple silicon) is supported"
    fi
  fi
}

ap_register_doctor_section "ap_doctor_check_os"
