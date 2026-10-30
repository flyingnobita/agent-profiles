#!/usr/bin/env bash
# Locking and lease API for agent-profiles
# shellcheck disable=SC2034

ap_ensure_locks_dir() {
  local repo_root="$1"
  local storage_dir="$repo_root/.agent-profiles"
  local locks_dir="$storage_dir/.locks"

  if [[ -L "$storage_dir" ]]; then
    ap_die "$EX_LAYOUT" "profile storage directory '$storage_dir' is a symbolic link (must be a real directory)"
  fi

  if [[ -L "$locks_dir" ]]; then
    ap_die "$EX_LAYOUT" "locks directory '$locks_dir' is a symbolic link (must be a real directory)"
  fi

  if [[ ! -d "$locks_dir" ]]; then
    (umask 077 && mkdir -p "$locks_dir")
  fi

  local real_ld
  if ! real_ld=$(ap_platform_realpath_existing "$locks_dir"); then
    ap_die "$EX_LAYOUT" "locks directory '$locks_dir' could not be resolved to a physical path"
  fi
  if [[ "$real_ld" != "$locks_dir" ]]; then
    ap_die "$EX_LAYOUT" "locks directory path mismatch with realpath ($locks_dir -> $real_ld)"
  fi
}

# Opens a persistent lock file on an allocated descriptor and locks it.
# ap_lock_file_into <varname> <lock-file> <shared|exclusive> <busy-message>
ap_lock_file_into() {
  local __ap_var="$1"
  local __ap_lock_file="$2"
  local __ap_mode="$3"
  local __ap_message="$4"
  local __ap_lock_fd

  if ! ap_lock_fd_open_into __ap_lock_fd "$__ap_lock_file"; then
    ap_die "$EX_LAYOUT" "lock file '$__ap_lock_file' could not be opened"
  fi
  if ! ap_platform_lock "$__ap_mode" "$__ap_lock_fd"; then
    ap_lock_fd_release "$__ap_lock_fd"
    ap_die "$EX_BUSY" "$__ap_message"
  fi
  eval "$__ap_var=\$__ap_lock_fd"
}

ap_prepare_lock_file() {
  local lock_file="$1"
  local label="$2"

  if [[ -L "$lock_file" ]]; then
    ap_die "$EX_LAYOUT" "$label '$lock_file' is a symbolic link"
  fi
  if [[ ! -f "$lock_file" ]]; then
    (umask 077 && touch "$lock_file" && chmod 600 "$lock_file")
  fi
}

ap_lock_storage_shared() {
  local repo_root="$1"
  ap_ensure_locks_dir "$repo_root"

  local storage_lock="$repo_root/.agent-profiles/.locks/.storage.lock"
  ap_prepare_lock_file "$storage_lock" "storage lock file"
  ap_lock_file_into AP_STORAGE_LOCK_FD "$storage_lock" shared \
    "cannot acquire shared storage lock (storage is locked by another operation)"
}

ap_unlock_storage() {
  if [[ -n "${AP_STORAGE_LOCK_FD:-}" ]]; then
    ap_lock_fd_release "$AP_STORAGE_LOCK_FD"
    unset AP_STORAGE_LOCK_FD
  fi
}

ap_lock_storage_exclusive() {
  local repo_root="$1"
  ap_ensure_locks_dir "$repo_root"

  local storage_lock="$repo_root/.agent-profiles/.locks/.storage.lock"
  ap_prepare_lock_file "$storage_lock" "storage lock file"
  ap_lock_file_into AP_STORAGE_LOCK_FD "$storage_lock" exclusive \
    "cannot acquire exclusive storage lock (storage is busy)"
}

