<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->
# Issue: Multinomial and Dirichlet-Multinomial models for compositional counts

**Title:** `feat(analysis): Multinomial and Dirichlet-Multinomial models — Songbird-like multinomial regression, DM for overdispersed compositions`

**Labels:** `enhancement`, `analysis`, `deferred`, `compositional`, `scientific-value:high`, `difficulty:hard`

**Body:**

### Scientific Value
Current v1 has NB_GLM (counts per taxon independent, not compositional) and CLR/ILR+LM (compositional but Gaussian on log-ratios, not count-based). Multinomial models treat the vector of counts per sample as compositional directly:

- **Multinomial (MN):** Sample counts ~ Multinomial(total, p) where log(p_j / p_ref) = X beta. Ranks taxa by association with covariates (like Songbird). Value: interpretable as log-fold change in relative abundance, handles compositionality without pseudocount (zeros handled via count likelihood, not log(0)).
- **Dirichlet-Multinomial (DM):** Adds overdispersion to MN via Dirichlet prior on p, accounts for extra-multinomial variation (common in microbiome, technical + biological variance). Value: more accurate standard errors than MN, reduces false positives from overdispersion. Used in HMP, La Rosa et al. 2012.
- **Use case:** Diet intervention where total load unchanged but composition shifts — NB_GLM may call many taxa differential due to library size confounding, MN/DM correctly identifies compositional shift.

Impact: Bridges gap between count-based and compositional, provides effect sizes that are compositionally coherent (sum to zero in log-ratio space), avoids pseudocount tuning.

### Scope (Deferred)
- New methods in AnalysisConfig v2: `multinomial`, `dirichlet_multinomial`, `songbird` (alias for multinomial with TensorFlow)
- Normalization: MN/DM use total as offset, not size_factors; normalization.method = `none` or `multinomial` (total as denominator)
- Zero handling: MN handles zeros naturally (likelihood includes zero count), but needs epsilon for log(p) when p=0 in optimization — use same epsilon as AdvancedConfig
- Implementation options:
  - Pure Julia: `Turing.jl` or `Optim.jl` for MN/DM MLE, DirichletMultinomial from `DirichletMultinomial.jl` or custom
  - R: `MGLM::MGLMreg` for MN/DM, `HMP::DM.MoM` for DM moments
  - Python: `songbird` via `PythonCall.jl` or subprocess (multinomial regression with TensorFlow)
- AdvancedConfig: add `mn_reference_taxon`, `dm_overdispersion_method` (mom, mle), `mn_penalty` (L1 for Songbird-like)
- Nickel: new enum values `multinomial`, `dirichlet_multinomial`, contracts for reference taxon existence
- DEED: `(method :name "multinomial" :reference-taxon "Bacteroides")`
- Frontend: context_help explains MN vs DM vs NB_GLM vs CLR, when to use

### Difficulty
**Hard** — requires:
- Optimization: MN is convex (multinomial logistic regression) but high-dimensional (p = n_taxa x n_covariates), need L1 penalty or filtering (max_features). For 10k taxa x 100 samples x 5 covariates = 50k parameters, need efficient solver (e.g., `MLJ` or `GLMNet`).
- DM: non-convex, needs EM or Newton-Raphson, may have local optima. Must test convergence.
- Zero handling: MN likelihood with p_j=0 and count>0 is -Inf, so need to ensure p_j>0 via softmax, but optimization may still push p_j→0. Need epsilon and bounds.
- Performance: MN with 10k taxa, 100 samples, 5 covariates, L-BFGS ~ minutes, not seconds. Must be behind Advanced Analysis, with benchmark and estimated runtime warning.
- Memory: DM covariance matrix n_taxa x n_taxa if full, but diagonal approximation feasible. For 10k taxa, full covariance 10k^2 ~ 800MB, too large — must use diagonal or low-rank.
- Validation: compare coefficients vs R `MGLM` and Python `songbird` for 3 datasets.

### Risks
- **Performance regression:** MN/DM 10-100x slower than NB_GLM, may timeout in CI. Must fail loudly if runtime >10x, not silently. Need separate benchmark lane, not part of main CI gate for existing methods (but still fail if existing methods regress >10%).
- **Scientific controversy:** Compositional methods debated — MN/DM assume compositionality but not absolute abundance. Need balanced context help, not claiming MN solves all compositional issues. Risk of users over-interpreting MN as absolute.
- **Numerical instability:** Softmax with large logits overflows, need log-sum-exp trick. DM with small overdispersion → MN, with large → unstable. Need heavy validation of overdispersion parameter in (0, Inf), warning if >100.
- **Dependency:** If using Python Songbird, adds TensorFlow dependency (non-deterministic, GPU vs CPU, seed). Must record seed, version, and make deterministic, otherwise DOI bundle not reproducible. Risk of breaking reproducibility.
- **Reference taxon:** MN requires reference taxon (e.g., last taxon or user-specified). Choice affects interpretation (log-ratio vs reference). If reference is rare or zero in many samples, coefficients unstable. Need validation: reference must have min_prevalence >=0.5 and min_abundance >0, otherwise refuse.
- **Provenance:** Must store reference taxon, penalty, overdispersion method, seed, otherwise not reproducible.

### Acceptance Criteria
- [ ] New methods `multinomial`, `dirichlet_multinomial` in AnalysisConfig v2, with `mn_reference_taxon`, `dm_overdispersion_method`, `mn_penalty`
- [ ] Validation: reference taxon exists, prevalent, not zero-inflated; penalty >=0; overdispersion in (0, Inf)
- [ ] BH mandatory, DANGER banner preserved
- [ ] Tests: coefficients match R MGLM and Python songbird within 1e-3 for 3 datasets (mock, gut, soil) with 100 taxa subset
- [ ] Benchmark: runtime and memory for 100, 1000, 10000 taxa, with warning if >5 min, fail CI if existing methods regress >10%
- [ ] Nickel, DEED, JSON schemas updated
- [ ] Context help explains MN vs DM vs NB_GLM vs CLR, with citations (Morton et al. 2019 Songbird, La Rosa et al. 2012 DM, Gloor et al. 2017 compositional)
- [ ] Frontend: Advanced Analysis expander, reference taxon selector with prevalence filter, estimated runtime
- [ ] Docs: explains compositional coherence, reference choice, overdispersion, when to use vs NB_GLM

### Related
- Blocked by: AnalysisConfig v1, TSS/CSS/RSS (needs exact normalization comparison)
- Blocks: Advanced compositional (ANCOM-BC, ALDEx2 comparison)
- References: Morton et al. 2019 mSystems Songbird, La Rosa et al. 2012 Biostatistics DM, Gloor et al. 2017 Front Microbiol compositional
