<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000047
parent: 0198ba50-0000-7000-8000-000000000040
position: 70
kind: page
tags:
  - theory
  - statistics
  - roadmap
archived: false
-->

# Advanced functionality — the coming suite

**Status: COMING throughout (one item BLOCKED by design).** The advanced
statistical and exploration suite, in its approved order, with the design
reasoning and the risks each item carries. This is the "what is coming"
half of the honesty contract — written down in depth so nobody has to guess.
Specifications of record: `docs/issues/milestone3/` (six numbered specs),
`docs/milestones/02-deferred-issues.md`; issues #3, #5–8, #17–21.

## The gate that governs all of it

Every method below enters through the same door as the current layer:
**publish its supported/unsupported conditions first, implement second.**
The conditions template (already in force) demands: response types and zero
handling; study-design support (pairing, blocking, repeated measures,
covariates, depth, compositionality); overdispersion and depth policy
named, not defaulted; uncertainty (interval method, effect size, BH —
mandatory); diagnostics including "the assumption most likely to be wrong";
computational limits and the states at them.

The approved dependency order (the queue, honestly):

## 1. Exact statistical tests — issue #3 (the flagship)

*Why:* asymptotics fail at small n and sparse features — rare biosphere,
low-biomass, clinical cohorts. The motivating case from the issue: pathogen
detection where 2/3 cases vs 0/20 controls *should* be significant.

*Scope:* Fisher's exact (2×2 presence/absence vs group); exact negative
binomial test (the edgeR `exactTest` shape: exact tail mass under the NB
model); permutation-based exact p-values for NB-GLM (parametric bootstrap);
exact CLR/ILR inference by permuting Aitchison distances. AnalysisConfig
methods `exact_fisher`, `exact_nb`, `permutation_nb`.

*Design notes and risks (why it is not trivial):* Fisher on large tables
needs the network algorithm (O(n!) is not a strategy); permutation storage
(B=10⁴ resamples × 10⁴ taxa) is ~GB — resample-wise batching required;
**exact is not assumption-free** — exchangeability under the null is still
required and the context help must say so (exact tests can be uselessly
conservative); edgeR/BiocParallel enter `renv.lock` with all the fragility
that implies. Acceptance: p-values match R's `fisher.test` on known tables;
benchmarks show <10% regression on existing methods; estimated runtime shown
before launch (it will sit behind the Advanced expander).

*Note the naming:* "exact test" means the tail mass is enumerated rather
than asymptotically approximated — see
[Exact Arithmetic](Deep-Dives--Exact-Arithmetic) for why that is still not
"exact numbers".

## 2. Multinomial and Dirichlet-Multinomial — issue #17

*Why:* bridges count models and compositional geometry — effect sizes that
are log-contrasts, compositionally coherent, **no pseudocount**. The
Songbird-shaped answer to "p-values on a simplex are awkward".

*Risks recorded in the spec:* high-dimensional non-convex optimisation (DM
especially); 10–100× runtime; reference-taxon choice changes the story
(unstable bases must surface); determinism is hard if any learned component
sneaks in (the layer's determinism rule forbids that).

## 3. Occupancy models — issue #18

*Why:* presence/absence with imperfect detection — distinguishing true
absence from "not detected", the zero-inflation/hurdle family. Reduces false
negatives for rare taxa.

*Risks:* non-identifiability when detection and occupancy share parameters
(single-visit adaptation is genuinely controversial); ZINB vs NB
overfitting — the diagnostics must make the choice visible, not default.

## 4. Constrained ordinations — issue #19

*Why:* RDA/CCA/CAP/dbRDA with permutation tests and variance partitioning —
beta diversity *explained by covariates*, the community-level complement to
per-taxon models.

*Risks:* RDA with Bray–Curtis is a misuse magnet (distance-based form is
the right tool — the help must say which); permutation p-values are only as
good as the exchangeability structure; 999-permutation cost at scale;
biplot UI is its own project.

## 5. PhILR / SBP ILR bases — issue #20

*Why:* biologically meaningful ILR balances — phylogenetic ILR (balances as
clades), sequential binary partitions (hypothesis-driven), balance
dendrograms for display. This is where the ilr's arbitrary basis becomes a
scientific choice.

*Risks:* SBP flexibility is a p-hacking surface (pre-registration guidance
belongs in the UI copy); phylogeny accuracy bounds the method; O(n²) memory
(~800 MB at 10k taxa) — budgeted in the conditions.

## 6. Advanced zero handling and dispersion — issue #21

*Why:* zeros distort transforms ([Compositional
Statistics](Deep-Dives--Compositional-Statistics)); glmGamPoi gives faster,
stabler dispersion for big count matrices; Bayesian multiplicative
replacement propagates zero-replacement uncertainty instead of laundering
it through a pseudocount.

*Risks:* replacement choices are conclusions, not settings — the receipt
must carry which was used; dependency weight (glmGamPoi, zCompositions).

## 7. The compositional grand family — issue #5

ANCOM-BC, ALDEx2, Songbird-class methods — log-contrast inference with bias
corrections. Landed behind and dependent on the above.

## The exploration layer — issues #6–8

- **CladeCumulus (#6)** — cumulative cladistic explorer: tree with
  cumulative frequencies, epistemic colour coding
  ([Epistemic Status](Deep-Dives--Epistemic-Status)), cloud sizing by
  residual count, drag-and-drop re-partitioning with live
  `present_in_every_admissible_world` validation. Scaffold in place; the UI
  rides its branch.
- **Full Evidence Mode (#7)** — the epistemic editor and fibre visualiser
  (the `avec_fibre` story made visible).
- **Zenodo DOI minting (#8)** — automated citable release of a study's
  artefacts; a recoverable publication-and-citations slice is in draft
  (PR #74).

## The blocked one — the symbolic engine, issue #2

Formula manipulation, contrast derivation, provenance-carrying algebra —
**BLOCKED**, deliberately and formally: a symbolic layer over unvalidated
numeric machinery would launder approximate results through exact-looking
notation. The unblock condition is named (validation of the numeric layer on
real biological data — issue #1's review is on that path). This is not
neglect; it is the same refusal discipline the runtime enforces, applied to
project management. When it comes, it is where identity types earn their
keep — proof-carrying manipulation, not string rewriting
([Type Theory Meets Statistics](Deep-Dives--Type-Theory-Meets-Statistics)).

## What all of this does to the docs

Each landing updates, in order: its method-conditions document (first),
the catalogue, [Analysis and Statistics Today](Users--Analysis-and-Statistics-Today),
[Status and Roadmap](Status-and-Roadmap), and the EXPLAINME gaps list. The
README's "Planned" note shrinks as items cross to IN PLACE — and only then.
