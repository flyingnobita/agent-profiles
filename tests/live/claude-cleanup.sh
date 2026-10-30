#!/usr/bin/env bash
# Ownership-aware process cleanup for Claude live QA.
#
# A process is test-owned only when all of these hold:
#   - it is not the current shell or one of its ancestors;
#   - its real UID matches the caller;
#   - the current boot identity matches the boot the QA run started in;
#   - it carries AGENT_PROFILES_DIR=<disposable profile dir>, or (on Darwin,
#     where another process's environment cannot be read) it keeps the profile
#     lease descriptor or a profile file open.
#
# argv and cwd are deliberately not used: a scanner's own subprocess can carry
# either, which caused the previous scanner to detect and signal itself. The
# profile is disposable and unique to one QA run, so profile ownership is a
# stricter bound than a start-time comparison, and it is the bound that also
# works on Darwin. Every rule is implemented by the shared portable harness in
# tests/live/lib.sh, which uses stock ps plus the standard-library adapter.
# shellcheck disable=SC2034

if ! declare -F ap_live_pid_owns_profile >/dev/null 2>&1; then
  # shellcheck source=tests/live/lib.sh
  source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
fi

ap_claude_qa_boot_id() {
  ap_live_boot_identity
}

# Prints the current shell, the command-substitution shell when applicable, and
# their parent chain. These are never candidates for cleanup.
ap_claude_qa_ancestry_pids() {
  ap_live_ancestry_pids
}

# Usage: ap_claude_qa_owned_pids <profile-dir> [boot-id]
ap_claude_qa_owned_pids() {
  local profile_dir="${1:-}"
  local expected_boot="${2:-}"
  local boot excluded_csv

  [[ -n "$profile_dir" ]] || return 1
  boot=$(ap_live_boot_identity) || return 1
  [[ -n "$boot" ]] || return 1
  if [[ -n "$expected_boot" && "$boot" != "$expected_boot" ]]; then
    return 1
  fi

  excluded_csv=$(ap_claude_qa_ancestry_pids | tr '\n' ' ')

  # The bulk adapter pass enforces the caller's UID, the profile ownership and
  # the ancestry exclusion; nothing here signals anything.
  ap_live_profile_pids "$profile_dir" "$excluded_csv"
  return 0
}

# Usage: ap_claude_qa_cleanup <profile-dir> [boot-id]
# Prints each signalled PID, one per line. Never signals a process group.
ap_claude_qa_cleanup() {
  local profile_dir="${1:-}"
  local boot="${2:-}"
  local attempt pid
  local -a pids=()

  for attempt in 1 2 3 4; do
    pids=()
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      pids+=("$pid")
    done < <(ap_claude_qa_owned_pids "$profile_dir" "$boot")
    if [[ ${#pids[@]} -eq 0 ]]; then
      return 0
    fi
    printf '%s\n' "${pids[@]}"
    kill -TERM "${pids[@]}" 2>/dev/null || true
    sleep 0.3
    kill -KILL "${pids[@]}" 2>/dev/null || true
    sleep 0.3
  done
  return 0
}
