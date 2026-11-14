#!/usr/bin/env bash
# Shared test harness functions for live agent QA (offline probes, synthetic host
# isolation, ownership-aware process-group cleanup).
#
# Stock macOS has bash 3.2 and no procfs, mapfile, associative arrays, setsid or
# pgrep assumptions, so this harness is written for both platforms: indexed
# arrays only, ps for process identity, and the shipped standard-library adapter
# (scripts/lib/platform.py) for process identity, boot identity and hashing.
# Every ownership check for cleanup is preserved: real UID, profile ownership,
# process-group identity and start/boot identity are all proven before a signal.
# shellcheck disable=SC2034

AP_LIVE_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
AP_LIVE_PLATFORM_SH="${AP_LIVE_PLATFORM_SH:-$AP_LIVE_LIB_DIR/../../skills/agent-profiles/scripts/lib/platform.sh}"
AP_LIVE_PLATFORM_PY="${AP_LIVE_PLATFORM_PY:-$AP_LIVE_LIB_DIR/../../skills/agent-profiles/scripts/lib/platform.py}"
AP_LIVE_PTY_EXEC="${AP_LIVE_PTY_EXEC:-$AP_LIVE_LIB_DIR/pty-exec.py}"

if [[ ! -f "$AP_LIVE_PLATFORM_SH" || ! -f "$AP_LIVE_PLATFORM_PY" ]]; then
  printf 'agent-profiles live: platform adapter not found next to %s\n' "$AP_LIVE_LIB_DIR" >&2
  # shellcheck disable=SC2317  # sourced file: return ends the source, not the shell
  return 1
fi

if ! declare -F ap_die >/dev/null 2>&1; then
  # platform.sh reaches ap_die only when python3 is missing on PATH.
  ap_die() {
    local code="${1:-69}"
    shift || true
    printf 'agent-profiles live: error: %s\n' "$*" >&2
    exit "$code"
  }
fi

# shellcheck source=/dev/null
source "$AP_LIVE_PLATFORM_SH"

# --- platform and process identity ------------------------------------------

ap_live_platform() {
  "$AP_PLATFORM_PYTHON" "$AP_PLATFORM_PY" "$@"
}

ap_live_platform_os() {
  ap_platform_os
}

ap_live_is_darwin() {
  [[ "$(ap_live_platform_os)" == "Darwin" ]]
}

# Prints an opaque identity for this boot. Cleanup refuses to signal when it is
# unavailable, so a PID recycled from an earlier boot can never authorize one.
ap_live_boot_identity() {
  ap_live_platform boot-identity
}

# Prints "<process-group> <start-identity>" for a live process. The start
# identity is the platform's own native value: procfs ticks on Linux and ps
# lstart on Darwin. It is only ever compared for exact equality against another
# value from the same boot, so Linux ticks are never compared with Darwin
# timestamps.
ap_live_pid_identity() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 1
  ap_live_platform process-identity "$(ap_live_platform_os)" "$pid"
}

ap_live_pid_uid() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 1
  ap_live_platform process-uid "$pid"
}

# Prints the member PIDs of a process group. ps -g is not used: its meaning
# differs between userlands, so the group column is selected explicitly.
ap_live_pgid_members() {
  local pgid="${1:-}"
  [[ -n "$pgid" ]] || return 1
  ps -axo pid=,pgid= 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid { print $1 }'
}

# Prints the direct children of a PID through ps, so no pgrep-specific
# assumption is required.
ap_live_child_pids() {
  local parent="${1:-}"
  [[ -n "$parent" ]] || return 1
  ps -axo pid=,ppid= 2>/dev/null | awk -v parent="$parent" '$2 == parent { print $1 }'
}

ap_live_descendant_pids() {
  local pid="$1" child
  printf '%s\n' "$pid"
  for child in $(ap_live_child_pids "$pid"); do
    ap_live_descendant_pids "$child"
  done
}

