#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""Independent reference values for the exact statistics layer (issue #1).

Why this file exists
--------------------
The Julia tests in `test/unit/test_exact_statistics.jl` assert known answers.
A known answer is only worth something if the number was produced somewhere
other than the implementation under test: comparing an implementation with
itself proves that it is consistently wrong just as well as that it is right.

So the expected values here are computed by a second implementation, written
from the published definitions, in a different language and with different
arithmetic libraries:

  * exact rationals use Python's `fractions.Fraction`;
  * Shannon values use `decimal.Decimal` at 80 significant digits, whose
    `ln()` is a correctly-rounded-to-context implementation, not the same
    algorithm Julia's MPFR call uses;
  * every expected-richness value is checked twice - once with the closed form
    written with `math.comb`, and once by brute-force enumeration over every
    subset of the library (only for libraries small enough to enumerate). The
    two are independent of each other, so a value that agrees with both is
    pinned down rather than merely consistent.

The output is `test/fixtures/statistics_known_answers.json`, which the Julia
suite reads. Regenerate with:

    python3 scripts/statistics-reference.py

and the fixture is rewritten (the script prints nothing else, so it can be
diffed). If the Julia implementation and this reference ever disagree, one of
them has a bug; the fixture is the record of what was agreed at review time.

Scope note: this validates arithmetic and the closed-form expectation. It says
nothing about biological validity, and it does not validate any statistical
method that does not yet exist in the catalogue.
"""

from __future__ import annotations

import json
import math
from decimal import Decimal, getcontext
from fractions import Fraction
from itertools import combinations
from pathlib import Path

getcontext().prec = 80

FIXTURES = Path(__file__).resolve().parent.parent / "test" / "fixtures" / "statistics_known_answers.json"


def simpson(counts: list[int]) -> Fraction:
    """Gini-Simpson complement: 1 - sum(p_i^2), exactly."""
    total = sum(counts)
    if total == 0:
        raise ZeroDivisionError("Simpson index of a sample with zero reads")
    squares = sum(Fraction(c, total) ** 2 for c in counts)
    return 1 - squares


def shannon(counts: list[int]) -> Decimal:
    """-sum(p_i ln p_i) at the ambient Decimal precision."""
    total = Decimal(sum(counts))
    h = Decimal(0)
    for c in counts:
        if c == 0:
            continue
        p = Decimal(c) / total
        h -= p * p.ln()
    return +h


def expected_richness_closed_form(counts: list[int], depth: int) -> Fraction:
    """Hurlbert (1971): sum_i (1 - C(N - n_i, m) / C(N, m))."""
    total = sum(counts)
    if not 1 <= depth <= total:
        raise ValueError("depth out of range")
    denom = math.comb(total, depth)
    s = Fraction(0)
    for c in counts:
        s += 1 - Fraction(math.comb(total - c, depth) if total - c >= depth else 0, denom)
    return s


def expected_richness_brute_force(counts: list[int], depth: int) -> Fraction:
    """Enumerate every subsample of `depth` reads and average the richness.

    Reads are treated as distinguishable individuals, which is exactly the
    without-replacement model the closed form assumes.
    """
    reads: list[int] = []
    for feature, c in enumerate(counts):
        reads.extend([feature] * c)
    total = len(reads)
    if not 1 <= depth <= total or math.comb(total, depth) > 2_000_000:
        raise ValueError("library too large to enumerate")
    observed = Decimal(0)
    n = 0
    for subset in combinations(reads, depth):
        observed += len(set(subset))
        n += 1
    return Fraction(int(observed), n)


def ratio_string(value: Fraction) -> str:
    return f"{value.numerator}/{value.denominator}"


def bytes_to_permutations(counts: list[int]) -> list[list[int]]:
    """The reverse order, used to check that the expectation is permutation-invariant."""
    return list(reversed(counts))


SIMPSON_CASES = [
    [1, 2],
    [1, 1, 1, 1],
    [50, 50],
    [90, 10],
    [1],
    [2, 3, 5, 7, 11],
    [10**6, 3 * 10**6, 0],
    [0, 0, 7],
]

EXPECTED_RICHNESS_CASES = [
    ([2, 3], 1),
    ([2, 3], 2),
    ([2, 3], 5),
    ([1, 1, 1], 2),
    ([5, 0, 0], 3),
    ([10, 20, 30], 15),
    ([1, 2, 3, 4], 5),
    ([4, 4, 4, 4], 8),
]

SHANNON_CASES = [
    [50, 50],
    [90, 10],
    [1, 1, 1],
    [1, 10**9],
    [25, 25, 25, 25],
]

PROPORTION_CASES = [
    [1, 2],
    [3, 3, 3],
    [90, 10],
    [0, 5, 5],
]


def main() -> None:
    fixture: dict = {
        "_provenance": {
            "producer": "scripts/statistics-reference.py",
            "language": "Python " + ".".join(str(v) for v in __import__("sys").version_info[:3]),
            "arithmetic": "fractions.Fraction (exact rationals); decimal.Decimal at 80 digits for logarithms",
            "independence": [
                "written from the published definitions, not ported from the Julia code",
                "expected richness checked against both a closed form and exhaustive subset enumeration",
                "Shannon values computed with Decimal.ln at 80 digits, not MPFR",
            ],
            "does_not_validated": "anything inferential: the layer makes no inference, and no statistical test is validated here",
            "shannon_digits": 60,
        },
        "simpson": [],
        "expected_richness": [],
        "shannon": [],
        "proportions": [],
    }

    for counts in SIMPSON_CASES:
        value = simpson(counts)
        fixture["simpson"].append({
            "counts": counts,
            "value": ratio_string(value),
            "permuted_value": ratio_string(simpson(bytes_to_permutations(counts))),
            "scaled_by_three": ratio_string(simpson([3 * c for c in counts])),
            "display_6": f"{float(value):.6f}",
        })

    for counts, depth in EXPECTED_RICHNESS_CASES:
        closed = expected_richness_closed_form(counts, depth)
        entry = {
            "counts": counts,
            "depth": depth,
            "value": ratio_string(closed),
            "permuted_value": ratio_string(expected_richness_closed_form(bytes_to_permutations(counts), depth)),
            "display_6": f"{float(closed):.6f}",
        }
        try:
            brute = expected_richness_brute_force(counts, depth)
        except ValueError:
            entry["brute_force"] = None
        else:
            if brute != closed:
                raise SystemExit(
                    f"closed form and enumeration disagree for {counts} at depth {depth}: "
                    f"{closed} != {brute}"
                )
            entry["brute_force"] = ratio_string(brute)
        fixture["expected_richness"].append(entry)

    for counts in SHANNON_CASES:
        value = shannon(counts)
        fixture["shannon"].append({
            "counts": counts,
            # 60 significant digits, truncated rather than rounded: the Julia test
            # compares with a tolerance, and a truncated reference cannot be more
            # precise than it claims.
            "value_decimal": str(value.quantize(Decimal(1).scaleb(-60))),
            "digits": 60,
            "double": float(value),
        })

    for counts in PROPORTION_CASES:
        total = sum(counts)
        fixture["proportions"].append({
            "counts": counts,
            "values": [ratio_string(Fraction(c, total)) for c in counts],
        })

    FIXTURES.parent.mkdir(parents=True, exist_ok=True)
    FIXTURES.write_text(json.dumps(fixture, indent=2, sort_keys=False) + "\n")
    print(f"wrote {FIXTURES}")


if __name__ == "__main__":
    main()
