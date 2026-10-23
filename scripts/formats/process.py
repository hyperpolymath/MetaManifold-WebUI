# SPDX-License-Identifier: MPL-2.0
"""Bounded POSIX IO for a deliberately closed set of format-probe commands.

Installed tools are trusted executables, not sandboxed plugins. CLI input may
select their location, never a shell command, arbitrary program or arguments.
Child diagnostics can contain secrets and are not printed by the probe CLIs.
"""
import math
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import time
from dataclasses import dataclass

TIMEOUT = "tool exceeded its time budget"
_ALLOWED = {
    "ijson-jcs": {("canon",)},
    "kyq-json-adapter": {("canon",)},
    "git": {("rev-parse", "HEAD"), ("status", "--porcelain", "--untracked-files=all")},
    "just": {(name,) for name in ("--version", "build", "wasm", "test")},
}


class ToolError(RuntimeError):
    """Infrastructure failure; distinct from a tool rejecting a document."""


@dataclass(frozen=True)
class Result:
    code: int
    stdout: bytes
    stderr: bytes


def _command(argv):
    if not argv or not all(isinstance(arg, str) for arg in argv):
        raise ToolError("invalid command")
    location = shutil.which(argv[0])
    if location is None:
        raise ToolError("tool not found")
    program = Path(location).resolve(strict=True)
    # Check the final name, so a symlink to an unrelated executable cannot turn
    # `--tool /path/ijson-jcs` into rm, sh, Python, etc. No arbitrary flags.
    allowed = _ALLOWED.get(program.name, set())
    if tuple(argv[1:]) not in allowed:
        raise ToolError("program or arguments are outside the probe protocol")
    return [str(program), *argv[1:]]


class _Pump:
    def __init__(self, child, data, limit):
        self.child, self.data, self.limit = child, data, limit
        self.offset = 0
        self.total = 0
        self.buffers = {"stdout": bytearray(), "stderr": bytearray()}

    def register(self, selector):
        for stream, label in ((self.child.stdout, "stdout"), (self.child.stderr, "stderr")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, label)
        if not self.data:
            self.child.stdin.close()
            return
        os.set_blocking(self.child.stdin.fileno(), False)
        selector.register(self.child.stdin, selectors.EVENT_WRITE, "stdin")

    def write_input(self, selector, stream):
        try:
            self.offset += os.write(stream.fileno(), self.data[self.offset:self.offset + 16384])
        except BrokenPipeError:
            self.offset = len(self.data)
        except BlockingIOError:
            return
        if self.offset == len(self.data):
            selector.unregister(stream)
            stream.close()

    def read_output(self, selector, stream, label):
        try:
            chunk = os.read(stream.fileno(), 16384)
        except BlockingIOError:
            return
        if not chunk:
            selector.unregister(stream)
            stream.close()
            return
        self.total += len(chunk)
        if self.total > self.limit:
            raise ToolError("tool exceeded its output budget")
        self.buffers[label].extend(chunk)

    def collect(self, deadline):
        with selectors.DefaultSelector() as selector:
            self.register(selector)
            while selector.get_map():
                for key, _ in selector.select(_remaining(deadline)):
                    if key.data == "stdin":
                        self.write_input(selector, key.fileobj)
                    else:
                        self.read_output(selector, key.fileobj, key.data)
        try:
            code = self.child.wait(timeout=_remaining(deadline))
        except subprocess.TimeoutExpired as error:
            raise ToolError(TIMEOUT) from error
        return Result(code, bytes(self.buffers["stdout"]), bytes(self.buffers["stderr"]))


def _remaining(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ToolError(TIMEOUT)
    return remaining


def _cleanup(child):
    # A leader may exit while a descendant keeps a pipe open. Kill its session,
    # not just the leader, so timed-out probes cannot leave children behind.
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait()
    for stream in (child.stdin, child.stdout, child.stderr):
        if not stream.closed:
            stream.close()


def run(argv, data=b"", *, cwd=None, timeout=5.0, limit=131072):
    if not math.isfinite(timeout) or timeout <= 0 or limit <= 0 or len(data) > limit:
        raise ToolError("invalid process budget or oversized test input")
    if os.name != "posix":
        raise ToolError("this probe currently supports POSIX pipe IO only")
    try:
        child = subprocess.Popen(
            _command(argv), cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True, shell=False,
        )
    except OSError as error:
        raise ToolError("tool could not be started") from error
    try:
        return _Pump(child, data, limit).collect(time.monotonic() + timeout)
    finally:
        _cleanup(child)
