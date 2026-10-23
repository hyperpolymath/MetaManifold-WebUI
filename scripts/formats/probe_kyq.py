#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Probe pinned kyq source recipes without installing or rewriting anything.

Exit 0 means ONLY that build/wasm/test returned success. It does not establish
parser conformance, an installed executable, or readiness for application use.
Exit 1 = recipe failure; 2 = missing tools, wrong source pin, or other infra.
"""
import argparse
from pathlib import Path
import sys
import tomllib

from process import ToolError, run

ROOT = Path(__file__).resolve().parents[2]


def probe(source, just, timeout):
    with (ROOT / "config/format-tools.toml").open("rb") as stream:
        pin = tomllib.load(stream)["kyq"]
    actual = run(["git", "rev-parse", "HEAD"], cwd=source)
    clean = run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=source)
    if actual.code or actual.stdout.decode().strip() != pin["revision"] or clean.code or clean.stdout:
        raise ToolError("source is not the clean pinned revision")
    version = run([just, "--version"])
    if version.code or version.stdout.decode().strip() != f"just {pin['just_version']}":
        raise ToolError("unexpected just version")
    ok = True
    for recipe in ("build", "wasm", "test"):
        result = run([just, recipe], cwd=source, timeout=timeout)
        print(f"{recipe}: exit={result.code}")
        ok = ok and result.code == 0
    print("install: NOT_RUN (no isolated-prefix contract has been established)")
    print("parser/CLI conformance: NOT_RUN (separate evidence required)")
    print("MetaManifold migration: BLOCKED pending runtime conformance and isolated installation")
    return 0 if ok else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--just", default="just")
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args(argv)
    try:
        return probe(args.source, args.just, args.timeout)
    except (ToolError, OSError, ValueError, KeyError) as error:
        print(f"INFRASTRUCTURE: {type(error).__name__}; kyq readiness not established", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
