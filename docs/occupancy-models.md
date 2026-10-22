# Occupancy and two-part abundance models

The differential-abundance configuration supports `zinb` and `hurdle_nb` in
addition to the existing `nb_glm` and `clr_welch` models. The two new methods
are fixed-effect, per-taxon models with a two-part negative-binomial likelihood.
They use the configured `tss` or `rle` library-size offset in the count
component and apply Benjamini–Hochberg correction to the joint tests.

## Zero-inflated negative binomial (ZINB)

For taxon count `Y`, the model has a logistic structural-zero probability
`π`, and an NB count distribution with mean `μ` and dispersion `θ`:

- `P(Y = 0) = π + (1 - π) NB(0; μ, θ)`
- `P(Y = y > 0) = (1 - π) NB(y; μ, θ)`

Both the zero component and log-mean count component include a group effect;
the latter includes the log library-size offset. The reported count effect is
the log fold change (and its log2 conversion). The result also reports the
zero-component group log-odds coefficient. The p-value is a joint 2-df
likelihood-ratio test against a model without either group effect. The fits use
base R's `stats::optim` and `stats::dnbinom`, so no extra R modeling package is
required.

## Hurdle negative binomial

A logistic component models whether a count is zero. Conditional on a positive
count, the abundance follows an NB distribution truncated at zero. All zeros
are assigned to the occurrence component; unlike ZINB, the count component
cannot produce zero. The same joint test, count-process effect, offset, and
multiple-testing policy apply.

These are not interchangeable explanations of sparse data. NB overdispersion
can itself produce many zeros; selecting ZINB just because the matrix is sparse
can overfit and make the structural-zero component weakly identified. Compare
models using diagnostics and report the chosen model. Results do not currently
include a formal Vuong comparison or DHARMa residual diagnostic.

## Repeated-visit occupancy estimator

The lower-level Julia entry point
`MetaManifold.Differential.fit_occupancy(history, groups, taxa; levels)` accepts
a Boolean array with dimensions **sites × repeat visits × taxa**. It fits an
occupancy probability `ψ` with an intercept and binary group effect and a
detection probability `p` shared across visits. `psi_reference` is the fitted
occupancy probability for `levels[1]` (the reference); `psi_contrast` is for
`levels[2]` (the contrast). A per-taxon likelihood-ratio test assesses the
group effect in occupancy; p-values are BH-adjusted. The returned table also
includes the estimated `p`.

This is intentionally not selected by `analysis.differential.method` and is
not called by the single-observation differential endpoint: that endpoint has
no repeat-visit design or detection-history input. The estimator refuses fewer
than two visits rather than treating technical or biological samples as repeat
visits. The initial implementation does not yet accept detection covariates
such as library size, batch, or primer, and does not implement arbitrary
occupancy/detection formulas or random effects. A deployment that needs these
should collect a defensible repeated-detection design and supply/validate
covariates before interpreting `ψ` and `p`.

Occupancy assumes closure over repeat visits: a site's true occupancy does not
change during the detection period. Microbiome sampling is often destructive,
and the meaning of a repeated visit may therefore be questionable. Single-visit
occupancy is not empirically separated into ψ and p without additional strong
assumptions. Interpret results cautiously and document the sampling design.

## Provenance and limitations

Pipeline configuration retains the selected two-part method, offset,
prevalence threshold, and dispersion option. The current analysis assumes a
single binary group contrast and has no user-supplied zero/detection formula.
The two-part tests use a 2-df LRT, not an individual-component significance
test; their reported count fold change is only one part of the joint hypothesis.

References:

- MacKenzie, D. I. et al. (2002). Estimating site occupancy rates when detection
  probabilities are less than one. *Ecology* 83(8), 2248–2255.
- Martin, T. G. et al. (2005). Zero tolerance ecology: improving ecological
  inference by modelling the source of zero observations. *Ecology Letters* 8,
  1235–1246.
