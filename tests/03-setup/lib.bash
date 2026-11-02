#!/usr/bin/env bash
# Ticket 03 setup test support: temp mise configuration, os-release fixtures,
# PATH spies, controlled PATHs, and read-only tree snapshots.
#
# The portable primitives (hashing, tree snapshots, portable timeouts, lock and
# process fixtures) live in tests/helpers/platform.bash and are sourced here so
# every setup test gets them without repeating a GNU-only pipeline.

# shellcheck source=/dev/null
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../helpers/platform.bash"

# Point all mise state at the disposable test tree so no host configuration is
# read or written. The caller has already run setup_isolation.
setup_mise_env() {
  export MISE_CONFIG_DIR="$TEST_TMPDIR/mise/config"
  export MISE_DATA_DIR="$TEST_TMPDIR/mise/data"
  export MISE_STATE_DIR="$TEST_TMPDIR/mise/state"
  export MISE_CACHE_DIR="$TEST_TMPDIR/mise/cache"
  export MISE_TRUSTED_CONFIG_PATHS="$TEST_TMPDIR"
  export AP_OS_RELEASE="$TEST_TMPDIR/os-release"
  # The Arch and Debian fixtures in this directory describe Linux machines.
  # Pin the platform probe to Linux so their detection, package-manager and
  # prerequisite paths stay testable on a macOS test host too. darwin.bats
  # selects Darwin itself, and on a Linux host this input matches the real OS.
  export AP_TEST_PLATFORM_OS="${AP_TEST_PLATFORM_OS:-Linux}"
  mkdir -p "$MISE_CONFIG_DIR" "$MISE_DATA_DIR" "$MISE_STATE_DIR" "$MISE_CACHE_DIR"
}

write_os_release() {
  local id="$1"
  local id_like="${2:-}"
  local pretty="${3:-$id Linux}"
  mkdir -p "$(dirname "$AP_OS_RELEASE")"
  {
    printf 'ID=%s\n' "$id"
    if [[ -n "$id_like" ]]; then
      printf 'ID_LIKE=%s\n' "$id_like"
    fi
    printf 'PRETTY_NAME="%s"\n' "$pretty"
  } >"$AP_OS_RELEASE"
}

# make_spy <dir> <name>: create a command that records its argv to AP_SPY_LOG
# and exits with AP_SPY_EXIT (default 0).
make_spy() {
  local dir="$1"
  local name="$2"
  mkdir -p "$dir"
  rm -f "$dir/$name"
  cat >"$dir/$name" <<'SPY'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0") $*" >>"${AP_SPY_LOG:?AP_SPY_LOG not set}"
exit "${AP_SPY_EXIT:-0}"
SPY
  chmod +x "$dir/$name"
}

# make_restricted_bin <dest> [excluded-name...]
# Build a PATH directory of symlinks to every executable on the current PATH
# except the excluded names, so tests can simulate missing tools without
# touching the host. The destination is the only PATH entry afterwards.
make_restricted_bin() {
  local dest="$1"
  shift
  local -a exclude=("$@")
  mkdir -p "$dest"

  local -a dirs
  IFS=':' read -ra dirs <<<"$PATH"

  local dir tool name skip entry
  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    for tool in "$dir"/*; do
      [[ -f "$tool" && -x "$tool" ]] || continue
      name="$(basename "$tool")"
      skip=0
      for entry in "${exclude[@]}"; do
        [[ "$name" == "$entry" ]] && skip=1
      done
      [[ $skip -eq 1 ]] && continue
      [[ -e "$dest/$name" ]] && continue
      ln -s "$tool" "$dest/$name" 2>/dev/null || true
    done
  done
}

# snapshot_tree <path...>: stable description of directory entries, modes,
# symlink targets and regular-file hashes for read-only assertions. The GNU
# find -printf / sort -z / xargs -r pipeline this used to be silently produced
# incomplete comparisons on BSD, so the traversal is the portable helper.
snapshot_tree() {
  ap_test_snapshot_tree "$@"
}

# write_fake_agent <path> <version>: minimal executable that only reports a
# version, so detection can resolve it without executing host agents.
write_fake_agent() {
  local path="$1"
  local version="$2"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<AGENT
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  echo "$version"
fi
exit 0
AGENT
  chmod +x "$path"
}
