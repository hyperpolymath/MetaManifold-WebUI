<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->
# Issue: Constrained ordinations — RDA, CCA, CAP, dbRDA for beta-diversity explained by covariates

**Title:** `feat(analysis): Constrained ordinations — RDA, CCA, CAP, dbRDA, with permutation tests and variance partitioning`

**Labels:** `enhancement`, `analysis`, `deferred`, `ordination`, `beta-diversity`, `scientific-value:high`, `difficulty:hard`

**Body:**

### Scientific Value
Current v1 has diversity.jl for alpha/beta diversity (Shannon, Bray-Curtis, UniFrac) but no constrained ordination to explain beta-diversity by covariates. Constrained ordinations are standard for microbiome beta-diversity:

- **RDA (Redundancy Analysis):** Linear constrained ordination, extends PCA with covariates. Model: Y (taxa table, CLR-transformed) ~ X (metadata). Value: tests how much variance in community composition explained by group, batch, age, etc., with R2 and p-value via permutation.
- **CCA (Canonical Correspondence Analysis):** Unimodal constrained ordination, for presence/absence or abundance with chi-square distance. Value: for gradient analysis (e.g., pH gradient).
- **CAP (Canonical Analysis of Principal Coordinates, Anderson & Willis 2003):** Constrained version of PCoA, uses any distance (Bray-Curtis, UniFrac) + covariates. Value: combines beta-diversity distance with covariate explanation, more flexible than RDA/CCA.
- **dbRDA (distance-based RDA, Legendre & Anderson 1999):** RDA on PCoA axes, similar to CAP but with different algorithm. Value: standard in vegan, widely used.

Use case: Study with groups and batches, want to know if group explains beta-diversity after controlling for batch. Constrained ordination with formula `~ group + Condition(batch)` gives variance partitioning.

Impact: Enables beta-diversity hypothesis testing with covariates, not just alpha and per-taxon differential abundance. Complements NB_GLM/CLR_LM (per-taxon) with community-level test.

### Scope (Deferred)
- New methods in AnalysisConfig v2 or new OrdinationConfig (separate from AnalysisConfig, but linked): `rda`, `cca`, `cap`, `dbrda`
- Formula: same as AnalysisConfig, e.g., `~ group + batch`, but for community table, not per taxon
- Distance: for CAP/dbRDA, need distance metric (bray, unifrac, jaccard, euclidean on CLR)
- Implementation:
  - R: `vegan::rda`, `vegan::cca`, `vegan::capscale` (CAP), `vegan::dbrda`, with `anova.cca` for permutation tests
  - Julia: `MultivariateStats.jl` for RDA (PCA + regression), `Distances.jl` for distances, custom for CCA/CAP
- AdvancedConfig: add `ordination_distance`, `ordination_scaling` (1 or 2), `permutations` (999), `variance_partitioning` bool
- Nickel: new enum for ordination methods, contracts for distance compatibility
- DEED: `(ordination :method "rda" :formula "~ group + batch" :distance "bray" :permutations 999)`
- Frontend: context_help explains RDA vs CCA vs CAP vs dbRDA, when to use, scaling, variance partitioning
- Provenance: store distance, scaling, permutations, formula

### Difficulty
**Hard** — requires:
- Statistical: Constrained ordination involves eigen-decomposition of constrained covariance, with permutation tests for significance. Need to implement or call vegan correctly, with Condition() for partial ordinations.
- R integration: vegan is R package, needs R runtime lock, may conflict with DADA2. Need to ensure RCall or R via pipeline tools works.
- Performance: RDA with 10k taxa x 100 samples is O(n_taxa * n_samples^2) for covariance, maybe seconds in R, but permutation with 999 permutations x 10k taxa = 10M ordinations, may be minutes. Need to limit permutations for large data or use approximation.
- Memory: Distance matrix for 100 samples is 100x100 = 10k entries, trivial, but for 1000 samples 1M entries, still okay. For 10k taxa, taxa table 10k x 100 = 1M entries, okay.
- Validation: compare RDA/CCA/CAP results vs vegan for 3 datasets (mock, gut, soil) within 1e-6 for eigenvalues, R2, p-values.
- Testing: unit tests for RDA with known dataset (e.g., dune dataset from vegan), integration test with AnalysisConfig.

