#!/usr/bin/env python3
"""Internal portability primitives for agent-profiles.

The shipped shell code calls this file through ``scripts/lib/platform.sh``; it
is deliberately not a public command. Every primitive must behave the same with
GNU userland, BSD/macOS userland and stock macOS ``/bin/bash`` 3.2, so only the
Python standard library is used: ``os.path``, ``os.stat``, ``hashlib``,
``subprocess``, ``shutil`` and ``fcntl``.
"""

import os
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


def main(argv):
    if len(argv) < 2:
        return _usage("missing command")
    command, args = argv[1], argv[2:]
    handlers = {
        "script-dir": cmd_script_dir,
        "realpath": cmd_realpath,
    }
    handler = handlers.get(command)
    if handler is None:
        return _usage("unknown command: %s" % command)
    return handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
