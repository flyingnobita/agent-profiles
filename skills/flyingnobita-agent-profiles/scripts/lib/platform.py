#!/usr/bin/env python3
"""Internal portability primitives for agent-profiles.

The shipped shell code calls this file through ``scripts/lib/platform.sh``; it
is deliberately not a public command. Every primitive must behave the same with
GNU userland, BSD/macOS userland and stock macOS ``/bin/bash`` 3.2, so only the
Python standard library is used: ``os.path``, ``os.stat``, ``hashlib``,
``subprocess``, ``shutil`` and ``fcntl``.
"""

import errno
import fcntl
import hashlib
import os
import shutil
import signal
import stat
import subprocess
import sys


def _tool_path(override_var, candidates):
    """Resolves a base-system tool, honouring an internal test seam first.

    The seams (AP_DARWIN_PS, AP_DARWIN_LSOF) exist so the Darwin inspector can
    be proven unavailable, or driven from a fixture, inside the test suite.
    They are never user-facing options.
    """
    override = os.environ.get(override_var)
    if override:
        return override
    for candidate in candidates:
        if os.access(candidate, os.X_OK):
            return candidate
    return shutil.which(os.path.basename(candidates[-1]))


def _ps_bin():
    return _tool_path("AP_DARWIN_PS", ("/bin/ps", "/usr/bin/ps", "ps"))


def _lsof_bin():
    return _tool_path("AP_DARWIN_LSOF", ("/usr/sbin/lsof", "/usr/bin/lsof", "lsof"))


def _usage(message):
    sys.stderr.write("platform.py: %s\n" % message)
    return 2


def _hash_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def cmd_script_dir(args):
    if len(args) != 1:
        return _usage("script-dir requires a script path")
    # Follow the entrypoint's symlinks without GNU readlink -f, then resolve the
    # physical directory so LIB_DIR points at the installed skill.
    path = os.path.realpath(args[0])
    sys.stdout.write(os.path.dirname(path) + "\n")
    return 0


def cmd_realpath(args):
    if len(args) != 2:
        return _usage("realpath requires --existing|--missing and a path")
    mode, path = args
    resolved = os.path.realpath(path)
    if mode == "--existing":
        # GNU realpath -e fails when any component, including the last, is
        # missing. Callers depend on that failure to fail closed.
        if not os.path.exists(resolved):
            return 1
    elif mode == "--missing":
        # GNU realpath -m resolves the existing ancestors, keeps a missing tail
        # and never requires the target to exist.
        pass
    else:
        return _usage("unknown realpath mode: %s" % mode)
    sys.stdout.write(resolved + "\n")
    return 0


def cmd_stat(args):
    if len(args) != 2:
        return _usage("stat requires a format and a path")
    fmt, path = args
    try:
        info = os.stat(path)
    except OSError:
        return 1
    if fmt == "size":
        sys.stdout.write("%d\n" % info.st_size)
    elif fmt == "mode":
        sys.stdout.write("%o\n" % stat.S_IMODE(info.st_mode))
    elif fmt == "owner":
        sys.stdout.write("%d\n" % info.st_uid)
    elif fmt == "dev":
        sys.stdout.write("%d\n" % info.st_dev)
    elif fmt == "devino":
        sys.stdout.write("%d:%d\n" % (info.st_dev, info.st_ino))
    else:
        return _usage("unknown stat format: %s" % fmt)
    return 0


def _hash_stream(handle):
    digest = hashlib.sha256()
    for chunk in iter(lambda: handle.read(65536), b""):
        digest.update(chunk)
    return digest.hexdigest()


def cmd_sha256sum(args):
    if len(args) != 1:
        return _usage("sha256sum requires a path")
    path = args[0]
    try:
        with open(path, "rb") as handle:
            digest = _hash_stream(handle)
    except OSError as exc:
        sys.stderr.write("sha256sum: %s: %s\n" % (path, exc))
        return 1
    # Same single-line text as GNU sha256sum, so existing manifests stay valid.
    sys.stdout.write("%s  %s\n" % (digest, path))
    return 0


def cmd_sha256_text(args):
    if args:
        return _usage("sha256-text reads standard input")
    digest = _hash_stream(sys.stdin.buffer)
    sys.stdout.write(digest + "\n")
    return 0


