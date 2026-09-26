<!-- berrywiki
id: 0198ba50-0000-7000-8000-000000000045
parent: 0198ba50-0000-7000-8000-000000000040
position: 50
kind: page
tags:
  - theory
  - statistics
  - compositional
archived: false
-->

# Compositional statistics and offsets

**Status: IN PLACE (offsets); COMING (the compositional method suite).**
Why sequencing depth is *modelled* here rather than normalised away, and
what a genuinely compositional answer would add. Conditions of record:
`docs/statistics/method-conditions/scaling-and-offsets.md`; code:
`src/analysis/scaling.jl`.

## The problem in one paragraph

Sequencing produces counts with an arbitrary library size: the same
underlying community sequenced deeper yields larger numbers everywhere. The
classical reflex — divide by library size, analyse proportions — quietly
changes the *type* of the response (counts → compositions) and destroys the
mean–variance relationship count models depend on. Worse, compositions live
on a simplex where "more of A" forces "less of B" — an artefact of closure,
not biology. Everything in this area is about which of these distortions you
are willing to pay for.

## The vocabulary the code enforces

| Term | Shape | What it touches | May it change the response? |
|---|---|---|---|
| **Scaling factor** | one positive number per sample | nothing yet — it is a number | n/a |
| **Offset** | log of the factor (after a stated centring) | the linear predictor of a count model | **no** — counts stay counts |
| **Transform** | new table (CLR, ILR, relative) | the response itself | yes — and then a *different model family* applies |

The type distinction is the safety property: an `Offset` cannot be used
where a `Transform` is required or vice versa, and `nb_glm` consumes counts
+ offsets while `clr_lm`/`ilr_lm` consume transforms. This is the "no silent
substitution" rule at the type level.

## The three offsets: TSS, CSS, RSS

- **TSS (total sum scaling) factors** — library size (its log, centred).
  The honest baseline: model depth as exposure. (The name is historically
  overloaded with "convert to relative abundance" — which is the *transform*
  of the same name. Here TSS produces **factors**, not proportions. That
  disambiguation is half the point of the conditions document.)
- **CSS (cumulative sum scaling) factors** — the `metagenomeSeq` idea:
  normalise by the cumulative sum up to a percentile of the count
  distribution, robust to a heavy tail of features. Implemented locally;
  treat package-equivalence as unreviewed.
- **RSS (relative sum scaling) factors** — sum-scaling relative to a
  reference sum. Distinct from TSS factors in centring; again a factor, not
  a transform.

These are **not** "normalisation" in the chart-facing sense — the
`analysis.normalisation` config key (none/rarefaction/relative for display)
is a separate concern ([Configuration Reference](Users--Configuration-Reference)).

## What this replaced — the three silent substitutions

The conditions document opens with the historical failures, because they are
the justification for the whole design:

1. `TSS` divided counts by library size and returned **proportions** — the
   exact compositional transform the design was written to avoid — for every
   method except `nb_glm`.
2. `CSS` and `RSS` were **aliased to `relative` outright** (with a `@warn`):
   under `nb_glm` a proportion table met a count model.
3. `size_factors` was *named* "DESeq2 median-of-ratios" and *implemented* as
   library size over its own geometric mean — TSS wearing another method's
   name.

Each is now refused at the boundary; regressions are test-locked; method
names compare case-insensitively (#62) so `tss`/`TSS` cannot redden a
compliant run (#46's echo of the capital-letter incident). The standing
rule when document and code disagree: **the document is right and the file
is the bug.**

## What offsets deliberately do not solve

Offsets handle *depth*. They do not handle *compositionality* — the simplex
constraint remains in the data whether or not the model sees exposure. For
differential abundance that respects the geometry, you need the compositional
suite, which is **COMING**:

- **CLR/ILR + linear models** — **PARTIAL/IN PLACE** as `clr_lm`/`ilr_lm`
  (transforms + Gaussian models, with the zero-replacement question
  currently handled by the configured zero policy; improvements below).
- **Multinomial / Dirichlet-Multinomial regression** (#17) — effect sizes
  living on the simplex; no pseudocount; Songbird-like. Hard: high-dimensional
  non-convex optimisation, reference-taxon choice, determinism.
- **ANCOM-BC, ALDEx2, Songbird-class methods** (#5) — log-contrast families
  with their own bias corrections.
- **PhILR / SBP ILR bases** (#20) — balances as clades (phylogenetic ILR),
  hypothesis-driven sequential binary partitions, balance dendrograms; the
  *basis* of the ilr is where biology enters.
- **Advanced zero handling** (#21) — zeros are the compositionalist's
  nightmare: sampling zeros vs structural zeros. Bayesian multiplicative
  replacement and glmGamPoi dispersion are queued ahead of trusting ILR
  fully.
- **Occupancy models** (#18) — "absent" vs "undetected" is a latent-variable
  question at the count/zero boundary.

Until those land, the honest position (which the software enforces) is:
report offsets-based `nb_glm` effects as *depth-modelled count effects*, and
`clr_lm`/`ilr_lm` effects as *log-contrast effects under the stated zero
policy* — and never call either "compositional differential abundance
analysis".

## Reading list (for the statistically curious)

Aitchison's log-contrast geometry is the ground (compositions as log-ratios);
Gloor et al. on why relative abundance misleads; the `metagenomeSeq` CSS
paper for the cumulative-sum idea; Nearing et. al. (the Songbird/DIAMOND
line) for multinomial regression as the compositional alternative to
p-value tables. The repository's method-conditions documents cite what each
implementation actually follows.