ap_lease_profile_shared() {
  local repo_root="$1"
  local profile="$2"
  ap_ensure_locks_dir "$repo_root"

  local lock_file="$repo_root/.agent-profiles/.locks/$profile.lock"
  ap_prepare_lock_file "$lock_file" "profile lock file"

  # The descriptor stays open across exec, so bwrap and every descendant keeps
  # the shared lease after this helper exits.
  ap_lock_file_into AP_PROFILE_LEASE_FD "$lock_file" shared \
    "cannot acquire shared profile lease for '$profile' (profile is locked exclusively)"
}

ap_lock_profile_exclusive() {
  local repo_root="$1"
  local profile="$2"
  ap_ensure_locks_dir "$repo_root"

  local lock_file="$repo_root/.agent-profiles/.locks/$profile.lock"
  ap_prepare_lock_file "$lock_file" "profile lock file"

  ap_lock_file_into AP_PROFILE_EXCLUSIVE_FD "$lock_file" exclusive \
    "cannot acquire exclusive lock for profile '$profile' (profile is in use)"
}

ap_unlock_profile() {
  if [[ -n "${AP_PROFILE_EXCLUSIVE_FD:-}" ]]; then
    ap_lock_fd_release "$AP_PROFILE_EXCLUSIVE_FD"
    unset AP_PROFILE_EXCLUSIVE_FD
  fi
  if [[ -n "${AP_PROFILE_LEASE_FD:-}" ]]; then
    ap_lock_fd_release "$AP_PROFILE_LEASE_FD"
    unset AP_PROFILE_LEASE_FD
  fi
}

# Acquire exclusive locks for several profiles in name order.
# Storage must already be locked by the caller. Used by migrate and recover,
# which can affect more than one profile in a single operation.
ap_lock_profiles_exclusive() {
  local repo_root="$1"
  shift
  AP_PROFILE_EXCLUSIVE_FDS=()

  [[ $# -gt 0 ]] || return 0

  local name lock_file fd
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    ap_ensure_locks_dir "$repo_root"
    lock_file="$repo_root/.agent-profiles/.locks/$name.lock"
    ap_prepare_lock_file "$lock_file" "profile lock file"

    # All descriptors stay open together, in sorted name order.
    ap_lock_file_into fd "$lock_file" exclusive \
      "cannot acquire exclusive lock for profile '$name' (profile is in use)"
    AP_PROFILE_EXCLUSIVE_FDS+=("$fd")
  done < <(printf "%s\n" "$@" | LC_ALL=C sort -u)
}

ap_unlock_profiles() {
  local fd
  for fd in "${AP_PROFILE_EXCLUSIVE_FDS[@]:-}"; do
    [[ -n "$fd" ]] || continue
    ap_lock_fd_release "$fd"
  done
  AP_PROFILE_EXCLUSIVE_FDS=()
}

# Journal lock files are persistent and separate from the JSON payload so an
# atomic tmp+rename journal write never moves the inode that holds the lock.
ap_journal_lock_path() {
  local journal_file="$1"
  printf "%s.lock\n" "${journal_file%.json}"
}

# Validates the journal sidecar lock path before it is ever opened. A symlinked
# or non-regular sidecar would let a stale record follow a path outside the
# checkout, and an unreadable or unwritable one cannot be inspected safely.
ap_validate_journal_lock_path() {
  local lock_file="$1"

  if [[ -L "$lock_file" ]]; then
    ap_die "$EX_LAYOUT" "journal lock file '$lock_file' is a symbolic link"
  fi
  if [[ -e "$lock_file" ]]; then
    if [[ ! -f "$lock_file" ]]; then
      ap_die "$EX_LAYOUT" "journal lock file '$lock_file' is not a regular file"
    fi
    if [[ ! -r "$lock_file" || ! -w "$lock_file" ]]; then
      ap_die "$EX_REFUSED" "journal lock file '$lock_file' is not readable and writable; inspect it manually instead of guessing whether the operation is live"
    fi
  fi
}

ap_ensure_journal_lock_file() {
  local journal_file="$1"
  local lock_file
  lock_file=$(ap_journal_lock_path "$journal_file")

  ap_validate_journal_lock_path "$lock_file"

  if [[ ! -f "$lock_file" ]]; then
    (umask 077 && mkdir -p "$(dirname "$lock_file")" && touch "$lock_file" && chmod 600 "$lock_file")
  fi
  printf "%s\n" "$lock_file"
}

# Returns 0 when the journal is stale (no process holds its lock) and 1 when
# a live operation still owns it. A missing lock file means stale. Only actual
# flock contention counts as live; an uninspectable sidecar fails safely.
ap_journal_is_stale() {
  local journal_file="$1"
  local lock_file
  lock_file=$(ap_journal_lock_path "$journal_file")

  ap_validate_journal_lock_path "$lock_file"

  if [[ ! -e "$lock_file" ]]; then
    return 0
  fi

  local rc=0
  (
    local probe_fd
    if ! ap_lock_fd_open_into probe_fd "$lock_file"; then
      exit 3
    fi
    ap_platform_lock exclusive "$probe_fd"
  ) 2>/dev/null || rc=$?

  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    3)
      ap_die "$EX_REFUSED" "journal lock file '$lock_file' could not be opened; refusing to guess whether the operation is live"
      ;;
    *)
      ap_die "$EX_REFUSED" "journal lock file '$lock_file' could not be probed (status $rc); refusing to guess whether the operation is live"
      ;;
  esac
}

