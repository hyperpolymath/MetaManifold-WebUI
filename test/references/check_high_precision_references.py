#!/usr/bin/env python3
"""Reproduce the independent high-precision known answers used by Julia tests.

Python's decimal module is deliberately independent of Julia/MPFR. No result
produced by the implementation is read here. With --check (the default when a
path is supplied), verify the constants embedded in test_high_precision.jl.
"""
from __future__ import annotations

import argparse
from decimal import Decimal, getcontext
import json
from pathlib import Path
import re
import sys

PRECISION = 220


def references() -> dict[str, str]:
    getcontext().prec = PRECISION
    counts = (1, 2, 3, 4)
    total = sum(counts)
    h = sum(
        -(Decimal(count) / total) * (Decimal(count) / total).ln()
        for count in counts
    )
    return {
        "REF_LN2": str(Decimal(2).ln()),
        "REF_LN3": str(Decimal(3).ln()),
        "REF_TWO_THIRDS": str(Decimal(2) / Decimal(3)),
        "REF_H_1234": str(h),
    }


def check(path: Path, expected: dict[str, str]) -> list[str]:
    text = path.read_text(encoding="utf-8")
    failures = []
    for name, value in expected.items():
        match = re.search(rf'^const {name} = "([^"]+)"$', text, re.MULTILINE)
        if not match:
            failures.append(f"{name}: constant not found")
        elif match.group(1) != value:
            failures.append(f"{name}: embedded reference differs from Python decimal")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("julia_test", nargs="?", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = references()
    if args.check or args.julia_test:
        if not args.julia_test:
            parser.error("--check requires the Julia test path")
        failures = check(args.julia_test, expected)
        if failures:
            print("\n".join(failures), file=sys.stderr)
            return 1
        print(f"Independent decimal references agree ({PRECISION}-digit context).")
        return 0
    print(json.dumps({"decimal_precision": PRECISION, "references": expected}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
