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

ap_detect_live_profile() {
  if [[ ! -r /proc/self/mountinfo ]]; then
    return 0
  fi

  sed -n -E 's|.*\.agent-profiles/([a-z0-9_-]+)/.*|\1|p' /proc/self/mountinfo 2>/dev/null | head -n 1
}

ap_check_profile_aliasing() {
  local repo_root="$1"
  local profile="$2"
  local storage_dir="$repo_root/.agent-profiles"
  local prof_dir="$storage_dir/$profile"

  if [[ -L "$prof_dir" ]]; then
    ap_die "$EX_LAYOUT" "profile directory '$prof_dir' is a symbolic link (must be a real directory)"
  fi

  if [[ -d "$prof_dir" ]]; then
    local real_pd
    real_pd=$(readlink -f "$prof_dir" 2>/dev/null || true)
    if [[ "$real_pd" != "$prof_dir" ]]; then
      ap_die "$EX_LAYOUT" "profile directory '$prof_dir' realpath mismatch ($real_pd)"
    fi

    local target_ino
    target_ino=$(stat -c "%d:%i" "$prof_dir" 2>/dev/null || true)

    for entry in "$storage_dir"/*; do
      [[ -d "$entry" ]] || continue
      local b
      b=$(basename "$entry")
      [[ "$b" == "$profile" || "$b" == .* ]] && continue
      local other_ino
      other_ino=$(stat -c "%d:%i" "$entry" 2>/dev/null || true)
      if [[ -n "$target_ino" && "$target_ino" == "$other_ino" ]]; then
        ap_die "$EX_LAYOUT" "profile '$profile' aliases existing profile '$b' (same filesystem inode $target_ino)"
      fi
    done
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

ap_prepare_profile_env() {
  local repo_root="$1"
  local profile="$2"
  local prof_dir="$repo_root/.agent-profiles/$profile"

  # 1. Calculate AGENT_PROFILES_BASE_PATH by purging any profile directories from PATH
  local raw_path="${PATH:-}"
  local filtered_paths=()
  local IFS=':'
  read -ra path_entries <<<"$raw_path"
  unset IFS

  for entry in "${path_entries[@]}"; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" != */.agent-profiles/* ]]; then
      filtered_paths+=("$entry")
    fi
  done

  local base_path=""
  if [[ ${#filtered_paths[@]} -gt 0 ]]; then
    local old_ifs="${IFS:-}"
    IFS=':'
    base_path="${filtered_paths[*]}"
    IFS="$old_ifs"
  fi

  # 2. Reset managed variables
  unset AGENT_PROFILES_NAME AGENT_PROFILES_DIR AGENT_PROFILES_ROOT AGENT_PROFILES_BASE_PATH
  unset AGENT_SANDBOX_DIR AGENT_SANDBOX_PROFILE
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
  unset NPM_CONFIG_PREFIX NPM_CONFIG_CACHE
  unset UV_TOOL_DIR UV_TOOL_BIN_DIR UV_CACHE_DIR
  unset CARGO_INSTALL_ROOT GOBIN PYTHONUSERBASE
  unset CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR CODEX_HOME OPENCODE_CONFIG_DIR

  # 3. Export profile variables
  export AGENT_PROFILES_NAME="$profile"
  export AGENT_PROFILES_DIR="$prof_dir"
  export AGENT_PROFILES_ROOT="$repo_root/.agent-profiles"
  export AGENT_PROFILES_BASE_PATH="$base_path"

  # Legacy output-only aliases
  export AGENT_SANDBOX_PROFILE="$profile"
  export AGENT_SANDBOX_DIR="$prof_dir"

  # XDG directories
  export XDG_CONFIG_HOME="$prof_dir/.config"
  export XDG_DATA_HOME="$prof_dir/.local/share"
  export XDG_STATE_HOME="$prof_dir/.local/state"
  export XDG_CACHE_HOME="$prof_dir/.cache"

  # Package managers
  export NPM_CONFIG_PREFIX="$prof_dir/npm-global"
  export NPM_CONFIG_CACHE="$prof_dir/.cache/npm"
  export UV_TOOL_DIR="$prof_dir/uv-tools"
  export UV_TOOL_BIN_DIR="$prof_dir/uv-tools/bin"
  export UV_CACHE_DIR="$prof_dir/.cache/uv"
  export CARGO_INSTALL_ROOT="$prof_dir/cargo-global"
  export GOBIN="$prof_dir/bin"
  export PYTHONUSERBASE="$prof_dir/python-user"

  # Profile binaries prepended to PATH
  local prof_bins="$prof_dir/npm-global/bin:$prof_dir/bin:$prof_dir/cargo-global/bin:$prof_dir/python-user/bin"
  if [[ -n "$base_path" ]]; then
    export PATH="$prof_bins:$base_path"
  else
    export PATH="$prof_bins"
  fi

  # Call agent environment hooks if defined
  for ag in claude codex agy opencode; do
    local hook="ap_agent_env_$ag"
    if declare -F "$hook" >/dev/null 2>&1; then
      "$hook" "$prof_dir"
    fi
  done
}

ap_check_bwrap_readiness() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    ap_die "$EX_UNAVAILABLE" "operating system '$(uname -s)' is not qualified (Linux is required)"
  fi

  if ! command -v bwrap >/dev/null 2>&1; then
    ap_die "$EX_UNAVAILABLE" "bubblewrap (bwrap) is required but not found on PATH. Install bubblewrap via your system package manager."
  fi

  if ! bwrap --dev-bind / / true >/dev/null 2>&1; then
    ap_die "$EX_UNAVAILABLE" "bubblewrap namespace setup failed. Ensure unprivileged user namespaces are enabled (check kernel.unprivileged_userns_clone sysctl, AppArmor apparmor_restrict_unprivileged_userns, or container seccomp profiles)."
  fi
}

ap_build_bwrap_mounts() {
  local repo_root="$1"
  local profile="$2"
  local prof_dir="$repo_root/.agent-profiles/$profile"
  local storage_dir="$repo_root/.agent-profiles"

  local redirect_dirs=(.claude .codex .gemini .agents)
  local seen_targets=()
  BWRAP_MOUNT_ARGS=()

  for d in "${redirect_dirs[@]}"; do
    local src="$prof_dir/$d"
    if [[ ! -d "$src" ]]; then
      mkdir -p "$src"
    fi

    local target="$HOME/$d"

    # Check for dangling symlink
    if [[ -L "$target" && ! -e "$target" ]]; then
      ap_die "$EX_LAYOUT" "mount target '$target' is a dangling symlink"
    fi

    # Follow valid directory symlinks to their physical host target
    if [[ -L "$target" ]]; then
      local phys_target
      phys_target=$(readlink -f "$target" 2>/dev/null || true)
      if [[ ! -d "$phys_target" ]]; then
        ap_die "$EX_LAYOUT" "mount target '$target' resolves to '$phys_target' which is not a directory"
      fi
      target="$phys_target"
    fi

    # Check if target is a regular file or other non-directory
    if [[ -e "$target" && ! -d "$target" ]]; then
      ap_die "$EX_LAYOUT" "mount target '$target' exists but is not a directory"
    fi

    # Check root target
    if [[ "$target" == "/" ]]; then
      ap_die "$EX_LAYOUT" "mount target cannot be '/'"
    fi

    # Check if target overlaps profile storage
    if [[ "$target" == "$storage_dir"* || "$storage_dir" == "$target"* ]]; then
      ap_die "$EX_LAYOUT" "mount target '$target' cannot overlap with profile storage directory '$storage_dir'"
    fi

    # Check for target duplicate / overlap
    for seen in "${seen_targets[@]}"; do
      if [[ "$target" == "$seen" ]]; then
        ap_die "$EX_LAYOUT" "duplicate mount target '$target'"
      fi
    done
    seen_targets+=("$target")

    # If missing, create as empty host directory with stderr notice
    if [[ ! -e "$target" ]]; then
      mkdir -p "$target"
      printf "agent-profiles: notice: created empty host mountpoint %s\n" "$target" >&2
    fi

    BWRAP_MOUNT_ARGS+=(--bind "$src" "$target")
  done
}
