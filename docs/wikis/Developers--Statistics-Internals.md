<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000033
parent: 0198ba50-0000-7000-8000-000000000030
position: 30
kind: page
tags:
  - developers
  - statistics
archived: false
-->

# Statistics internals

**Status: PARTIAL — implemented with strong tests; independent review (#1)
outstanding.** The module map and the contracts; the mathematics is in
[Deep Dives](Deep-Dives).

## The modules and what each may claim

| Module | Owns | May claim | May never claim |
|---|---|---|---|
| `numeric_policy.jl` | `NumericPolicySpec` (modes `:ordinary`, `:exact_counts`, `:high_precision`) | exactness of integers/rationals; bounded denominators; display rounding | that high precision is exactness |
| `exact_summaries.jl` | counts + proportions at exact precision | exact descriptive facts (incl. counts > 2⁵³−1) | any inference |
| `estimation.jl` | per-feature ML fits (`nb_glm`, `clr_lm`, `ilr_lm`, `logistic`) | estimates **or** named unsuccessful states | a number when a fit fails |
| `scaling.jl` | size factors + offsets (TSS/CSS/RSS) | depth modelling without touching the response | that offsets solve compositionality |
| `AnalysisConfig.jl` + `Execution.jl` | immutable config; the run path | what the user actually asked for | silent substitution of a nearby method |
| `diversity.jl` / `analysis.jl` | indices, charts, NMDS/PERMANOVA | descriptive + vegan-backed ordination | significance without status |
| `epistemic.jl` | statuses, receipts, DANGER banner | *how* a result is warranted | soundness of a warrant (deliberately) |

The contracts the code is held to (published **before** implementation, and
the tests check code against documents, not the reverse):

- `docs/statistics/numeric-contracts.md` — exact/approximate/rounded; what
  may cross each boundary; what is refused (`assert_mode` fails rather than
  handing a Float64 that looks exact).
- `docs/statistics/method-conditions/exact-descriptive-summaries.md` —
  catalogue item 1. Surfaced two real defects under the layer (`to_display`
  labelling a rendering *6dp* then printing 80 digits; `2//3` syntax leaking
  into user text) — the conditions doc caught both.
- `docs/statistics/method-conditions/parametric-fits.md` — catalogue item 2:
  the four methods' response types, refusals, determinism (no resampling, no
  random start; the recorded seed is honestly labelled "not a parameter of
  any number here").
- `docs/statistics/method-conditions/scaling-and-offsets.md` — factors vs
  offsets vs **transforms**; the three historical substitutions it forbids
  (TSS→proportions; CSS/RSS→`relative`; `size_factors`→TSS wearing DESeq2's
  name) and why "the document is right and the file is the bug".

## The run path

`Execution.run_analysis` is the only door the server uses: parse/validate
`AnalysisConfig` → assert numeric mode → dispatch to the modules → compose
Plotly specs. Ordering rules that bite newcomers:

1. Zero-depth samples are **healed before** any transform (#58) — transforms
   are not zero-safe and are not claimed to be.
2. Offsets attach at the fit (log of the size factor, stated centring);
   the response stays counts.
3. BH (`p.adjust`, R) is attached wherever several tests are reported — the
   DANGER banner path exists to make disabling it loud.
4. A refusal short-circuits *with a name* (non-convergence, non-identifiable,
   boundary estimate, precondition failure, resource limit). Downstream chart
   builders receive the state and render it as such.

## Where the R lives

`MASS::glm.nb` (NB-GLM), `stats::lm` (CLR/ILR), `stats::glm(family=binomial)`
(logistic), `p.adjust` (BH), vegan (`vegdist`/`adonis`-family for NMDS/
PERMANOVA) — reached through `src/core/r_runtime.jl`. R's `NA` is read as
missing (#66's lesson). The independent reference tests fit the same fixtures
in R and compare coefficient-by-coefficient — that suite is the reason to
trust the bridge at all.

## Anti-patterns this layer has already survived (do not reintroduce)

- **Placeholder-as-result:** p-values once derived from `hash(taxon_id)`.
  Removed; a source-level guard test now fails if anything similar returns.
  If you are tempted to stub a statistic to unblock a UI, return an
  unsuccessful state — the UI already knows how to render one.
- **Silent method substitution:** accepting `CSS` and computing `relative`.
  Method names compare in lower case (#62) and unknown/aliased methods refuse.
- **Precision-laundering:** printing a rounded display labelled as exact.
  `to_display` is contract-tested.

## Extending it

Adding a method = conditions document first (response types, design support,
zeros, overdispersion/depth, uncertainty + multiple testing, diagnostics,
computational limits), then code, then tests with known answers + negative
controls for every refusal path. See
[Extending the Pipeline](Developers--Extending-the-Pipeline).
