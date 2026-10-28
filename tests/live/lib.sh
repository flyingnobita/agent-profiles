#!/usr/bin/env bash
# Shared test harness functions for live agent QA (offline probes, synthetic host isolation, and PGID cleanup)
# shellcheck disable=SC2034

ap_live_setup_isolation() {
  local base_dir="$1"
  export AP_LIVE_TMPDIR="$base_dir"
  export HOME="$base_dir/home"
  export XDG_CONFIG_HOME="$base_dir/config"
  export XDG_DATA_HOME="$base_dir/data"
  export XDG_STATE_HOME="$base_dir/state"
  export XDG_CACHE_HOME="$base_dir/cache"
  export DISABLE_TELEMETRY=1
  export npm_config_cache="$base_dir/npm_cache"

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
    printf "Recorded:\n%s\nCurrent:\n%s\n" "$recorded_chk" "$current_chk" >&2
    return 1
  fi
}

ap_live_run_offline_in_profile() {
  local helper="$1"
  local profile="$2"
  shift 2

  # Wrap in unshare-net for offline isolation
  bwrap --dev-bind / / --unshare-net -- bash "$helper" run --profile "$profile" -- "$@"
}

ap_live_cleanup_pgid() {
  local pgid="$1"
  if [[ -n "$pgid" && "$pgid" -gt 1 ]]; then
    kill -TERM -"$pgid" 2>/dev/null || true
    sleep 0.1
    kill -KILL -"$pgid" 2>/dev/null || true
  fi
}
