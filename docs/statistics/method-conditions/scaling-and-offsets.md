<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Method conditions — library-size scaling and offsets

**Status: published 2026-09-25, before the implementation in
`src/analysis/scaling.jl`.** Where this document and that file disagree, the document is
right and the file is the bug.

**Why it exists now.** Issue #16 specified exact TSS/CSS/RSS behaviour and carried the
line *"Deferred — DO NOT IMPLEMENT IN MILESTONE 3"*. That line is a scope decision, not a
scientific finding, and the owner directed on 2026-09-25 that the remaining deferred
items be implemented. The deferral is therefore lifted here, explicitly and in writing,
for this item only. The conditions below are what "implemented" is allowed to mean.

**What it replaces.** Three normalisation methods that the configuration accepted and
the execution path silently turned into something else:

- `TSS` divided counts by library size and returned **proportions** — the compositional
  transform the issue was written to avoid — for every method except `nb_glm`.
- `CSS` and `RSS` were aliased to `relative` outright, with a `@warn`. Under `nb_glm`
  that produced a proportion table where a count model expects counts.
- `size_factors` was described as "DESeq2 median-of-ratios" in the code and implemented
  as library size divided by its own geometric mean — TSS wearing another method's name.

## What this method is

A **scaling factor** is one positive number per sample; an **offset** is that factor's
logarithm (after a stated centring), handed to a count model so that sequencing depth is
modelled rather than analysed. Neither changes the response. A **transform** (relative,
CLR, ILR, presence/absence) changes what the response *is*. Conflating the two is what
made `nb_glm` + `TSS` report proportions as if they were counts.

All four kinds below return factors normalised to **geometric mean 1**, so the offset is
centred and the constant absorbed by the model's intercept. The uncentred quantities (raw
sums, library sizes, log-ratios) are recorded in the provenance, so the published numbers
can be reproduced without the centring convention.

### TSS — total sum scaling (library size), offset form

- `factor_j = library_size_j / geomean(library_size)`, `library_size_j = Σᵢ xᵢⱼ`.
- Offset `log(factor_j)`. Applicable to count responses only; for a non-count response
  TSS *is* the proportional transform and is reported as `relative`, not as an offset.
- Zeros: nothing is replaced. A sample with total 0 has no library size to divide by and
  is refused — it is reported as an unsuccessful state, never as factor 0 or 1.
- This is the McMurdie & Holmes (2014) argument: keep counts, model depth.

### CSS — cumulative sum scaling (Paulson et al. 2013, metagenomeSeq)

- Per sample `j`: `threshold_j = quantile(x·ⱼ, p)` with `p = css_quantile`
  (default 0.75), using the quantile definition of R's default `type = 7` and Julia's
  `Statistics.quantile` default. All features in the sample participate, zeros included.
