#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""Negative controls: plant a defect, prove a named test kills it.

A passing test suite is evidence that the code currently agrees with its
assertions. It is not evidence that the assertions can fail. This script makes
the difference checkable by mutating one reviewed decision at a time and
requiring the focused test file to go red.

Every mutant is applied to the real tree, the focused tests are run, and the
file is restored from a saved copy in a finally block. The script refuses to
start when a target file is already modified, so a failed run cannot launder
someone else's working-tree change.

Usage:
    scripts/statistics/mutation_check.py [--julia julia] [--max-mutants N]
                                         [--output FILE]

Exit status:
    0  every planted mutant was killed and the tree was restored
    1  a mutant survived (the tests passed while the defect was present)
    2  the campaign could not run (missing tool, dirty target, bad argument)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class Mutant:
    name: str
    path: str
    old: str
    new: str
    tests: tuple[str, ...]
    description: str


MUTANTS = (
    Mutant(
        name="catalogue-status-draft",
        path="config/defaults/validated_statistics.kyaml",
        old='status: "approved"',
        new='status: "draft"',
        tests=("method_catalogue",),
        description="An unapproved catalogue must not load.",
    ),
    Mutant(
        name="catalogue-cell-limit-drift",
        path="config/defaults/validated_statistics.kyaml",
        old="max_cells: 100000",
        new="max_cells: 100001",
        tests=("method_catalogue",),
        description="A catalogue that advertises more than the code enforces must fail.",
    ),
    Mutant(
        name="request-limit-drift",
        path="src/analysis/numeric_policy.jl",
        old="const MAX_REQUEST_BYTES = 16 * 1024 * 1024",
        new="const MAX_REQUEST_BYTES = 32 * 1024 * 1024",
        tests=("method_catalogue",),
        description="The request limit is owned by one constant; drifting it must fail.",
    ),
    Mutant(
        name="ui-csp-weakened",
        path="src/server/routes/statistics_ui.jl",
        old="\"default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'\"",
        new="\"default-src 'self'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'\"",
        tests=("statistics_ui",),
        description="The script-free page must not be served with a permissive default source.",
    ),
    Mutant(
        name="exact-proportion-becomes-float",
        path="src/analysis/exact_summaries.jl",
        old="proportions[i] = exact_relative_abundance(count, total; policy)",
        new="proportions[i] = exact_fraction(BigInt(round(Int, 1_000_000 * count / total)), 1_000_000; policy)",
        tests=("exact_summaries",),
        description="Replacing an exact proportion with a Float64-derived one must be caught.",
    ),
    Mutant(
        name="zero-total-treated-as-one",
        path="src/analysis/high_precision.jl",
        old="""    if iszero(total)
        return (total=total, richness=richness, shannon=nothing, gini_simpson=nothing)
    end""",
        new="""    if iszero(total)
        return (total=total, richness=richness, shannon=zero(BigFloat), gini_simpson=zero(BigFloat))
    end""",
        tests=("high_precision",),
        description="A zero-total sample must stay undefined, not become zero diversity.",
    ),
)


def _git_status(paths: list[str]) -> str:
    return subprocess.run(
        ["git", "-C", str(ROOT), "status", "--porcelain", "--", *paths],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _run_tests(julia: str, tests: tuple[str, ...], log: Path) -> int:
    command = [julia, "--project=.", "-t2", "--compiled-modules=no",
               "test/runtests.jl", *tests]
    with log.open("wb") as handle:
        handle.write(("$ " + " ".join(command) + "\n").encode())
        handle.flush()
        completed = subprocess.run(command, cwd=ROOT, stdout=handle,
                                   stderr=subprocess.STDOUT)
    return completed.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--julia", default="julia")
    parser.add_argument("--max-mutants", type=int, default=len(MUTANTS))
    parser.add_argument("--output", type=Path,
                        default=Path("mutation-report.json"))
    parser.add_argument("--keep-logs", type=Path, default=None,
                        help="Directory for per-mutant test logs")
    args = parser.parse_args()

    if shutil.which(args.julia) is None:
        print(f"mutation_check: {args.julia} is not on PATH", file=sys.stderr)
        return 2
    if args.max_mutants < 1:
        print("mutation_check: --max-mutants must be at least 1", file=sys.stderr)
        return 2

    selected = MUTANTS[: args.max_mutants]
    paths = sorted({mutant.path for mutant in selected})
    dirty = _git_status(paths)
    if dirty:
        print("mutation_check: refusing to run on a modified target:\n" + dirty,
              file=sys.stderr)
        return 2

    logs = Path(tempfile.mkdtemp(prefix="mutation-logs-"))
    if args.keep_logs is not None:
        args.keep_logs.mkdir(parents=True, exist_ok=True)
        logs = args.keep_logs

    results = []
    survived = []
    for index, mutant in enumerate(selected, start=1):
        target = ROOT / mutant.path
        original = target.read_text(encoding="utf-8")
        if original.count(mutant.old) != 1:
            print(f"mutation_check: '{mutant.name}' anchor matched "
                  f"{original.count(mutant.old)} times in {mutant.path}; refusing",
                  file=sys.stderr)
            return 2
        backup = logs / f"{index:02d}-{mutant.name}.orig"
        backup.write_text(original, encoding="utf-8")
        log = logs / f"{index:02d}-{mutant.name}.log"
        try:
            target.write_text(original.replace(mutant.old, mutant.new, 1),
                              encoding="utf-8")
            code = _run_tests(args.julia, mutant.tests, log)
        finally:
            target.write_text(original, encoding="utf-8")
        if _sha256(target) != _sha256(backup):
            print(f"mutation_check: failed to restore {mutant.path}", file=sys.stderr)
            return 2
        killed = code != 0
        survived.append(mutant.name) if not killed else None
        results.append({
            "name": mutant.name,
            "description": mutant.description,
            "path": mutant.path,
            "tests": list(mutant.tests),
            "killed": killed,
            "exit_code": code,
            "log": str(log),
        })
        print(f"{'KILLED  ' if killed else 'SURVIVED'} {mutant.name}")

    if _git_status(paths):
        print("mutation_check: the tree was not restored", file=sys.stderr)
        return 2

    report = {
        "schema": "metamanifold.statistics-mutation-report.v1",
        "command": "scripts/statistics/mutation_check.py",
        "julia": subprocess.run([args.julia, "--version"], capture_output=True,
                                text=True).stdout.strip(),
        "mutants": results,
        "killed": sum(1 for result in results if result["killed"]),
        "survived": survived,
        "complete": not survived,
    }
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n",
                           encoding="utf-8")
    print(f"mutation_check: {report['killed']}/{len(results)} mutants killed; "
          f"report {args.output}")
    return 0 if report["complete"] else 1


if __name__ == "__main__":
    sys.exit(main())
