# SPDX-License-Identifier: CC-BY-SA-4.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

# `dispersion_method = "glmGamPoi"` — conditions of use

Reference: Ahlmann-Eltze, C., Huber, W. (2020), *glmGamPoi: fitting Gamma-Poisson generalized
linear models on a single cell*, Bioinformatics / Genome Biology 21:246,
doi:10.1186/s13059-020-02185-y. Ported from `const-ae/glmGamPoi`
(`R/overdispersion.R`, `R/quasi_gamma_poisson_shrinkage.R`, `R/loc_median_fit.R`,
`src/overdispersion.cpp`).

This method is a **port**, not an alias: it is not DESeq2's dispersion estimator under
another name, and it does not silently fall back to one. Where the reference does something
that is not ported, the request is refused by name instead of being answered with a
different estimator.

## 1. What runs

1. **Pass 1 — the mean.** For each feature, `MASS::glm.nb` fits the negative binomial GLM with
   the configured design and the size factors as offset. A feature whose fit fails (fewer
   than three finite fitted values, or fewer than two distinct ones) enters the mean matrix
   as its row mean; its index is recorded in
   `diagnostics["features_whose_pass_1_fit_failed_indices"]`, and it fails again in pass 2
   with its own reason rather than disappearing.
2. **The dispersion.** `src/analysis/dispersion.jl` runs the reference's pipeline on those
   means, in Julia:
   * per-feature **Cox-Reid adjusted** maximum likelihood, with the reference's `0.99`
     correction factor on the log-determinant of `X'WX` (LU-based, diagonal clamped at
     `1e-50`, `W = 1/(1/µ + θ)`), the reference's early returns (all-zero counts → 0; a mean
     at 0 → `1e-6`; a score below zero at the lower bound → 0, "Even for very small theta, no
     maximum identified"), its starting value `(var − µ)/µ²` or `0.5`, and its bounds
     `log(1e-16) … log(1e16)`;
   * the **local-median trend** (`loc_median_fit`: normal-weighted median over
     `npoints = max(1, round(0.1n))` window points on a `dnorm` weighted grid over
     `seq(-3, 3)`, no interpolation, endpoints filled);
   * the **quasi-likelihood conversion** `ql = (1 + m·disp)/(1 + m·trend)` with `m` the
     feature mean;
   * the **inverse-chisquare prior** by Nelder-Mead from `c(0,0)`, and the shrunken value
     `(df0·var0 + df·s2)/(df0 + df)`.
3. **Pass 2 — the fit.** The GLM is refitted at the fixed dispersion. The θ handed to
   `MASS::negative.binomial` is `1/α`; where α is 0 the fit uses `stats::glm(poisson())`,
   which is what θ → ∞ means. The fit uses the reference's `dispersion_trend`, not the
   shrunk quasi-likelihood value — the reference's own choice (`R/glm_gp_impl.R`), and the
   two are both reported so the integration cannot confuse them.

## 2. What is NOT ported, and what happens when it is asked for

| Not ported | Behaviour |
| --- | --- |
| The **natural-spline abundance trend** for the variance prior, which glmGamPoi switches on at 100 or more features (`ns` with 4 df, `maxit = 5000`, falling back to the non-trended fit with a warning on error). | `abundance_trend = true` is **refused** with a message naming the option that runs the reference's own non-trended prior. With `abundance_trend` unset, a table at or above 100 features is **refused**, because running the non-trended prior under the label `glmGamPoi` would change every standard error without saying so. `abundance_trend = false` runs the reference's non-trended form and records the deviation in provenance and diagnostics. |
| The **quasi-likelihood F-test** and the downstream Wald machinery. | Not ported; hypothesis tests continue to come from the pipeline's existing estimator. The shrunken quasi-likelihood dispersion *is* computed and reported, because it is the input that test would take. |
| **Gene-wise dispersion fitting on a subset of features** (`glm_gp`'s internal subsampling when the table is very large). | Not ported; the port fits every feature. Cost, not correctness: see the benchmark lane. |
| The **spline in the prior scale** (`variance_prior`'s `covariate` path). | Refused through the same `abundance_trend` switch. |

## 3. Conditions of use

| Condition | Value |
| --- | --- |
| Requires | `method = "nb_glm"` (count data, size factors preferred). Asking for it with a CLR/ILR method is refused at the configuration layer. |
| Requires | R with `MASS` (pass 1 and pass 2 are R), and the Julia side for the dispersion itself. |
| Feature count | `abundance_trend` unset is refused at ≥ 100 features (`SPLINE_TREND_MIN_FEATURES`); `false` is the escape hatch and is recorded. |
| Samples | residual df `n_samples − n_coefficients` must be positive; otherwise refused rather than reporting a dispersion with no residual information. |
| Design matrix | must have one row per sample, and must be the matrix R's `model.matrix` produces for the formula (intercept, numeric columns as-is, treatment dummies with sorted levels and the first level as reference). The Cox-Reid term is computed from it, so a mismatch changes the answer silently — the port builds it once with `_design_matrix` and records the columns it used. |
| Refusals | non-finite θ after the fit; variances or degrees of freedom that are not finite and positive; design rows that do not match the samples; empty tables |
| Provenance | the two-pass description, the trend actually used, the port scope, the fallback indices, and the two un-ported items above |

## 4. Why this is worth two languages and a port

`dispersion_method = "parametric"` fits a mean–dispersion trend by method of moments. glmGamPoi's
estimator is a likelihood estimator with a Cox-Reid correction, a robust local-median trend
and an empirical-Bayes shrinkage step, and it is *defined* by those steps: it is the thing
papers cite when they say "glmGamPoi". Returning a method-of-moments trend under that name
would be a silent substitution, which is the failure mode this repository's catalogue calls
out by name. Hence the port, the refusals, and the parity tests:

* `test/unit/test_dispersion.jl` asserts the port against the pinned fixture, and against R's
  `glmGamPoi` itself wherever R and the package are installed (CI installs both). Where they
  are not installed, the test says the comparison did not run — it does not pass quietly.
* `test/fixtures/issue21/golden.json` records how the pinned numbers were derived, including
  the fact that they are a transcription rather than a live call, and that
  `test/reference/issue21_reference.jl` is what turns them into a reproduced result.

## 5. Residues, stated plainly

1. The **spline trend** is the reference's default at scale, and this port refuses it. A
   100-taxon run with `glmgampoi_abundance_trend = false` is the reference's non-trended form,
   which the reference itself would not have chosen at that size. The deviation is recorded,
   not hidden, and the alternative (`parametric`) is named in the error.
2. The port's **Nelder-Mead** is a hand-written implementation of the reference's optimiser
   settings, not R's `optim` internals. Agreement is asserted to 1e-6 on the fixture and on
   the R comparison where available; it is not a proof that the two optimisers take identical
   paths.
3. The **`0.99` Cox-Reid factor** and the LU clamp are the reference's own numerical
   defences, transcribed. If the reference changes them, this port is wrong and the fixture
   would have to move with it.
4. The **proved** part of the shrinkage step is its shape, not its inputs:
   `proofs/agda/DispersionShrinkage.agda` proves that the shrunken value lies between the
   prior and the sample estimate and is exact when the prior is the sample estimate. Nothing
   there says the prior fit is right.
