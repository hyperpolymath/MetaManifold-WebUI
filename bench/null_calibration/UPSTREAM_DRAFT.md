# Draft upstream report: null calibration of the `glm.nb` Wald test

*Status: draft prepared downstream for maintainer review; it has not been filed
upstream. It includes the completed native comparator run #40091522843.
`REPORT.md` and the run-specific summary/provenance CSVs define exactly what ran,
where, and what remains unmeasured. This replaces the earlier draft based on
the reduced 2026-10-22 run and does not recommend an automatic default change.*

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

## Native Bioconductor comparators

The successful [native-R Actions run 40091522843](https://github.com/hyperpolymath/MetaManifold-WebUI/actions/runs/40091522843) used the same seeded null designs at original shape/TSS, n=4 and n=12, configured for 1,000 simulations × 40 taxa per cell (R 4.5.0, glmGamPoi 1.22.0, edgeR 4.8.2):

| n/group | comparator | summary rows (`n_attempted`) | p-values (failed fits) | α=0.05 (Wilson 95% CI) | verdict |
|---:|---|---:|---:|---|---|
| 4 | glmGamPoi QL F (`glmgampoi_ql`) | 39,993 | 39,904 (89) | **0.0525** (0.0503–0.0547) | narrowly anti-conservative |
| 4 | edgeR QL F (`edger_ql`) | 39,993 | 39,904 (89) | **0.0687** (0.0663–0.0713) | anti-conservative |
| 4 | glmGamPoi trend Wald (`wald_trend`) | 39,993 | 39,904 (89) | **0.0838** (0.0811–0.0865) | anti-conservative |
| 12 | glmGamPoi QL F (`glmgampoi_ql`) | 40,000 | 40,000 (0) | 0.0499 (0.0478–0.0520) | not flagged |
| 12 | edgeR QL F (`edger_ql`) | 40,000 | 40,000 (0) | **0.0712** (0.0687–0.0737) | anti-conservative |
| 12 | glmGamPoi trend Wald (`wald_trend`) | 40,000 | 40,000 (0) | **0.0764** (0.0739–0.0791) | anti-conservative |

“Not flagged” means the Wilson interval includes 0.05; it is not proof of exact calibration. The summary's `n_attempted` field is computed as `nrow(d)`, the rows present in each per-test output; the `taxa=40` setting is the raw design size, not an observed post-filter testing denominator. At n=4, the summary reports 39,904 p-values and 89 failed fits (39,993 output rows total); seven positions from the configured 40,000 taxon-simulation design are absent from the summary, and their disposition is unresolved. Rejection rates use the 39,904 reported p-values; do not assign the seven absent positions to successes or failures or treat the 40,000 design count as an observed testing denominator. At n=12, the summary reports 40,000 p-values and no failed fits. The native comparator lane tested nulls only: it did not measure power, BH-FDR under alternatives, other sample sizes, or other shapes/offsets. The complete 12-row output and per-cell provenance are retained in `results/native_comparator_summary_run_40091522843.csv` and `results/native_comparator_provenance_run_40091522843.csv`.

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
uncontrolled FDR. Among the three methods included in this power design, the
tagwise QL F test is closest to nominal FDR, but at 4/group it is nearly
powerless after BH because its F reference has only six residual degrees of
freedom (`F(1,6)` ≈ 5.99, |t| > 2.45). The native Bioconductor comparator run
was null-only and did not measure their power or FDR under alternatives.

## Options for the upstream maintainer's consideration

1. **Result-notes caveat for small samples** (adopted downstream). Record a
   calibration caveat with `ml`-dispersion results, scaled by group size.
   Changes no statistic or default. The downstream text is justified unchanged
   by this run: Wald is above nominal at every measured size through 20.
2. **Likelihood-ratio test for the `glm_nb` path.** Measurably closer to nominal
   but still anti-conservative everywhere, slower, and it fails more often at
   tiny n. It is a mitigation, not a calibration fix; the numbers above quantify
   the trade-off.
3. **Consider glmGamPoi's QL F test below a group-size threshold.** The native
   null run places it closest to nominal among the two Bioconductor QL tests:
   0.0525 at 4/group (Wilson 95% CI 0.0503–0.0547, narrowly anti-conservative)
   and 0.0499 at 12/group (0.0478–0.0520, not flagged). edgeR QL is higher at
   0.0687 and 0.0712. The separate `wald_trend` row is a glmGamPoi
   dispersion-trend Wald test, not its QL test; the production fixed-θ Wald
   path must not be described as glmGamPoi QL. These comparator cells are
   null-only: they do not measure power/BH behaviour, other sample sizes, or
   other shapes/offsets. The tagwise `ql_f` power results therefore cannot be
   transferred to glmGamPoi QL. The measured row makes option 3 discussable,
   not an automatic default recommendation.

The downstream recommendation remains **1 now, 2 and 3 as an upstream
maintainer decision**. The native run fills the requested QL calibration cells,
but it does not establish a default threshold or quantify the power trade-off
for glmGamPoi QL. No production default change is proposed by this draft.

## Reproducing

```sh
Rscript -e 'renv::restore()'
# the 16 cells actually run are listed in REPORT.md §"Cells run"
Rscript bench/null_calibration/calibration.R --shapes=original --offsets=tss \
  --n-per=3,4,6,8,12,20 --sims=1000 --taxa=40 --tests=wald_ml,lrt,ql_f
Rscript bench/null_calibration/summarise.R
```

The committed `results/` CSVs carry the baseline rates and intervals. The
native comparator output and provenance are recorded separately in
`results/native_comparator_summary_run_40091522843.csv` and
`results/native_comparator_provenance_run_40091522843.csv`; the source is [Actions
run 40091522843](https://github.com/hyperpolymath/MetaManifold-WebUI/actions/runs/40091522843),
tag `null-calibration-run4-2026-10-24`. The raw Actions artifact is retained
through 2026-11-23.
