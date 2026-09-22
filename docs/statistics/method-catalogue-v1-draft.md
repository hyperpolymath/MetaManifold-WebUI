<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Bounded method catalogue, v1 — DRAFT for owner approval

**Status: DRAFT. Not approved, not implemented.** Issue #1 requires the bounded
catalogue and its supported/unsupported conditions to be approved *before* methods are
implemented. This document is the artefact to approve or amend, not a claim that the
catalogue is settled.

## What is already in the application

These exist today and are not new work; the catalogue records them so that "supported"
means something specific.

| Method | Where | Response type | Notes |
| --- | --- | --- | --- |
| Richness, Shannon, Simpson | `src/analysis/diversity.jl` | counts per sample | descriptive indices |
| Rarefaction / normalisation | `src/analysis/diversity.jl` | counts per sample | `none`, `rarefy` |
| Alpha diversity comparisons | `src/analysis/analysis.jl` | group → value | significance reported with a status, never silently degraded |
| NMDS ordination | `src/analysis/analysis.jl` | distance matrix | vegan, via the locked R runtime |
| PERMANOVA | `src/analysis/analysis.jl` | distance matrix + grouping | vegan; exchangeability of the permutation units is the standing caveat |

## Proposed v1 additions, in dependency order

1. **Descriptive summaries at exact precision** — counts and proportions as exact
   integers/rationals. No inference claimed. Depends only on `numeric_policy.jl`,
   which this PR adds.
2. **Parametric fits with explicit constraint and convergence reporting** —
   maximum likelihood where the model justifies it, with identifiability,
   boundary-estimate and convergence checks that produce *unsuccessful states* rather
   than plausible parameters.
3. **Nonparametric tests** — permutation/bootstrap, with resampling units and
   exchangeability stated, seeds recorded, and Monte Carlo limits reported alongside
   the estimate.
4. **Exact statistical tests** (separate issue, #3) — Fisher's exact, exact negative
   binomial, permutation PERMANOVA. Not in v1.

## Supported / unsupported conditions to be agreed with each method

Every method above will publish, before implementation:

- **Response type** it accepts (counts, proportions, distances, continuous) and what
  it does with zeros, and with all-zero samples.
- **Study design** it supports: pairing, blocking, repeated measures, covariates,
  unequal sequencing depth, compositionality. Missing design information means a
  descriptive summary, never a guess.
- **Overdispersion and depth** handling, named explicitly, not absorbed into a
  default.
- **Uncertainty**: interval method, effect size, multiple-testing policy (BH is
  mandatory where several tests are reported — an existing project rule).
- **Diagnostics and warnings** surfaced to the user, in accessible language, including
  the assumption that is most likely to be wrong for the data at hand.
- **Computational limits**: time and memory bounds, and what happens at them
  (`ResourceLimitError`, an explicit unsuccessful state).

## Explicitly not claimed

- No Poisson/negative-binomial or binomial/beta-binomial model is approved by this
  draft for sequencing data; both are candidates requiring review, not defaults.
- "Nonparametric" is a class of methods, not a universal safe distribution and not an
  assumption-free alternative. Exchangeability still has to be argued.
- No method is selected by a normality test or by which p-value looks favourable, and
  no method is switched silently.
- Higher precision is not exactness (see `numeric-contracts.md`).

## What approval is being asked for

1. The v1 scope above (items 1–3; item 4 stays deferred).
2. The per-method publication list as the acceptance gate for each method.
3. The reading that a descriptive summary is the correct default whenever the
   information needed for valid inference is missing.
