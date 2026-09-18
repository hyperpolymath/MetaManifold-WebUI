<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->
# Issue: Occupancy models — presence/absence with imperfect detection, zero-inflation beyond NB

**Title:** `feat(analysis): Occupancy models — presence/absence with imperfect detection, zero-inflated NB, hurdle models`

**Labels:** `enhancement`, `analysis`, `deferred`, `zero-inflation`, `scientific-value:high`, `difficulty:hard`

**Body:**

### Scientific Value
Current v1 has logistic for presence/absence (assumes perfect detection) and NB_GLM for counts (assumes zeros are true absences, not detection failures). Real microbiome data has imperfect detection: zero may be true absence or undetected presence due to low biomass, sequencing depth, or primer bias.

Occupancy models (MacKenzie et al. 2002 ecology, adapted to microbiome) separate occupancy (true presence) from detection (observed presence given occupancy):

- **Occupancy (ψ):** Probability taxon truly present in sample, modeled as logit(ψ) = X beta
- **Detection (p):** Probability taxon detected given present, modeled as logit(p) = W gamma, where W may include log(library size), batch, primer
- **Value:** Distinguishes true absence from undetected presence, reduces false negatives for rare taxa, accounts for variable detection due to library size.
- **Zero-inflated NB (ZINB) and Hurdle:** Two-part models: zero-inflation part (logistic) + count part (NB). Value: handles excess zeros beyond NB expectation (common in sparse microbiome), provides both presence and abundance effects.

Use case: Low-biomass samples (e.g., skin, lung) where many zeros are detection failures, not true absences. Occupancy model with library size as detection covariate gives more accurate occupancy estimates.

Impact: More accurate presence/absence and abundance inference for sparse data, which is most microbiome data (80% zeros typical).

### Scope (Deferred)
- New methods: `occupancy`, `zinb`, `hurdle_nb`, `hurdle_lognormal`
- Normalization: occupancy uses detection covariates (library size, batch), not size_factors for occupancy part; count part may use size_factors
- Zero handling: occupancy explicitly models zeros as mixture, so zero_policy = `occupancy` or `hurdle`, not pseudocount/refuse
- Implementation:
  - R: `unmarked::occu` for occupancy, `pscl::zeroinfl` for ZINB, `MASS::glm.nb` + custom hurdle, or `glmmTMB` for ZINB with random effects
  - Julia: `Turing.jl` for Bayesian occupancy, `MixedModels.jl` for ZINB via `glmmTMB` equivalent, or pure Julia via `Optim.jl`
- AdvancedConfig: add `occupancy_detection_formula`, `zinb_zero_formula`, `hurdle_count_dist` (nb, lognormal, poisson)
- Validation: detection formula must reference columns that affect detection (e.g., library size, batch), not biological group (unless group affects detection, but then warning)
- Nickel: new enum values, contracts for detection formula existence
- DEED: `(method :name "occupancy" :detection-formula "~ log_libsize + batch")`
- Frontend: context_help explains occupancy vs logistic vs ZINB, when to use, detection vs occupancy

### Difficulty
**Hard** — requires:
- Statistical: Occupancy likelihood is mixture, non-convex, may have identifiability issues if detection covariates collinear with occupancy covariates. Need to check identifiability (e.g., detection formula should not be same as occupancy formula, or at least include library size).
- Implementation: R `unmarked` requires detection history (multiple visits per site), but microbiome has single visit per sample — need to adapt to single-visit occupancy via `RPresence` or custom. Or use ZINB as approximation.
- Performance: Occupancy EM algorithm O(n_taxa * n_samples * n_iter), for 10k taxa x 100 samples x 100 iterations ~ 100M operations, maybe minutes.
- Memory: ZINB stores two models (zero + count) per taxon, double memory vs NB_GLM.
- Validation: compare occupancy ψ and p vs R `unmarked` and `pscl::zeroinfl` for 3 datasets, with known detection probabilities.
- Testing: simulate data with known ψ and p, check recovery.

### Risks
- **Identifiability:** If detection and occupancy covariates same, model non-identifiable, may give nonsense estimates. Need heavy validation: refuse if detection_formula == occupancy formula and no library size in detection, or warn strongly.
- **Scientific misuse:** Occupancy models assume closure (true occupancy doesn't change during detection), but microbiome sampling is destructive (one time point). Need context help explaining assumptions and that single-visit occupancy is controversial, with citations.
- **Performance regression:** Occupancy 10x slower than logistic, ZINB 2x slower than NB_GLM. Must be behind Advanced Analysis, benchmarked, fail CI if existing methods regress >10%.
- **Zero-inflation confusion:** ZINB zero-inflation may be confused with NB overdispersion. Need context help explaining difference: NB already handles some zeros via overdispersion, ZINB handles excess zeros beyond NB. Risk of overfitting if ZINB used when NB sufficient — need to advise using ZINB only if DHARMa residual test shows excess zeros.
- **Dependency:** `unmarked`, `pscl`, `glmmTMB` are R packages with heavy dependencies (lme4, TMB, Rcpp), may conflict with renv.lock. Mitigation: pure Julia implementation for ZINB via `MixedModels` or `Turing`.
- **Provenance:** Must store detection formula, zero formula, count distribution, otherwise not reproducible. Missing provenance breaks DOI bundle.

### Acceptance Criteria
- [ ] New methods `occupancy`, `zinb`, `hurdle_nb` in AnalysisConfig v2, with `occupancy_detection_formula`, `zinb_zero_formula`, `hurdle_count_dist`
- [ ] Validation: detection formula must include library size or batch or be different from occupancy formula, otherwise refuse or warn; zero formula must be valid R formula; count dist must be nb/lognormal/poisson
- [ ] BH mandatory, DANGER banner preserved
- [ ] Tests: simulate data with known ψ=0.7, p=0.5, check occupancy recovers ψ within 0.1 for 100 taxa; ZINB vs NB via Vuong test for excess zeros
- [ ] Benchmark: runtime and memory for 100, 1000 taxa, with warning if >5 min, fail CI if existing methods regress >10%
- [ ] Nickel, DEED, JSON schemas updated
- [ ] Context help explains occupancy vs logistic vs ZINB vs hurdle, with citations (MacKenzie 2002, Martin et al. 2005 ZINB, Hu et al. 2018 microbiome occupancy)
- [ ] Frontend: Advanced Analysis expander, detection formula editor with library size autocomplete, estimated runtime, identifiability check
- [ ] Docs: explains assumptions (closure, single-visit), when to use, how to interpret ψ and p, and that occupancy is still debated for microbiome

### Related
- Blocked by: AnalysisConfig v1, TSS/CSS/RSS (needs library size handling)
- Blocks: Exact stats layer (occupancy with exact detection), DOI bundle v2
- References: MacKenzie et al. 2002 Ecology occupancy, Martin et al. 2005 J Anim Ecol ZINB, Hu et al. 2018 Microbiome occupancy for microbiome, Paulson et al. 2013 CSS (zero handling)