### Risks
- **Performance regression:** Constrained ordination with 999 permutations may be 10x slower than diversity calculations, but diversity.jl currently fast. Must be behind Advanced Analysis, benchmarked, fail CI if existing diversity methods regress >10%.
- **Scientific misuse:** RDA assumes linear relationships, CCA assumes unimodal, CAP/dbRDA assume distance metric appropriate. Users may apply RDA to Bray-Curtis without CLR, which is questionable (RDA is Euclidean). Need context help explaining assumptions and that CAP/dbRDA are more appropriate for Bray-Curtis.
- **Permutation test interpretation:** p-value from `anova.cca` tests if model explains more variance than random, but not which covariates significant. Need variance partitioning to explain each covariate's contribution. Risk of users over-interpreting overall p-value as evidence for each covariate.
- **Dependency:** vegan is R package with dependencies (permute, lattice), may conflict with renv.lock. Mitigation: pure Julia implementation for RDA (PCA + regression) as fallback.
- **Provenance:** Must store distance, scaling, permutations, formula, otherwise not reproducible. Missing provenance breaks DOI bundle.
- **UI:** Ordination plot (RDA biplot) needs to be added to frontend, with arrows for covariates, points for samples, colored by group. Current frontend has Plotly for alpha/beta diversity, but not for constrained ordination. Need new component, behind Evidence Mode, with progressive disclosure.

### Acceptance Criteria
- [ ] New OrdinationConfig or extended AnalysisConfig with methods `rda`, `cca`, `cap`, `dbrda`, fields `ordination_distance`, `ordination_scaling`, `permutations`, `variance_partitioning`
- [ ] Validation: distance must be compatible with method (RDA allows euclidean, not bray unless CLR-transformed; CAP/dbRDA allow bray, unifrac, etc.); permutations in [99, 9999]; scaling in [1,2]
- [ ] BH mandatory for per-taxon tests still, but ordination p-values via permutation, not BH (overall model test, not per-taxon)
- [ ] Tests: RDA/CCA/CAP vs vegan for dune dataset and 3 microbiome datasets within 1e-6 for eigenvalues, R2, p-values (with fixed seed for permutations)
- [ ] Benchmark: runtime and memory for 100, 1000 samples, with warning if >5 min for 999 permutations, fail CI if existing diversity methods regress >10%
- [ ] Nickel, DEED, JSON schemas updated (if new config) or extended
- [ ] Context help explains RDA vs CCA vs CAP vs dbRDA, with citations (Legendre & Anderson 1999 dbRDA, Anderson & Willis 2003 CAP, Oksanen et al. vegan), assumptions, scaling, variance partitioning
- [ ] Frontend: Advanced Analysis expander, ordination method selector, distance selector, permutations slider, variance partitioning toggle, estimated runtime, biplot with Plotly
- [ ] Docs: explains constrained vs unconstrained ordination, when to use, how to interpret R2 and p-values, and that ordination is exploratory, not confirmatory

### Related
- Blocked by: AnalysisConfig v1, diversity.jl (needs beta-diversity distances), TSS/CSS/RSS (needs normalization for RDA)
- Blocks: DOI bundle v2 (needs ordination provenance), CladeCumulus phylogenetic integration (ordination + phylogeny)
- References: Legendre & Anderson 1999 Ecol Monogr dbRDA, Anderson & Willis 2003 Ecol Monogr CAP, Oksanen et al. vegan package, Gloor et al. 2017 compositional (CLR for RDA)
