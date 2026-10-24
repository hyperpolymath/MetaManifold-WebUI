#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""Publish distinct native-calibration failure notes as Actions warnings."""

from __future__ import annotations

import csv
from pathlib import Path
import sys

RESULT_FIELDS = [
    "truth",
    "shape",
    "offset",
    "n_per",
    "taxa",
    "sim",
    "taxon",
    "true_log2fc",
    "test",
    "status",
    "pvalue",
    "note",
]
LEGACY_FIELDS = RESULT_FIELDS[:-1]


def _escape_annotation(text: str) -> str:
    """Escape data characters reserved by the GitHub Actions command protocol."""
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def failure_annotations(csv_path: str | Path, cell: str) -> list[str]:
    """Return one warning for each distinct non-empty (test, failure-note) pair."""
    annotations: list[str] = []
    seen: set[tuple[str, str]] = set()
    with Path(csv_path).open(encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames not in (RESULT_FIELDS, LEGACY_FIELDS):
            raise ValueError(f"unexpected CSV header {reader.fieldnames!r}")
        for record_number, row in enumerate(reader, start=2):
            if None in row or any(value is None for value in row.values()):
                raise ValueError(f"malformed CSV record {record_number}")
            if row.get("status") != "failed":
                continue
            note = row.get("note")
            if not note or note == "NA":
                continue
            key = (row.get("test", ""), note)
            if key in seen:
                continue
            seen.add(key)
            message = _escape_annotation(f"{key[0]} :: {note}")
            annotations.append(
                f"::warning title={cell}: a requested test failed::{message}"
            )
    return annotations


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2:
        print(f"usage: {Path(sys.argv[0]).name} RESULTS.csv CELL", file=sys.stderr)
        return 2
    csv_path, cell = args
    try:
        for annotation in failure_annotations(csv_path, cell):
            print(annotation)
    except (OSError, UnicodeError, csv.Error, ValueError) as error:
        print(f"{csv_path}: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
