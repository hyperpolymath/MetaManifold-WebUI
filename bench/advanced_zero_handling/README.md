<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Advanced zero-handling benchmark

This opt-in benchmark measures the reference-backed replacement methods on
100, 1,000 and 10,000 taxa with 24 samples. An additional `--dispersion` flag
measures per-taxon ML and glmGamPoi fixed-dispersion NB fits. The dispersion
flag is separate because 10,000 R GLM fits can take substantially longer than
zero replacement.

Restore `renv.lock` first: zCompositions is required for replacement and both
MASS and glmGamPoi are required for `--dispersion`.

```sh
# Replacement only; JSON goes to stdout.
julia --project=. bench/advanced_zero_handling/benchmark.jl

# Include NB dispersion fits and save the measurements outside Git.
julia --project=. bench/advanced_zero_handling/benchmark.jl \
  --dispersion --output=/tmp/advanced-zero-current.json

# Quick smoke run (not a substitute for the full three-size benchmark).
julia --project=. bench/advanced_zero_handling/benchmark.jl --sizes=100

# Fail if an existing method takes more than 110% of its baseline runtime.
julia --project=. bench/advanced_zero_handling/benchmark.jl \
  --dispersion --baseline=/tmp/advanced-zero-baseline.json
```

Each record reports elapsed seconds, GC seconds, input-matrix size and Julia
allocated bytes. The allocation number includes RCall result copies but cannot
include allocations inside the embedded R runtime; it is not presented as total
RSS. Any individual operation taking more than five minutes emits a warning.
When a baseline is supplied, regressions over 10% in the pre-existing default
Bayesian replacement or ML dispersion path make the script exit unsuccessfully,
so a CI performance job can use the same gate. Baselines must use the same
runner, R package versions, data sizes and dispersion options to be comparable.