# Prints the current shell and its parent chain, one PID per line. Cleanup never
# treats any of them as a candidate, because a scanner's own subprocess can
# inherit the very descriptors it is scanning for.
ap_live_ancestry_pids() {
  local pid="${BASHPID:-$$}" parent="" depth=0
  local -a seen=()
  while [[ -n "$pid" && "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && "$depth" -lt 64 ]]; do
    case ",${seen[*]:-}," in
      *",$pid,"*) break ;;
    esac
    seen+=("$pid")
    printf '%s\n' "$pid"
    parent=$(ap_platform_process_ppid "$pid" 2>/dev/null || true)
    pid="$parent"
    depth=$((depth + 1))
  done
  if [[ "${BASHPID:-$$}" != "$$" ]]; then
    printf '%s\n' "$$"
  fi
}

# Profile ownership evidence. Linux reads the QA marker from procfs. Darwin
# cannot read another process's environment, so the evidence is the open profile
# lease descriptor or an open file inside the profile, both of which a profile
# run session always holds.
ap_live_pid_holds_profile() {
  local pid="${1:-}" profile_dir="${2:-}" lease=""
  [[ -n "$pid" && -n "$profile_dir" ]] || return 1
  lease="$(dirname "$profile_dir")/.locks/$(basename "$profile_dir").lock"
  ap_live_platform process-holds-path "$(ap_live_platform_os)" "$pid" "$profile_dir" && return 0
  ap_live_platform process-holds-path "$(ap_live_platform_os)" "$pid" "$lease"
}

ap_live_pid_owns_profile() {
  local pid="${1:-}" profile_dir="${2:-}" env_dump=""
  [[ -n "$pid" && -n "$profile_dir" ]] || return 1
  if ap_live_is_darwin; then
    ap_live_pid_holds_profile "$pid" "$profile_dir"
    return
  fi
  env_dump=$({ tr '\0' '\n' <"/proc/$pid/environ"; } 2>/dev/null) || return 1
  grep -Fqx "AGENT_PROFILES_DIR=$profile_dir" <<<"$env_dump"
}

# Prints the PIDs of the caller's QA profile-owned processes, excluding the
# given PIDs. One platform-adapter pass proves the whole set, so a scan never
# starts a helper process per candidate.
ap_live_profile_pids() {
  local profile_dir="${1:-}" exclude_csv="${2:-}"
  [[ -n "$profile_dir" ]] || return 1
  ap_live_platform owned-pids "$(ap_live_platform_os)" "$profile_dir" "$exclude_csv"
}

ap_live_pid_tree_owns_profile() {
  local pid="$1" profile_dir="$2" child
  ap_live_pid_owns_profile "$pid" "$profile_dir" && return 0
  for child in $(ap_live_child_pids "$pid"); do
    ap_live_pid_tree_owns_profile "$child" "$profile_dir" && return 0
  done
  return 1
}

ap_live_pgid_owns_profile() {
  local pgid="$1" profile_dir="$2" pid
  for pid in $(ap_live_pgid_members "$pgid"); do
    ap_live_pid_tree_owns_profile "$pid" "$profile_dir" && return 0
  done
  return 1
}

# Returns PGIDs in the root process tree that contain a process carrying the
# QA profile marker. The caller still cleans each group through
# ap_live_cleanup_pgid, which re-checks ownership before signalling.
ap_live_owned_pgids() {
  local root_pid="$1" profile_dir="$2" pid pgid known
  local -a seen=()
  for pid in $(ap_live_descendant_pids "$root_pid"); do
    pgid=$(ps -axo pid=,pgid= 2>/dev/null | awk -v pid="$pid" '$1 == pid { print $2; exit }')
    [[ -n "$pgid" ]] || continue
    known=",${seen[*]:-},"
    case "$known" in
      *",$pgid,"*) continue ;;
    esac
    if ap_live_pid_owns_profile "$pid" "$profile_dir"; then
      seen+=("$pgid")
      printf '%s\n' "$pgid"
    fi
  done
  return 0
}

ap_live_marker_field() {
  local marker="$1" key="$2"
  awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$marker" 2>/dev/null
}

