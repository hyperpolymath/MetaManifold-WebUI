# Null-calibration bench for `nb_glm` (issue #193)

Issue #193 measured that the default `nb_glm` path — `MASS::glm.nb` per taxon
with a fixed-scale Wald test, `analysis.differential.dispersion: ml` — rejects
true nulls too often in small studies (nominal 0.05 rejecting at 0.132 with 4
samples per group and 0.069 with 12). The mechanism is textbook: the Wald test
treats the per-taxon maximum-likelihood theta as known, ignoring its sampling
uncertainty, which is large when groups are small.

This bench replicates that finding at the scale #193 asked for, measures the
candidate remedies on identical datasets, and records what was actually run.
It is a bench, not a unit test: slow, stochastic, never run by CI.

## What is compared

Every simulated dataset is analysed by every enabled test (paired design — no
test gets an easier dataset):

| test | what it is | status |
|---|---|---|
| `wald_ml` | the production default, through the real `_FIT_R` block extracted from `src/analysis/differential.jl` (`da_use_gp = FALSE`) | production |
| `wald_trend` | the production `dispersion: glmGamPoi` option on this branch, through the same block (`da_use_gp = TRUE`): dispersion trend plugged into a fixed-theta Wald fit. **Not** a quasi-likelihood test | production option |
| `lrt` | `MASS::glm.nb` likelihood-ratio test, full vs intercept-only, each fit estimating its own theta; `2 × ΔlogLik` against χ²(1) | bench-only candidate |
| `glmgampoi_ql` | glmGamPoi's own quasi-likelihood F-test (`glm_gp` + `test_de`, numeric contrast weights) | reference (the calibrated path in #193) |
| `edger_ql` | edgeR's quasi-likelihood F-test, fed the same offsets | outside reference only, not a dependency |

A test whose package is unavailable is skipped loudly (stdout + provenance
file), never silently replaced.

## Protocol (mapped to #193's checklist)

- **Group sizes** `n ∈ {3, 4, 6, 8, 12, 20}` per group, equal groups.
- **Summaries**: rejection rates at α = 0.01 / 0.05 / 0.10 with Wilson 95%
  intervals, Kolmogorov–Smirnov D and p of the null p-values against
  Uniform(0, 1), and per-test fit-failure shares (`summarise.R`).
- **Data shapes** (`--shapes`):
  - `original` — the #193 generator: taxon means exp(U(log 2, log 500)),
    dispersion `0.05 + 2/√μ`, library sizes lognormal(0, 0.3);
  - `constant` — same means, dispersion 0.5 for every taxon;
  - `sparse` — amplicon-like: means exp(N(log 3, 1.6)), so most taxa are rare
    and a few dominate; many zeros;
  - `unequal_lib` — `original` with group B library sizes ×2.5.
- **Offsets** (`--offsets`): `tss` and `rle`, implemented to mirror
  `tss_factors` / `rle_factors` in `differential.jl`. An RLE refusal (no taxon
  present in every sample) is counted, never replaced by TSS.
- **Power** (`--truth=power --log2fc=L`): 25% of taxa truly change by ±L (log2),
  the rest are null. Reports raw and BH power on the changed taxa, the BH
  false discovery rate at 0.05 (averaged per dataset, BH applied within each
  dataset over its tested family, as production does), and null-taxon
  calibration within the same cells.
- **Taxa filter**: the #193 script's filter is kept for fidelity — a taxon
  needs reads in ≥2 samples and non-constant counts. Taxon parameters are
  redrawn for every dataset, as in #193. Datasets with <5 testable taxa are
  skipped and counted.
- **Seeds**: `seed0 + cell_index × 1000003 + sim`, one per dataset, so cells
  can run in any order or in parallel processes and reproduce exactly.
  Default `seed0 = 20261020` (the #193 seed).

### Reading a cell

A test is **flagged anti-conservative** in a cell when the lower bound of the
Wilson 95% interval for its rejection rate at α = 0.05 exceeds 0.05, and
**flagged conservative** when the upper bound is below 0.05. The KS statistic
is supporting evidence, not the criterion — with ~10⁴ p-values it detects
departures too small to matter at any single α.

## Running it

Native R with the pinned library (the supported route; `Rscript -e
'renv::restore()'` first):

```sh
# smoke: 10 sims, one cell, a few seconds
Rscript bench/null_calibration/calibration.R --mode=quick

# one direct-replication cell
Rscript bench/null_calibration/calibration.R \
  --shapes=original --offsets=tss --n-per=4 --sims=200 --taxa=40 \
  --tests=wald_ml,lrt

# the full #193 grid — 1,000 sims per cell; expect hours, use several
# processes by splitting --n-per / --shapes across terminals
Rscript bench/null_calibration/calibration.R --mode=full

# aggregate whatever raw cells exist
Rscript bench/null_calibration/summarise.R
```

Outputs append to `results/raw/pvalues_<cell>.csv` (gitignored), one row per
taxon × test, so an interrupted run keeps finished simulations; each cell also
writes `provenance_<cell>.txt` with arguments, package versions and
`sessionInfo()`. `summarise.R` writes `results/calibration_summary.csv` (and
`power_summary.csv` when power cells exist).

### No native R? The WebR fallback

`webr_run.mjs` runs the same `calibration.R` / `summarise.R` under WebR (R in
WebAssembly) for environments with Node but no R. `glm.nb` is pure R (MASS
7.3-65's `negbin.R` makes no `.C`/`.Call`/`.Fortran` call), so sourcing that
one file provides genuine MASS code; `calibration.R` detects this mode,
strips the block's `MASS::` prefixes as a single mechanical substitution, and
records the fact in every provenance file. glmGamPoi and edgeR are compiled
Bioconductor packages and cannot run this way — their tests skip loudly.
Setup and usage are in the header of `webr_run.mjs`. Prefer native Rscript
whenever it exists.

## What has actually been run

`REPORT.md` records each committed run: cells, sizes, environment and results,
with the corresponding summary CSVs in `results/`. Anything not in `REPORT.md`
has not been run — in particular, a committed bench is not a result.

## Limitations (read before quoting rates)

- Taxa are simulated independently. Real amplicon tables are compositional and
  correlated; independence makes BH behaviour here cleaner than in practice.
- Groups are equal-sized. Unequal groups change both theta estimation and
  offset behaviour; #193's grid did not cross that factor either.
- The ≥2-sample presence filter mirrors #193, not production's default
  `min_prevalence = 0` (under which untestable taxa instead surface as failed
  rows outside the BH family). Failure shares are reported so the tested
  family is never a hidden denominator.
- `original`-shape library sizes are mild (lognormal σ = 0.3). Harsher depth
  variation is covered only through `unequal_lib`'s group shift.
