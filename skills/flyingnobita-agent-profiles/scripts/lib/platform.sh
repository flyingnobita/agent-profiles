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

# Apple's /usr/bin/python3 writes the bytecode of every imported stdlib module
# into ~/Library/Caches/com.apple.python, which ignores XDG and follows HOME.
# Every python process this helper starts is short-lived work, so it must never
# leave that cache behind: on a shared host it is a write the user did not ask
# for, and inside a redirected profile it makes a "host unchanged" check fail.
# It is exported rather than prefixed so that the child python processes the
# doctor and lifecycle code start are covered as well.
export PYTHONDONTWRITEBYTECODE=1

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

# Prints the operating-system family the helper is running on. Production
# behaviour is always decided by the real platform: AP_TEST_PLATFORM_OS is an
# internal seam that is only honoured when the Bats test runner is present, so
# it cannot be selected through a normal user-facing command.
ap_platform_os() {
  if [[ -n "${AP_TEST_PLATFORM_OS:-}" && -n "${BATS_TEST_FILENAME:-}" ]]; then
    printf "%s\n" "$AP_TEST_PLATFORM_OS"
    return 0
  fi
  uname -s
}

ap_platform_is_darwin() {
  [[ "$(ap_platform_os)" == "Darwin" ]]
}

# True when the machine that will actually execute a child process is Darwin.
#
# AP_TEST_PLATFORM_OS lets the test suite qualify the Darwin adapter on a Linux
# host. It must never do the opposite: macOS ships no bubblewrap, no procfs and
# no user namespaces, so a Linux execution path taken there can only fail. The
# run adapter and its prerequisites therefore ask about the kernel, not about
# the platform that was selected for a diagnostic.
ap_platform_host_is_darwin() {
  if [[ "$(ap_platform_os)" == "Darwin" ]]; then
    return 0
  fi
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]
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

# --- Lock descriptors -------------------------------------------------------
# Stock bash 3.2 has no dynamic {varname} redirection, so the shell keeps an
# explicit table of the descriptors it opened. The kernel lock is applied to one
# of those descriptors by platform.py, which shares the open file description
# with the shell: the lock therefore survives the helper exiting and is
# inherited by exec'd children and descendants exactly like a plain redirect.
AP_LOCK_FD_BASE="${AP_LOCK_FD_BASE:-30}"
AP_LOCK_FD_MAX="${AP_LOCK_FD_MAX:-59}"
AP_LOCK_FDS=()

ap_fd_tracked() {
  local candidate="$1"
  local tracked
  for tracked in "${AP_LOCK_FDS[@]:-}"; do
    [[ -n "$tracked" && "$tracked" == "$candidate" ]] && return 0
  done
  return 1
}

ap_fd_is_open() {
  local candidate="$1"
  (: >&"$candidate") 2>/dev/null
}

# Prints the lowest descriptor that is neither tracked nor already open.
ap_lock_fd_alloc() {
  local candidate="$AP_LOCK_FD_BASE"
  while [[ "$candidate" -le "$AP_LOCK_FD_MAX" ]]; do
    if ! ap_fd_tracked "$candidate" && ! ap_fd_is_open "$candidate"; then
      printf "%s\n" "$candidate"
      return 0
    fi
    candidate=$((candidate + 1))
  done
  return 1
}

# ap_lock_fd_open_into <varname> <file>: opens the lock file read-write on a
# fixed descriptor and records it. Returns 2 when no descriptor could be opened.
ap_lock_fd_open_into() {
  local __ap_var="$1"
  local __ap_file="$2"
  local __ap_fd
  if ! __ap_fd=$(ap_lock_fd_alloc); then
    return 2
  fi
  if ! eval "exec ${__ap_fd}<>\"\$__ap_file\"" 2>/dev/null; then
    return 2
  fi
  AP_LOCK_FDS+=("$__ap_fd")
  eval "$__ap_var=\$__ap_fd"
  return 0
}

ap_lock_fd_release() {
  local fd="${1:-}"
  local kept=()
  local tracked
  [[ -n "$fd" ]] || return 0
  eval "exec ${fd}>&-" 2>/dev/null || true
  for tracked in "${AP_LOCK_FDS[@]:-}"; do
    [[ -n "$tracked" && "$tracked" != "$fd" ]] || continue
    kept+=("$tracked")
  done
  AP_LOCK_FDS=("${kept[@]:-}")
}

# Prints the parent PID of a live process. Linux keeps reading procfs exactly
# as before (AP_PROC_ROOT stays a fault-injection seam); Darwin has no procfs
# and asks ps instead.
ap_platform_process_ppid() {
  local pid="$1"
  if ap_platform_is_darwin; then
    ap_platform ps-ppid "$pid"
    return
  fi
  local proc_root="${AP_PROC_ROOT:-/proc}"
  [[ -r "$proc_root/$pid/stat" ]] || return 1
  cut -d' ' -f4 "$proc_root/$pid/stat" 2>/dev/null
}

# Prints "  PID <pid> (<comm>)" for every process that keeps a path open. This
# is an advisory diagnostic for an already-busy lock: it never signals, never
# refuses, and never prints an environment value or a command line.
ap_platform_process_holders() {
  ap_platform proc-holders "$1" "$2" "$3"
}

# Applies a shared or exclusive non-blocking lock to an inherited descriptor.
ap_platform_lock() {
  ap_platform lock "$1" "$2"
}

# Prints "hash  path" exactly like GNU sha256sum, so every existing manifest
# keeps its text format.
ap_platform_sha256sum() {
  ap_platform sha256sum "$1"
}

# Prints the SHA-256 of standard input as a bare hex digest.
ap_platform_sha256_text() {
  ap_platform sha256-text
}

# Prints the setup manifest for a skill directory: every shipped script in
# sorted order, then VERSION.
ap_platform_manifest() {
  ap_platform manifest "$1"
}

# Verifies a manifest against a deployed tree. Returns non-zero on any mismatch.
ap_platform_manifest_verify() {
  ap_platform manifest-verify "$1" "$2"
}

ap_platform_stat_size() {
  ap_platform stat size "$1"
}

# Runs a command with a wall-clock limit, exiting 124 on timeout exactly like
# GNU timeout so callers keep their existing classification.
ap_platform_timeout() {
  ap_platform timeout "$@"
}

# Copies a tree preserving modes, timestamps and symlinks without GNU cp
# options. The destination must not exist yet.
ap_platform_copy_preserve() {
  ap_platform copy-preserve "$1" "$2"
}
