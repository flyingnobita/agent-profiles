#!/usr/bin/env bash
# Shared test harness functions for live agent QA (offline probes, synthetic host isolation, and PGID cleanup)
# shellcheck disable=SC2034

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
  (
    cd "$target_home" && find . -type f ! -name ".checksums.sha256" -exec sha256sum {} + | sort >"$chk_file"
    chmod 600 "$chk_file" 2>/dev/null || true
  )
}

ap_live_verify_host_untouched() {
  local target_home="$1"
  local chk_file="$target_home/.checksums.sha256"

  if [[ ! -f "$chk_file" ]]; then
    printf "ap_live_verify_host_untouched: missing checksum file %s\n" "$chk_file" >&2
    return 1
  fi

  local current_chk
  current_chk=$(
    cd "$target_home" && find . -type f ! -name ".checksums.sha256" -exec sha256sum {} + | sort
  )
  local recorded_chk
  recorded_chk=$(cat "$chk_file")

  if [[ "$current_chk" != "$recorded_chk" ]]; then
    printf "ap_live_verify_host_untouched: synthetic host files were modified!\n" >&2
    return 1
  fi
}

ap_live_descendant_pids() {
  local pid="$1" child
  printf '%s\n' "$pid"
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    ap_live_descendant_pids "$child"
  done
}

ap_live_pid_has_profile_env() {
  local pid="$1" profile_dir="$2" env_dump=""
  [[ -n "$pid" && -n "$profile_dir" ]] || return 1
  env_dump=$({ tr '\0' '\n' <"/proc/$pid/environ"; } 2>/dev/null) || return 1
  grep -Fqx "AGENT_PROFILES_DIR=$profile_dir" <<<"$env_dump"
}

ap_live_pid_uid() {
  local pid="$1" uid=""
  uid=$({ awk '/^Uid:/ { print $2; exit }' "/proc/$pid/status"; } 2>/dev/null) || return 1
  [[ -n "$uid" ]] || return 1
  printf '%s\n' "$uid"
}

# Prints "<process-group> <starttime-ticks>" for a live process. Start time is
# part of the marker identity so a recycled PID cannot authorize a signal.
ap_live_pid_stat() {
  local pid="$1"
  python3 - "$pid" <<'PY'
import sys

pid = sys.argv[1]
try:
    with open(f"/proc/{pid}/stat", "rb") as handle:
        data = handle.read().decode("utf-8", "replace")
except OSError:
    raise SystemExit(1)

end = data.rfind(")")
if end < 0:
    raise SystemExit(1)
fields = data[end + 2:].split()
if len(fields) < 20:
    raise SystemExit(1)

print(f"{fields[2]} {fields[19]}")
PY
}

ap_live_profile_pids() {
  local profile_dir="$1" pid
  for pid in $(ps -eo pid= 2>/dev/null); do
    if ap_live_pid_has_profile_env "$pid" "$profile_dir"; then
      printf '%s\n' "$pid"
    fi
  done
  return 0
}

ap_live_pid_tree_has_profile_env() {
  local pid="$1" profile_dir="$2" child
  ap_live_pid_has_profile_env "$pid" "$profile_dir" && return 0
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    ap_live_pid_tree_has_profile_env "$child" "$profile_dir" && return 0
  done
  return 1
}

ap_live_pgid_has_profile_env() {
  local pgid="$1" profile_dir="$2" pid
  for pid in $(ps -o pid= -g "$pgid" 2>/dev/null || true); do
    ap_live_pid_tree_has_profile_env "$pid" "$profile_dir" && return 0
  done
  return 1
}

# Returns PGIDs in the root process tree that contain a process carrying the
# QA profile marker. The caller still cleans each group through
# ap_live_cleanup_pgid, which re-checks ownership before signalling.
ap_live_owned_pgids() {
  local root_pid="$1" profile_dir="$2" pid pgid
  local -A seen=()
  for pid in $(ap_live_descendant_pids "$root_pid"); do
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
    [[ -n "$pgid" ]] || continue
    [[ -n "${seen[$pgid]:-}" ]] && continue
    if ap_live_pid_has_profile_env "$pid" "$profile_dir"; then
      seen[$pgid]=1
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
# records the leader PID, boot ID, starttime and UID so later cleanup can
# distinguish the original group from a recycled PGID.
ap_live_write_group_marker() {
  local pgid="${1:-}" marker="${2:-}"
  local pgrp="" start="" uid="" boot="" myuid=""

  [[ "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 ]] || return 1
  [[ -n "$marker" ]] || return 1

  read -r pgrp start <<<"$(ap_live_pid_stat "$pgid" 2>/dev/null || true)" || return 1
  [[ "$pgrp" == "$pgid" && -n "$start" ]] || return 1

  uid=$(ap_live_pid_uid "$pgid" 2>/dev/null || true)
  myuid=$(id -u)
  [[ "$uid" == "$myuid" ]] || return 1

  boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
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

ap_live_spawn_test_process() {
  local marker_file="$1"
  shift

  local pgid=""
  pgid=$(python3 -c '
import os, sys, subprocess

cmd = sys.argv[1:]
proc = subprocess.Popen(
    cmd,
    start_new_session=True,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    close_fds=True
)
print(os.getpgid(proc.pid))
' "$@") || return 1

  if ! ap_live_write_group_marker "$pgid" "$marker_file"; then
    kill -KILL -"$pgid" 2>/dev/null || true
    return 1
  fi

  printf '%s\n' "$pgid"
}

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

# Usage: ap_live_cleanup_pgid <pgid> <marker-file> <qa-profile-dir>
# The marker must be written by ap_live_write_group_marker or
# ap_live_spawn_test_process. Every group member must carry the caller's real
# UID, and the profile marker must be present on a group member or descendant.
ap_live_cleanup_pgid() {
  local pgid="${1:-}"
  local marker_file="${2:-}"
  local profile_dir="${3:-}"
  local recorded_pgid="" leader_pid="" boot_id="" start_ticks="" marker_uid=""
  local current_boot="" pgrp="" current_start="" myuid=""
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

  pids=$(ps -o pid= -g "$pgid" 2>/dev/null | awk '{ print $1 }' || true)
  if [[ -z "$pids" ]]; then
    rm -f "$marker_file"
    return 0
  fi

  current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
  if [[ -z "$current_boot" || "$current_boot" != "$boot_id" ]]; then
    printf "ap_live_cleanup_pgid: boot identity mismatch for group %s\n" "$pgid" >&2
    return 1
  fi

  if [[ ! -r "/proc/$leader_pid/stat" ]]; then
    printf "ap_live_cleanup_pgid: process identity for group %s is unavailable (leader %s missing)\n" "$pgid" "$leader_pid" >&2
    return 1
  fi
  read -r pgrp current_start <<<"$(ap_live_pid_stat "$leader_pid" 2>/dev/null || true)" || true
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

  if ! ap_live_pgid_has_profile_env "$pgid" "$profile_dir"; then
    printf "ap_live_cleanup_pgid: process group %s lacks AGENT_PROFILES_DIR=%s ownership\n" \
      "$pgid" "$profile_dir" >&2
    return 1
  fi

  kill -TERM -"$pgid" 2>/dev/null || true
  sleep 0.1
  kill -KILL -"$pgid" 2>/dev/null || true
  rm -f "$marker_file"
  return 0
}
