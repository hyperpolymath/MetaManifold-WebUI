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
REQUIRED = frozenset({"sim", "test", "status", "pvalue", "true_log2fc"})
Z95 = NormalDist().inv_cdf(0.975)


def analyse_rows(rows, *, alpha=0.05, min_clusters=30):
    """Return per-method rows from one benchmark cell's raw p-value records."""
    if not (0 < alpha < 1):
        raise ValueError("alpha must lie strictly between zero and one")
    if min_clusters < 2:
        raise ValueError("at least two independent simulation clusters required")
    if not REQUIRED <= set(rows.fieldnames or ()):
        raise ValueError("missing required CSV columns: " +
                         ", ".join(sorted(REQUIRED - set(rows.fieldnames or ()))))
    clusters = defaultdict(lambda: defaultdict(lambda: [0, 0]))
    seen = set()
    for row in rows:
        method, sim = row["test"], row["sim"]
        if not method or not sim:
            raise ValueError("missing method or simulation identifier")
        if "taxon" in row:
            key = (method, sim, row["taxon"])
            if key in seen:
                raise ValueError("duplicated (test, sim, taxon) row: " + repr(key))
            seen.add(key)
        try:
            null = float(row["true_log2fc"]) == 0
        except (ValueError, TypeError):
            raise ValueError("invalid true_log2fc") from None
        if not null:
            continue
        pair = clusters[method][sim]
        if row["status"] in VALID:
            try:
                p = float(row["pvalue"])
            except (ValueError, TypeError):
                raise ValueError("valid fit has missing or nonnumeric p-value") from None
            if not math.isfinite(p) or not 0 <= p <= 1:
                raise ValueError("valid fit has invalid p-value")
            pair[0] += 1
            pair[1] += p < alpha
        elif row["status"] != "failed":
            raise ValueError("unknown fit status: " + repr(row["status"]))
    out = []
    for method, per_sim in sorted(clusters.items()):
        m = len(per_sim)
        if m < min_clusters:
            raise ValueError(f"{method}: only {m} independent simulation clusters; require {min_clusters}")
        N = sum(z[0] for z in per_sim.values())
        K = sum(z[1] for z in per_sim.values())
        if N == 0:
            raise ValueError(f"{method}: no valid null tests")
        rate = K / N
        # One independent cluster per simulated dataset. The m/(m-1)
        # correction and ratio-of-totals residuals permit any dependence
        # of taxa *within* a simulated dataset.
        ss = sum((k - rate * n) ** 2 for n, k in per_sim.values())
        se = math.sqrt(m / (m - 1) * ss) / N
        out.append({"test": method, "n_sims": m, "n_pvalues": N,
                    "n_rejected": K, "rate": rate, "cluster_se": se,
                    "cluster_95_lo": max(0.0, rate - Z95 * se),
                    "cluster_95_hi": min(1.0, rate + Z95 * se)})
    return out


def csv_sources(paths):
    """Yield CSV streams, including raw pvalues_*.csv members of ZIP archives."""
    for path in map(Path, paths):
        if path.suffix.lower() == ".zip":
            with zipfile.ZipFile(path) as z:
                members = sorted(x for x in z.namelist()
                                 if x.endswith(".csv") and "pvalues_" in Path(x).name)
                if not members:
                    raise ValueError(f"{path}: no pvalues_*.csv in ZIP")
                for member in members:
                    with z.open(member) as raw:
                        with io.TextIOWrapper(raw, encoding="utf-8", newline="") as f:
                            yield f"{path.name}/{member}", f
        else:
            with path.open(encoding="utf-8", newline="") as f:
                yield str(path), f


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("files", nargs="+", help="pvalues_*.csv or GitHub Actions artifact ZIP")
    p.add_argument("--alpha", type=float, default=0.05)
    p.add_argument("--min-clusters", type=int, default=30)
    args = p.parse_args(argv)
    fields = ["source", "test", "n_sims", "n_pvalues", "n_rejected", "rate",
              "cluster_se", "cluster_95_lo", "cluster_95_hi"]
    writer = csv.DictWriter(sys.stdout, fieldnames=fields)
    writer.writeheader()
    for name, stream in csv_sources(args.files):
        for row in analyse_rows(csv.DictReader(stream), alpha=args.alpha,
                                min_clusters=args.min_clusters):
            writer.writerow({"source": name, **row})


if __name__ == "__main__":
    main()
