<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000015
parent: 0198ba50-0000-7000-8000-000000000010
position: 50
kind: page
tags:
  - users
  - statistics
  - guide
archived: false
-->

# Analysis and statistics today

**Status: PARTIAL by policy** — everything on this page is implemented, but
the inference layer awaits issue #1's independent statistical review. Read
results as "computed as documented", not "reviewed". The deep reasoning lives
in [Deep Dives](Deep-Dives); this page is the user-facing contract.

## The honesty rule

> If a method cannot run validly on your data, MetaManifold returns an
> **unsuccessful state** — a named refusal — and no number at all. It will
> never substitute a plausible-looking statistic.

This is enforced in code and by test (a guard test fails if placeholder
statistics are ever reintroduced). When a significance test is requested
while R is busy, the answer is "unknown", not "not significant" (#31's rule).

## What is computed today

| Analysis | What it gives you | Where it comes from |
|---|---|---|
| Richness, Shannon, Simpson | per-sample descriptive indices | `src/analysis/diversity.jl` |
| Group comparisons of alpha diversity | test statistic + p-value **with status** (Kruskal–Wallis default; paired option) | `src/analysis/analysis.jl` |
| Exact descriptive summaries | counts as exact integers; proportions as exact rationals — no inference claimed | `src/analysis/exact_summaries.jl` |
| Parametric fits — `nb_glm`, `clr_lm`, `ilr_lm`, `logistic` | per-feature maximum-likelihood estimates with diagnostics **or** refusal | `src/analysis/estimation.jl` |
| Normalisation: none, rarefaction | chart-facing count scaling | `diversity.jl` |
| TSS / CSS / RSS | size-factor **offsets** for the fits (depth modelled, counts unchanged) | `src/analysis/scaling.jl` |
| Taxonomic composition bars, organism composition categories | per-sample or pooled composition | analysis + composition modules |
| Taxon overlap | proportional Euler / UpSet | `analysis.jl` |
| NMDS (Bray–Curtis), PERMANOVA | ordination and group test via the locked R runtime (vegan) | `analysis.jl` |
| Pipeline-stage read summaries | retention per stage | pipeline stats |

## Reading a parametric fit

Four methods, four response types (never mixed): `nb_glm` takes raw counts
(negative binomial, log link, R `MASS::glm.nb`); `clr_lm`/`ilr_lm` take
CLR/ILR-transformed values (Gaussian LM); `logistic` takes 0/1 presence. The
fit reports, per feature:

- convergence and identifiability status — an **unsuccessful state** replaces
  the estimates when either fails;
- boundary estimates (e.g. fitted dispersion at a limit) flagged as such;
- effect sizes and intervals by the method's published conditions;
- Benjamini–Hochberg adjusted p-values wherever several tests are reported —
  **mandatory**, with a DANGER banner if anyone tries to turn it off.

**Academics:** the conditions each method is held to are published *before*
implementation and live in `docs/statistics/method-conditions/` — those
documents are what you cite (or reproduce) when writing up which model, which
response, which refusals. The catalogue that gates them:
`docs/statistics/method-catalogue-v1.md`.

**Lab professionals:** the practical version is — a table with `refused` in a
status column is telling you the assay or design does not support that
analysis. Route it to a human decision; do not fish for a tool that will
give you a number.

## Offsets, not substitutions

TSS/CSS/RSS here are **offsets**: one positive size factor per sample (its
log after a stated centring) handed to the count model so sequencing depth is
*modelled*, not analysed away. The counts themselves are not replaced. An
earlier build silently aliased these to relative abundances — that behaviour
was removed and a regression test now forbids it. Offsets are **not** a
compositional solution; for that, see "coming" below.

## Exact means exact — and only where it can be

Counts and proportions in the descriptive layer carry exact precision
(integers beyond 2⁵³−1 included; proportions as rationals). Nothing floats
into that claim silently: a float-derived input is labelled approximate
wherever shown. Higher precision (any `BigFloat`) is *not* exactness. What
exactness does **not** extend to: inference. P-values and fits are
approximate by nature and say so. Deep end:
[Deep Dives — Exact Arithmetic](Deep-Dives--Exact-Arithmetic).

## What is coming — and how it is gated

Every method below is **COMING** (specified in `docs/issues/milestone3/`,
approved in scope, not implemented). Each must publish its supported /
unsupported conditions *before* implementation — response types, design
assumptions, zero handling, overdispersion and depth policy, uncertainty
method, multiple-testing policy (BH remains mandatory), diagnostics and
computational limits — and only then be written:

1. Nonparametric tests (permutation/bootstrap; catalogue item 3).
2. Exact statistical tests — Fisher's exact, exact NB, permutation PERMANOVA
   (#3, catalogue item 4) — for small-n and rare-taxon work.
3. Multinomial / Dirichlet-Multinomial regression (#17).
4. Occupancy models, zero-inflated NB, hurdle (#18).
5. Constrained ordinations — RDA/CCA/CAP/dbRDA with permutation tests (#19).
6. PhILR / SBP ILR bases with balance dendrograms (#20).
7. Advanced zero handling — glmGamPoi dispersion, Bayesian multiplicative
   replacement (#21).
8. ANCOM-BC, ALDEx2, Songbird-style compositional methods (#5).

**BLOCKED:** a symbolic formula engine (#2) — deliberately, until the numeric
layer has passed real-data validation.

The board: [Status and Roadmap](Status-and-Roadmap).
