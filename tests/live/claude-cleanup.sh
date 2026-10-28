#!/usr/bin/env bash
# Ownership-aware process cleanup for Claude live QA.
#
# A process is test-owned only when all of these hold:
#   - it is not the current shell or one of its ancestors;
#   - its real UID matches the caller;
#   - its start time is at or after the QA start tick in the current boot;
#   - its environment contains AGENT_PROFILES_DIR=<disposable profile dir>.
#
# argv and cwd are deliberately not used: a scanner's own subprocess can carry
# either, which caused the previous scanner to detect and signal itself.
# shellcheck disable=SC2034

ap_claude_qa_boot_id() {
  cat /proc/sys/kernel/random/boot_id 2>/dev/null
}

ap_claude_qa_clk_tck() {
  local tck
  tck=$(getconf CLK_TCK 2>/dev/null || true)
  [[ -n "$tck" ]] || tck=100
  printf '%s\n' "$tck"
}

# Prints a boot-relative tick used as the lower bound for QA-owned processes.
ap_claude_qa_uptime_ticks() {
  local tck uptime_seconds
  tck=$(ap_claude_qa_clk_tck)
  uptime_seconds=$(cut -d. -f1 /proc/uptime 2>/dev/null || true)
  [[ -n "$uptime_seconds" ]] || return 1
  printf '%s\n' $((uptime_seconds * tck))
}

ap_claude_qa_pid_start_ticks() {
  local pid="$1" data
  [[ -n "$pid" ]] || return 1
  data=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
  data=${data##*) }
  awk '{ print $20 }' <<<"$data"
}

ap_claude_qa_pid_uid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  awk '/^Uid:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null
}

ap_claude_qa_pid_has_profile_env() {
  local pid="$1" profile_dir="$2" env_dump=""
  [[ -n "$pid" && -n "$profile_dir" ]] || return 1
  env_dump=$(cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n') || return 1
  grep -Fqx "AGENT_PROFILES_DIR=$profile_dir" <<<"$env_dump"
}

# Prints the current shell, the command-substitution shell when applicable, and
# their parent chain. These are never candidates for cleanup.
ap_claude_qa_ancestry_pids() {
  local pid="${BASHPID:-$$}" parent=""
  local -A seen=()
  while [[ -n "$pid" && "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]; do
    [[ -n "${seen[$pid]:-}" ]] && break
    seen[$pid]=1
    printf '%s\n' "$pid"
    parent=$(awk '/^PPid:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null || true)
    pid="$parent"
  done
  if [[ "$pid" != "$$" ]]; then
    printf '%s\n' "$$"
  fi
}

# Usage: ap_claude_qa_owned_pids <profile-dir> <start-ticks> [boot-id]
ap_claude_qa_owned_pids() {
  local profile_dir="${1:-}"
  local start_ticks="${2:-}"
  local expected_boot="${3:-}"
  local myuid boot proc pid uid started
  local -A excluded=()

  [[ -n "$profile_dir" && -n "$start_ticks" ]] || return 1
  myuid=$(id -u)
  boot=$(ap_claude_qa_boot_id)
  [[ -n "$boot" ]] || return 1
  if [[ -n "$expected_boot" && "$boot" != "$expected_boot" ]]; then
    return 1
  fi

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && excluded[$pid]=1
  done < <(ap_claude_qa_ancestry_pids)

  for proc in /proc/[0-9]*; do
    pid="${proc#/proc/}"
    [[ -n "${excluded[$pid]:-}" ]] && continue
    uid=$(ap_claude_qa_pid_uid "$pid" 2>/dev/null || true)
    [[ "$uid" == "$myuid" ]] || continue
    started=$(ap_claude_qa_pid_start_ticks "$pid" 2>/dev/null || true)
    [[ -n "$started" && "$started" -ge "$start_ticks" ]] || continue
    ap_claude_qa_pid_has_profile_env "$pid" "$profile_dir" || continue
    printf '%s\n' "$pid"
  done
  return 0
}

# Usage: ap_claude_qa_cleanup <profile-dir> <start-ticks> [boot-id]
# Prints each signalled PID, one per line. Never signals a process group.
ap_claude_qa_cleanup() {
  local profile_dir="${1:-}"
  local start_ticks="${2:-}"
  local boot="${3:-}"
  local attempt pid
  local -a pids=()

  for attempt in 1 2 3 4; do
    mapfile -t pids < <(ap_claude_qa_owned_pids "$profile_dir" "$start_ticks" "$boot")
    [[ ${#pids[@]} -eq 0 ]] && return 0
    printf '%s\n' "${pids[@]}"
    kill -TERM "${pids[@]}" 2>/dev/null || true
    sleep 0.3
    kill -KILL "${pids[@]}" 2>/dev/null || true
    sleep 0.3
  done
  return 0
}
