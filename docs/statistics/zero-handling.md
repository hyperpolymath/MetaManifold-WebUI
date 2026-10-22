<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Zero handling in differential abundance

**Status:** implemented for `clr_welch`; updated 2026-10-22.

Zeros are observed values, not missing data. The `clr_welch` method requires a
strictly positive composition before taking logarithms, so it replaces zeros
with `zCompositions::cmultRepl` after filtering taxa by
`analysis.differential.min_prevalence`. Replaced values are imputed inputs to
the log-ratio calculation; they are not measurements and do not establish
structural absence.

## Replacement options

- `bayesian_multiplicative` (default) uses GBM, the geometric
  Bayesian-multiplicative replacement. It uses a leave-one-out taxon profile as
a prior mean. `bayesian_alpha: ~` uses the estimated Dirichlet concentration;
a finite positive value uses the same prior mean with the requested
concentration. Posterior parameters are recorded in result diagnostics. The
implementation uses posterior estimates, not posterior draws.
- `multiplicative_replacement` uses CZM, the count zero-multiplicative
  replacement. Its starting threshold depends on `replacement_delta` and the
sample total. Both methods preserve ratios among observed parts before
multiplicative closure, and both cap high imputations relative to the taxon's
smallest observed proportion.

`replacement_delta` must be strictly between 0 and 1. Values below 0.01 or at
least 0.9 trigger a caution. It is not a tuning parameter for significance.
Bayesian replacement requires each retained taxon to occur in at least two
samples; CZM requires at least one. A composition needs at least two retained
taxa. Input that cannot produce a valid replacement is refused rather than
silently converted to a pseudocount result.

## Interpretation and alternatives

The `clr_welch` estimate is a contrast-minus-reference difference in centred
log-ratio units, not a fold change. Replacement choice and parameters are
returned in `config`; zero counts, imputed-mass summaries, warnings, and (for
GBM) concentration information are returned in `diagnostics.zero_replacement`.

Every zero-replacement method introduces assumptions and can bias results,
especially when zeros are common or sample sizes are small. Do not choose a
replacement or `delta` to obtain a preferred p-value. Consider the negative
binomial methods on raw counts (`nb_glm`, `zinb`, `hurdle_nb`) when appropriate.
Repeated-detection occupancy is a separate, incomplete workflow; see
[occupancy model notes](../occupancy-models.md) and
[roadmap](../../ROADMAP.md).

## References

- Martín-Fernández, J. A., Barceló-Vidal, C. & Pawlowsky-Glahn, V. (2003).
  Dealing with zeros and missing values in compositional data sets using
  nonparametric imputation. *Mathematical Geology*, 35, 253–278.
- Martín-Fernández, J. A., Hron, K., Templ, M., Filzmoser, P. & Palarea-Albaladejo,
  J. (2015). Bayesian-multiplicative treatment of count zeros in compositional
  data sets. *Statistical Modelling*, 15(2), 134–158.
- The implementation uses the documented `zCompositions::cmultRepl` methods;
  consult that package's version-matched documentation for exact details.