ap_lock_journal() {
  local journal_file="$1"
  local lock_file
  lock_file=$(ap_ensure_journal_lock_file "$journal_file")

  ap_lock_file_into AP_JOURNAL_LOCK_FD "$lock_file" exclusive \
    "cannot acquire exclusive lock for journal '$journal_file' (operation in progress)"
}

ap_unlock_journal() {
  if [[ -n "${AP_JOURNAL_LOCK_FD:-}" ]]; then
    ap_lock_fd_release "$AP_JOURNAL_LOCK_FD"
    unset AP_JOURNAL_LOCK_FD
  fi
}

ap_record_run() {
  local repo_root="$1"
  local profile="$2"
  ap_ensure_locks_dir "$repo_root"

  local runs_file="$repo_root/.agent-profiles/.locks/$profile.runs"
  if [[ -L "$runs_file" ]]; then
    ap_die "$EX_LAYOUT" "profile runs file '$runs_file' is a symbolic link"
  fi
  local boot_id="00000000-0000-0000-0000-000000000000"
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    boot_id=$(tr -d '[:space:]' </proc/sys/kernel/random/boot_id)
  fi

  local start_ticks="0"
  if [[ -r /proc/self/stat ]]; then
    start_ticks=$(cut -d' ' -f22 /proc/self/stat 2>/dev/null || echo "0")
  fi

  (
    umask 077
    printf "%s %s\n" "$boot_id" "$start_ticks" >>"$runs_file"
    chmod 600 "$runs_file" 2>/dev/null || true
  )
}

ap_run_preflight() {
  local repo_root="$1"
  local profile="$2"
  local preflight_dir="$LIB_DIR/preflight.d"

  if [[ ! -d "$preflight_dir" ]]; then
    return 0
  fi

  local hooks=()
  for hook in "$preflight_dir"/*.sh; do
    [[ -f "$hook" ]] || continue
    hooks+=("$hook")
  done

  local ordered_hooks=()
  if [[ ${#hooks[@]} -gt 0 ]]; then
    local hook_path
    while IFS= read -r hook_path; do
      [[ -n "$hook_path" ]] || continue
      ordered_hooks+=("$hook_path")
    done < <(printf "%s\n" "${hooks[@]}" | LC_ALL=C sort)
  fi

  for hook in "${ordered_hooks[@]:-}"; do
    [[ -n "$hook" ]] || continue
    # Source hook so ap_die terminates immediately with exact code
    # shellcheck source=/dev/null
    source "$hook"
  done
}
