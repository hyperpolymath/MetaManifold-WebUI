# SPDX-License-Identifier: MPL-2.0
"""Bounded POSIX subprocess IO for format-tool probes, never a shell command.

Do not print child diagnostics: parser diagnostics can contain input secrets.
This is test tooling, not an application parser or an alternative canonicalizer.
"""
import math
import os
import selectors
import signal
import subprocess
import time
from dataclasses import dataclass


class ToolError(RuntimeError):
    """Infrastructure failure; distinct from a tool rejecting a document."""


@dataclass(frozen=True)
class Result:
    code: int
    stdout: bytes
    stderr: bytes


def run(argv, data=b"", *, cwd=None, timeout=5.0, limit=131072):
    if not math.isfinite(timeout) or timeout <= 0 or limit <= 0 or len(data) > limit:
        raise ToolError("invalid process budget or oversized test input")
    if os.name != "posix":
        raise ToolError("this probe currently supports POSIX pipe IO only")
    try:
        child = subprocess.Popen(
            argv, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True,
        )
    except OSError as error:
        raise ToolError("tool could not be started") from error
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    deadline = time.monotonic() + timeout
    offset = 0
    total = 0
    try:
        with selectors.DefaultSelector() as selector:
            for stream, label in ((child.stdout, "stdout"), (child.stderr, "stderr")):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, label)
            if data:
                os.set_blocking(child.stdin.fileno(), False)
                selector.register(child.stdin, selectors.EVENT_WRITE, "stdin")
            else:
                child.stdin.close()
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ToolError("tool exceeded its time budget")
                for key, _ in selector.select(remaining):
                    stream = key.fileobj
                    if key.data == "stdin":
                        try:
                            offset += os.write(stream.fileno(), data[offset:offset + 16384])
                        except BrokenPipeError:
                            offset = len(data)
                        except BlockingIOError:
                            continue
                        if offset == len(data):
                            selector.unregister(stream)
                            stream.close()
                    else:
                        try:
                            chunk = os.read(stream.fileno(), 16384)
                        except BlockingIOError:
                            continue
                        if not chunk:
                            selector.unregister(stream)
                            stream.close()
                            continue
                        total += len(chunk)
                        if total > limit:
                            raise ToolError("tool exceeded its output budget")
                        buffers[key.data].extend(chunk)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ToolError("tool exceeded its time budget")
        try:
            code = child.wait(timeout=remaining)
        except subprocess.TimeoutExpired as error:
            raise ToolError("tool exceeded its time budget") from error
        return Result(code, bytes(buffers["stdout"]), bytes(buffers["stderr"]))
    finally:
        # Kill the session even if its leader exited but descendants kept a pipe
        # open. A hung descendant must not outlive a timed-out probe.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        for stream in (child.stdin, child.stdout, child.stderr):
            if not stream.closed:
                stream.close()
