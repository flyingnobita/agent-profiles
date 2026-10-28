#!/usr/bin/env bash
# Runtime functions for agent-profiles: storage, profiles, environment, and bwrap
# shellcheck disable=SC2034

ap_find_repo_root() {
  local root
  if ! root=$(git rev-parse --show-toplevel 2>/dev/null); then
    ap_die "$EX_NOINPUT" "not a git repository (or any of the parent directories)"
  fi
  printf "%s\n" "$root"
}

ap_validate_profile_name() {
  local name="$1"
  if [[ -z "$name" || ! "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
    ap_die "$EX_DATAERR" "invalid profile name: '$name' (must be 1-32 chars of lowercase letters, digits, '_' or '-', starting with a letter)"
  fi
}

ap_ensure_storage_dir() {
  local repo_root="$1"
  local storage_dir="$repo_root/.agent-profiles"

  if [[ -L "$storage_dir" ]]; then
    ap_die "$EX_LAYOUT" "profile storage directory '$storage_dir' is a symbolic link (must be a real directory)"
  fi

  if [[ ! -d "$storage_dir" ]]; then
    (umask 077 && mkdir -p "$storage_dir")
  fi

  local real_st
  real_st=$(readlink -f "$storage_dir" 2>/dev/null || true)
  if [[ "$real_st" != "$storage_dir" ]]; then
    ap_die "$EX_LAYOUT" "profile storage directory path mismatch with realpath ($storage_dir -> $real_st)"
  fi
}

ap_ensure_exclude() {
  local repo_root="$1"
  local storage_dir="$repo_root/.agent-profiles"
  local exclude_path
  exclude_path=$(git -C "$repo_root" rev-parse --git-path info/exclude 2>/dev/null || true)

  if [[ -z "$exclude_path" ]]; then
    return 0
  fi

  # In git, --git-path info/exclude may output a relative path from the repo root
  if [[ "$exclude_path" != /* ]]; then
    exclude_path="$repo_root/$exclude_path"
  fi

  mkdir -p "$(dirname "$exclude_path")"

  local locks_dir="$storage_dir/.locks"
  if [[ ! -d "$locks_dir" ]]; then
    (umask 077 && mkdir -p "$locks_dir")
  fi

  local lock_file="$locks_dir/.exclude.lock"
  (
    exec 9>>"$lock_file"
    flock -x 9
    if [[ ! -f "$exclude_path" ]] || ! grep -Fxq '/.agent-profiles/' "$exclude_path"; then
      printf "%s\n" "/.agent-profiles/" >>"$exclude_path"
    fi
  )
}

ap_init_profile() {
  local repo_root="$1"
  local name="$2"

  ap_validate_profile_name "$name"
  ap_ensure_storage_dir "$repo_root"
  ap_ensure_exclude "$repo_root"

  local storage_dir="$repo_root/.agent-profiles"
  local prof_dir="$storage_dir/$name"

  if [[ -L "$prof_dir" ]]; then
    ap_die "$EX_LAYOUT" "profile directory '$prof_dir' is a symbolic link (must be a real directory)"
  fi

  local subdirs=(
    .claude
    .codex
    .gemini
    .agents
    .opencode
    home
    bin
    npm-global
    uv-tools
    cargo-global
    python-user
    .config
    .local/share
    .local/state
    .cache
  )

  (
    umask 077
    mkdir -p "$prof_dir"
    for sub in "${subdirs[@]}"; do
      mkdir -p "$prof_dir/$sub"
    done
    if [[ ! -f "$prof_dir/.agent-profile" ]]; then
      printf "version=1\nformat=1\n" >"$prof_dir/.agent-profile"
      chmod 600 "$prof_dir/.agent-profile" 2>/dev/null || true
    fi
  )
}

ap_list_profiles() {
  local repo_root="$1"
  local json_mode="${2:-0}"
  local storage_dir="$repo_root/.agent-profiles"

  local profiles=()
  if [[ -d "$storage_dir" ]]; then
    for entry in "$storage_dir"/*; do
      if [[ -d "$entry" && ! -L "$entry" ]]; then
        local b
        b="$(basename "$entry")"
        if [[ "$b" != .* && -d "$entry/home" ]]; then
          profiles+=("$b")
        fi
      fi
    done
  fi

  # Sort profiles
  if [[ ${#profiles[@]} -gt 1 ]]; then
    mapfile -t profiles < <(printf "%s\n" "${profiles[@]}" | sort)
  fi

  if [[ "$json_mode" -eq 1 ]]; then
    local json="["
    local first=1
    for p in "${profiles[@]}"; do
      if [[ $first -eq 1 ]]; then
        first=0
      else
        json+=","
      fi
      json+="\"$p\""
    done
    json+="]"
    printf '{\n  "profiles": %s\n}\n' "$json"
  else
    for p in "${profiles[@]}"; do
      printf "%s\n" "$p"
    done
  fi
}
