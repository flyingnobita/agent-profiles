#!/usr/bin/env bash
# Internal portability adapter for agent-profiles. Not a public command.
#
# GNU userland is not available on stock macOS, so every path, stat, hash,
# timeout, lock and copy primitive the helper needs comes from the standard
# library through platform.py. Callers keep their existing fail-closed checks.
# shellcheck disable=SC2034

AP_PLATFORM_DIR="${AP_PLATFORM_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
AP_PLATFORM_PY="$AP_PLATFORM_DIR/platform.py"
if command -v python3 >/dev/null 2>&1; then
  AP_PLATFORM_PYTHON="$(command -v python3)"
else
  AP_PLATFORM_PYTHON=""
fi

ap_platform_require() {
  if [[ -z "$AP_PLATFORM_PYTHON" ]]; then
    ap_die "${EX_UNAVAILABLE:-69}" "python3 is required but not found on PATH"
  fi
  if [[ ! -f "$AP_PLATFORM_PY" ]]; then
    ap_die "${EX_BROKEN:-78}" "internal portability helper is missing: $AP_PLATFORM_PY"
  fi
}

ap_platform() {
  ap_platform_require
  "$AP_PLATFORM_PYTHON" "$AP_PLATFORM_PY" "$@"
}

# Resolves the physical directory that holds an entrypoint script.
ap_platform_script_dir() {
  ap_platform script-dir "$1"
}

# Canonicalizes a path whose final component must already exist.
ap_platform_realpath_existing() {
  ap_platform realpath --existing "$1"
}

# Canonicalizes a path that may not exist yet, resolving real ancestors.
ap_platform_realpath_missing() {
  ap_platform realpath --missing "$1"
}

# Prints one filesystem attribute so callers stop depending on GNU stat -c.
ap_platform_stat_mode() {
  ap_platform stat mode "$1"
}

ap_platform_stat_owner() {
  ap_platform stat owner "$1"
}

ap_platform_stat_dev() {
  ap_platform stat dev "$1"
}

ap_platform_stat_devino() {
  ap_platform stat devino "$1"
}
