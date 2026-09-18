<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->
# Issue: TSS/CSS/RSS offsets — exact normalization with DESeq2-style offsets

**Title:** `feat(analysis): TSS/CSS/RSS offsets — exact normalization with DESeq2-style offsets, not alias to relative`

**Labels:** `enhancement`, `analysis`, `deferred`, `normalization`, `scientific-value:high`, `difficulty:medium`

**Body:**

### Scientific Value
Current v1 aliases TSS/CSS/RSS to `relative` (proportions) with warning. Exact implementations provide proper statistical offsets for count models, not just proportions:

- **TSS (Total Sum Scaling) with offset:** Use log(library size) as offset in NB GLM, not as denominator for proportions. Preserves count nature, handles library size via offset (McMurdie & Holmes 2014 critique of rarefaction). Value: retains power, avoids compositional distortion.
- **CSS (Cumulative Sum Scaling, Paulson et al. 2013, metagenomeSeq):** Robust to high-abundance outliers, uses quantile (e.g., 75th percentile) of count distribution as scaling factor. Value: reduces false positives from a few dominant taxa.
- **RSS (Relative Log Expression, Robinson & Oshlack 2010, edgeR):** TMM-like, uses weighted trimmed mean of log-ratios vs reference. Value: gold standard for RNA-seq, applicable to microbiome when most taxa not differential.

Use case: Gut microbiome with 1 dominant genus (Bacteroides 60%) — TSS (relative) makes all other taxa appear depleted when Bacteroides increases, even if absolute counts unchanged. CSS/RSS mitigate this.

Impact: Reduces compositional bias without full CLR/ILR transform, keeps NB GLM interpretability (log fold-change in counts, not log-ratios).

### Scope (Deferred — DO NOT IMPLEMENT IN MILESTONE 3)
- Implement TSS offset: `log(colSums(counts))` as offset in MASS::glm.nb / DESeq2, not as `counts / libsize`
- Implement CSS: `metagenomeSeq::cumNorm` + `cumNormStatFast` to compute scaling factors, store as `size_factors` alternative
- Implement RSS/TMM: `edgeR::calcNormFactors(method="TMM")` or manual implementation (weighted trimmed mean)
- Extend NormalizationConfig: `method` enum already includes TSS/CSS/RSS (currently aliased), add fields `css_quantile`, `tmm_ref_column`, `tmm_log_ratio_trim`, `tmm_sum_trim`
- Update VALID_NORMALIZATION_FOR_METHOD: NB_GLM allows TSS/CSS/RSS as distinct from relative
- Nickel contract: MethodNormalizationCompatibility must distinguish TSS/CSS/RSS vs relative
- DEED: `(normalization :method "css" :css-quantile 0.75 :tmm-trim ...)`
- JSON schema: add properties `css_quantile`, `tmm_*`
- Frontend: context_help for TSS/CSS/RSS explains difference vs relative, when to use
- Provenance: store exact quantile, trim parameters, reference sample

### Difficulty
**Medium** — requires:
- R packages: `metagenomeSeq` (Bioconductor, heavy), `edgeR` (for TMM), or pure Julia implementation (Statistics, StatsBase)
- Validation: compare scaling factors vs R reference for 3 datasets (mock, gut, soil)
- Performance: CSS quantile per sample O(n log n), TMM pairwise O(n^2) for reference selection, but for 10k taxa x 100 samples still <1s in Julia, <5s in R
- Testing: unit tests for scaling factors, integration test that NB_GLM with TSS offset gives same coefficients as `glm.nb(count ~ group + offset(log(libsize)))`
- Memory: negligible (vector of size_factors length n_samples)

### Risks
- **Scientific misuse:** TSS/CSS/RSS still compositional in sense that they use library size, but not as compositional as CLR/ILR. Need context help explaining that they do NOT solve compositionality, only library size. Risk of users thinking CSS solves compositionality — must warn.
- **Dependency:** metagenomeSeq and edgeR are Bioconductor, increase renv.lock size, may conflict with existing DESeq2 version. Mitigation: implement pure Julia fallback for TSS and TMM, use R only for CSS if needed.
- **Performance regression:** If implemented in R via RCall, adds R runtime lock contention with DADA2/swarm stages. Must be behind Advanced Analysis expander and benchmarked: fail CI if >10% regression for existing methods.
- **Numerical:** CSS quantile 0.5 = median, but if many zeros, median may be zero → scaling factor zero → log(0). Need heavy validation: quantile must be high enough that cumulative sum >0 for all samples, refuse otherwise.
- **Provenance:** Must store quantile, trim, reference, otherwise not reproducible. Missing provenance would break DOI bundle reproducibility.

### Acceptance Criteria
- [ ] NormalizationConfig TSS/CSS/RSS not aliased, exact implementation with offset/size_factors
- [ ] New fields `css_quantile` (default 0.75), `tmm_log_ratio_trim` (0.3), `tmm_sum_trim` (0.05) with validation (0,1) and warnings
- [ ] BH mandatory preserved, DANGER banner if disabled
- [ ] Tests: scaling factors match R `metagenomeSeq::cumNorm` and `edgeR::calcNormFactors` for 3 datasets within 1e-6
- [ ] Benchmark: runtime <2x relative, memory <1.1x, fail CI on >10% regression for existing methods
- [ ] Nickel contract updated, DEED template includes new fields, JSON schema updated
- [ ] Context help explains TSS vs CSS vs RSS vs relative vs size_factors, with citations (Paulson 2013, Robinson 2010, McMurdie 2014)
- [ ] Frontend: Advanced Analysis expander, shows estimated scaling factors preview
- [ ] Docs: migration guide from relative alias to exact TSS/CSS/RSS

### Related
- Blocked by: AnalysisConfig v1 (Milestone 3)
- Blocks: ANCOM-BC comparison (needs exact TSS), DOI bundle v2 (needs provenance of scaling params)
- References: Paulson et al. 2013 Nature Methods CSS, Robinson & Oshlack 2010 Genome Biology TMM, McMurdie & Holmes 2014 PLoS Comp Bio rarefaction critique