- `sum_j = Σ { xᵢⱼ : xᵢⱼ ≤ threshold_j }` — the cumulative sum **up to** the quantile.
- `factor_j = sum_j / geomean(sum)`. Offset `log(factor_j)`.
- Refused when any `sum_j ≤ 0`: with a low quantile on a mostly-zero sample the
  cumulative sum can be zero, and `log(0)` is not a small number. The refusal names the
  sample and the quantile (this is the failure mode issue #16 called out in advance).
- **Not implemented, and not silently substituted:** metagenomeSeq's `cumNormStatFast`,
  which *chooses* `p` from the data. A data-driven choice of a modelling parameter is a
  decision the run has to record; this layer instead requires `p` to be declared by the
  caller and records it. Parity with `metagenomeSeq::cumNorm` is therefore an
  **outstanding condition**, not a claim (see *Evidence*).

### RSS / TMM — trimmed mean of M-values (Robinson & Oshlack 2010, edgeR)

RSS in the issue's configuration vocabulary is the TMM estimator the issue's own text
describes. One sample is the reference; every other sample's factor is a trimmed,
weighted mean of its log-ratios to the reference.

- Library sizes are column sums. The reference sample is the one whose
  upper-quartile-scaled count distribution is closest to the mean of those distributions
  (the edgeR default), or the sample named by `tmm_ref_column`.
- For sample `i` against reference `r`, over features with both counts positive:
  `M = log2(xᵢ/x_r)`, `A = ½·log2(xᵢ·x_r)`,
  `w = (1 − xᵢ/libᵢ)/xᵢ + (1 − x_r/lib_r)/x_r`.
- Features are trimmed by rank: the top `tmm_log_ratio_trim` (default 0.3) and bottom
  `tmm_log_ratio_trim` of `M`, and the tails of `A` beyond `tmm_sum_trim` (default 0.05),
  are dropped. Ties are ranked by first occurrence, matching R's `ties.method = "first"`.
- `factor_i = 2^(Σ M·w / Σ w)` over the kept features, then normalised as above. The
  reference sample gets factor 1 before normalisation.
- Refused when a sample has no positive-count feature in common with the reference, or
  when a library size is zero. A refusal is an unsuccessful state; it is never a factor of
  1 by default.

### `size_factors` — median-of-ratios (RLE)

- Per sample `j`: `factor_j = median { xᵢⱼ / geomean_k(xᵢ·)}` over features whose
  geometric mean across samples is positive. Offset `log(factor_j)`.
- This is the estimator the code previously claimed and did not compute. The previous
  behaviour (library-size centring) is available as `TSS`, which is where it belongs.

### Accepted responses and study designs

- Count responses for `nb_glm` (and any future count model): scaling factors, offsets,
  no modification of the response.
- Non-count responses: TSS is reported as the `relative` transform. CSS, RSS and
  `size_factors` are **refused for non-count responses by the configuration layer** —
  they are offsets, and there is nothing to offset.
- Study design is untouched by this layer. Pairing, blocking and repeated measures are
  still refused by the method layer (see `parametric-fits.md`); a scaling factor is not a
  design.

### Zeros, ties and degenerate samples

- Zeros are neither replaced nor imputed here. A zero count contributes to CSS only
  through the threshold rule, and to TMM not at all (pairwise-positive features only).
- All-zero samples are refused by name before any factor is computed.
- Constant samples (`xᵢⱼ = c` for all `i`) are defined: TSS and CSS give every such sample
  the same factor; TMM's log-ratios are all 0, giving factor 1; RLE gives factor 1
  (each ratio is 1). None of these is special-cased — the mathematics already holds.
- Ties in `M` and `A` are ranked deterministically by first occurrence, so a run is
  reproducible; this is asserted, because R's default and a naive sort differ on ties.

### Diagnostics and provenance

Every run that computes factors records, in `diagnostics.checks["scaling"]` and in the
manifest provenance:

- the kind (`tss`, `css`, `rss`, `size_factors`) and the definition sentence for it;
- the declared parameters: quantile, trims, named reference (if any), and which sample
  was chosen as the reference when it was chosen from the data;
- the raw quantities before centring (cumulative sums, library sizes, or log-ratio means)
  and their geometric mean, so the paper's numbers are recoverable;
- every warning (for example: very low `css_quantile`, or a weighted mean that fell back
  to unweighted because all weights were zero).

### Computational limits

All four are O(n_features × n_samples), with an O(n log n) sort per sample for CSS and
per pair for TMM. No per-run memory bound has been measured or is claimed. A large
feature count costs time linearly; nothing here is iterative and nothing is randomised.

## Evidence, as delivered

In `test/unit/test_scaling.jl` and `test/unit/test_execution.jl`:

- **Known answers from first principles** — factors for a hand-computable table, with the
  arithmetic written out next to the expected number, not recorded from a previous run.
- **Properties that a wrong implementation fails**: doubling every count in one sample
  doubles that sample's TSS factor; a sample that is an exact multiple of another has a
  factor equal to that multiple (TMM, all log-ratios equal); permuting features does not
  change any factor; scaling every sample by the same constant changes nothing.
- **CSS robustness to an outlier** — adding one dominant feature to one sample moves its
  TSS factor far more than its CSS factor, which is the property CSS exists for.
- **Negative controls** — zero-total sample, `css_quantile` low enough to give a zero
  cumulative sum, unknown `tmm_ref_column`, out-of-range trims, and CSS/RSS on a
  non-count response all refused, each with the reason named.
- **Integration** — `prepare_analysis_table` keeps counts as the response under `nb_glm`
  and hands the offset to `run_analysis`; the manifest records the parameters; the offset
  hash changes when the parameters change.
- **Limits, stated rather than hidden**: parity with `metagenomeSeq::cumNorm` and
  `edgeR::calcNormFactors` at 1e-6 is **not verified here**. Neither package is in the
  pinned R environment (`renv.lock`), and this repository does not add an unpinned R
  dependency to make a test pass. A transcription cross-check in R is included for TMM
  (same author, different language: it catches implementation slips, not specification
  errors) and is labelled as such. This is recorded as an outstanding condition in
  issue #16 rather than claimed as met.

## Explicitly not claimed

- No scaling factor makes compositional data safe. CSS and TMM correct library size;
  they do not remove the compositional constraint, and a log fold change from a model
  with these offsets is still relative to the sampled community. Issue #16 asked for
  this warning in the user-facing help, and it is there.
- TMM's exchangeability assumption (most features not differentially abundant) is not
  testable from the data and is not checked. An experiment where a large fraction of
  features moves in the same direction will bias TMM; nothing here detects that.
- CSS's data-driven quantile (`cumNormStatFast`) is not implemented; the declared
  quantile must be chosen by the analyst and is recorded.
- No claim is made that these estimates are more accurate than the alternatives for any
  particular dataset. They are named, computed, and recorded; choosing between them is
  the analyst's decision, and the choice is in the provenance.
