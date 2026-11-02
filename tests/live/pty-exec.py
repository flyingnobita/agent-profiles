#!/usr/bin/env python3
"""Standard-library PTY driver for live agent QA.

Stock macOS has no util-linux ``script -qfc``, so every interactive TUI probe in
``tests/live`` runs through this driver instead: it allocates a pseudo-terminal,
sets the window size, starts the command in a new session (so the whole probe is
one process group) and copies bytes between the caller and the terminal until the
command exits. Only the Python standard library is used, so the same command
works on Linux and macOS.
"""

import errno
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time


def _usage(message):
    sys.stderr.write("pty-exec: %s\n" % message)
    return 64


def _terminate(process):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except OSError:
            pass
        try:
            process.wait(timeout=2)
            return
        except subprocess.TimeoutExpired:
            continue


def _run(command, rows, cols, timeout):
    master, slave = pty.openpty()
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass
    try:
        process = subprocess.Popen(
            command,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            start_new_session=True,
            close_fds=True,
        )
    except OSError as exc:
        os.close(master)
        os.close(slave)
        sys.stderr.write("pty-exec: failed to run %s: %s\n" % (command[0], exc))
        return 127
    os.close(slave)

    try:
        stdin_fd = sys.stdin.fileno()
    except (AttributeError, OSError, ValueError):
        stdin_fd = None
    stdout_fd = sys.stdout.fileno()
    deadline = time.time() + timeout if timeout else None
    exit_code = 0

    while True:
        readable_fds = [master]
        if stdin_fd is not None:
            readable_fds.append(stdin_fd)
        wait = None
        if deadline is not None:
            wait = deadline - time.time()
            if wait <= 0:
                _terminate(process)
                exit_code = 124
                break
        try:
            ready, _, _ = select.select(readable_fds, [], [], wait)
        except (OSError, select.error):
            break
        if not ready:
            _terminate(process)
            exit_code = 124
            break
        if master in ready:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    chunk = b""
                else:
                    raise
            if not chunk:
                break
            _write_all(stdout_fd, chunk)
        if stdin_fd is not None and stdin_fd in ready:
            try:
                chunk = os.read(stdin_fd, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                stdin_fd = None
            else:
                _write_all(master, chunk)

    try:
        code = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        _terminate(process)
        code = 124
    try:
        os.close(master)
    except OSError:
        pass
    if exit_code:
        return exit_code
    if code < 0:
        return 128 + abs(code)
    return code


def _write_all(fd, chunk):
    while chunk:
        try:
            written = os.write(fd, chunk)
        except OSError:
            return
        chunk = chunk[written:]


def main(argv):
    rows, cols, timeout = 40, 120, 0.0
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument == "--":
            index += 1
            break
        if argument == "--rows" and index + 1 < len(argv):
            rows = int(argv[index + 1])
            index += 2
            continue
        if argument == "--cols" and index + 1 < len(argv):
            cols = int(argv[index + 1])
            index += 2
            continue
        if argument == "--timeout" and index + 1 < len(argv):
            timeout = float(argv[index + 1])
            index += 2
            continue
        if argument in ("-h", "--help"):
            sys.stdout.write(
                "Usage: pty-exec.py [--rows N] [--cols N] [--timeout SECONDS] -- COMMAND...\n"
            )
            return 0
        break
    command = argv[index:]
    if not command:
        return _usage("missing command")
    return _run(command, rows, cols, timeout)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
