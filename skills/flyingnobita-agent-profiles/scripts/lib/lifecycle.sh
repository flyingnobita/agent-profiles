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
  local extra_json="${8:-}"
  [[ -n "$extra_json" ]] || extra_json='{}'

  local boot_id="00000000-0000-0000-0000-000000000000"
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    boot_id=$(tr -d '[:space:]' </proc/sys/kernel/random/boot_id)
  fi

  python3 - "$journal_file" "$op" "$profile" "$state" "$profile_dir" "$trash_path" "$assume_unrelated" "$boot_id" "$extra_json" <<'PY'
import json, os, sys

journal_file, op, profile, state, profile_dir, trash_path, assume_raw, boot_id, extra_raw = sys.argv[1:10]

try:
    extra = json.loads(extra_raw)
except ValueError as exc:
    raise SystemExit(f"journal extra data is not valid JSON: {exc}")
if not isinstance(extra, dict):
    raise SystemExit("journal extra data must be a JSON object")

data = {
    "op": op,
    "profile": profile,
    "state": state,
    "profile_dir": profile_dir,
    "trash_path": trash_path,
    "assume_unrelated": [int(p) for p in assume_raw.split(",") if p.isdigit()],
    "boot_id": boot_id,
}
data.update(extra)

tmp_file = journal_file + ".tmp"
with open(tmp_file, "w") as handle:
    json.dump(data, handle, indent=2)
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(tmp_file, 0o600)
os.replace(tmp_file, journal_file)

dir_fd = os.open(os.path.dirname(journal_file) or ".", os.O_RDONLY)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY

  if [[ -n "${AP_FAULT_AFTER:-}" && "${AP_FAULT_AFTER:-}" == "$state" ]]; then
    exit 137
  fi
}

ap_copy_journal_to_backup() {
  local journal_file="$1"
  local backup_dir="$2"

  [[ -f "$journal_file" && -d "$backup_dir" ]] || return 0
  (
    umask 077
    cp "$journal_file" "$backup_dir/journal.json"
    chmod 600 "$backup_dir/journal.json"
  )
}

# Reads a journal into NUL-separated fields: op, profile, state, profile_dir,
# trash_path, assume_unrelated CSV, backup_dir, staged_dir, legacy_dir,
# migrated_profiles CSV, content_manifest.
ap_read_journal_fields() {
  local journal_file="$1"

  python3 - "$journal_file" <<'PY'
import json, sys

with open(sys.argv[1], "r") as handle:
    data = json.load(handle)

fields = [
    str(data.get("op", "")),
    str(data.get("profile", "")),
    str(data.get("state", "")),
    str(data.get("profile_dir", "")),
    str(data.get("trash_path", "")),
    ",".join(str(p) for p in data.get("assume_unrelated", [])),
    str(data.get("backup_dir", "")),
    str(data.get("staged_dir", "")),
    str(data.get("legacy_dir", "")),
    " ".join(str(p) for p in data.get("migrated_profiles", [])),
    str(data.get("content_manifest", "")),
]
sys.stdout.buffer.write(("\0".join(fields) + "\0").encode())
PY
}

# Prints one TAB-separated "path label mode" line per recorded migration source.
ap_read_journal_sources() {
  local journal_file="$1"

  python3 - "$journal_file" <<'PY'
import json, sys

with open(sys.argv[1], "r") as handle:
    data = json.load(handle)

sources = data.get("sources", [])
if not isinstance(sources, list):
    sources = []

for source in sources:
    if not isinstance(source, dict):
        continue
    fields = [str(source.get("path", "")), str(source.get("label", "")), str(source.get("mode", ""))]
    sys.stdout.write("\t".join(fields) + "\n")
PY
}

# Returns 0 when a basename is a recognizable legacy agent entry. Used to
# validate recorded migration source paths during recovery.
ap_migrate_is_agent_entry() {
  case "$1" in
    .claude | .codex | .gemini | .agents | .opencode | .claude.json | home | bin | npm-global | uv-tools | cargo-global | python-user | .config | .local | .cache)
      return 0
      ;;
  esac
  return 1
}

