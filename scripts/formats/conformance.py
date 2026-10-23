#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Characterize an installed ijson-jcs-compatible `canon` adapter.

Tests original bytes, exact stdout and documented exit codes. No parsing or
canonicalization is implemented in Python. Exit 0 = corpus passed, 1 = mismatch,
2 = infrastructure/configuration failure. This is NOT kyq readiness approval.
"""
import argparse
from pathlib import Path
import re
import sys
import tomllib

from process import ToolError, run

ROOT = Path(__file__).resolve().parents[2]


def load_cases(path):
    with Path(path).open("rb") as stream:
        document = tomllib.load(stream)
    if document.get("schema") != 1 or set(document) != {"schema", "case"}:
        raise ValueError("unsupported corpus schema")
    cases = document["case"]
    if not isinstance(cases, list) or not cases:
        raise ValueError("empty or invalid corpus")
    seen = set()
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("case must be a table")
        allowed = {"id", "input", "hex", "valid", "canonical"}
        if set(case) - allowed:
            raise ValueError("unknown case field")
        name = case.get("id", "")
        if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9-]+", name) or name in seen:
            raise ValueError("invalid or duplicate case id")
        seen.add(name)
        if type(case.get("valid")) is not bool or (("input" in case) == ("hex" in case)):
            raise ValueError("case needs an explicit verdict and exactly one input")
        if case["valid"] != ("canonical" in case):
            raise ValueError("only valid cases must have expected canonical bytes")
        raw = case.get("input", case.get("hex"))
        if not isinstance(raw, str):
            raise ValueError("input must be a string or hex string")
        data = case["input"].encode("utf-8") if "input" in case else bytes.fromhex(case["hex"])
        if case["valid"] and not isinstance(case["canonical"], str):
            raise ValueError("canonical bytes must be a UTF-8 string")
        expected = case["canonical"].encode("utf-8") if case["valid"] else b""
        if len(data) > 131072 or len(expected) > 131072:
            raise ValueError("case exceeds the corpus budget")
        yield name, data, case["valid"], expected


def check(executable, cases, *, timeout=5.0):
    passed = True
    for name, data, valid, expected in cases:
        result = run([executable, "canon"], data, timeout=timeout)
        # Rejection must be the documented invalid-input exit, not a crash,
        # missing library, usage failure from a wrapper, or arbitrary nonzero.
        wanted = 0 if valid else 2
        ok = result.code == wanted and result.stdout == expected
        print(f"{'PASS' if ok else 'FAIL'} {name}")
        passed = passed and ok
    return passed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", required=True, help="installed binary or canon-protocol adapter")
    parser.add_argument("--corpus", type=Path, default=ROOT / "test/fixtures/formats/ijson-jcs.toml")
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args(argv)
    try:
        # Validate the entire corpus before invoking the first child.
        cases = list(load_cases(args.corpus))
        ok = check(args.tool, cases, timeout=args.timeout)
        print(f"Corpus: {len(cases)} cases; runtime migration remains separately gated")
        return 0 if ok else 1
    except (ToolError, ValueError, TypeError, OSError) as error:
        # Do not echo paths, source text, child stderr or exception values.
        print(f"INFRASTRUCTURE: {type(error).__name__}; no conformance pass", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
