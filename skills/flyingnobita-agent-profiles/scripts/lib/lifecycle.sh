#!/usr/bin/env bash
# Lifecycle operations engine for agent-profiles
# shellcheck disable=SC2034

ap_preview_profile_categories() {
  local prof_dir="$1"

  python3 -c '
import os, sys

prof_dir = os.path.realpath(sys.argv[1])

categories = {
    "settings": {"count": 0, "bytes": 0},
    "transcripts": {"count": 0, "bytes": 0},
    "credentials": {"count": 0, "bytes": 0},
    "tools": {"count": 0, "bytes": 0},
    "other": {"count": 0, "bytes": 0}
}

cred_names = {"auth.json", "credentials.json", ".credentials.json", "token", "secret", "key"}

for root, dirs, files in os.walk(prof_dir):
    for f in files:
        fpath = os.path.join(root, f)
        try:
            rel = os.path.relpath(fpath, prof_dir)
            st = os.lstat(fpath)
            size = st.st_size
        except OSError:
            continue

        low_f = f.lower()
        if low_f in cred_names or "auth" in low_f or "token" in low_f or "credential" in low_f or "secret" in low_f:
            cat = "credentials"
        elif rel.startswith(".config") or rel == ".agent-profile" or "settings" in rel or "config" in rel:
            cat = "settings"
        elif rel.startswith(".local/share") or rel.startswith(".local/state") or "transcript" in rel or "history" in rel or "session" in rel:
            cat = "transcripts"
        elif rel.startswith("npm-global") or rel.startswith("uv-tools") or rel.startswith("cargo-global") or rel.startswith("python-user") or rel.startswith("bin") or rel.startswith(".cache"):
            cat = "tools"
        else:
            cat = "other"

        categories[cat]["count"] += 1
        categories[cat]["bytes"] += size

items = [
    ("settings", "Settings"),
    ("transcripts", "Transcripts"),
    ("credentials", "Credentials"),
    ("tools", "Installed tools")
]

for cat_key, label in items:
    cnt = categories[cat_key]["count"]
    sz = categories[cat_key]["bytes"]
    print(f"  {label}: {cnt} file(s), {sz} bytes")
' "$prof_dir"
}

ap_ensure_journal_dir() {
  local repo_root="$1"
  local storage_dir="$repo_root/.agent-profiles"
  local journal_dir="$storage_dir/.journal"

  if [[ -L "$storage_dir" ]]; then
    ap_die "$EX_LAYOUT" "profile storage directory '$storage_dir' is a symbolic link"
  fi
  if [[ -L "$journal_dir" ]]; then
    ap_die "$EX_LAYOUT" "journal directory '$journal_dir' is a symbolic link"
  fi
  if [[ ! -d "$journal_dir" ]]; then
    (umask 077 && mkdir -p "$journal_dir" && chmod 700 "$journal_dir")
  fi
}

ap_ensure_trash_dir() {
  local repo_root="$1"
  local storage_dir="$repo_root/.agent-profiles"
  local trash_dir="$storage_dir/.trash"

  if [[ -L "$storage_dir" ]]; then
    ap_die "$EX_LAYOUT" "profile storage directory '$storage_dir' is a symbolic link"
  fi
  if [[ -L "$trash_dir" ]]; then
    ap_die "$EX_LAYOUT" "trash directory '$trash_dir' is a symbolic link"
  fi
  if [[ ! -d "$trash_dir" ]]; then
    (umask 077 && mkdir -p "$trash_dir" && chmod 700 "$trash_dir")
  fi
}

ap_record_journal() {
  local journal_file="$1"
  local op="$2"
  local profile="$3"
  local state="$4"
  local profile_dir="$5"
  local trash_path="${6:-}"
  local assume_unrelated="${7:-}"
  local extra_json="${8:-{}}"

  local boot_id="00000000-0000-0000-0000-000000000000"
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    boot_id=$(tr -d '[:space:]' </proc/sys/kernel/random/boot_id)
  fi

  local tmp_file="${journal_file}.tmp.$$"
  python3 -c '
import json, sys, os

tmp_file = sys.argv[1]
op = sys.argv[2]
profile = sys.argv[3]
state = sys.argv[4]
profile_dir = sys.argv[5]
trash_path = sys.argv[6]
assume_unrelated = [int(p) for p in sys.argv[7].split(",") if p.isdigit()]
boot_id = sys.argv[8]
extra = json.loads(sys.argv[9])

data = {
    "op": op,
    "profile": profile,
    "state": state,
    "profile_dir": profile_dir,
    "trash_path": trash_path,
    "assume_unrelated": assume_unrelated,
    "boot_id": boot_id,
    **extra
}

with open(tmp_file, "w") as f:
    json.dump(data, f, indent=2)
    f.flush()
    os.fsync(f.fileno())
os.chmod(tmp_file, 0o600)
' "$tmp_file" "$op" "$profile" "$state" "$profile_dir" "$trash_path" "$assume_unrelated" "$boot_id" "$extra_json"

  mv "$tmp_file" "$journal_file"

  # Check fault injection hook
  if [[ -n "${AP_FAULT_AFTER:-}" && "${AP_FAULT_AFTER:-}" == "$state" ]]; then
    exit 137
  fi
}

ap_detect_legacy_layouts() {
  local repo_root="$1"

  python3 -c '
import os, sys

repo_root = sys.argv[1]
sandbox_dir = os.path.join(repo_root, ".agent-sandbox")
profiles_dir = os.path.join(repo_root, ".agent-profiles")

legacy = []
agent_subdirs = {".claude", ".codex", ".gemini", ".agents", ".opencode", "home", ".config", ".local", "npm-global", "uv-tools"}

# 1. Check .agent-sandbox
if os.path.exists(sandbox_dir):
    if os.path.islink(sandbox_dir):
        legacy.append("symlink-sandbox")
    elif os.path.isdir(sandbox_dir):
        entries = os.listdir(sandbox_dir)
        has_direct_agent_dirs = any(e in agent_subdirs for e in entries)
        if has_direct_agent_dirs:
            legacy.append("unnamed-sandbox")
        has_named_dirs = any(os.path.isdir(os.path.join(sandbox_dir, e)) and e not in agent_subdirs and not e.startswith(".") for e in entries)
        if has_named_dirs:
            legacy.append("named-sandbox")
        if not has_direct_agent_dirs and not has_named_dirs and entries:
            legacy.append("unnamed-sandbox")

# 2. Check .agent-profiles for unnamed root entries
if os.path.exists(profiles_dir) and os.path.isdir(profiles_dir) and not os.path.islink(profiles_dir):
    entries = os.listdir(profiles_dir)
    has_unnamed_in_profiles = any(e in agent_subdirs for e in entries)
    if has_unnamed_in_profiles:
        legacy.append("unnamed-profiles")

print(",".join(legacy))
' "$repo_root"
}
