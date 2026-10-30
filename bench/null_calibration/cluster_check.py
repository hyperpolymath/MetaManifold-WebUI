#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Dataset-clustered uncertainty for MetaManifold's null-calibration CSVs.

This script does not fit any scientific model. The independent unit is the
simulated *dataset* (sim), not its correlated taxon-level p-values.
The CI is a large-sample normal interval using the cluster-robust standard
error of the ratio of rejected tests to valid tests, suitable for hundreds
of independent simulations, not an exact finite-sample guarantee.
"""
from __future__ import annotations

import argparse
import csv
import io
import math
import sys
import zipfile
from collections import defaultdict
from pathlib import Path
from statistics import NormalDist

VALID = frozenset({"ok", "boundary"})
REQUIRED = frozenset({"sim", "test", "taxon", "status", "pvalue", "true_log2fc"})
Z95 = NormalDist().inv_cdf(0.975)


def _record_null(row, seen, clusters, alpha):
    """Validate a row and accumulate its contribution to a null dataset."""
    method, sim = row["test"], row["sim"]
    if not method or not sim:
        raise ValueError("missing method or simulation identifier")
    taxon = row["taxon"]
    if not taxon:
        raise ValueError("missing taxon identifier")
    key = (method, sim, taxon)
    if key in seen:
        raise ValueError("duplicated (test, sim, taxon) row: " + repr(key))
    seen.add(key)
    # Register every method, even if its dataset lacks null observations.
    # It must fail explicitly instead of disappearing from the report.
    clusters[method]
    try:
        truth = float(row["true_log2fc"])
    except (ValueError, TypeError):
        raise ValueError("invalid true_log2fc") from None
    if not math.isfinite(truth):
        raise ValueError("non-finite true_log2fc")
    if truth != 0:
        return

    counts = clusters[method][sim]
    status = row["status"]
    if status == "failed":
        return
    if status not in VALID:
        raise ValueError("unknown fit status: " + repr(status))
    try:
        pvalue = float(row["pvalue"])
    except (ValueError, TypeError):
        raise ValueError("valid fit has missing or nonnumeric p-value") from None
    if not math.isfinite(pvalue) or not (0 <= pvalue <= 1):
        raise ValueError("valid fit has invalid p-value")
    counts[0] += 1
    counts[1] += pvalue < alpha


def _summarise_method(method, per_sim, min_clusters):
    """Estimate one pooled null rate with simulation-clustered uncertainty."""
    m = len(per_sim)
    if m == 0:
        raise ValueError(f"{method}: no null observations")
    if m < min_clusters:
        raise ValueError(f"{method}: only {m} independent simulation clusters; require {min_clusters}")
    n_total = sum(pair[0] for pair in per_sim.values())
    rejected = sum(pair[1] for pair in per_sim.values())
    if n_total == 0:
        raise ValueError(f"{method}: no valid null tests")
    rate = rejected / n_total
    # Treat independently simulated datasets as clusters, not individual taxa.
    residual_ss = sum((k - rate * n) ** 2 for n, k in per_sim.values())
    se = math.sqrt(m / (m - 1) * residual_ss) / n_total
    return {"test": method, "n_sims": m, "n_pvalues": n_total,
            "n_rejected": rejected, "rate": rate, "cluster_se": se,
            "cluster_95_lo": max(0.0, rate - Z95 * se),
            "cluster_95_hi": min(1.0, rate + Z95 * se)}


def analyse_rows(rows, *, alpha=0.05, min_clusters=30):
    """Summarise null p-values from one benchmark cell, sorted by method.

    ``rows`` must have CSV field names including ``sim``, ``test``, ``status``,
    ``pvalue`` and ``true_log2fc``. Only null rows with status ``ok`` or
    ``boundary`` contribute p-values; failed null rows still count towards the
    number of simulation clusters. A p-value is rejected when it is strictly
    below ``alpha``, which must be between zero and one. Each method needs at
    least ``min_clusters`` simulations containing null rows, with a minimum of
    two clusters.

    Return a list of dictionaries with counts, the pooled rejection rate, its
    cluster standard error and a normal 95% interval clipped to [0, 1]. Return
    an empty list if there are no null rows. Raise ``ValueError`` for invalid
    settings, missing columns, invalid records, duplicate test/simulation/taxon
    keys when a taxon column is present, too few clusters or no valid null
    tests for a method. Errors from the input iterator propagate.
    """
    if not 0 < alpha < 1:
        raise ValueError("alpha must lie strictly between zero and one")
    if min_clusters < 2:
        raise ValueError("at least two independent simulation clusters required")
    missing = REQUIRED - set(rows.fieldnames or ())
    if missing:
        raise ValueError("missing required CSV columns: " + ", ".join(sorted(missing)))
    clusters = defaultdict(lambda: defaultdict(lambda: [0, 0]))
    seen = set()
    for row in rows:
        _record_null(row, seen, clusters, alpha)
    if not clusters:
        raise ValueError("no method records in CSV")
    return [_summarise_method(method, per_sim, min_clusters)
            for method, per_sim in sorted(clusters.items())]


def csv_sources(paths):
    """Yield ``(source, stream)`` pairs for files and matching ZIP members.

    ZIP members are selected when their filename contains ``pvalues_`` and
    ends in ``.csv``; they are yielded in sorted order. ZIP sources use the
    archive's basename followed by the member path. Each UTF-8 text stream is
    open only until this generator advances or closes.

    Raise ``ValueError`` if a ZIP has no matching members. File, ZIP and text
    decoding errors propagate when opening or consuming the streams.
    """
    for path in map(Path, paths):
        if path.suffix.lower() == ".zip":
            with zipfile.ZipFile(path) as z:
                members = sorted(x for x in z.namelist()
                                 if x.endswith(".csv") and "pvalues_" in Path(x).name)
                if not members:
                    raise ValueError(f"{path}: no pvalues_*.csv in ZIP")
                for member in members:
                    with z.open(member) as raw, io.TextIOWrapper(
                            raw, encoding="utf-8", newline="") as f:
                        yield f"{path.name}/{member}", f
        else:
            with path.open(encoding="utf-8", newline="") as f:
                yield str(path), f


def main(argv=None):
    """Write a CSV of per-source, per-method summaries to standard output.

    ``argv`` supplies command-line arguments, or defaults to the process
    arguments. Argument parsing can raise ``SystemExit``; input and analysis
    errors propagate and may leave partial CSV output.
    """
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("files", nargs="+", help="pvalues_*.csv or GitHub Actions artifact ZIP")
    p.add_argument("--alpha", type=float, default=0.05)
    p.add_argument("--min-clusters", type=int, default=30)
    args = p.parse_args(argv)
    fields = ["source", "test", "alpha", "n_sims", "n_pvalues", "n_rejected", "rate",
              "cluster_se", "cluster_95_lo", "cluster_95_hi"]
    writer = csv.DictWriter(sys.stdout, fieldnames=fields)
    writer.writeheader()
    for name, stream in csv_sources(args.files):
        for row in analyse_rows(csv.DictReader(stream), alpha=args.alpha,
                                min_clusters=args.min_clusters):
            writer.writerow({"source": name, "alpha": args.alpha, **row})


if __name__ == "__main__":
    main()
