#!/usr/bin/env bash
# Locking and lease API for agent-profiles
# shellcheck disable=SC2034

ap_ensure_locks_dir() {
  local repo_root="$1"
  local storage_dir="$repo_root/.agent-profiles"
  local locks_dir="$storage_dir/.locks"

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
  if [[ ! -f "$lock_file" ]]; then
    (umask 077 && touch "$lock_file" && chmod 600 "$lock_file")
  fi

  exec {AP_PROFILE_EXCLUSIVE_FD}<>"$lock_file"
  if ! flock -x -n "$AP_PROFILE_EXCLUSIVE_FD"; then
    ap_die "$EX_BUSY" "cannot acquire exclusive lock for profile '$profile' (profile is in use)"
  fi
}

ap_record_run() {
  local repo_root="$1"
  local profile="$2"
  ap_ensure_locks_dir "$repo_root"

  local runs_file="$repo_root/.agent-profiles/.locks/$profile.runs"
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
