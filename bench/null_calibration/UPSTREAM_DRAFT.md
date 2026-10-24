# Draft upstream report: null calibration of the `glm.nb` Wald test

*Status: draft prepared downstream for review before anything is filed
upstream. Every number is from `REPORT.md` in this directory, which defines
exactly what ran, where, and what did not run. This replaces the earlier draft
based on the reduced 2026-10-22 run.*

## Summary

In null simulations that drive the production negative-binomial fitting code
(`MASS::glm.nb` per taxon, fixed-scale Wald test, per-taxon ML theta treated as
known), true nulls are rejected more often than nominal at every measured group
size, including 20 samples per group. At α = 0.05 the rejection rate is 0.172
at 3/group, 0.140 at 4, 0.104 at 6, 0.090 at 8, 0.075 at 12 and 0.064 at 20
(1,000 sims × 40 taxa per cell; every Wilson 95% lower bound is above 0.05).

The mechanism is the standard one: the Wald test plugs in the per-taxon ML
theta and ignores its sampling uncertainty.

Two cheaper alternatives, measured on identical datasets:

- a likelihood-ratio test on the same two `glm.nb` fits removes about a third of
  the excess at 4/group (0.140 → 0.101) but is still anti-conservative in every
  cell;
- a quasi-likelihood F test (`φ` = Pearson X² / residual df, `F = (β/se)²/φ`
  against `F(1, df)`; a tagwise scale, **not** glmGamPoi's or edgeR's
  empirical-Bayes version) is much closer: 0.044 at 3/group (conservative),
  0.055 at 4, 0.058–0.060 through 8, 0.056 at 20. It remains ~1 point above
  nominal, not at nominal.

The inflation is not specific to one data shape: constant dispersion, sparse
zero-heavy tables, unequal library sizes and RLE offsets all reproduce it
(4/group Wald 0.112–0.142; 12/group 0.070–0.081). RLE is not a remedy; at
12/group it was the worst configuration measured.

## What this means for Benjamini–Hochberg

Under a power design (25% of taxa at |log2FC| = 1, 400 sims), BH at 0.05:

| n/group | test | BH power | BH FDR |
|---:|---|---:|---:|
| 4 | Wald (production) | 0.275 | **0.362** |
| 4 | LRT | 0.115 | 0.192 |
| 4 | QL F (`ql_f`) | 0.022 | 0.037 |
| 12 | Wald (production) | 0.536 | **0.118** |
| 12 | LRT | 0.468 | 0.078 |
| 12 | QL F (`ql_f`) | 0.433 | 0.063 |

The default's apparent power advantage at small n is an artefact of an
uncontrolled FDR. The QL F test is the only measured option whose FDR is near
nominal, but at 4/group it is nearly powerless after BH because its F reference
has only six residual degrees of freedom (`F(1,6)` ≈ 5.99, |t| > 2.45).

## Options for the upstream maintainer's consideration

1. **Result-notes caveat for small samples** (adopted downstream). Record a
   calibration caveat with `ml`-dispersion results, scaled by group size.
   Changes no statistic or default. The downstream text is justified unchanged
   by this run: Wald is above nominal at every measured size through 20.
2. **Likelihood-ratio test for the `glm_nb` path.** Measurably closer to nominal
   but still anti-conservative everywhere, slower, and it fails more often at
   tiny n. It is a mitigation, not a calibration fix; the numbers above quantify
   the trade-off.
3. **Quasi-likelihood F test below a group-size threshold.** Closest to nominal
   at every size and the only option with near-nominal BH FDR, but it changes
   critical values substantially at 3–4 samples per group and costs almost all
   BH power there. glmGamPoi's own QL F-test (the calibrated path in the
   downstream issue) is the version worth considering rather than a tagwise
   reimplementation, and it was not measured in this sandbox (see `REPORT.md`
   §"What was not run" for the native-R command).

The downstream recommendation is **1 now, 2 and 3 as an upstream decision**.
A default change would need the glmGamPoi QL F row measured on native R first;
this bench provides the code path and the protocol for it.

## Reproducing

```sh
Rscript -e 'renv::restore()'
# the 16 cells actually run are listed in REPORT.md §"Cells run"
Rscript bench/null_calibration/calibration.R --shapes=original --offsets=tss \
  --n-per=3,4,6,8,12,20 --sims=1000 --taxa=40 --tests=wald_ml,lrt,ql_f
Rscript bench/null_calibration/summarise.R
```

The committed `results/` CSVs carry every rate and interval quoted above;
`results/provenance_summary.csv` carries the executor, the package versions and
the input digests for each cell.
