# Null-calibration bench report (issue #193)

This report records the one reduced run that has actually been executed.
Anything not listed here has not been run. The committed summary CSVs in
`results/` (`calibration_summary.csv`, `power_summary.csv`) are the source of
truth for every number below; per-cell run records are summarised in
`results/provenance_summary.csv` (the raw p-value files under `results/raw/`
are gitignored and reproducible from the recorded seeds and arguments).

## Run identity

- **Date:** 2026-10-22 (UTC, per-cell provenance records).
- **Executor:** WebR 0.6.0 (R 4.6.0, wasm32) through `webr_run.mjs`, because the
  sandbox used for this run had Node but no native R. `MASS::glm.nb` was
  provided by sourcing MASS 7.3-65's pure-R `negbin.R` (the exact MASS version
  pinned in `renv.lock`); in that mode `calibration.R` strips the `MASS::`
  prefixes from the extracted production block as a single mechanical
  substitution and records the fact in every provenance file. Native
  `Rscript` runs use the extracted block byte-identically. The sandbox R
  version (4.6.0) differs from the lockfile's R 4.5.0.
- **Production path under test:** the real `_FIT_R` block extracted from
  `src/analysis/differential.jl` (`wald_ml`, `dispersion: ml`), paired on
  identical datasets with a bench-only likelihood-ratio test (`lrt`: full vs
  intercept-only `glm.nb`, each fit estimating its own theta, `2 × ΔlogLik`
  against χ²(1)).
- **Not run in this sandbox:** `wald_trend`, `glmgampoi_ql`, `edger_ql`
  (glmGamPoi/edgeR are compiled Bioconductor packages and were absent — the
  provenance records say so). Their code paths in `calibration.R` are
  unexecuted here and need a native R/Bioconductor run.
- **Cells:** direct replication (original/TSS null) at 3/4/6/8/12/20 samples
  per group, 200 sims × 40 taxa; shape/offset variations (constant, sparse,
  unequal library sizes, original/RLE) at 4 and 12 per group, 150 × 40; power
  cells (original/TSS, 25% of taxa at |log2FC| = 1) at 4 and 12 per group,
  150 × 40. This is a *reduced* run: the full 1,000-sim grid in `README.md`
  has not been run.

## Results

A cell is flagged anti-conservative when the lower bound of the Wilson 95%
interval for its α = 0.05 rejection rate exceeds 0.05. **All 32 summarised
α = 0.05 test-cells were flagged**, including 20 samples per group; the
closest cell was LRT at 20/group on original/TSS (lower bound 0.0534).

### Direct replication (original shape, TSS offset, null)

Rejection rates at α = 0.01 / 0.05 / 0.10. Issue #193 reported Wald at
4/group: 0.060 / 0.132 / 0.198 and 12/group: 0.019 / 0.069 / 0.124 — the
replication lands essentially on those values.

| n/group | sims | `wald_ml` (production) | `lrt` (bench-only) | Wald fit failures | LRT fit failures |
|---:|---:|---|---|---:|---:|
| 3 | 200 | 0.092 / 0.179 / 0.251 | 0.046 / 0.131 / 0.203 | 6.41% | 8.43% |
| 4 | 200 | 0.063 / 0.138 / 0.204 | 0.030 / 0.103 / 0.169 | 2.68% | 3.61% |
| 6 | 200 | 0.045 / 0.111 / 0.171 | 0.023 / 0.087 / 0.149 | 0.79% | 1.20% |
| 8 | 200 | 0.029 / 0.089 / 0.145 | 0.017 / 0.070 / 0.129 | 0.20% | 0.33% |
| 12 | 200 | 0.025 / 0.076 / 0.130 | 0.017 / 0.065 / 0.119 | 0.01% | 0.04% |
| 20 | 200 | 0.019 / 0.065 / 0.116 | 0.014 / 0.058 / 0.110 | 0.00% | 0.00% |