def cmd_manifest(args):
    if len(args) != 1:
        return _usage("manifest requires a skill directory")
    skill_dir = args[0]
    scripts = os.path.join(skill_dir, "scripts")
    files = []
    for current, dirs, names in os.walk(scripts):
        # Bytecode is local build state, not shipped source. The release tar
        # builder and the artifact fingerprint already exclude it, so the
        # setup manifest uses the same file set: a stray .pyc must not change
        # the deployed release digest.
        dirs[:] = [name for name in dirs if name != "__pycache__"]
        for name in names:
            if name.endswith(".pyc"):
                continue
            path = os.path.join(current, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            files.append(os.path.relpath(path, skill_dir))
    # Byte order of the full relative path, matching LC_ALL=C sort on find
    # output.
    files.sort(key=lambda value: value.encode())
    lines = []
    for relative in files + ["VERSION"]:
        path = os.path.join(skill_dir, relative)
        try:
            with open(path, "rb") as handle:
                lines.append("%s  %s" % (_hash_stream(handle), relative))
        except OSError as exc:
            sys.stderr.write("manifest: %s: %s\n" % (path, exc))
            return 1
    sys.stdout.write("\n".join(lines) + "\n")
    return 0


def cmd_manifest_verify(args):
    if len(args) != 2:
        return _usage("manifest-verify requires a base directory and a manifest")
    base, manifest = args
    failures = []
    try:
        handle = open(manifest, "r")
    except OSError as exc:
        sys.stderr.write("manifest-verify: %s: %s\n" % (manifest, exc))
        return 1
    with handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            fields = line.split(None, 1)
            if len(fields) != 2:
                failures.append("%s: improperly formatted manifest line" % manifest)
                continue
            expected, relative = fields[0], fields[1].lstrip("*")
            path = os.path.join(base, relative)
            if os.path.islink(path) or not os.path.isfile(path):
                failures.append("%s: No such file or directory" % path)
                continue
            try:
                with open(path, "rb") as file_handle:
                    actual = _hash_stream(file_handle)
            except OSError as exc:
                failures.append("%s: %s" % (path, exc))
                continue
            if actual != expected:
                failures.append("%s: FAILED" % path)
    if failures:
        for failure in failures:
            sys.stderr.write(failure + "\n")
        return 1
    return 0


def cmd_timeout(args):
    if len(args) < 2:
        return _usage("timeout requires a duration and a command")
    try:
        seconds = float(args[0])
    except ValueError:
        return _usage("timeout duration is not a number: %s" % args[0])
    command = args[1:]
    try:
        # A new session lets a timeout kill the whole probe tree, matching GNU
        # timeout's process-group behaviour.
        process = subprocess.Popen(command, start_new_session=True)
    except OSError as exc:
        sys.stderr.write("timeout: failed to run %s: %s\n" % (command[0], exc))
        return 127
    try:
        code = process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        _kill_group(process, signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            _kill_group(process, signal.SIGKILL)
            process.wait()
        return 124
    if code < 0:
        return 128 + abs(code)
    return code


def _kill_group(process, sig):
    try:
        os.killpg(process.pid, sig)
    except OSError:
        pass


def cmd_copy_preserve(args):
    if len(args) != 2:
        return _usage("copy-preserve requires a source and a destination")
    source, destination = args
    try:
        info = os.lstat(source)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            return 1
        if os.path.lexists(destination):
            # cp -a <dir> <existing-dir> copies inside the destination.
            destination = os.path.join(destination, os.path.basename(source.rstrip("/")))
            if os.path.lexists(destination):
                return 1
        _copy_tree(source, destination)
    except OSError as exc:
        sys.stderr.write("copy-preserve: %s\n" % exc)
        return 1
    return 0


def _copy_tree(source, destination):
    info = os.lstat(source)
    os.mkdir(destination, stat.S_IMODE(info.st_mode))
    for name in sorted(os.listdir(source)):
        source_path = os.path.join(source, name)
        destination_path = os.path.join(destination, name)
        entry = os.lstat(source_path)
        if stat.S_ISLNK(entry.st_mode):
            # Shipped legacy data may contain symlinks; never follow them.
            os.symlink(os.readlink(source_path), destination_path)
        elif stat.S_ISDIR(entry.st_mode):
            _copy_tree(source_path, destination_path)
        elif stat.S_ISREG(entry.st_mode):
            shutil.copyfile(source_path, destination_path)
            shutil.copystat(source_path, destination_path, follow_symlinks=False)
        else:
            raise OSError(errno.EINVAL, "unsupported file type", source_path)
    shutil.copystat(source, destination, follow_symlinks=False)


def _path_under_targets(name, targets):
    if not name or not name.startswith("/"):
        return False
    try:
        resolved = os.path.realpath(name)
    except OSError:
        resolved = name
    for target in targets:
        if resolved == target or resolved.startswith(target + "/"):
            return True
    return False


def _lsof_entries(uid):
    """Maps PID to {comm, names} for the given UID, or None when unavailable."""
    binary = _lsof_bin()
    if not binary:
        return None
    entries = {}
    pid = None
    try:
        proc = subprocess.run(
            [binary, "-n", "-P", "-u", str(uid), "-F", "pcn"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            universal_newlines=True,
        )
    except OSError:
        return None
    # lsof exits 1 when it could not list every open file, which happens
    # routinely for unreadable files and volumes. Anything above that is a real
    # inspection failure and callers must fail closed.
    if proc.returncode not in (0, 1):
        return None
    for line in proc.stdout.splitlines():
        if not line:
            continue
        tag, value = line[0], line[1:]
        if tag == "p":
            pid = int(value) if value.isdigit() else None
            if pid is not None:
                entries.setdefault(pid, {"comm": "", "names": []})
        elif tag == "c" and pid is not None:
            entries[pid]["comm"] = value
        elif tag == "n" and pid is not None:
            entries[pid]["names"].append(value)
    return entries


def _proc_comm(pid):
    try:
        with open("/proc/%d/comm" % pid, "r") as handle:
            return handle.read().strip()
    except OSError:
        return "?"


def _proc_open_names(pid, proc_root):
    """Prints the fd, cwd and exe targets of one process from procfs."""
    names = []
    for entry in (
        os.path.join(proc_root, "%d" % pid, "cwd"),
        os.path.join(proc_root, "%d" % pid, "exe"),
    ):
        try:
            names.append(os.readlink(entry))
        except OSError:
            pass
    fd_dir = os.path.join(proc_root, "%d" % pid, "fd")
    try:
        handles = os.listdir(fd_dir)
    except OSError:
        handles = []
    for handle in handles:
        try:
            names.append(os.readlink(os.path.join(fd_dir, handle)))
        except OSError:
            pass
    return names


def cmd_ps_ppid(args):
    """Prints the parent PID of a live process from ps, for Darwin ancestry."""
    if len(args) != 1:
        return _usage("ps-ppid requires a PID")
    binary = _ps_bin()
    if not binary:
        return 1
    try:
        proc = subprocess.run(
            [binary, "-o", "ppid=", "-p", args[0]],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            universal_newlines=True,
        )
    except OSError:
        return 1
    value = proc.stdout.strip()
    if not value.isdigit():
        return 1
    sys.stdout.write(value + "\n")
    return 0


def _ps_rows():
    """Returns the ps table as dicts, or None when ps cannot be run."""
    binary = _ps_bin()
    if not binary:
        return None
    try:
        proc = subprocess.run(
            [
                binary,
                "-axo",
                "pid=,ppid=,pgid=,uid=,stat=,lstart=,comm=",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            universal_newlines=True,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    rows = []
    for line in proc.stdout.splitlines():
        fields = line.split(None, 10)
        if len(fields) < 10:
            continue
        pid, ppid, pgid, uid, state = fields[:5]
        if not (pid.isdigit() and ppid.isdigit() and uid.isdigit()):
            continue
        rows.append(
            {
                "pid": int(pid),
                "ppid": int(ppid),
                "pgid": int(pgid) if pgid.isdigit() else 0,
                "uid": int(uid),
                "state": state,
                "start": " ".join(fields[5:10]).replace(" ", "_"),
                "comm": fields[10] if len(fields) > 10 else "",
            }
        )
    return rows


def _still_running(starts):
    """Returns the PIDs in starts that are still the same live process.

    ps and lsof are two snapshots. A process that exits between them is in the
    ps table but missing from lsof, which reads as "uninspectable". starts maps
    each candidate PID to its start time from the first ps snapshot. A PID is
    dropped only on positive evidence that the original process is gone: the
    kernel reports no such PID, ps shows it as a zombie, or ps shows a
    different start time because the PID was reused. Anything the re-check
    cannot establish keeps the PID, so a failed probe still fails closed.
    """
    existing = set()
    for pid in starts:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        except OSError:
            pass
        existing.add(pid)
    if not existing:
        return existing
    binary = _ps_bin()
    if not binary:
        return existing
    try:
        proc = subprocess.run(
            [
                binary,
                "-o",
                "pid=,stat=,lstart=",
                "-p",
                ",".join(str(pid) for pid in sorted(existing)),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            universal_newlines=True,
        )
    except OSError:
        return existing
    alive = set(existing)
    for line in proc.stdout.splitlines():
        fields = line.split()
        if len(fields) < 7 or not fields[0].isdigit():
            continue
        pid = int(fields[0])
        if pid not in existing:
            continue
        if "Z" in fields[1]:
            alive.discard(pid)
        elif starts.get(pid) and "_".join(fields[2:7]) != starts[pid]:
            alive.discard(pid)
    return alive


def _comm_label(comm):
    if not comm:
        return "?"
    return os.path.basename(comm) or comm


def _refusal(label, relevant, unknown):
    lines = []
    for pid, comm in relevant:
        lines.append(
            "  PID %d (%s) [relevant: active profile resources in use]" % (pid, comm)
        )
    for pid, comm in unknown:
        lines.append(
            "  PID %d (%s) [relevant-unknown: uninspectable process potentially bound to profile]"
            % (pid, comm)
        )
    if not lines:
        return 0
    sys.stderr.write(
        "agent-profiles: error: refused: active process(es) associated with "
        + label
        + ":\n"
    )
    for line in lines:
        sys.stderr.write(line + "\n")
    sys.stderr.write(
        "Use --assume-unrelated PID[,PID...] to explicitly vouch for unknown uninspectable processes.\n"
    )
    return 75


def _inspection_unavailable(detail):
    """A missing or unreadable probe never means "no process".

    Destructive lifecycle refuses with EX_UNAVAILABLE (69) before any change
    when complete inspection of the current user's processes cannot be
    obtained.
    """
    sys.stderr.write(
        "agent-profiles: error: refused: process inspection is unavailable "
        "(%s); the lifecycle operation refuses rather than assuming that no "
        "process uses this profile\n" % detail
    )
    return 69


def cmd_darwin_proc_scan(args):
    """Refuses while an owned process is bound to a target path on Darwin.

    Procfs does not exist on Darwin, so the evidence comes from stock ps and
    lsof: open descriptors, the inherited profile lease descriptor and the
    working directory. Processes that ps sees but lsof cannot inspect keep the
    Linux relevant-unknown semantics and refuse unless the caller vouches for
    them, so an incomplete probe never means "no process".
    """
    if len(args) < 5:
        return _usage(
            "darwin-proc-scan requires a label, a UID, caller PIDs, assumed PIDs and a target"
        )
    label, uid_text, caller_csv, assume_csv = args[:4]
    targets = [os.path.realpath(path) for path in args[4:] if path]
    if not targets:
        return 0
    try:
        uid = int(uid_text)
    except ValueError:
        return _usage("darwin-proc-scan UID is not a number: %s" % uid_text)

    rows = _ps_rows()
    if rows is None:
        return _inspection_unavailable("ps")
    entries = _lsof_entries(uid)
    if entries is None:
        return _inspection_unavailable("lsof")
    # A probe that reports success but cannot describe even the inspector's own
    # open descriptors has produced incomplete information, not an empty
    # process table. Destructive lifecycle must never read that as "no process".
    if os.getpid() not in entries:
        return _inspection_unavailable(
            "lsof reported no information about the inspector process"
        )

    parents = {row["pid"]: row["ppid"] for row in rows}
    excluded = set(int(value) for value in caller_csv.split() if value.isdigit())
    excluded.add(os.getpid())
    # The inspector inherits the caller's lock descriptors, so its own ps/lsof
    # children hold the profile lease open. Exclude only the inspector's own
    # descendants: a QA session spawned by the caller is a real holder.
    inspector = os.getpid()
    for row in rows:
        ancestor = row["ppid"]
        for _ in range(64):
            if ancestor == inspector:
                excluded.add(row["pid"])
                break
            ancestor = parents.get(ancestor, 0)
            if ancestor <= 1:
                break

    relevant = []
    unknown = []
    inspected = set(entries)

    for pid in sorted(entries):
        if pid in excluded or pid <= 1:
            continue
        record = entries[pid]
        if any(_path_under_targets(name, targets) for name in record["names"]):
            relevant.append((pid, _comm_label(record["comm"])))

    assume_unrelated = set(
        int(value) for value in assume_csv.split(",") if value.strip().isdigit()
    )
    for row in rows:
        pid = row["pid"]
        if pid in excluded or pid <= 1 or pid in inspected:
            continue
        if row["uid"] != uid:
            continue
        # A zombie holds nothing and cannot be bound to a profile.
        if "Z" in row["state"]:
            continue
        if pid in assume_unrelated:
            continue
        if row["ppid"] <= 1:
            unknown.append((pid, _comm_label(row["comm"])))
            continue
        ancestor = row["ppid"]
        for _ in range(64):
            if ancestor in excluded or ancestor <= 1:
                break
            comm = next(
                (_comm_label(item["comm"]) for item in rows if item["pid"] == ancestor),
                None,
            )
            if comm in ("bwrap", "agent-profiles"):
                unknown.append((pid, _comm_label(row["comm"])))
                break
            ancestor = parents.get(ancestor, 0)

    if unknown:
        starts = dict((row["pid"], row["start"]) for row in rows)
        alive = _still_running(dict((pid, starts.get(pid)) for pid, _ in unknown))
        unknown = [(pid, comm) for pid, comm in unknown if pid in alive]

    return _refusal(label, relevant, unknown)


def cmd_boot_identity(args):
    """Prints an opaque identity for the current boot, or fails.

    Live cleanup refuses to signal anything when this is unavailable, so a
    recycled PID from a previous boot can never authorize a signal. Darwin
    reports kern.boottime; Linux reports the kernel boot UUID. The two values
    are never compared with each other.
    """
    if args:
        return _usage("boot-identity takes no arguments")
    sysctl = _tool_path("AP_DARWIN_SYSCTL", ("/usr/sbin/sysctl", "/usr/bin/sysctl", "sysctl"))
    if sysctl:
        try:
            proc = subprocess.run(
                [sysctl, "-n", "kern.boottime"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                universal_newlines=True,
            )
            if proc.returncode == 0:
                fields = proc.stdout.replace(",", " ").split()
                values = {}
                for index, token in enumerate(fields):
                    if token in ("sec", "usec") and index + 2 < len(fields):
                        values[token] = fields[index + 2]
                if "sec" in values:
                    sys.stdout.write(
                        "darwin-%s.%s\n"
                        % (values["sec"], values.get("usec", "0"))
                    )
                    return 0
        except OSError:
            pass
    try:
        with open("/proc/sys/kernel/random/boot_id", "r") as handle:
            value = handle.read().strip()
    except OSError:
        return 1
    if not value:
        return 1
    sys.stdout.write(value + "\n")
    return 0


def _proc_stat_identity(pid):
    try:
        with open("/proc/%s/stat" % pid, "rb") as handle:
            data = handle.read().decode("utf-8", "replace")
    except OSError:
        return None
    end = data.rfind(")")
    if end < 0:
        return None
    fields = data[end + 2:].split()
    if len(fields) < 20:
        return None
    return fields[2], fields[19]


def cmd_process_identity(args):
    """Prints "<process-group> <start-identity>" for one live process.

    The start identity is the platform's own: procfs ticks on Linux and ps
    lstart on Darwin. Callers compare it only for exact equality within one
    boot, so Linux ticks are never compared with Darwin timestamps.
    """
    if len(args) != 2:
        return _usage("process-identity requires a platform and a PID")
    family, pid = args
    if family == "Darwin":
        binary = _ps_bin()
        if not binary:
            return 1
        try:
            proc = subprocess.run(
                [binary, "-o", "pgid=,lstart=", "-p", str(pid)],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                universal_newlines=True,
            )
        except OSError:
            return 1
        line = proc.stdout.strip()
        if not line:
            return 1
        parts = line.split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            return 1
        sys.stdout.write("%s %s\n" % (parts[0], parts[1].strip().replace(" ", "_")))
        return 0
    identity = _proc_stat_identity(pid)
    if identity is None:
        return 1
    sys.stdout.write("%s %s\n" % identity)
    return 0


def cmd_process_uid(args):
    if len(args) != 1:
        return _usage("process-uid requires a PID")
    binary = _ps_bin()
    if not binary:
        return 1
    try:
        proc = subprocess.run(
            [binary, "-o", "uid=", "-p", args[0]],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            universal_newlines=True,
        )
    except OSError:
        return 1
    value = proc.stdout.strip()
    if not value.isdigit():
        return 1
    sys.stdout.write(value + "\n")
    return 0


def cmd_process_holds_path(args):
    """Exits 0 when a process keeps a path, or a path under it, open."""
    if len(args) != 3:
        return _usage("process-holds-path requires a platform, a PID and a path")
    family, pid, path = args
    try:
        target = os.path.realpath(path)
    except OSError:
        target = path
    names = []
    if family == "Darwin":
        binary = _lsof_bin()
        if not binary:
            return 2
        try:
            proc = subprocess.run(
                [binary, "-n", "-P", "-p", str(pid), "-F", "n"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                universal_newlines=True,
            )
        except OSError:
            return 2
        if proc.returncode not in (0, 1):
            return 2
        for line in proc.stdout.splitlines():
            if line.startswith("n"):
                names.append(line[1:])
    else:
        names = _proc_open_names(int(pid), "/proc") if str(pid).isdigit() else []
        if not names:
            return 2
    for name in names:
        if _path_under_targets(name, [target]):
            return 0
    return 1


def cmd_hash_tree(args):
    """Prints a deterministic "hash  ./relative" listing for a directory.

    The live harness records synthetic host trees with this so a comparison
    cannot silently pass on a failed GNU pipeline.
    """
    if len(args) != 1:
        return _usage("hash-tree requires a directory")
    root = args[0]
    entries = []
    for current, dirs, files in os.walk(root):
        dirs.sort()
        for name in files:
            if name in (".checksums.sha256", ".checksums.sha256.tmp"):
                continue
            path = os.path.join(current, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                digest = _hash_file(path)
            except OSError as exc:
                sys.stderr.write("hash-tree: %s: %s\n" % (path, exc))
                return 1
            relative = os.path.relpath(path, root)
            entries.append("%s  ./%s" % (digest, relative))
    entries.sort()
    for entry in entries:
        sys.stdout.write(entry + "\n")
    return 0


def cmd_owned_pids(args):
    """Prints the current user's processes that own a QA profile.

    One ps snapshot and, on Darwin, one lsof pass prove the whole set, so a live
    cleanup never has to start a helper per process. Ownership is the marker in
    the environment on Linux and an open profile lease descriptor or profile
    file on Darwin, where another process's environment cannot be read.
    """
    if len(args) != 3:
        return _usage("owned-pids requires a platform, a profile directory and excluded PIDs")
    family, profile_dir, exclude_csv = args
    if not profile_dir:
        return _usage("owned-pids requires a profile directory")
    excluded = set(int(value) for value in exclude_csv.split() if value.isdigit())
    excluded.add(os.getpid())
    lease = os.path.join(
        os.path.dirname(profile_dir.rstrip("/")),
        ".locks",
        os.path.basename(profile_dir.rstrip("/")) + ".lock",
    )
    targets = [os.path.realpath(profile_dir), os.path.realpath(lease)]
    rows = _ps_rows()
    if rows is None:
        return 1
    uid = os.getuid()
    candidates = [
        row["pid"]
        for row in rows
        if row["uid"] == uid and row["pid"] > 1 and "Z" not in row["state"]
    ]
    owned = []
    if family == "Darwin":
        entries = _lsof_entries(uid)
        if entries is None:
            return 1
        for pid in candidates:
            if pid in excluded:
                continue
            record = entries.get(pid)
            if record is None:
                continue
            if any(_path_under_targets(name, targets) for name in record["names"]):
                owned.append(pid)
    else:
        for pid in candidates:
            if pid in excluded:
                continue
            try:
                with open("/proc/%d/environ" % pid, "rb") as handle:
                    environ = handle.read()
            except OSError:
                continue
            marker = ("AGENT_PROFILES_DIR=" + profile_dir).encode("utf-8", "surrogateescape")
            if marker in environ.split(b"\0"):
                owned.append(pid)
    for pid in sorted(owned):
        sys.stdout.write("%d\n" % pid)
    return 0


def cmd_proc_holders(args):
    """Prints "  PID <pid> (<comm>)" for each process that keeps a path open.

    Advisory diagnostic only: it never signals, never refuses and never prints
    an environment value or command line. Callers use it to name the holder of
    an already-busy lock. Procfs is used on Linux (AP_PROC_ROOT aware) and
    ps/lsof on Darwin.
    """
    if len(args) != 3:
        return _usage("proc-holders requires a platform, a path and caller PIDs")
    family, path, caller_csv = args
    targets = [os.path.realpath(path)]
    callers = set(int(value) for value in caller_csv.split() if value.isdigit())
    holders = []

    if family == "Darwin":
        entries = _lsof_entries(os.getuid())
        if entries is None:
            return 1
        for pid in sorted(entries):
            if pid in callers:
                continue
            if any(_path_under_targets(name, targets) for name in entries[pid]["names"]):
                holders.append((pid, entries[pid]["comm"] or "?"))
    else:
        proc_root = os.environ.get("AP_PROC_ROOT") or "/proc"
        try:
            candidates = sorted(
                int(name)
                for name in os.listdir(proc_root)
                if name.isdigit()
            )
        except OSError:
            return 1
        for pid in candidates:
            if pid in callers:
                continue
            names = _proc_open_names(pid, proc_root)
            if any(_path_under_targets(name, targets) for name in names):
                holders.append((pid, _proc_comm(pid)))

    for pid, comm in holders:
        sys.stdout.write("  PID %d (%s)\n" % (pid, comm))
    return 0


def cmd_lock(args):
    if len(args) != 2:
        return _usage("lock requires a mode and a descriptor")
    mode, descriptor = args
    try:
        fd = int(descriptor)
    except ValueError:
        return _usage("lock descriptor is not a number: %s" % descriptor)
    flags = fcntl.LOCK_SH if mode == "shared" else fcntl.LOCK_EX
    try:
        fcntl.flock(fd, flags | fcntl.LOCK_NB)
    except OSError as exc:
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            return 1
        return 3
    # The lock lives on the open file description shared with the shell, so it
    # stays held after this process exits.
    return 0


def main(argv):
    if len(argv) < 2:
        return _usage("missing command")
    command, args = argv[1], argv[2:]
    handlers = {
        "script-dir": cmd_script_dir,
        "sha256-text": cmd_sha256_text,
        "sha256sum": cmd_sha256sum,
        "boot-identity": cmd_boot_identity,
        "copy-preserve": cmd_copy_preserve,
        "darwin-proc-scan": cmd_darwin_proc_scan,
        "hash-tree": cmd_hash_tree,
        "lock": cmd_lock,
        "proc-holders": cmd_proc_holders,
        "process-holds-path": cmd_process_holds_path,
        "process-identity": cmd_process_identity,
        "process-uid": cmd_process_uid,
        "ps-ppid": cmd_ps_ppid,
        "manifest": cmd_manifest,
        "manifest-verify": cmd_manifest_verify,
        "owned-pids": cmd_owned_pids,
        "realpath": cmd_realpath,
        "stat": cmd_stat,
        "timeout": cmd_timeout,
    }
    handler = handlers.get(command)
    if handler is None:
        return _usage("unknown command: %s" % command)
    return handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