# Lists the names under a profile storage directory that are genuine unnamed
# legacy data: agent directory entries that do not have the layout of a named
# profile. A named profile is a real directory with a home/ directory or an
# .agent-profile marker, so previously valid profile names such as bin, home,
# npm-global, uv-tools, cargo-global and python-user are never captured.
ap_list_unnamed_legacy_entries() {
  local storage_dir="$1"

  python3 - "$storage_dir" <<'PY'
import os, sys

storage_dir = sys.argv[1]
agent_subdirs = {
    ".claude", ".codex", ".gemini", ".agents", ".opencode",
    "home", "bin", "npm-global", "uv-tools", "cargo-global",
    "python-user", ".config", ".local", ".cache", ".claude.json",
}


def is_named_profile(path):
    return os.path.isdir(os.path.join(path, "home")) or os.path.isfile(
        os.path.join(path, ".agent-profile")
    )


try:
    entries = sorted(os.listdir(storage_dir))
except OSError:
    entries = []

for entry in entries:
    if entry not in agent_subdirs:
        continue
    path = os.path.join(storage_dir, entry)
    if os.path.isdir(path) and not os.path.islink(path) and is_named_profile(path):
        continue
    print(entry)
PY
}

ap_detect_legacy_layouts() {
  local repo_root="$1"

  python3 - "$repo_root" <<'PY'
import os, sys

repo_root = sys.argv[1]
sandbox_dir = os.path.join(repo_root, ".agent-sandbox")
profiles_dir = os.path.join(repo_root, ".agent-profiles")

agent_subdirs = {
    ".claude", ".codex", ".gemini", ".agents", ".opencode",
    "home", "bin", "npm-global", "uv-tools", "cargo-global",
    "python-user", ".config", ".local", ".cache", ".claude.json",
}


def is_named_profile(path):
    return os.path.isdir(os.path.join(path, "home")) or os.path.isfile(
        os.path.join(path, ".agent-profile")
    )


layouts = []

if os.path.lexists(sandbox_dir):
    if os.path.islink(sandbox_dir):
        layouts.append("symlink-sandbox")
    elif not os.path.isdir(sandbox_dir):
        layouts.append("invalid-sandbox")
    else:
        try:
            entries = os.listdir(sandbox_dir)
        except OSError:
            entries = []

        agent_entries = [e for e in entries if e in agent_subdirs]
        named_entries = []
        other_entries = []
        for entry in entries:
            if entry in agent_subdirs:
                continue
            if entry.startswith("."):
                continue
            path = os.path.join(sandbox_dir, entry)
            if os.path.isdir(path) and not os.path.islink(path):
                named_entries.append(entry)
            else:
                other_entries.append(entry)

        if agent_entries and named_entries:
            layouts.extend(["unnamed-sandbox", "named-sandbox", "mixed-sandbox"])
        elif agent_entries:
            layouts.append("unnamed-sandbox")
        elif named_entries:
            layouts.append("named-sandbox")
        elif other_entries:
            layouts.append("unknown-sandbox")

if os.path.lexists(profiles_dir):
    if os.path.islink(profiles_dir):
        layouts.append("symlink-profiles")
    elif os.path.isdir(profiles_dir):
        try:
            entries = os.listdir(profiles_dir)
        except OSError:
            entries = []
        unnamed = False
        for entry in entries:
            if entry not in agent_subdirs:
                continue
            path = os.path.join(profiles_dir, entry)
            if os.path.isdir(path) and not os.path.islink(path) and is_named_profile(path):
                continue
            unnamed = True
            break
        if unnamed:
            layouts.append("unnamed-profiles")

print(",".join(layouts))
PY
}

