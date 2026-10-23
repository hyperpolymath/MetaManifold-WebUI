# Draft upstream report: null calibration of the `glm.nb` Wald test

*Status: draft prepared downstream for review before anything is filed
upstream. All numbers are from `REPORT.md` in this directory, which defines
exactly what ran, where, and what did not run.*

## Summary

In null simulations that drive the production negative-binomial fitting code
(`MASS::glm.nb` per taxon, fixed-scale Wald test, per-taxon ML theta treated
as known), true nulls are rejected more often than nominal at every measured
group size. At α = 0.05 the rejection rate was 0.138 with 4 samples per group
and 0.076 with 12 (original/TSS shape, 200 sims × 40 taxa), and still 0.065
at 20 per group. A likelihood-ratio test on the same fits/datasets was closer
to nominal (0.103 / 0.065 / 0.058) but still anti-conservative in every cell
(Wilson 95% lower bound > 0.05 in all 32 summarised test-cells). Under a
power design (25% of taxa at |log2FC| = 1), Benjamini–Hochberg at 0.05
delivered FDR 0.38 (Wald, 4/group) and 0.13 (12/group).

The mechanism is the standard one: the Wald test plugs in the per-taxon ML
theta and ignores its sampling uncertainty. The bench that produces these
numbers extracts the production fitting block directly from
`src/analysis/differential.jl`, so the `wald_ml` column is the shipped code
path, not a reimplementation.

## What was and was not measured

Measured (reduced WebR run, genuine MASS 7.3-65 `glm.nb`; see `REPORT.md` for
provenance limits): Wald vs LRT, paired on identical datasets; group sizes
3–20; constant/sparse/unequal-library shapes; RLE offsets; one power design.

Not yet measured: the glmGamPoi quasi-likelihood F-test as an in-bench
comparator on this branch (the calibrated path reported in the downstream
issue), the dispersion-trend Wald option, edgeR, and the full 1,000-sim grid.
The bench (`bench/null_calibration/`, native `Rscript` route) is ready to run
those where R + Bioconductor are available.

## Options for the upstream maintainer's consideration

1. **Result-notes caveat for small samples** (adopted downstream): record a
   calibration caveat with `ml`-dispersion results, scaled by group size.
   Changes no statistics or defaults.
2. **LRT instead of Wald for the `glm.nb` path:** measurably closer to
   nominal in this bench, but still anti-conservative, slower, and fails
   more often at tiny n. The bench quantifies the trade-off; it is not a
   calibration fix.
3. **Prefer a quasi-likelihood path below a group-size threshold:** the
   downstream measurements that motivated this bench found the QL F-test at
   nominal rates where Wald was inflated. Any such default change is
   upstream's call; this draft only supplies the replication bench and
   numbers to decide with.
