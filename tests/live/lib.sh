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

ap_live_spawn_test_process() {
  local marker_file="$1"
  shift

  python3 -c '
import os, sys, subprocess

marker = sys.argv[1]
cmd = sys.argv[2:]

proc = subprocess.Popen(
    cmd,
    start_new_session=True,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    close_fds=True
)
pgid = os.getpgid(proc.pid)

with open(marker, "w") as f:
    f.write(f"{pgid}\n")
os.chmod(marker, 0o600)

print(pgid)
' "$marker_file" "$@"
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

ap_live_cleanup_pgid() {
  local pgid="${1:-}"
  local marker_file="${2:-}"

  if [[ -z "$pgid" || ! "$pgid" =~ ^[0-9]+$ || "$pgid" -le 1 ]]; then
    printf "ap_live_cleanup_pgid: invalid or protected PGID: %s\n" "$pgid" >&2
    return 1
  fi

  if [[ -z "$marker_file" || ! -f "$marker_file" ]]; then
    printf "ap_live_cleanup_pgid: missing test ownership marker file: %s\n" "$marker_file" >&2
    return 1
  fi

  local recorded_pgid
  recorded_pgid=$(tr -d '[:space:]' <"$marker_file" 2>/dev/null || true)
  if [[ "$recorded_pgid" != "$pgid" ]]; then
    printf "ap_live_cleanup_pgid: marker recorded PGID (%s) does not match target (%s)\n" "$recorded_pgid" "$pgid" >&2
    return 1
  fi

  local p_uids
  p_uids=$(ps -o uid= -g "$pgid" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ -z "$p_uids" ]]; then
    rm -f "$marker_file"
    return 0
  fi

  local my_uid
  my_uid=$(id -u)
  for u in $p_uids; do
    if [[ "$u" != "$my_uid" ]]; then
      printf "ap_live_cleanup_pgid: process group %s has processes owned by other UID (%s != %s)\n" "$pgid" "$u" "$my_uid" >&2
      return 1
    fi
  done

  kill -TERM -"$pgid" 2>/dev/null || true
  sleep 0.1
  kill -KILL -"$pgid" 2>/dev/null || true
  rm -f "$marker_file"
  return 0
}