ap_path_within() {
  local child="$1"
  local parent="$2"
  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

# Validates and, if needed, creates a private backup root. Refuses symlinked or
# shared components, paths inside the checkout, and paths not owned by the user.
# Prints the resolved physical root.
# Read-only validation of a backup root, used by previews and before creating
# anything. Prints the resolved lexical path.
ap_validate_private_backup_path() {
  local repo_root="$1"
  local backup_root="$2"

  if [[ "$backup_root" != /* ]]; then
    ap_die "$EX_LAYOUT" "backup root '$backup_root' must be an absolute path"
  fi

  local normalized
  normalized=$(realpath -m "$backup_root" 2>/dev/null || printf '%s\n' "$backup_root")

  local real_repo
  real_repo=$(realpath -e "$repo_root" 2>/dev/null || printf '%s\n' "$repo_root")

  if ap_path_within "$normalized" "$real_repo"; then
    ap_die "$EX_LAYOUT" "backup path cannot be inside the git checkout ($backup_root)"
  fi

  if [[ -d "$normalized" ]]; then
    local resolved owner mode
    if ! resolved=$(realpath -e "$normalized" 2>/dev/null); then
      ap_die "$EX_LAYOUT" "backup path '$backup_root' does not resolve to a directory"
    fi
    if ap_path_within "$resolved" "$real_repo"; then
      ap_die "$EX_LAYOUT" "backup path resolves inside the git checkout ($resolved)"
    fi
    owner=$(stat -c "%u" "$resolved" 2>/dev/null || true)
    if [[ "$owner" != "$(id -u)" ]]; then
      ap_die "$EX_LAYOUT" "backup path '$resolved' is not owned by the current user"
    fi
    mode=$(stat -c "%a" "$resolved" 2>/dev/null || true)
    if [[ -n "$mode" ]] && ((8#$mode & 8#022)); then
      ap_die "$EX_LAYOUT" "insecure permissions on backup path '$resolved' (must not be group or world writable, got mode $mode)"
    fi
  fi

  printf "%s\n" "$normalized"
}

ap_prepare_private_backup_root() {
  local repo_root="$1"
  local backup_root="$2"

  if [[ "$backup_root" != /* ]]; then
    ap_die "$EX_LAYOUT" "backup root '$backup_root' must be an absolute path"
  fi

  local normalized
  normalized=$(realpath -m "$backup_root" 2>/dev/null || printf '%s\n' "$backup_root")

  local real_repo
  real_repo=$(realpath -e "$repo_root" 2>/dev/null || printf '%s\n' "$repo_root")

  if ap_path_within "$normalized" "$real_repo"; then
    ap_die "$EX_LAYOUT" "backup path cannot be inside the git checkout ($backup_root)"
  fi

  local missing_chain=()
  local current="$normalized"
  while [[ ! -e "$current" && "$current" != "/" ]]; do
    missing_chain=("$current" "${missing_chain[@]}")
    current=$(dirname "$current")
  done

  if [[ ! -d "$current" ]]; then
    ap_die "$EX_LAYOUT" "backup root ancestor '$current' is not a directory"
  fi

  local component
  for component in "${missing_chain[@]}"; do
    if [[ -L "$component" ]]; then
      ap_die "$EX_LAYOUT" "backup path component '$component' is a symbolic link"
    fi
    if ! (umask 077 && mkdir -m 700 "$component") 2>/dev/null; then
      if [[ ! -d "$component" || -L "$component" ]]; then
        ap_die "$EX_LAYOUT" "cannot create private backup directory '$component'"
      fi
    fi
  done

  local resolved
  if ! resolved=$(realpath -e "$normalized" 2>/dev/null); then
    ap_die "$EX_LAYOUT" "backup path '$backup_root' does not resolve to a directory"
  fi

  if ap_path_within "$resolved" "$real_repo"; then
    ap_die "$EX_LAYOUT" "backup path resolves inside the git checkout ($resolved)"
  fi

  local owner mode
  owner=$(stat -c "%u" "$resolved" 2>/dev/null || true)
  if [[ "$owner" != "$(id -u)" ]]; then
    ap_die "$EX_LAYOUT" "backup path '$resolved' is not owned by the current user"
  fi

  mode=$(stat -c "%a" "$resolved" 2>/dev/null || true)
  if [[ -n "$mode" ]] && ((8#$mode & 8#022)); then
    ap_die "$EX_LAYOUT" "insecure permissions on backup path '$resolved' (must not be group or world writable, got mode $mode)"
  fi

  printf "%s\n" "$resolved"
}

ap_backup_run_name() {
  local repo_root="$1"
  local resolved_repo
  resolved_repo=$(realpath -e "$repo_root" 2>/dev/null || printf '%s\n' "$repo_root")

  local repo_name
  repo_name=$(basename "$resolved_repo")
  local repo_sha8
  repo_sha8=$(printf "%s" "$resolved_repo" | sha256sum | cut -c1-8)
  local utc_ts
  utc_ts=$(date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || date +"%Y%m%d%H%M%S")

  printf "%s-%s-%s\n" "$repo_name" "$repo_sha8" "$utc_ts"
}

# Prints the path a run would use without creating anything (preview).
ap_candidate_backup_path() {
  local repo_root="$1"
  local backup_root="$2"
  printf "%s/%s\n" "${backup_root%/}" "$(ap_backup_run_name "$repo_root")"
}

# Creates the per-run backup directory with a non-recursive mkdir, so an
# existing path is never reused. Prints the created path.
ap_create_per_run_backup() {
  local repo_root="$1"
  local resolved_root="$2"

  local run_dir
  run_dir=$(ap_candidate_backup_path "$repo_root" "$resolved_root")

  if [[ -e "$run_dir" || -L "$run_dir" ]]; then
    ap_die "$EX_LAYOUT" "backup destination '$run_dir' already exists"
  fi

  if ! (umask 077 && mkdir -m 700 "$run_dir") 2>/dev/null; then
    ap_die "$EX_LAYOUT" "cannot create per-run backup directory '$run_dir'"
  fi
  if [[ -L "$run_dir" || ! -d "$run_dir" ]]; then
    ap_die "$EX_LAYOUT" "per-run backup path '$run_dir' is not a real directory"
  fi

  printf "%s\n" "$run_dir"
}

ap_fsync_tree() {
  local tree_root="$1"

  python3 - "$tree_root" <<'PY'
import os, sys

root = sys.argv[1]
errors = []

for current, dirs, files in os.walk(root, followlinks=False):
    for name in files:
        path = os.path.join(current, name)
        if os.path.islink(path):
            continue
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError as exc:
            errors.append(f"{path}: {exc}")
            continue
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    for name in dirs:
        path = os.path.join(current, name)
        if os.path.islink(path):
            continue
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError as exc:
            errors.append(f"{path}: {exc}")
            continue
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

if errors:
    for message in errors:
        print(message, file=sys.stderr)
    raise SystemExit(1)
PY
}

ap_assert_tree_has_no_special_files() {
  local tree_root="$1"

  python3 - "$tree_root" <<'PY'
import os, stat, sys

root = sys.argv[1]
found = []

for current, dirs, files in os.walk(root, followlinks=False):
    for name in list(dirs) + list(files):
        path = os.path.join(current, name)
        try:
            mode = os.lstat(path).st_mode
        except OSError:
            continue
        if stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode) or stat.S_ISBLK(mode) or stat.S_ISCHR(mode):
            found.append(path)

if found:
    for path in found:
        print(f"unsafe special file in legacy data: {path}", file=sys.stderr)
    raise SystemExit(1)
PY
}

# Writes a durable per-source content manifest for the verified migration
# backup. Arguments are alternating label and tree path pairs.
ap_write_content_manifest() {
  local destination="$1"
  shift

  python3 - "$destination" "$@" <<'PY'
import hashlib, json, os, stat, sys


def manifest(root):
    records = {}
    for current, dirs, files in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(current, root)
        if rel_dir != ".":
            st = os.lstat(current)
            records[rel_dir] = {"type": "dir", "mode": stat.S_IMODE(st.st_mode)}
        for name in list(dirs) + list(files):
            path = os.path.join(current, name)
            rel = os.path.relpath(path, root)
            if rel in records:
                continue
            st = os.lstat(path)
            mode = stat.S_IMODE(st.st_mode)
            if stat.S_ISLNK(st.st_mode):
                records[rel] = {"type": "link", "mode": mode, "target": os.readlink(path)}
            elif stat.S_ISDIR(st.st_mode):
                records[rel] = {"type": "dir", "mode": mode}
            elif stat.S_ISREG(st.st_mode):
                digest = hashlib.sha256()
                with open(path, "rb") as handle:
                    for chunk in iter(lambda: handle.read(65536), b""):
                        digest.update(chunk)
                records[rel] = {"type": "file", "mode": mode, "size": st.st_size, "sha256": digest.hexdigest()}
            else:
                records[rel] = {"type": "other", "mode": mode}
    return records


destination = sys.argv[1]
pairs = sys.argv[2:]
if len(pairs) % 2 != 0:
    raise SystemExit("content manifest requires label/tree pairs")

sources = {}
for index in range(0, len(pairs), 2):
    sources[pairs[index]] = manifest(pairs[index + 1])

data = {"version": 1, "sources": sources}
tmp_path = destination + ".tmp"
with open(tmp_path, "w") as handle:
    json.dump(data, handle, indent=2)
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, destination)

dir_fd = os.open(os.path.dirname(destination) or ".", os.O_RDONLY)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
}

# Compares a tree against one label in a durable content manifest.
# Exit 0: match; 1: mismatch; 2: manifest or label missing/unreadable.
ap_verify_tree_matches_manifest() {
  local manifest_file="$1"
  local label="$2"
  local tree="$3"

  python3 - "$manifest_file" "$label" "$tree" <<'PY'
import hashlib, json, os, stat, sys


def manifest(root):
    records = {}
    for current, dirs, files in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(current, root)
        if rel_dir != ".":
            st = os.lstat(current)
            records[rel_dir] = {"type": "dir", "mode": stat.S_IMODE(st.st_mode)}
        for name in list(dirs) + list(files):
            path = os.path.join(current, name)
            rel = os.path.relpath(path, root)
            if rel in records:
                continue
            st = os.lstat(path)
            mode = stat.S_IMODE(st.st_mode)
            if stat.S_ISLNK(st.st_mode):
                records[rel] = {"type": "link", "mode": mode, "target": os.readlink(path)}
            elif stat.S_ISDIR(st.st_mode):
                records[rel] = {"type": "dir", "mode": mode}
            elif stat.S_ISREG(st.st_mode):
                digest = hashlib.sha256()
                with open(path, "rb") as handle:
                    for chunk in iter(lambda: handle.read(65536), b""):
                        digest.update(chunk)
                records[rel] = {"type": "file", "mode": mode, "size": st.st_size, "sha256": digest.hexdigest()}
            else:
                records[rel] = {"type": "other", "mode": mode}
    return records


try:
    with open(sys.argv[1], "r") as handle:
        data = json.load(handle)
except Exception:
    print("MISSING-MANIFEST")
    raise SystemExit(2)

sources = data.get("sources")
if data.get("version") != 1 or not isinstance(sources, dict) or sys.argv[2] not in sources:
    print("MISSING-LABEL")
    raise SystemExit(2)

try:
    actual = manifest(sys.argv[3])
except OSError as exc:
    print(f"UNREADABLE-TREE: {exc}")
    raise SystemExit(1)

if actual != sources[sys.argv[2]]:
    print("MISMATCH")
    raise SystemExit(1)

print("MATCH")
PY
}

ap_verify_tree_copy() {
  local source_tree="$1"
  local copy_tree="$2"

  python3 - "$source_tree" "$copy_tree" <<'PY'
import hashlib, json, os, stat, sys


def manifest(root):
    records = {}
    for current, dirs, files in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(current, root)
        if rel_dir != ".":
            st = os.lstat(current)
            records[rel_dir] = {"type": "dir", "mode": stat.S_IMODE(st.st_mode)}
        for name in list(dirs) + list(files):
            path = os.path.join(current, name)
            rel = os.path.relpath(path, root)
            if rel in records:
                continue
            st = os.lstat(path)
            mode = stat.S_IMODE(st.st_mode)
            if stat.S_ISLNK(st.st_mode):
                records[rel] = {"type": "link", "mode": mode, "target": os.readlink(path)}
            elif stat.S_ISDIR(st.st_mode):
                records[rel] = {"type": "dir", "mode": mode}
            elif stat.S_ISREG(st.st_mode):
                digest = hashlib.sha256()
                with open(path, "rb") as handle:
                    for chunk in iter(lambda: handle.read(65536), b""):
                        digest.update(chunk)
                records[rel] = {"type": "file", "mode": mode, "size": st.st_size, "sha256": digest.hexdigest()}
            else:
                records[rel] = {"type": "other", "mode": mode}
    return records


source_manifest = manifest(sys.argv[1])
copy_manifest = manifest(sys.argv[2])

if source_manifest != copy_manifest:
    print("MISMATCH")
    raise SystemExit(1)

print("MATCH")
PY
}

ap_write_backup_manifest() {
  local backup_dir="$1"

  python3 - "$backup_dir" <<'PY'
import hashlib, json, os, stat, sys

backup_dir = sys.argv[1]
records = []

for current, dirs, files in os.walk(backup_dir, followlinks=False):
    for name in list(dirs) + list(files):
        path = os.path.join(current, name)
        rel = os.path.relpath(path, backup_dir)
        if rel == "manifest.json":
            continue
        try:
            st = os.lstat(path)
        except OSError:
            continue
        mode = stat.S_IMODE(st.st_mode)
        if stat.S_ISLNK(st.st_mode):
            records.append({"path": rel, "type": "link", "mode": mode, "target": os.readlink(path)})
        elif stat.S_ISDIR(st.st_mode):
            records.append({"path": rel, "type": "dir", "mode": mode})
        elif stat.S_ISREG(st.st_mode):
            digest = hashlib.sha256()
            with open(path, "rb") as handle:
                for chunk in iter(lambda: handle.read(65536), b""):
                    digest.update(chunk)
            records.append({
                "path": rel,
                "type": "file",
                "mode": mode,
                "size": st.st_size,
                "sha256": digest.hexdigest(),
            })
        else:
            records.append({"path": rel, "type": "other", "mode": mode})

records.sort(key=lambda record: record["path"])

manifest_path = os.path.join(backup_dir, "manifest.json")
tmp_path = manifest_path + ".tmp"
with open(tmp_path, "w") as handle:
    json.dump(records, handle, indent=2)
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(tmp_path, 0o600)
os.replace(tmp_path, manifest_path)

dir_fd = os.open(backup_dir, os.O_RDONLY)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
}

# Refuses a journal-recorded path that traverses a symlink under a known base.
ap_assert_no_symlink_components() {
  local base="$1"
  local target="$2"
  local label="${3:-path}"

  if [[ "$target" != "$base" && "$target" != "$base"/* ]]; then
    ap_die "$EX_LAYOUT" "$label '$target' is not under '$base'"
  fi

  local relative="${target#"$base"}"
  relative="${relative#/}"
  local current="$base"
  local part
  local IFS='/'
  if [[ -n "$relative" ]]; then
    for part in $relative; do
      if [[ -z "$part" || "$part" == "." || "$part" == ".." ]]; then
        ap_die "$EX_LAYOUT" "$label '$target' contains an unsafe path component"
      fi
      current="$current/$part"
      if [[ -L "$current" ]]; then
        ap_die "$EX_LAYOUT" "$label '$target' traverses symbolic link '$current'"
      fi
    done
  fi
}

# Validates an existing private directory recorded in a journal.
ap_validate_existing_private_dir() {
  local directory="$1"
  local label="$2"

  if [[ ! -d "$directory" ]]; then
    ap_die "$EX_LAYOUT" "$label '$directory' no longer exists"
  fi

  local resolved
  if ! resolved=$(realpath -e "$directory" 2>/dev/null); then
    ap_die "$EX_LAYOUT" "$label '$directory' does not resolve to a directory"
  fi

  local owner mode
  owner=$(stat -c "%u" "$resolved" 2>/dev/null || true)
  if [[ "$owner" != "$(id -u)" ]]; then
    ap_die "$EX_LAYOUT" "$label '$resolved' is not owned by the current user"
  fi

  mode=$(stat -c "%a" "$resolved" 2>/dev/null || true)
  if [[ -n "$mode" ]] && ((8#$mode & 8#022)); then
    ap_die "$EX_LAYOUT" "$label '$resolved' is group or world writable (mode $mode)"
  fi

  printf "%s\n" "$resolved"
}
