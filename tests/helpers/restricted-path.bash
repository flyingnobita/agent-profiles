#!/usr/bin/env bash
# Restricted PATH fixtures: a directory of symlinks that mirrors the current
# PATH minus named commands, so a test can make a tool absent without touching
# the host. Safe to source from setup_file, setup or a test body.

# ap_test_restricted_bin <dest> [excluded-name...]
# Links every executable on PATH into <dest> except the excluded names. An
# earlier PATH entry wins over a later one with the same name, as in lookup.
#
# Hosts carry thousands of executables, so the loop forks nothing per file:
# names come from parameter expansion and each PATH directory is linked with a
# single ln call. A per-file basename and ln made each call take 20-45 seconds.
# The loop also runs in a fresh bash: under bats the caller carries a DEBUG
# trap with functrace, which runs on every statement and alone costs seconds
# per call across a few thousand PATH entries.
ap_test_restricted_bin() {
  bash -c "$(declare -f ap_test_restricted_bin_impl); ap_test_restricted_bin_impl \"\$@\"" \
    ap_test_restricted_bin "$@"
}

ap_test_restricted_bin_impl() {
  local dest="$1"
  shift
  mkdir -p "$dest"

  local -a dirs
  IFS=':' read -ra dirs <<<"$PATH"

  local dir tool name entry skip
  local -a links
  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    links=()
    for tool in "$dir"/*; do
      [[ -x "$tool" && ! -d "$tool" ]] || continue
      name="${tool##*/}"
      skip=0
      for entry in "$@"; do
        if [[ "$name" == "$entry" ]]; then
          skip=1
          break
        fi
      done
      [[ $skip -eq 0 ]] || continue
      [[ -e "$dest/$name" || -L "$dest/$name" ]] && continue
      links+=("$tool")
    done
    if [[ ${#links[@]} -gt 0 ]]; then
      ln -s "${links[@]}" "$dest/" 2>/dev/null || true
    fi
  done
}
