<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Zero handling and dispersion for differential abundance

## Why zeros need an explicit decision

A centred log-ratio (CLR) is `log(x_ij) - mean_j(log(x_ij))`, so it is undefined
when any part of the composition is zero. A sequencing zero can mean biological
absence or a taxon that was present below the run's detection limit; the count
table alone does not distinguish those explanations.

**Every zero replacement is biased. A replaced zero is not a measurement.**
Multiplicative methods avoid some of the distortion caused by adding a
pseudocount, but they cannot recover an unobserved abundance. Do not try several
parameters and report only the run with the desired significance. The selected
method, delta and (when Bayesian) alpha are stored in the resolved run
configuration, the analysis response and the CSV settings line.

A negative-binomial model does not have this problem: its likelihood is defined
at zero, so `nb_glm` analyses the observed integer counts without a pseudocount
or replacement.

## Replacement policies for `clr_welch`

The Analysis configuration expander exposes
`analysis.differential.replacement_method`. Both policies call the pinned R
reference implementation, `zCompositions::cmultRepl`, with `z.warning = 1` and
`z.delete = FALSE`. Prevalence filtering is deliberately done by MetaManifold
before replacement; cmultRepl is never allowed to drop a sparse row or taxon and
silently change the tested family.

| Setting | Reference call | Behaviour |
| --- | --- | --- |
| `bayesian_multiplicative` (default) | `cmultRepl(..., method = "GBM", output = "prop")` | Geometric Bayesian-multiplicative posterior replacement with a leave-one-out prior mean and an estimated Dirichlet concentration. |
| `bayesian_multiplicative` with `bayesian_alpha > 0` | `cmultRepl(..., method = "user", t = ..., s = alpha, output = "prop")` | The same leave-one-out prior mean with an explicitly selected positive Dirichlet concentration. |
| `multiplicative_replacement` | `cmultRepl(..., method = "CZM", output = "prop")` | Count-zero multiplicative replacement. Before adjustment, a zero receives `delta * 0.5 / sample_total`. |

For both policies, cmultRepl closes each sample to a composition and scales its
observed parts by one common factor. Consequently, each output row sums to one
and ratios among observed parts are preserved. This is the important difference
from adding the same pseudocount to every cell, which changes observed-part
ratios. It does **not** make the imputed values unbiased.

A taxon seen in fewer than two samples is refused for Bayesian replacement
because its leave-one-out prior is undefined. CZM needs at least one observation
of every included taxon. An all-zero sample, a never-observed CZM taxon, fewer
than two taxa, or an invalid resulting composition is refused explicitly rather
than repaired with a guessed value.

### Delta

`analysis.differential.replacement_delta` is cmultRepl's `frac` and must be
strictly between 0 and 1; the default is 0.65.

- For CZM it multiplies the `0.5 / sample_total` threshold.
- With `adjust = TRUE` (the reference default used here), either policy caps an
  imputed proportion that exceeds its taxon's smallest observed proportion at
  `delta` times that proportion.
- Values below 0.01 produce a numerical caution because very small replacements
  can underflow. Values at least 0.9 produce a caution because imputed values
  can receive substantial mass relative to observed parts. These are numerical
  heuristics, not biologically optimal cutoffs.

Delta is recorded even when a particular table has no zeros, so the configuration
that produced a result remains reproducible.

### Bayesian posterior, without pretending to sample it

For a Bayesian replacement with at least one zero, `replace_zeros` also returns
`posterior.prior_mean` and `posterior.concentration`. For sample `i`, these fully
parameterise the pre-adjustment posterior

```text
Dirichlet(observed_counts[i, :] + concentration[i] * prior_mean[i, :])
```

The analysis diagnostics record the concentration for every sample and this
parameterisation. cmultRepl's subsequent `frac` cap and multiplicative closure
are deterministic adjustments, not draws from that Dirichlet distribution. The
Web UI therefore describes the result as an **adjusted posterior estimate**, not
as a posterior sample or an uncertainty interval.

Alpha is optional (`null` by default), must be finite and strictly positive when
set, and is ignored by CZM. A larger alpha gives the prior more weight relative
to the observed counts.

## glmGamPoi dispersion for `nb_glm`

`analysis.differential.dispersion: glmGamPoi` calls the pinned R
`glmGamPoi::glm_gp` once across all taxa passing the prevalence filter and takes
`overdispersion_shrinkage_list.dispersion_trend`. Each taxon is then fitted with
`MASS::negative.binomial(theta = 1 / dispersion)` and a Wald test with fixed
scale 1. The default `ml` path remains unchanged and uses `MASS::glm.nb`.

This is plug-in negative-binomial Wald inference using glmGamPoi's shrunken
dispersion trend. It is **not** glmGamPoi's quasi-likelihood test, and it does
not propagate uncertainty in the estimated trend. Selecting it for `clr_welch`
is refused. Missing R packages produce an explicit service-unavailable error;
there is no silent fallback to another estimator.

## When not to replace zeros

- Use `nb_glm` when a count model answers the scientific question; raw zeros are
  valid observations under that model.
- Raise `min_prevalence` when rare taxa would make imputed values dominate the
  composition. The result reports median and maximum imputed mass per sample.
- Use `multinomial` or `dirichlet_multinomial` when the whole composition is the
  unit of inference: a zero count is part of the likelihood, no size factor is
  fitted, and conditioning on each sample's read total makes every effect a log
  ratio against a reference taxon rather than an absolute abundance.
- Consider an occupancy/observation model when detection itself is the object of
  inference, or a zero-inflated or hurdle model when structural and sampling
  zeros must be separated. Those models are not implemented by `clr_welch`, and
  multiplicative replacement is not a substitute for them.

## References

- Martín-Fernández, J. A., Barceló-Vidal, C. & Pawlowsky-Glahn, V. (2003).
  *Dealing with zeros and missing values in compositional data sets using
  nonparametric imputation*. Mathematical Geology 35, 253–278.
  <https://doi.org/10.1023/A:1023866030544>
- Martín-Fernández, J. A., Hron, K., Templ, M., Filzmoser, P. &
  Palarea-Albaladejo, J. (2015). *Bayesian-multiplicative treatment of count
  zeros in compositional data sets*. Statistical Modelling 15(2), 134–158.
  <https://doi.org/10.1177/1471082X14535524>
- Palarea-Albaladejo, J. & Martín-Fernández, J. A. (2015). *zCompositions — R
  package for multivariate imputation of left-censored data under a
  compositional approach*. Chemometrics and Intelligent Laboratory Systems 143,
  85–96. <https://doi.org/10.1016/j.chemolab.2015.02.019>
- Ahlmann-Eltze, C. & Huber, W. (2020). *glmGamPoi: fitting Gamma-Poisson
  generalized linear models on single cell count data*. Bioinformatics 36(24),
  5701–5702. <https://doi.org/10.1093/bioinformatics/btaa1009>

Implementation and direct-reference tests live in
`src/analysis/differential.jl` and `test/unit/test_differential.jl`. The
opt-in 100/1,000/10,000-taxon runtime and allocation benchmark is documented in
`bench/advanced_zero_handling/README.md`.
