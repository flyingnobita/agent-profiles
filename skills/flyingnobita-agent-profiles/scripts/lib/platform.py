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
import stat
import sys


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
    for current, _dirs, names in os.walk(scripts):
        for name in names:
            path = os.path.join(current, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            files.append(os.path.relpath(path, skill_dir))
    # Byte order of the full relative path, matching LC_ALL=C sort on find
    # output.
    files.sort(key=lambda value: value.encode())
    lines = []
    for relative in files:
        with open(os.path.join(skill_dir, relative), "rb") as handle:
            lines.append("%s  %s" % (_hash_stream(handle), relative))
    with open(os.path.join(skill_dir, "VERSION"), "rb") as handle:
        lines.append("%s  VERSION" % _hash_stream(handle))
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
        "lock": cmd_lock,
        "manifest": cmd_manifest,
        "manifest-verify": cmd_manifest_verify,
        "realpath": cmd_realpath,
        "stat": cmd_stat,
    }
    handler = handlers.get(command)
    if handler is None:
        return _usage("unknown command: %s" % command)
    return handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
