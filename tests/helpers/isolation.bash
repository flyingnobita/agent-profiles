#!/usr/bin/env bash

setup_isolation() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  export HOME="$TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$TEST_TMPDIR/config"
  export XDG_DATA_HOME="$TEST_TMPDIR/data"
  export XDG_STATE_HOME="$TEST_TMPDIR/state"
  export XDG_CACHE_HOME="$TEST_TMPDIR/cache"
  export npm_config_cache="$TEST_TMPDIR/npm_cache"
  export DISABLE_TELEMETRY=1

  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$npm_config_cache"
}

teardown_isolation() {
  if [[ -z "${BATS_TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}
