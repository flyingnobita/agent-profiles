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
