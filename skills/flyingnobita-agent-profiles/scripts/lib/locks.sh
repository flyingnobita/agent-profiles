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
  real_ld=$(readlink -f "$locks_dir" 2>/dev/null || true)
  if [[ "$real_ld" != "$locks_dir" ]]; then
    ap_die "$EX_LAYOUT" "locks directory path mismatch with realpath ($locks_dir -> $real_ld)"
  fi
}

ap_lock_storage_shared() {
  local repo_root="$1"
  ap_ensure_locks_dir "$repo_root"

  local storage_lock="$repo_root/.agent-profiles/.locks/.storage.lock"
  if [[ -L "$storage_lock" ]]; then
    ap_die "$EX_LAYOUT" "storage lock file '$storage_lock' is a symbolic link"
  fi
  if [[ ! -f "$storage_lock" ]]; then
    (umask 077 && touch "$storage_lock" && chmod 600 "$storage_lock")
  fi

  exec {AP_STORAGE_LOCK_FD}<>"$storage_lock"
  if ! flock -s -n "$AP_STORAGE_LOCK_FD"; then
    ap_die "$EX_BUSY" "cannot acquire shared storage lock (storage is locked by another operation)"
  fi
}

ap_unlock_storage() {
  if [[ -n "${AP_STORAGE_LOCK_FD:-}" ]]; then
    exec {AP_STORAGE_LOCK_FD}>&-
    unset AP_STORAGE_LOCK_FD
  fi
}

ap_lock_storage_exclusive() {
  local repo_root="$1"
  ap_ensure_locks_dir "$repo_root"

  local storage_lock="$repo_root/.agent-profiles/.locks/.storage.lock"
  if [[ -L "$storage_lock" ]]; then
    ap_die "$EX_LAYOUT" "storage lock file '$storage_lock' is a symbolic link"
  fi
  if [[ ! -f "$storage_lock" ]]; then
    (umask 077 && touch "$storage_lock" && chmod 600 "$storage_lock")
  fi

  exec {AP_STORAGE_LOCK_FD}<>"$storage_lock"
  if ! flock -x -n "$AP_STORAGE_LOCK_FD"; then
    ap_die "$EX_BUSY" "cannot acquire exclusive storage lock (storage is busy)"
  fi
}

ap_lease_profile_shared() {
  local repo_root="$1"
  local profile="$2"
  ap_ensure_locks_dir "$repo_root"

  local lock_file="$repo_root/.agent-profiles/.locks/$profile.lock"
  if [[ -L "$lock_file" ]]; then
    ap_die "$EX_LAYOUT" "profile lock file '$lock_file' is a symbolic link"
  fi
  if [[ ! -f "$lock_file" ]]; then
    (umask 077 && touch "$lock_file" && chmod 600 "$lock_file")
  fi

  # Open file descriptor without O_CLOEXEC so it is inherited by bwrap and descendants
  exec {AP_PROFILE_LEASE_FD}<>"$lock_file"
  if ! flock -s -n "$AP_PROFILE_LEASE_FD"; then
    ap_die "$EX_BUSY" "cannot acquire shared profile lease for '$profile' (profile is locked exclusively)"
  fi
}

ap_lock_profile_exclusive() {
  local repo_root="$1"
  local profile="$2"
  ap_ensure_locks_dir "$repo_root"

  local lock_file="$repo_root/.agent-profiles/.locks/$profile.lock"
  if [[ -L "$lock_file" ]]; then
    ap_die "$EX_LAYOUT" "profile lock file '$lock_file' is a symbolic link"
  fi
  if [[ ! -f "$lock_file" ]]; then
    (umask 077 && touch "$lock_file" && chmod 600 "$lock_file")
  fi

  exec {AP_PROFILE_EXCLUSIVE_FD}<>"$lock_file"
  if ! flock -x -n "$AP_PROFILE_EXCLUSIVE_FD"; then
    ap_die "$EX_BUSY" "cannot acquire exclusive lock for profile '$profile' (profile is in use)"
  fi
}

ap_unlock_profile() {
  if [[ -n "${AP_PROFILE_EXCLUSIVE_FD:-}" ]]; then
    exec {AP_PROFILE_EXCLUSIVE_FD}>&-
    unset AP_PROFILE_EXCLUSIVE_FD
  fi
  if [[ -n "${AP_PROFILE_LEASE_FD:-}" ]]; then
    exec {AP_PROFILE_LEASE_FD}>&-
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

  local names=()
  mapfile -t names < <(printf "%s\n" "$@" | sort -u)

  local name lock_file fd
  for name in "${names[@]}"; do
    ap_ensure_locks_dir "$repo_root"
    lock_file="$repo_root/.agent-profiles/.locks/$name.lock"
    if [[ -L "$lock_file" ]]; then
      ap_die "$EX_LAYOUT" "profile lock file '$lock_file' is a symbolic link"
    fi
    if [[ ! -f "$lock_file" ]]; then
      (umask 077 && touch "$lock_file" && chmod 600 "$lock_file")
    fi

    exec {fd}<>"$lock_file"
    if ! flock -x -n "$fd"; then
      exec {fd}>&-
      ap_die "$EX_BUSY" "cannot acquire exclusive lock for profile '$name' (profile is in use)"
    fi
    AP_PROFILE_EXCLUSIVE_FDS+=("$fd")
  done
}

ap_unlock_profiles() {
  local fd
  for fd in "${AP_PROFILE_EXCLUSIVE_FDS[@]:-}"; do
    [[ -n "$fd" ]] || continue
    exec {fd}>&-
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
    if ! exec {probe_fd}<>"$lock_file" 2>/dev/null; then
      exit 3
    fi
    flock -x -n "$probe_fd"
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

  exec {AP_JOURNAL_LOCK_FD}<>"$lock_file"
  if ! flock -x -n "$AP_JOURNAL_LOCK_FD"; then
    ap_die "$EX_BUSY" "cannot acquire exclusive lock for journal '$journal_file' (operation in progress)"
  fi
}

ap_unlock_journal() {
  if [[ -n "${AP_JOURNAL_LOCK_FD:-}" ]]; then
    exec {AP_JOURNAL_LOCK_FD}>&-
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

  if [[ ${#hooks[@]} -gt 1 ]]; then
    mapfile -t hooks < <(printf "%s\n" "${hooks[@]}" | sort)
  fi

  for hook in "${hooks[@]}"; do
    # Source hook so ap_die terminates immediately with exact code
    # shellcheck source=/dev/null
    source "$hook"
  done
}