# Writes a private marker for an existing process-group leader. The marker
# records the leader PID, boot identity, start identity and UID so later cleanup
# can distinguish the original group from a recycled PGID. start_ticks holds the
# platform-native start identity; it is an opaque token compared for equality,
# never a unit conversion between platforms.
ap_live_write_group_marker() {
  local pgid="${1:-}" marker="${2:-}"
  local pgrp="" start="" uid="" boot="" myuid=""

  [[ "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 ]] || return 1
  [[ -n "$marker" ]] || return 1

  read -r pgrp start <<<"$(ap_live_pid_identity "$pgid" 2>/dev/null || true)" || return 1
  [[ "$pgrp" == "$pgid" && -n "$start" ]] || return 1

  uid=$(ap_live_pid_uid "$pgid" 2>/dev/null || true)
  myuid=$(id -u)
  [[ "$uid" == "$myuid" ]] || return 1

  boot=$(ap_live_boot_identity 2>/dev/null || true)
  [[ -n "$boot" ]] || return 1

  (
    umask 077
    {
      printf 'pgid=%s\n' "$pgid"
      printf 'leader_pid=%s\n' "$pgid"
      printf 'boot_id=%s\n' "$boot"
      printf 'start_ticks=%s\n' "$start"
      printf 'uid=%s\n' "$uid"
    } >"$marker"
  ) || return 1
  chmod 600 "$marker" 2>/dev/null || true
  return 0
}

# Spawns a detached process group with Python start_new_session, then records
# its identity. A profile directory fd is inherited by the child as well, so a
# Darwin cleanup has profile ownership evidence even when the environment of the
# process cannot be read. AP_LIVE_SPAWN_STDOUT and AP_LIVE_SPAWN_STDERR may name
# files when the caller needs the child's output (a TUI probe log).
ap_live_spawn_test_process() {
  local marker_file="$1"
  shift

  local pgid=""
  pgid=$(python3 -c '
import os, sys, subprocess

cmd = sys.argv[1:]
pass_fds = ()
profile_dir = os.environ.get("AGENT_PROFILES_DIR", "")
if profile_dir and os.path.isdir(profile_dir):
    try:
        pass_fds = (os.open(profile_dir, os.O_RDONLY),)
    except OSError:
        pass_fds = ()

stdout = subprocess.DEVNULL
stderr = subprocess.DEVNULL
if os.environ.get("AP_LIVE_SPAWN_STDOUT"):
    stdout = open(os.environ["AP_LIVE_SPAWN_STDOUT"], "ab")
if os.environ.get("AP_LIVE_SPAWN_STDERR"):
    stderr = open(os.environ["AP_LIVE_SPAWN_STDERR"], "ab")

proc = subprocess.Popen(
    cmd,
    start_new_session=True,
    stdin=subprocess.DEVNULL,
    stdout=stdout,
    stderr=stderr,
    close_fds=True,
    pass_fds=pass_fds
)
print(os.getpgid(proc.pid))
' "$@") || return 1

  if ! ap_live_write_group_marker "$pgid" "$marker_file"; then
    kill -KILL -"$pgid" 2>/dev/null || true
    return 1
  fi

  printf '%s\n' "$pgid"
}

# --- synthetic host isolation ----------------------------------------------

ap_live_setup_isolation() {
  local base_dir="$1"

  # 1. Snapshot host effective mise directories before altering environment
  local mise_config="${MISE_CONFIG_DIR:-}"
  local mise_data="${MISE_DATA_DIR:-}"
  local mise_state="${MISE_STATE_DIR:-}"
  local mise_cache="${MISE_CACHE_DIR:-}"

  if command -v mise >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    local json_out
    json_out=$(MISE_YES=1 mise doctor --json 2>/dev/null || true)
    if [[ -n "$json_out" ]]; then
      local parsed
      parsed=$(python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
    dirs = data.get("dirs", {})
    mapping = {"config": "MISE_CONFIG_DIR", "data": "MISE_DATA_DIR", "state": "MISE_STATE_DIR", "cache": "MISE_CACHE_DIR"}
    for k, vname in mapping.items():
        v = dirs.get(k)
        if v and isinstance(v, str) and v.startswith("/"):
            print(f"{vname}={v}")
except Exception:
    pass
' "$json_out" 2>/dev/null || true)
      if [[ -n "$parsed" ]]; then
        while IFS='=' read -r var val || [[ -n "$var" ]]; do
          [[ -z "$var" || -z "$val" ]] && continue
          case "$var" in
            MISE_CONFIG_DIR) [[ -z "$mise_config" ]] && mise_config="$val" ;;
            MISE_DATA_DIR) [[ -z "$mise_data" ]] && mise_data="$val" ;;
            MISE_STATE_DIR) [[ -z "$mise_state" ]] && mise_state="$val" ;;
            MISE_CACHE_DIR) [[ -z "$mise_cache" ]] && mise_cache="$val" ;;
          esac
        done <<<"$parsed"
      fi
    fi
  fi

  # 2. Reset agent config overrides and credentials
  unset CODEX_HOME CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR OPENCODE_CONFIG_DIR
  unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENCODE_API_KEY
  unset GITHUB_TOKEN GH_TOKEN COPILOT_API_KEY OPENAI_BASE_URL

  # 3. Export isolated synthetic home and XDG roots
  export AP_LIVE_TMPDIR="$base_dir"
  export HOME="$base_dir/home"
  export XDG_CONFIG_HOME="$base_dir/config"
  export XDG_DATA_HOME="$base_dir/data"
  export XDG_STATE_HOME="$base_dir/state"
  export XDG_CACHE_HOME="$base_dir/cache"
  export DISABLE_TELEMETRY=1
  export npm_config_cache="$base_dir/npm_cache"

  [[ -n "$mise_config" ]] && export MISE_CONFIG_DIR="$mise_config"
  [[ -n "$mise_data" ]] && export MISE_DATA_DIR="$mise_data"
  [[ -n "$mise_state" ]] && export MISE_STATE_DIR="$mise_state"
  [[ -n "$mise_cache" ]] && export MISE_CACHE_DIR="$mise_cache"

  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$npm_config_cache"
}

