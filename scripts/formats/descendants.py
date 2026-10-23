# SPDX-License-Identifier: MPL-2.0
"""Linux-only, single-threaded supervision of trusted probe subprocesses.

A subreaper adopts orphaned descendants even if they call setsid/double-fork.
Restore the previous process-wide setting; refuse pre-existing child contexts.
This is lifecycle management, not a sandbox for adversarial executables.
"""
import ctypes
import os
from pathlib import Path
import signal
import sys
import threading
import time


class SupervisionError(RuntimeError):
    pass


def _children(pid):
    result = set()
    try:
        tasks = list(Path(f"/proc/{pid}/task").iterdir())
    except FileNotFoundError:
        return result
    for task in tasks:
        try:
            result.update(int(value) for value in (task / "children").read_text().split())
        except FileNotFoundError:
            pass  # The process/thread exited during enumeration.
    return result


def _kill_tree(pid):
    pending, stopped = [pid], []
    while pending:
        current = pending.pop()
        try:
            os.kill(current, signal.SIGSTOP)
            stopped.append(current)
            pending.extend(_children(current))
        except ProcessLookupError:
            pass
    for current in reversed(stopped):
        try:
            os.kill(current, signal.SIGKILL)
        except ProcessLookupError:
            pass


class Supervise:
    def __enter__(self):
        if sys.platform != "linux" or threading.active_count() != 1:
            raise SupervisionError("probe requires single-threaded Linux supervision")
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.previous = ctypes.c_int()
        if self.libc.prctl(37, ctypes.byref(self.previous), 0, 0, 0) != 0:
            raise SupervisionError("cannot inspect subreaper state")
        if _children(os.getpid()):
            raise SupervisionError("probe requires no pre-existing child processes")
        self._set(1)
        return self

    def _set(self, value):
        if self.libc.prctl(36, ctypes.c_ulong(value), 0, 0, 0) != 0:
            raise SupervisionError("cannot set subreaper state")

    def _drain(self):
        deadline = time.monotonic() + 0.5
        while True:
            children = _children(os.getpid())
            if not children:
                return
            for pid in children:
                _kill_tree(pid)
                try:
                    os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    pass
            if time.monotonic() >= deadline:
                raise SupervisionError("descendants did not exit within cleanup budget")
            time.sleep(0.005)  # Bounded cleanup; also reap newly adopted orphans.

    def __exit__(self, *_):
        try:
            self._drain()
        finally:
            self._set(self.previous.value)
