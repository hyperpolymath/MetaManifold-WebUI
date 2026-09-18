<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->
# Issue: Advanced zero handling and dispersion — glmGamPoi, Bayesian multiplicative replacement, multiplicative replacement

**Title:** `feat(analysis): Advanced zero handling — glmGamPoi dispersion, Bayesian multiplicative replacement, multiplicative replacement with delta`

**Labels:** `enhancement`, `analysis`, `deferred`, `zero-handling`, `scientific-value:medium`, `difficulty:medium`

**Body:**

### Scientific Value
Current v1 has pseudocount (default 0.5) and basic zero handling, with `multiplicative_replacement`, `bayesian_multiplicative`, `refuse` allowed but `multiplicative_replacement` and `bayesian_multiplicative` only partially implemented (delta validation but not exact replacement). `glmGamPoi` dispersion method allowed but not implemented (currently alias to parametric).

Exact implementations improve:

- **glmGamPoi (Ahlmann-Eltze & Huber 2020):** Fast, accurate dispersion estimation for NB GLM, uses quasi-likelihood, 10x faster than DESeq2 parametric, better for large n (100+ samples). Value: speeds up NB_GLM for large studies, more accurate for small counts.
- **Multiplicative Replacement (Martín-Fernández et al. 2003):** Replaces zeros with delta * (geometric mean of non-zeros) * (something), then multiplicatively adjusts non-zeros to preserve total. Preserves ratios, better than pseudocount for compositional (CLR/ILR). Value: less distortion than pseudocount, especially for low-abundance taxa.
- **Bayesian Multiplicative (Martín-Fernández et al. 2015):** Bayesian version of multiplicative replacement, uses Dirichlet prior, provides posterior distribution of replacement, accounts for uncertainty. Value: more robust, provides uncertainty for zeros, better for sparse data.
- **Delta parameter:** For multiplicative replacement, delta in (0,1) controls replacement magnitude, e.g., delta=0.65 * detection limit. Value: allows tuning, but needs validation and context help.

Use case: Sparse gut microbiome with 80% zeros, pseudocount 0.5 distorts low-abundance taxa (e.g., 0 -> 0.5 vs 1 -> 1.5, ratio 1:3 vs true 0:1). Multiplicative replacement preserves ratios better.

Impact: More accurate zero handling for compositional methods, faster dispersion for NB_GLM, reduces pseudocount bias.

### Scope (Deferred)
- Implement glmGamPoi: via R `glmGamPoi::glmGamPoi` or pure Julia via `GLM` + custom, compute dispersion per taxon, store in AdvancedConfig
- Implement multiplicative replacement: `zCompositions::cmultRepl` or pure Julia, with delta parameter, replace zeros, adjust non-zeros multiplicatively
- Implement Bayesian multiplicative: `zCompositions::cmultRepl` with `method="GBM"` or `Bayes` or pure Julia via Dirichlet sampling
- Extend NormalizationConfig: `multiplicative_replacement_delta` already exists, validate in (0,1), add `bayesian_multiplicative_alpha` (Dirichlet prior concentration)
- Extend AdvancedConfig: `dispersion_method` already includes `glmGamPoi` (currently alias), implement exact; add `zero_replacement_method` (pseudocount, multiplicative, bayesian), `multiplicative_delta`, `bayesian_alpha`
- Nickel: contracts for delta in (0,1), alpha >0, dispersion method compatibility with NB_GLM
- DEED: `(normalization :method "clr" :zero-policy "multiplicative_replacement" :multiplicative-replacement-delta 0.65)`
- Frontend: context_help explains pseudocount vs multiplicative vs Bayesian, when to use, delta tuning, with warnings for small delta
- Provenance: store delta, alpha, dispersion method, replacement method

### Difficulty
**Medium** — requires:
- R packages: `glmGamPoi` (Bioconductor, depends on `beachmat`, `DelayedArray`), `zCompositions` (for multiplicative and Bayesian), or pure Julia implementation
- Validation: compare dispersion vs R `glmGamPoi` for 3 datasets, compare replacement vs `zCompositions::cmultRepl` for 3 datasets within 1e-6
- Performance: glmGamPoi is fast (10x faster than parametric), multiplicative replacement O(n_taxa * n_samples) for 10k taxa x 100 samples = 1M operations, trivial
- Memory: negligible for replacement, but glmGamPoi stores dispersion vector length n_taxa, trivial
- Testing: unit tests for delta validation (0,1), alpha >0, dispersion method compatibility, integration tests for replacement preserving total and ratios

### Risks
- **Performance regression:** glmGamPoi is faster, not slower, so no regression risk, but if implemented in R via RCall, adds R runtime lock contention. Must be behind Advanced Analysis, benchmarked, fail CI if existing dispersion methods regress >10%.
- **Scientific misuse:** Multiplicative replacement still distorts, just less than pseudocount. Need context help explaining that all zero replacement is biased, and that occupancy models or ZINB may be better for sparse data. Risk of users thinking multiplicative replacement solves zero problem — must warn.
- **Delta tuning p-hacking:** Users could try many deltas until significant, then report only one. Need to log delta in provenance and DOI bundle, with DANGER banner if delta changed many times (e.g., >3 deltas tried).
- **Dependency:** `glmGamPoi` and `zCompositions` are Bioconductor/CRAN, may conflict with renv.lock. Mitigation: pure Julia fallback for multiplicative replacement (simple formula), and for glmGamPoi use `GLM` + custom quasi-likelihood.
- **Provenance:** Must store delta, alpha, dispersion method, replacement method, otherwise not reproducible. Missing provenance breaks DOI bundle.
- **Numerical:** Multiplicative replacement with delta close to 0 or 1 may cause underflow or overflow, need validation and warnings.

### Acceptance Criteria
- [ ] glmGamPoi dispersion implemented, not aliased, fast, accurate vs R `glmGamPoi` within 1e-6 for 3 datasets
- [ ] Multiplicative replacement implemented, preserves total and ratios, vs `zCompositions::cmultRepl` within 1e-6
- [ ] Bayesian multiplicative implemented, provides posterior, vs `zCompositions` with Bayes method
- [ ] Delta validation in (0,1), alpha >0, warnings for small/large delta
- [ ] BH mandatory, DANGER banner preserved
- [ ] Tests: unit tests for delta, alpha, dispersion method, integration tests for replacement and dispersion
- [ ] Benchmark: runtime and memory for 100, 1000, 10000 taxa, with warning if >5 min, fail CI if existing methods regress >10%
- [ ] Nickel, DEED, JSON schemas updated (delta already in schema, but need alpha)
- [ ] Context help explains pseudocount vs multiplicative vs Bayesian, with citations (Martín-Fernández 2003, 2015, Ahlmann-Eltze 2020 glmGamPoi), when to use, delta tuning, warnings
- [ ] Frontend: Advanced Analysis expander, zero_policy selector, delta slider with preview of replacement effect, dispersion method selector, estimated runtime
- [ ] Docs: explains zero handling, why zeros are problematic for log-ratios, and that all replacement is biased, with alternatives (occupancy, ZINB)

### Related
- Blocked by: AnalysisConfig v1, TSS/CSS/RSS (needs normalization comparison)
- Blocks: Advanced compositional (ANCOM-BC vs multiplicative), DOI bundle v2
- References: Martín-Fernández et al. 2003 Math Geol multiplicative replacement, Martín-Fernández et al. 2015 J Chemom Bayesian, Ahlmann-Eltze & Huber 2020 Genome Biology glmGamPoi
