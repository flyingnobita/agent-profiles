#!/usr/bin/env bash
# Process scanning and relevance detection for agent profiles
# shellcheck disable=SC2034

ap_scan_processes() {
  local repo_root="$1"
  local profile="$2"
  local assume_unrelated_csv="${3:-}"

  local proc_root="${AP_PROC_ROOT:-/proc}"
  if [[ ! -d "$proc_root" ]]; then
    return 0
  fi

  local target_prof_dir="$repo_root/.agent-profiles/$profile"
  local real_target_dir
  real_target_dir=$(readlink -f "$target_prof_dir" 2>/dev/null || echo "$target_prof_dir")

  local current_uid
  current_uid=$(id -u)

  # Collect caller ancestry to exclude from process candidates
  local caller_pids=()
  local curr_p=$$
  while [[ -n "$curr_p" && "$curr_p" -gt 0 ]]; do
    caller_pids+=("$curr_p")
    local next_p
    next_p=$(cut -d' ' -f4 "$proc_root/$curr_p/stat" 2>/dev/null || true)
    if [[ -z "$next_p" || "$next_p" -eq "$curr_p" ]]; then
      break
    fi
    curr_p="$next_p"
  done

  # Parse assume-unrelated list
  local assume_unrelated=()
  if [[ -n "$assume_unrelated_csv" ]]; then
    IFS=',' read -r -a assume_unrelated <<<"$assume_unrelated_csv"
  fi

  # Determine earliest run record start ticks for this profile in current boot
  local boot_id="00000000-0000-0000-0000-000000000000"
  if [[ -r "$proc_root/sys/kernel/random/boot_id" ]]; then
    boot_id=$(tr -d '[:space:]' <"$proc_root/sys/kernel/random/boot_id")
  elif [[ -r /proc/sys/kernel/random/boot_id ]]; then
    boot_id=$(tr -d '[:space:]' </proc/sys/kernel/random/boot_id)
  fi

  local earliest_run_ticks=""
  local runs_file="$repo_root/.agent-profiles/.locks/$profile.runs"
  if [[ -f "$runs_file" && -r "$runs_file" ]]; then
    while read -r rec_boot rec_ticks; do
      if [[ "$rec_boot" == "$boot_id" && -n "$rec_ticks" ]]; then
        if [[ -z "$earliest_run_ticks" || "$rec_ticks" -lt "$earliest_run_ticks" ]]; then
          earliest_run_ticks="$rec_ticks"
        fi
      fi
    done <"$runs_file"
  fi

  python3 -c '
import os, sys, glob, re

repo_root = sys.argv[1]
profile = sys.argv[2]
target_dir = os.path.realpath(sys.argv[3])
proc_root = sys.argv[4]
current_uid = int(sys.argv[5])
caller_pids = set(int(p) for p in sys.argv[6].split() if p)
assume_unrelated = set(int(p) for p in sys.argv[7].split(",") if p.isdigit())
earliest_run_ticks = int(sys.argv[8]) if sys.argv[8].isdigit() else None

relevant_processes = []
relevant_unknown_processes = []

def is_path_under_target(p):
    if not p:
        return False
    try:
        rp = os.path.realpath(p)
        if rp == target_dir or rp.startswith(target_dir + "/"):
            return True
    except OSError:
        pass
    return False

for pdir in glob.glob(os.path.join(proc_root, "[0-9]*")):
    bname = os.path.basename(pdir)
    if not bname.isdigit():
        continue
    pid = int(bname)
    if pid in caller_pids:
        continue

    # Check process UID from status file
    status_file = os.path.join(pdir, "status")
    proc_uid = None
    proc_ppid = None
    comm = bname
    try:
        with open(status_file, "r") as f:
            for line in f:
                if line.startswith("Uid:"):
                    parts = line.split()
                    if len(parts) >= 2:
                        proc_uid = int(parts[1])
                elif line.startswith("PPid:"):
                    parts = line.split()
                    if len(parts) >= 2:
                        proc_ppid = int(parts[1])
                elif line.startswith("Name:"):
                    comm = line.split(None, 1)[1].strip()
    except Exception:
        # Cannot read status at all; skip if unreadable
        continue

    if proc_uid is not None and proc_uid != current_uid:
        continue

    comm_file = os.path.join(pdir, "comm")
    if os.path.exists(comm_file):
        try:
            with open(comm_file, "r") as f:
                comm = f.read().strip()
        except Exception:
            pass

    # Check inspectability
    inspectable = True
    environ_data = None
    mountinfo_data = None
    cwd_path = None
    root_path = None
    exe_path = None
    fd_links = []

    # 1. environ
    try:
        with open(os.path.join(pdir, "environ"), "rb") as f:
            environ_data = f.read()
    except Exception:
        inspectable = False

    # 2. mountinfo
    try:
        with open(os.path.join(pdir, "mountinfo"), "r") as f:
            mountinfo_data = f.read()
    except Exception:
        inspectable = False

    # 3. cwd, root, exe
    try:
        cwd_path = os.readlink(os.path.join(pdir, "cwd"))
    except Exception:
        inspectable = False

    try:
        root_path = os.readlink(os.path.join(pdir, "root"))
    except Exception:
        inspectable = False

    try:
        exe_path = os.readlink(os.path.join(pdir, "exe"))
    except Exception:
        inspectable = False

    # 4. fds
    fd_dir = os.path.join(pdir, "fd")
    try:
        for fentry in os.listdir(fd_dir):
            try:
                target = os.readlink(os.path.join(fd_dir, fentry))
                fd_links.append(target)
            except Exception:
                pass
    except Exception:
        inspectable = False

    # Check if inspectable and relevant
    is_relevant = False
    if environ_data is not None:
        env_entries = environ_data.split(b"\0")
        for entry in env_entries:
            if entry.startswith(b"AGENT_PROFILES_DIR=") or entry.startswith(b"AGENT_SANDBOX_DIR="):
                val = entry.split(b"=", 1)[1].decode("utf-8", "surrogateescape")
                if is_path_under_target(val):
                    is_relevant = True
                    break

    if not is_relevant and cwd_path and is_path_under_target(cwd_path):
        is_relevant = True

    if not is_relevant and root_path and is_path_under_target(root_path):
        is_relevant = True

    if not is_relevant and exe_path and is_path_under_target(exe_path):
        is_relevant = True

    if not is_relevant:
        for fl in fd_links:
            if is_path_under_target(fl):
                is_relevant = True
                break

    if not is_relevant and mountinfo_data:
        for line in mountinfo_data.splitlines():
            parts = line.strip().split()
            if len(parts) >= 5:
                root_part = parts[3]
                mp_part = parts[4]
                if is_path_under_target(root_part) or is_path_under_target(mp_part):
                    is_relevant = True
                    break

    if is_relevant:
        relevant_processes.append((pid, comm))
    elif not inspectable:
        # Check start time and orphan status
        stat_file = os.path.join(pdir, "stat")
        start_ticks = None
        try:
            with open(stat_file, "r") as f:
                content = f.read()
                # Parse field 22 from stat
                rparen = content.rfind(")")
                if rparen != -1:
                    fields = content[rparen + 2:].split()
                    # fields[0] is state (field 3 of stat)
                    # field 22 is index 19 in fields
                    if len(fields) >= 20:
                        start_ticks = int(fields[19])
        except Exception:
            pass

        # Check ancestry / orphan
        is_orphaned = (proc_ppid is None or proc_ppid == 1)
        if is_orphaned:
            if earliest_run_ticks is None:
                relevant_unknown_processes.append((pid, comm))
            elif start_ticks is not None and start_ticks >= earliest_run_ticks:
                relevant_unknown_processes.append((pid, comm))
        else:
            # Check ppid chain
            curr = proc_ppid
            chain_hit = False
            for _ in range(20):
                if not curr or curr <= 1 or curr in caller_pids:
                    break
                p_comm_f = os.path.join(proc_root, str(curr), "comm")
                if os.path.exists(p_comm_f):
                    try:
                        with open(p_comm_f, "r") as f:
                            p_c = f.read().strip()
                            if p_c in ["bwrap", "agent-profiles"]:
                                chain_hit = True
                                break
                    except Exception:
                        pass
                curr_stat = os.path.join(proc_root, str(curr), "stat")
                try:
                    with open(curr_stat, "r") as f:
                        curr = int(f.read().split()[3])
                except Exception:
                    break
            if chain_hit:
                relevant_unknown_processes.append((pid, comm))

# Evaluate refusals
# Relevant inspectable processes ALWAYS refuse (cannot be assumed unrelated)
# Relevant-unknown processes refuse unless present in assume_unrelated
refusal_lines = []

for pid, comm in relevant_processes:
    refusal_lines.append(f"  PID {pid} ({comm}) [relevant: active profile resources in use]")

for pid, comm in relevant_unknown_processes:
    if pid in assume_unrelated:
        continue
    refusal_lines.append(f"  PID {pid} ({comm}) [relevant-unknown: uninspectable process potentially bound to profile]")

if refusal_lines:
    print("agent-profiles: error: refused: active process(es) associated with profile '\''" + profile + "'\'':", file=sys.stderr)
    for line in refusal_lines:
        print(line, file=sys.stderr)
    print("Use --assume-unrelated PID[,PID...] to explicitly vouch for unknown uninspectable processes.", file=sys.stderr)
    sys.exit(75)

sys.exit(0)
' "$repo_root" "$profile" "$real_target_dir" "$proc_root" "$current_uid" "${caller_pids[*]}" "${assume_unrelated[*]}" "$earliest_run_ticks"
}
