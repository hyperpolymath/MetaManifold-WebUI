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

PR_SET_CHILD_SUBREAPER = 36
PR_GET_CHILD_SUBREAPER = 37


class SupervisionError(RuntimeError):
    pass


def _children(pid):
    result = set()
    try:
        tasks = list(Path(f"/proc/{pid}/task").iterdir())
    except FileNotFoundError as error:
        if pid == os.getpid():
            raise SupervisionError("procfs child enumeration unavailable") from error
        return result
    for task in tasks:
        try:
            result.update(int(value) for value in (task / "children").read_text().split())
        except FileNotFoundError as error:
            if pid == os.getpid() and task.name == str(pid):
                raise SupervisionError("procfs children interface unavailable") from error
            # A different process/thread exited during enumeration.
    return result


def _kill_tree(pid):
    pending, stopped = [pid], []
    while pending:
        current = pending.pop()
        try:
            os.kill(current, signal.SIGSTOP)
        except ProcessLookupError:
            # The process exited after its parent list was read; it has no live descendants to freeze.
            continue
        stopped.append(current)
        pending.extend(_children(current))
    for current in reversed(stopped):
        try:
            os.kill(current, signal.SIGKILL)
        except ProcessLookupError:
            # A frozen process can still disappear if it was reaped concurrently.
            continue


class Supervise:
    def __enter__(self):
        if sys.platform != "linux" or threading.active_count() != 1:
            raise SupervisionError("probe requires single-threaded Linux supervision")
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.previous = ctypes.c_int()
        if self.libc.prctl(PR_GET_CHILD_SUBREAPER, ctypes.byref(self.previous), 0, 0, 0) != 0:
            raise SupervisionError("cannot inspect subreaper state")
        if _children(os.getpid()):
            raise SupervisionError("probe requires no pre-existing child processes")
        self._set(1)
        return self

    def _set(self, value):
        if self.libc.prctl(PR_SET_CHILD_SUBREAPER, ctypes.c_ulong(value), 0, 0, 0) != 0:
            raise SupervisionError("cannot set subreaper state")

    def _drain(self):
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            children = _children(os.getpid())
            if not children:
                return
            for pid in children:
                _kill_tree(pid)
                try:
                    os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    # Popen.wait or an earlier nonblocking wait already reaped this child.
                    continue
            remaining = deadline - time.monotonic()
            if remaining > 0:
                # Bounded cleanup; also reap newly adopted orphans.
                time.sleep(min(0.005, remaining))

        # A final census lets a child that exited at the deadline be reaped,
        # and catches anything newly adopted by the subreaper during cleanup.
        children = _children(os.getpid())
        if not children:
            return
        for pid in children:
            _kill_tree(pid)
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                # Another wait already reaped it during the final census.
                continue
        if _children(os.getpid()):
            raise SupervisionError("descendants did not exit within cleanup budget")

    def __exit__(self, *_):
        try:
            self._drain()
        finally:
            self._set(self.previous.value)
