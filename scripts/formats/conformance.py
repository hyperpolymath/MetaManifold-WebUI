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


def _input(case):
    if ("input" in case) == ("hex" in case):
        raise ValueError("case needs exactly one input")
    raw = case.get("input", case.get("hex"))
    if not isinstance(raw, str):
        raise ValueError("input must be a string or hex string")
    return raw.encode("utf-8") if "input" in case else bytes.fromhex(raw)


def _case(case):
    allowed = {"id", "input", "hex", "valid", "canonical"}
    if not isinstance(case, dict) or set(case) - allowed:
        raise ValueError("invalid case fields")
    name = case.get("id", "")
    if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9-]+", name):
        raise ValueError("invalid case id")
    if type(case.get("valid")) is not bool:
        raise ValueError("case needs an explicit verdict")
    if case["valid"] != ("canonical" in case):
        raise ValueError("only valid cases must have canonical bytes")
    expected = case.get("canonical", "")
    if not isinstance(expected, str):
        raise ValueError("canonical bytes must be a UTF-8 string")
    data, encoded = _input(case), expected.encode("utf-8")
    if len(data) > 131072 or len(encoded) > 131072:
        raise ValueError("case exceeds the corpus budget")
    return name, data, case["valid"], encoded


def load_cases(path):
    # Paths come from this repo's constant fixture location or test fixtures,
    # never a CLI-supplied filesystem path. No arbitrary-file reader CLI.
    with Path(path).open("rb") as stream:
        document = tomllib.load(stream)
    if type(document.get("schema")) is not int or document["schema"] != 1:
        raise ValueError("unsupported corpus schema")
    if set(document) != {"schema", "case"}:
        raise ValueError("unsupported corpus fields")
    cases = document["case"]
    if not isinstance(cases, list) or not cases:
        raise ValueError("empty or invalid corpus")
    seen = set()
    for raw in cases:
        case = _case(raw)
        if case[0] in seen:
            raise ValueError("duplicate case id")
        seen.add(case[0])
        yield case


def check(adapter, cases, *, timeout=5.0):
    operation = {"reference": "ijson-canon", "candidate": "kyq-canon"}[adapter]
    passed = True
    for name, data, valid, expected in cases:
        result = run(operation, data, timeout=timeout)
        # Rejection must be the documented invalid-input exit, not a crash,
        # missing library, usage failure from a wrapper, or arbitrary nonzero.
        wanted = 0 if valid else 2
        ok = result.code == wanted and result.stdout == expected
        print(f"{'PASS' if ok else 'FAIL'} {name}")
        passed = passed and ok
    return passed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", choices=("reference", "candidate"), default="reference",
                        help="named installed adapter on trusted PATH, never a command/path")
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args(argv)
    try:
        # Validate the entire corpus before invoking the first child.
        cases = list(load_cases(ROOT / "test/fixtures/formats/ijson-jcs.toml"))
        ok = check(args.adapter, cases, timeout=args.timeout)
        print(f"Corpus: {len(cases)} cases; runtime migration remains separately gated")
        return 0 if ok else 1
    except (ToolError, ValueError, TypeError, OSError) as error:
        # Do not echo paths, source text, child stderr or exception values.
        print(f"INFRASTRUCTURE: {type(error).__name__}; no conformance pass", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