# Deterministic content listing of a tree through the standard library, so a
# comparison can never pass on a failed GNU find/sha256sum pipeline.
ap_live_hash_tree() {
  ap_live_platform hash-tree "$1"
}

ap_live_create_synthetic_home() {
  local target_home="$1"
  mkdir -p "$target_home/.claude" \
    "$target_home/.codex" \
    "$target_home/.gemini" \
    "$target_home/.agents/skills"

  printf '{\n  "syntheticMarker": "claude-host-safe"\n}\n' >"$target_home/.claude/settings.json"
  printf 'model = "synthetic-codex-marker"\n' >"$target_home/.codex/config.toml"
  printf 'synthetic-gemini-marker\n' >"$target_home/.gemini/marker.txt"
  printf 'synthetic-agents-marker\n' >"$target_home/.agents/marker.txt"

  local chk_file="$target_home/.checksums.sha256"
  (umask 077 && ap_live_hash_tree "$target_home" >"$chk_file")
  chmod 600 "$chk_file" 2>/dev/null || true
}

ap_live_verify_host_untouched() {
  local target_home="$1"
  local chk_file="$target_home/.checksums.sha256"

  if [[ ! -f "$chk_file" ]]; then
    printf "ap_live_verify_host_untouched: missing checksum file %s\n" "$chk_file" >&2
    return 1
  fi

  local current_chk
  current_chk=$(ap_live_hash_tree "$target_home")
  local recorded_chk
  recorded_chk=$(cat "$chk_file")

  if [[ "$current_chk" != "$recorded_chk" ]]; then
    printf "ap_live_verify_host_untouched: synthetic host files were modified!\n" >&2
    return 1
  fi
}

# --- offline profile execution ---------------------------------------------

ap_live_run_offline_in_profile() {
  local helper="$1"
  local profile="$2"
  shift 2

  local env_args=(
    PATH="$PATH"
    HOME="$HOME"
    USER="${USER:-testuser}"
    LOGNAME="${LOGNAME:-testuser}"
    TERM="${TERM:-dumb}"
    LANG="${LANG:-C.UTF-8}"
    DISABLE_TELEMETRY=1
  )
  [[ -n "${MISE_CONFIG_DIR:-}" ]] && env_args+=(MISE_CONFIG_DIR="$MISE_CONFIG_DIR")
  [[ -n "${MISE_DATA_DIR:-}" ]] && env_args+=(MISE_DATA_DIR="$MISE_DATA_DIR")
  [[ -n "${MISE_STATE_DIR:-}" ]] && env_args+=(MISE_STATE_DIR="$MISE_STATE_DIR")
  [[ -n "${MISE_CACHE_DIR:-}" ]] && env_args+=(MISE_CACHE_DIR="$MISE_CACHE_DIR")

  env -i "${env_args[@]}" bwrap --dev-bind / / --unshare-net -- bash "$helper" run --profile "$profile" -- "$@"
}

# --- PTY driver ------------------------------------------------------------

# Runs a command under a Python standard-library PTY with a fixed window size,
# replacing util-linux script -qfc. Output goes to stdout and the caller's stdin
# is forwarded to the PTY, so interactive TUI probes work on both platforms.
# Usage: ap_live_pty_exec [--timeout SECONDS] [--rows N] [--cols N] -- CMD...
ap_live_pty_exec() {
  "$AP_PLATFORM_PYTHON" "$AP_LIVE_PTY_EXEC" "$@"
}

# Installs portable stand-ins for GNU-only QA helpers at the front of PATH, so
# an inner shell that only knows "timeout 25 cmd" keeps working on stock macOS.
ap_live_prepare_tool_shims() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/timeout" <<EOF
#!/usr/bin/env bash
exec "$AP_PLATFORM_PYTHON" "$AP_PLATFORM_PY" timeout "\$@"
EOF
  chmod 700 "$dir/timeout"
  export PATH="$dir:$PATH"
}

