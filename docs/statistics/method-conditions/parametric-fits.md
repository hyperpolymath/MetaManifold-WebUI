<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Method conditions — parametric fits

**Catalogue item 2** of [`method-catalogue-v1.md`](../method-catalogue-v1.md), approved
2026-09-22. **Published before implementation**, as the catalogue requires: the
implementation in `src/analysis/estimation.jl` is held to this document, so it is written to
be checked against rather than admired.

**Status: implemented** in `src/analysis/estimation.jl`, called by
`Execution.run_analysis`. Evidence, as delivered, is in `test/unit/test_estimation.jl`:
known answers written into the data rather than read back out of the fit; an independent
reference (the same data fitted directly in R, compared coefficient by coefficient, and BH
compared against R's `p.adjust`); negative controls for every refusal path; and a
source-level guard that the placeholder statistics this replaced do not come back.

**What this document does not claim.** There has been no independent statistical review of
this layer. Issue #1 requires one before its acceptance criteria are met, and that is still
outstanding. Nothing below is a claim that the models are *appropriate* for a given dataset;
it is a statement of what is computed, what is refused, and what is argued for the user.

## What ran before, and why this document exists

`Execution.run_analysis` used to return, per feature, a p-value computed as
`0.01 + (hash(taxon_id) % 100) / 1000.0`, an adjusted p-value of `p * 1.5`, a log2 fold
change of `(hash % 20) / 10 - 1` and a `baseMean` of `100 + hash % 1000`, all derived from
the *name* of the feature. Those numbers are deterministic, look plausible in a table, and
carry no information about the counts. They were labelled a stub in the source and handed to
the caller as results.

A stub that is returned as a result is a wrong answer. This layer replaces it: where a fit
cannot be run or fails, the output says so and carries no number at all.

## What this method is

Per-feature estimation of a declared model, one row per feature, with the design named by the
configuration's formula. Four methods, and for each one the response it accepts:

| Method | Response | Model | Fit in |
| --- | --- | --- | --- |
| `nb_glm` | raw counts (non-negative) | negative binomial GLM, log link | R `MASS::glm.nb` |
| `clr_lm` | CLR-transformed values | Gaussian linear model | R `stats::lm` |
| `ilr_lm` | ILR balances | Gaussian linear model | R `stats::lm` |
| `logistic` | 0/1 presence | binomial GLM, logit link | R `stats::glm(family = binomial)` |

Every fit is deterministic: there is no resampling, no permutation and no random start. The
provenance says so, and records the seed the caller passed as *not a parameter of any number
here* rather than implying it was used.

### Response types accepted, and what happens to zeros

- `nb_glm` requires counts. Zeros are handled before the fit, by
  `prepare_analysis_table`: either left alone (`pseudocount` is not applied to the raw counts
  in this path), or replaced by the declared zero policy, whose parameters are recorded in
  the config. A response that is constant, or has fewer than three finite values, is not
  fitted at all — see *Unsuccessful states* below.
- `clr_lm` and `ilr_lm` receive a table that has already been transformed. A zero reaching
  the transform is what the zero policy is for; `log(0)` is not silently conventionalised
  anywhere in this layer.
- `logistic` requires a 0/1 response and **refuses anything else**. A binomial fit on
  proportions needs the number of trials per sample, and this layer will not invent weights:
  the prepared table must come from the `presence_absence` transform.

### Study designs supported

Additive main effects over metadata columns: `~ a`, `~ a + b`, `~ a + b + c`, where every
term is a plain column name. The first term is the **primary contrast** — the coefficient
reported per feature and the coefficient the BH family is built from. For a factor, R's
default treatment coding applies: the coefficient is the contrast between the first two
levels, and the levels are recorded in the provenance so the sign is interpretable.

Refused, by name, with a reason (`UnsupportedFormula`):

- interactions (`*`, `:`), nesting (`/`), polynomial terms (`^`), transformations (`I()`,
  `log()`, `poly()`), random effects (`(1 | batch)`), functions of several arguments, and
  `-` in any position;
- a formula with no `~`, an empty right-hand side, a duplicated term, or a dangling `+`;
- `$`, backticks, `;`, backslashes and newlines anywhere in the formula.

**Pairing, blocking and repeated measures are not supported.** A paired design cannot be
expressed in this grammar; entering the subject as a covariate fits a fixed effect per
subject, which is not the same analysis and would be reported as though it were. Until a
paired model is implemented and validated, a paired study gets a refusal, not a p-value.

### Overdispersion and depth

- `nb_glm` estimates one dispersion parameter per feature by maximum likelihood
  (`MASS::glm.nb`), that is `dispersion_method = "parametric"`. The other names accepted by
  `AnalysisConfig` — `local`, `mean`, `pooled`, `glmGamPoi` — are **refused by name** at the
  point of fitting rather than aliased to it (issue #21). Dispersion sets every standard
  error in the fit; a run that asked for one estimator and received another would report
  different intervals and different multiple-testing outcomes under a label saying otherwise.
- **An offset is required for `nb_glm` and refused for every other method.** The offset is the
  log-scale factor computed in `prepare_analysis_table`: `log(library size)` for
  `none`/`TSS`/`CSS`/`RSS`, `log(size factor)` for `size_factors`. Raw counts fitted without
  one would attribute sequencing depth to biology; a Gaussian fit on CLR units has nothing to
  offset, and accepting the parameter would imply it had been used.
- Dispersion at a boundary is reported: theta ≥ 1e7 gives `status = "boundary"` with a note
  that the negative binomial model has collapsed onto Poisson; theta ≤ 1e-8 gives
  `status = "boundary"` with a note that the standard error is not trustworthy.
- `logistic` separation (R's "fitted probabilities numerically 0 or 1") gives
  `status = "boundary"` and a note saying the Wald test is not a valid p-value. It is never
  presented as a clean result.

### Uncertainty, effect sizes and multiple testing

- **Effect size, stated in units.** `estimate_scale` names what the number is in:
  `log_counts` (so `log2FoldChange = estimate / log(2)`, computed only for `nb_glm`),
  `clr_difference`, `ilr_balance`, `log_odds` (with `odds_ratio` for `logistic`). A CLR
  difference is not a fold change and is not labelled as one.
- **Intervals are Wald**, 95%: `estimate ± 1.96·SE` for the z-based fits, the t quantile for
  the Gaussian fits. Profile-likelihood intervals are not computed — they cost orders of
  magnitude more per feature, and the limitation is stated here rather than left implicit.
- **BH is mandatory** (`config.correction`). Adjusted p-values are computed by
  `Estimation.bh_adjust`, a step-up implementation with the monotonicity constraint enforced,
  tested against R's `p.adjust(method = "BH")`. Disabling BH requires the acknowledgement
  token and produces a DANGER banner; when it is disabled, `padj` is `null` rather than equal
  to `pvalue`, because absent and uncorrected are different statements.

### Unsuccessful states, and the shape of a failure

Three outcomes, all recorded in the result and in `diagnostics.checks["estimation"]`:

1. The fit ran. Each feature row carries `status` ∈ {`ok`, `boundary`} and its statistics.
2. Some features failed. Those rows carry `status = "failed"`, a `note` naming the cause, and
   `null` for every statistic — never a zero, never a NaN, never a substituted estimate. They
   are excluded from the BH family, the exclusion count is reported as `n_failed`, and the
   family is described as "features with a testable fit" so that a large exclusion rate is
   visible rather than flattering.
3. Nothing ran. `status = "not_run"`, `results` empty, and a reason: no metadata (no design),
   a formula term that is not in the metadata, a primary term with fewer than two distinct
   values, the R runtime busy past the timeout (`RBusyError`), R unreachable, or any other
   failure to execute. **An empty result is a statement about the run**, and it is never
   presented as "no features were significant".

### Provenance written for every run

Method, engine, formula, terms, primary term and its contrast and levels, `estimate_scale`,
dispersion method, offset kind and the SHA-256 of the offset vector, correction and alpha,
R version, MASS version, the SHA-256 of the per-feature table and of the coefficient table as
they crossed the boundary, the statement that the fits are deterministic, and the interval
method.

### Computational limits

Fits run inside the shared R runtime lock (`RRuntime`), which serialises them against the
pipeline and every other analysis. The wait is bounded by `Execution.ESTIMATION_R_WAIT_SECONDS`
(default 10 s), and exceeding it is an explicit `not_run`, not a partial result. Per-feature
cost is one R model fit; no per-feature memory bound has been measured, and none is claimed
here. A feature count in the tens of thousands will be slow, and slow is not the same as
failed: the run either completes or reports why it did not.

## Evidence, as delivered

In `test/unit/test_estimation.jl`:

- **Known answers** — a table with a written-in four-fold increase, a written-in no-effect
  feature and a written-in ten-fold decrease; the recovered log2 fold changes are checked
  against the arithmetic of the means, not against a recording of a previous run.
- **Independent reference** — the same counts fitted directly in R (`MASS::glm.nb` with the
  same offset) and compared coefficient by coefficient, standard error by standard error and
  p-value by p-value; and BH compared against R's `p.adjust`.
- **Negative controls** — every refusal above is asserted to throw, and every refusal's
  message is asserted to name what it refused. A constant feature is asserted to return
  `status = "failed"` with no numbers. A missing design, a wrong-length column and a
  single-level grouping are asserted to return `not_run`, not a fit.
- **Regression guard on the placeholder** — `Execution.jl` is read as source and asserted not
  to contain `hash(taxon_id)`, and `estimation.jl` is asserted not to contain `hash(` or
  `rand(`.

## Explicitly not claimed

- No Poisson, negative binomial or binomial model is *endorsed* by this document for
  sequencing data; the catalogue names them candidates requiring review, and this
  implementation does not change that.
- Wald intervals and z-based p-values are asymptotic. Small samples per group are exactly
  where they are weakest, and `min_samples_per_group` below 3 already raises a DANGER flag in
  the configuration layer.
- The BH family here is one test per feature on the primary contrast. Testing several
  contrasts per feature needs the contrast derivation and family accounting that issue #4
  covers; until then, other coefficients are reported but not adjusted as a family of their
  own.
- No equivalence testing, no power analysis, no multiplicity across several analyses of the
  same data.
- ELIGIBLE-FOR-REVIEW: independent statistical review, as issue #1 requires, has not happened.
