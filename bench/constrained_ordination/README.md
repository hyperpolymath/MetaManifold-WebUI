<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Constrained Ordination Benchmarks

Opt-in scaling and baseline-regression benchmark harness for `MetaManifold.Ordination` (`RDA`, `CCA`, `CAP`, `dbRDA`, `vegan::anova.cca`, and `vegan::varpart`).

## Running

```bash
# Default fast check (100 samples x 200 features, 999 permutations)
julia --project=. bench/constrained_ordination/benchmark.jl

# Full scaling sweep including 1000 samples x 200 features (999 permutations)
julia --project=. bench/constrained_ordination/benchmark.jl --include-1000

# Canonical RFC 8785 JCS JSON output
julia --project=. bench/constrained_ordination/benchmark.jl --include-1000 --json
```

## Thresholds and Invariants

- **5-minute warning guard**: Any method exceeding `300.0` seconds at `999` permutations is flagged (`exceeds_five_minutes: true`) in alignment with `Ordination.estimate_ordination_seconds` (`warn_five_minutes`).
- **Zero overhead on unconstrained diversity paths**: When `analysis.ordination.method` is `"none"` (the default), existing `Alpha`, `NMDS`, and `PERMANOVA` code paths in `MetaManifold.DiversityMetrics` and `MetaManifold.Analysis` execute unchanged with zero added allocations or runtime regression.