# --- ownership-aware cleanup -----------------------------------------------

# Usage: ap_live_cleanup_pgid <pgid> <marker-file> <qa-profile-dir>
# The marker must be written by ap_live_write_group_marker or
# ap_live_spawn_test_process. Every group member must carry the caller's real
# UID, and the profile marker must be present on a group member or descendant.
# Nothing is signalled until all of those checks pass.
ap_live_cleanup_pgid() {
  local pgid="${1:-}"
  local marker_file="${2:-}"
  local profile_dir="${3:-}"
  local recorded_pgid="" leader_pid="" boot_id="" start_ticks="" marker_uid=""
  local current_boot="" leader_identity="" pgrp="" current_start="" myuid=""
  local pids="" pid="" uid=""

  if [[ -z "$pgid" || ! "$pgid" =~ ^[0-9]+$ || "$pgid" -le 1 ]]; then
    printf "ap_live_cleanup_pgid: invalid or protected PGID: %s\n" "$pgid" >&2
    return 1
  fi

  if [[ -z "$marker_file" || ! -f "$marker_file" ]]; then
    printf "ap_live_cleanup_pgid: missing test ownership marker file: %s\n" "$marker_file" >&2
    return 1
  fi

  if [[ -z "$profile_dir" ]]; then
    printf "ap_live_cleanup_pgid: missing QA profile directory for ownership check\n" >&2
    return 1
  fi

  recorded_pgid=$(ap_live_marker_field "$marker_file" pgid)
  leader_pid=$(ap_live_marker_field "$marker_file" leader_pid)
  boot_id=$(ap_live_marker_field "$marker_file" boot_id)
  start_ticks=$(ap_live_marker_field "$marker_file" start_ticks)
  marker_uid=$(ap_live_marker_field "$marker_file" uid)
  if [[ -z "$recorded_pgid" || -z "$leader_pid" || -z "$boot_id" || -z "$start_ticks" || -z "$marker_uid" ]]; then
    printf "ap_live_cleanup_pgid: malformed or legacy ownership marker: %s\n" "$marker_file" >&2
    return 1
  fi

  if [[ "$recorded_pgid" != "$pgid" ]]; then
    printf "ap_live_cleanup_pgid: marker recorded PGID (%s) does not match target (%s)\n" "$recorded_pgid" "$pgid" >&2
    return 1
  fi

  pids=$(ap_live_pgid_members "$pgid")
  if [[ -z "$pids" ]]; then
    rm -f "$marker_file"
    return 0
  fi

  current_boot=$(ap_live_boot_identity 2>/dev/null || true)
  if [[ -z "$current_boot" || "$current_boot" != "$boot_id" ]]; then
    printf "ap_live_cleanup_pgid: boot identity mismatch for group %s\n" "$pgid" >&2
    return 1
  fi

  leader_identity=$(ap_live_pid_identity "$leader_pid" 2>/dev/null || true)
  if [[ -z "$leader_identity" ]]; then
    printf "ap_live_cleanup_pgid: process identity for group %s is unavailable (leader %s missing)\n" "$pgid" "$leader_pid" >&2
    return 1
  fi
  read -r pgrp current_start <<<"$leader_identity" || true
  if [[ "$pgrp" != "$pgid" || "$current_start" != "$start_ticks" ]]; then
    printf "ap_live_cleanup_pgid: process identity mismatch for group %s (possible PID reuse)\n" "$pgid" >&2
    return 1
  fi

  myuid=$(id -u)
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    uid=$(ap_live_pid_uid "$pid" 2>/dev/null || true)
    if [[ -z "$uid" || "$uid" != "$myuid" || "$uid" != "$marker_uid" ]]; then
      printf "ap_live_cleanup_pgid: process %s in group %s has unexpected UID (%s != %s)\n" \
        "$pid" "$pgid" "${uid:-unknown}" "$myuid" >&2
      return 1
    fi
  done <<<"$pids"

  if ! ap_live_pgid_owns_profile "$pgid" "$profile_dir"; then
    printf "ap_live_cleanup_pgid: process group %s lacks AGENT_PROFILES_DIR=%s ownership (no profile marker or open profile lease)\n" \
      "$pgid" "$profile_dir" >&2
    return 1
  fi

  kill -TERM -"$pgid" 2>/dev/null || true
  sleep 0.1
  kill -KILL -"$pgid" 2>/dev/null || true
  rm -f "$marker_file"
  return 0
}
