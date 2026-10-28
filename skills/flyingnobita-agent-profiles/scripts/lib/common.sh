#!/usr/bin/env bash
# Common definitions, error codes, and utilities for agent-profiles
# shellcheck disable=SC2034

# Exit codes per contract
EX_OK=0
EX_USAGE=64
EX_DATAERR=65
EX_NOINPUT=66
EX_UNAVAILABLE=69
EX_LAYOUT=73
EX_BUSY=75
EX_REFUSED=77
EX_BROKEN=78

ap_die() {
  local code="$1"
  shift
  printf "agent-profiles: error: %s\n" "$*" >&2
  exit "$code"
}

ap_warn() {
  printf "agent-profiles: warning: %s\n" "$*" >&2
}

ap_json_escape() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1])[1:-1])' "$1"
}
