<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000044
parent: 0198ba50-0000-7000-8000-000000000040
position: 40
kind: page
tags:
  - theory
  - statistics
  - estimation
archived: false
-->

# Maximum likelihood and refusals

**Status: PARTIAL — implemented and reference-tested; independent review
(#1) outstanding.** How estimation works here, why the return type is a sum,
and what each unsuccessful state means. Conditions of record:
`docs/statistics/method-conditions/parametric-fits.md`; code:
`src/analysis/estimation.jl`.

## What a fit is, here

Per-feature estimation of a **declared** model — one row per feature, the
design named by the configuration's formula. Four methods, and for each one
exactly one response type:

| Method | Response | Model | Fit in |
|---|---|---|---|
| `nb_glm` | raw counts (non-negative) | negative binomial GLM, log link | R `MASS::glm.nb` |
| `clr_lm` | CLR-transformed values | Gaussian linear model | R `stats::lm` |
| `ilr_lm` | ILR balances | Gaussian linear model | R `stats::lm` |
| `logistic` | 0/1 presence | binomial GLM, logit link | R `stats::glm(family=binomial)` |

Two structural rules:

- **No response mixing.** Counts go to `nb_glm`; transforms go to their
  linear models; presence to logistic. A proportion table where a count
  model expects counts is refused at the boundary (the historical
  alias-and-warn path is gone).
- **Determinism.** No resampling, no permutation, no random start. The
  provenance records the caller's seed *as "not a parameter of any number
  here"* — an honesty line that exists because seeds are easy to imply and
  hard to disclaim later.

Maximum likelihood is the estimator because the models justify it: for an
NB-GLM with log link the likelihood is (given dispersion) a GLM likelihood
solved by IRLS (`MASS::glm.nb` jointly estimates dispersion by profile
likelihood); for the Gaussian and binomial cases the same machinery is exact
for the canonical links. What ML *buys* is the classical asymptotic
apparatus — standard errors, z/Wald tests, intervals — and what it *costs*
is that every one of those is an asymptotic claim that must survive its
preconditions. Hence the next section.

## The return type is a sum, not a maybe

A fit returns **estimates or a named unsuccessful state** — never a number
dressed for the occasion. The states, and what each means:

| State | Meaning | Typical cause |
|---|---|---|
| **Non-convergence** | IRLS/profile iteration hit its cap without settling | separation, extreme overdispersion, degenerate design |
| **Non-identifiable** | the design matrix does not determine the parameters | collinear covariates, empty cells in a factor |
| **Boundary estimate** | a parameter sits at a limit (e.g. fitted dispersion) | true boundary or model misspecification — reported either way |
| **Precondition failure** | the declared response/design contract is violated | wrong response type, negative counts, unmodelled pairing |
| **Resource limit** | time/memory bounds exceeded | huge feature counts × expensive fits — bounded by contract |
| **Not implemented** | the method or its R package is absent from `renv.lock` | deliberately uninstalled dependency — refused, never faked |

The states are *results*. Users see them in tables where a p-value would be;
the UI renders them as such; the paper-language translation is "not tested"
(see [For Academics](Users--For-Academics)).

## What the tests hold the code to

The suite's idiom is the reason to trust any of this (all in
`test/unit/test_estimation.jl`):

1. **Known answers written into the data** — fixtures encode a planted
   effect (counts engineered to give a known coefficient direction and rough
   magnitude); the test checks the fit against the planting, not a snapshot.
2. **Independent reference** — the same data fitted directly in R outside
   the pipeline, compared coefficient by coefficient, and BH compared
   against `p.adjust`. The pipeline and the reference share R's
   implementations, so this checks the *wiring* (design matrix, offsets,
   response construction), which is where pipeline bugs actually live.
3. **Negative controls for every refusal path** — each state in the table
   above has a test that provokes it.
4. **The placeholder guard** — see below.

## The history this replaced (why the guard exists)

Before 2026-09-25, `run_analysis` returned per-feature "statistics"
computed as `0.01 + (hash(taxon_id) % 100) / 1000.0` — deterministic
nonsense derived from each taxon's *name*, labelled as results. The lesson
the conditions document states flatly: **a stub that is returned as a result
is a wrong answer.** The placeholder is deleted and a source-level guard
test now fails if anything of that shape returns. If you are tempted to stub
a statistic to unblock a UI: return an unsuccessful state instead. The UI
already knows how.

## Honest limits (the #1 caution, expanded)

- "Computed as documented" ≠ "appropriate for your data." The conditions
  document says nothing about whether an NB-GLM suits your study design —
  that remains the analyst's judgement (and the document names the
  assumption most likely to be wrong for each method).
- The asymptotics behind Wald intervals and z-tests degrade at small n and
  sparse features — the regime the **exact tests** (#3, COMING) exist for.
  Until they land, small-n claims should lean on
  [Exact Arithmetic](Deep-Dives--Exact-Arithmetic)'s descriptive layer.
- CSS (in `scaling.jl`) is a repo-local implementation of a published idea;
  equivalence to `metagenomeSeq` is unreviewed — same review umbrella.
- Multiple testing is BH everywhere several tests are reported. This is
  mandatory, enforced, and deliberately not configurable downward.
