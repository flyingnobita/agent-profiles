#!/usr/bin/env bash
# Mise integration: capture host effective directories before environment resets
# shellcheck disable=SC2034

ap_capture_effective_mise_dirs() {
  if ! command -v mise >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  local json_out
  json_out=$(mise doctor --json 2>/dev/null || true)
  if [[ -z "$json_out" ]]; then
    return 0
  fi

  local parsed
  parsed=$(python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
    dirs = data.get("dirs", {})
    mapping = {
        "config": "MISE_CONFIG_DIR",
        "data": "MISE_DATA_DIR",
        "state": "MISE_STATE_DIR",
        "cache": "MISE_CACHE_DIR"
    }
    for k, var_name in mapping.items():
        v = dirs.get(k)
        if v and isinstance(v, str) and v.startswith("/") and "\n" not in v:
            print(f"{var_name}={v}")
except Exception:
    pass
' "$json_out" 2>/dev/null || true)

  if [[ -n "$parsed" ]]; then
    while IFS='=' read -r var val || [[ -n "$var" ]]; do
      [[ -z "$var" || -z "$val" ]] && continue
      export "$var=$val"
    done <<<"$parsed"
  fi
}