### Other shapes and the RLE offset (α = 0.05, Wilson 95% interval)

| shape / offset | n/group | sims | `wald_ml` | `lrt` | Wald failures | LRT failures |
|---|---:|---:|---|---|---:|---:|
| `constant` / `tss` | 4 | 150 | 0.135 (0.126–0.144) | 0.104 (0.096–0.112) | 4.03% | 5.35% |
| `constant` / `tss` | 12 | 150 | 0.073 (0.066–0.080) | 0.065 (0.059–0.072) | 0.18% | 0.23% |
| `sparse` / `tss` | 4 | 150 | 0.107 (0.098–0.116) | 0.082 (0.074–0.090) | 15.12% | 18.36% |
| `sparse` / `tss` | 12 | 150 | 0.068 (0.062–0.075) | 0.060 (0.054–0.067) | 4.52% | 5.07% |
| `unequal_lib` / `tss` | 4 | 150 | 0.149 (0.140–0.158) | 0.114 (0.106–0.122) | 1.68% | 3.17% |
| `unequal_lib` / `tss` | 12 | 150 | 0.074 (0.068–0.081) | 0.062 (0.056–0.068) | 0.00% | 0.08% |
| `original` / `rle` | 4 | 150 | 0.138 (0.130–0.147) | 0.100 (0.093–0.108) | 2.57% | 3.37% |
| `original` / `rle` | 12 | 150 | 0.080 (0.074–0.087) | 0.068 (0.061–0.074) | 0.02% | 0.02% |

The inflation is not specific to the original mean-varying dispersion shape,
and the RLE offset does not rescue calibration.

### Power and BH behaviour (25% of taxa at |log2FC| = 1)

BH is applied within each simulated dataset over its tested family, as
production does. “Null rate” is the α = 0.05 rejection rate among the truly
null taxa in the same cells.

| n/group | test | sims | null rate @0.05 | raw power | BH power | BH FDR | mean discoveries |
|---:|---|---:|---:|---:|---:|---:|---:|
| 4 | `lrt` | 150 | 0.114 | 0.414 | 0.147 | 0.184 | 1.89 |
| 4 | `wald_ml` | 150 | 0.150 | 0.480 | 0.290 | 0.379 | 4.70 |
| 12 | `lrt` | 150 | 0.083 | 0.668 | 0.422 | 0.101 | 4.82 |
| 12 | `wald_ml` | 150 | 0.096 | 0.688 | 0.509 | 0.129 | 5.99 |

## Interpretation

- #193 replicates. The production fixed-scale Wald test on per-taxon ML theta
  rejects true nulls well above nominal at every measured group size,
  including 20/group (0.065 at α = 0.05).
- The LRT is consistently closer to nominal but remains anti-conservative in
  every cell, and fails more often than Wald at tiny n (it needs two fits).
  It is a mitigation, not a calibration fix.
- Wald's extra BH “power” is bought with uncontrolled FDR (0.38 at 4/group
  against a nominal 0.05). Nothing measured in this sandbox “stays
  calibrated”; the calibrated comparator from #193 (glmGamPoi’s
  quasi-likelihood F-test) still needs the native run.
- Because even 20/group remained flagged, the production calibration caveat
  (see `_calibration_caveat` in `src/analysis/differential.jl`) uses “caution”
  severity through the largest measured size and only drops to “info” beyond
  the measured range. That caveat is fork-side only; any change to upstream
  defaults remains an upstream decision (see `UPSTREAM_DRAFT.md`).

## Checklist mapping (#193)

Done in this reduced run: direct replication at larger sim counts and more
group sizes; additional shapes; RLE offset at 4/12 per group; an additional
test (LRT) on identical datasets; power and BH-FDR at |log2FC| = 1.
Not done: the full 1,000-sim grid; `wald_trend`; glmGamPoi QL F; edgeR QL;
native Rscript/Bioconductor execution; power at other effect/group sizes.
