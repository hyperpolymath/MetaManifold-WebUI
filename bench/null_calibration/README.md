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
| `ql_f` | quasi-likelihood F test on the same full `glm.nb` fit as `lrt`: `φ = Pearson X² / residual df`, `F = (β/se)² / φ` against `F(1, residual df)`. A tagwise dispersion scale, **not** empirical-Bayes shrinkage and **not** glmGamPoi's `test_de` | bench-only candidate |
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
- **Seeds**: a per-cell key hashed from the cell's identity string (truth,
  shape, offset, samples per group, taxa, log2FC), then
  `seed0 + key × 1000003 + sim`. One seed per dataset, so a cell reproduces
  exactly whatever else is requested, in whatever order or process. (It
  previously used the cell's *index* in the invocation, which changed every
  dataset when a grid was split across processes.) The key is recorded in each
  provenance file. Default `seed0 = 20261020` (the #193 seed).

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
  --tests=wald_ml,lrt,ql_f

# the full #193 grid — 1,000 sims per cell; expect hours, use several
# processes by splitting --n-per / --shapes across terminals (with the
# identity-hashed seeds, splitting the grid does not change any dataset)
Rscript bench/null_calibration/calibration.R --mode=full

# aggregate whatever raw cells exist
Rscript bench/null_calibration/summarise.R
```

Outputs append to `results/raw/pvalues_<cell>.csv` (gitignored), one row per
taxon × test. Re-running a cell **resumes** it: simulations whose number is
already in the file are skipped, so an interrupted long cell costs only the
current simulation. Because the per-sim seed is a function of cell identity and
sim number, the resumed rows are the same rows the uninterrupted run would have
written. A cell whose provenance records a different seed key is refused rather
than appended to; delete that cell's two files to start it over.

Each cell also writes `provenance_<cell>.txt` with the arguments, seed and cell
key, executor (webR/native R), package versions, MD5s of `calibration.R` and of
the extracted `_FIT_R` block, and `sessionInfo()`. `summarise.R` writes
`results/calibration_summary.csv`, `power_summary.csv` when power cells exist,
and `provenance_summary.csv` — the run record, generated from the per-cell
provenance files rather than assembled by hand.

### The comparators that need compiled Bioconductor packages

`glmGamPoi` and `edgeR` cannot be installed in every environment. WebR can load
packages compiled for WebAssembly, but cannot load ordinary native R binaries.
The repository's CI already provisions native R from the pinned CRAN repository,
then `renv::restore()` with `glmGamPoi` — so
`.github/workflows/null-calibration-comparators.yml` is a
**manual-dispatch** lane that runs those cells there and, by default, commits the
summary CSVs back to the dispatched branch. Pushing a `null-calibration-*` tag
also triggers it, with results emitted as annotations and an artifact. Ordinary
branch pushes and pull requests do not trigger it: the bench is slow and
stochastic and must not gate anything. `edgeR` is not in `renv.lock` (it is
an outside reference, never an app dependency), so the lane installs it against
the pinned Bioconductor release and every provenance file records its version.

### No native R? The WebR fallback

`webr_run.mjs` runs the same `calibration.R` / `summarise.R` under WebR (R in
WebAssembly) for environments with Node but no R. `glm.nb` is pure R (MASS
7.3-65's `negbin.R` makes no `.C`/`.Call`/`.Fortran` call), so sourcing that
one file provides genuine MASS code; `calibration.R` detects this mode,
strips the block's `MASS::` prefixes as a single mechanical substitution, and
records the fact in every provenance file. This fallback does not provision
WebAssembly builds of glmGamPoi or edgeR; their tests skip loudly when the
packages are unavailable.
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
