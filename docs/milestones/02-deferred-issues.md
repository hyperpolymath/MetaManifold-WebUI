<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->

# Deferred Features — Ready-to-Paste GitHub Issue Bodies

These are for features that must NOT be implemented in the current task (exact statistics layer and symbolic engine),
but have clear scientific value and should be tracked.

Each issue includes scientific value, difficulty, risks.

---

## Issue 1: Exact Statistics Layer — Exact Tests for Small Samples

**Title:** `feat(analysis): Exact statistics layer — Fisher's exact, exact NB, permutation tests for small-n microbiome data`

**Labels:** `enhancement`, `analysis`, `deferred`, `scientific-value:high`, `difficulty:hard`

**Body:**

### Scientific Value
Parametric approximations (NB GLM, Gaussian LM) break down with small sample sizes (n<10 per group) or sparse features. Exact tests (Fisher's exact for presence/absence, exact NB test via `exactTest` in edgeR, permutation-based PERMANOVA with exact p-values) provide valid inference when asymptotics fail. Critical for rare biosphere, low-biomass samples, and clinical cohorts with limited n.

- **Use case:** Pathogen detection where presence in 2/3 cases vs 0/20 controls should be significant even with tiny n.
- **Impact:** Reduces false negatives in small studies, improves reproducibility for low-abundance taxa.

### Scope (Deferred — DO NOT IMPLEMENT HERE)
- Exact Fisher's test for 2x2 tables (presence/absence vs group)
- Exact negative binomial test (edgeR `exactTest` or `exactTestDoubleTail`)
- Permutation-based exact p-values for NB GLM (parametric bootstrap)
- Exact CLR/ILR via permutation of Aitchison distances
- Integration with AnalysisConfig: new method `exact_fisher`, `exact_nb`, `permutation`

### Difficulty
**Hard** — requires:
- R integration (exact tests via `stats::fisher.test`, `edgeR`, `permute`)
- Combinatorial explosion for large tables (need network algorithm for Fisher)
- Performance: exact tests O(n!) naive, need optimized implementations
- Memory: permutation stores B=10k resamples per taxon
- Validation: compare against known exact p-values from R

### Risks
- **Performance regression:** Exact tests 10-100x slower than asymptotic; must be behind Advanced Analysis expander and Evidence Mode, with warning about runtime.
- **Memory:** Permutation matrices for 10k taxa x 10k permutations = 100M entries ~ 800MB
- **Scientific misuse:** Exact does not mean assumption-free; still assumes exchangeability under null. Need context help explaining when exact is appropriate vs when it is overly conservative.
- **Dependency:** Adds `edgeR`, `BiocParallel` to renv.lock — increases install time and fragility

### Acceptance Criteria
- [ ] New methods in AnalysisConfig v2: `exact_fisher`, `exact_nb`, `permutation_nb`
- [ ] BH still mandatory, DANGER banner if disabled
- [ ] Benchmark: <10% regression for existing methods, new methods benchmarked separately with 100 taxa, n=5 per group
- [ ] Tests: exact p-values match R's `fisher.test` for 10 known tables
- [ ] Docs: context help explains exact vs asymptotic, when to use
- [ ] UI: behind Advanced Analysis expander, shows estimated runtime

### Related
- Blocked by: AnalysisConfig v1 (this PR)
- Blocks: Symbolic engine (needs exact p-value expressions)

---

## Issue 2: Symbolic Engine — Formula Manipulation and Provenance

**Title:** `feat(analysis): Symbolic engine for formula manipulation, contrast derivation, and provenance`

**Labels:** `enhancement`, `analysis`, `deferred`, `scientific-value:high`, `difficulty:very-hard`

**Body:**

### Scientific Value
Current AnalysisConfig stores formula as string (`~ group + batch`). Symbolic engine would:
- Parse formula into AST, validate variables exist, derive contrasts (e.g., `groupB - groupA`)
- Automatically generate all pairwise contrasts for multi-level factors
- Prove that BH correction is applied to the correct family (e.g., all taxa, or per-contrast?)
- Generate human-readable report: "Testing 1500 taxa for effect of group, controlling for batch, with BH FDR 0.05"
- Enable DOI bundle to include symbolic derivation of analysis intent

- **Use case:** Study with 4 groups (control, diseaseA, diseaseB, diseaseC) — should automatically test all 6 pairwise, with BH across 1500*6=9000 tests, not 1500.
- **Impact:** Prevents p-hacking by making analysis intent explicit and auditable.

### Scope (Deferred — DO NOT IMPLEMENT HERE)
- Formula parser: R-style `~` and `+`, `*`, `:`, `I()`, `(1|batch)` for random effects (future)
- Contrast derivation: for factor with k levels, generate k-1 or k*(k-1)/2 contrasts
- Provenance: symbolic proof that result hash chains to formula AST hash
- Integration with DEED: `(formula (ast ...) (contrasts ...))`
- Nickel contract: formula as structured data, not string

### Difficulty
**Very Hard** — requires:
- Parser combinators or RCall to `terms.formula`
- Symbolic algebra (like `Symbolics.jl` or custom)
- Handling of R's non-standard evaluation (NSE) for formulas
- Provenance: need to hash AST, not just string (string `~ group + batch` vs `~ batch + group` are same model but different strings — should hash to same? Or not? Decision needed)
- UI: visual formula editor with drag-and-drop of metadata columns, live validation

### Risks
- **Complexity:** Symbolic engine is a research project itself; may introduce bugs in contrast derivation leading to wrong scientific conclusions (worst risk)
- **Scope creep:** Random effects `(1|batch)` opens mixed models, which is a whole new layer (lme4, glmmTMB) — must be explicitly out of scope for v1
- **Performance:** Parsing 1500 formulas (one per taxon) x 6 contrasts = 9000 parses — need caching
- **R dependency:** If using R's `terms`, need R runtime lock, which may deadlock with pipeline stages
- **Security:** Formula injection if AST allows arbitrary R code (e.g., `~ group + system('rm -rf /')`) — must whitelist allowed symbols

### Acceptance Criteria
- [ ] Formula AST type in Julia, with `from_string` and `to_string` roundtrip
- [ ] Contrast derivation for factors, with BH family size correctly computed
- [ ] Provenance: config hash includes AST hash, not just string hash
- [ ] Tests: 20 formulas parsed, contrasts derived, compared to R's `model.matrix` and `contrasts`
- [ ] Security: refuses formulas containing `system`, `eval`, `parse`, etc.
- [ ] Docs: explains symbolic vs string, why AST matters for provenance
- [ ] UI: formula editor with autocomplete of metadata columns, shows derived contrasts

### Related
- Blocked by: AnalysisConfig v1, exact stats layer (needs exact p-value symbols)
- Blocks: Automated report generation, DOI bundle v2

---

## Issue 3: Compositional Data Analysis — Advanced Methods (ANCOM-BC, ALDEx2, Songbird)

**Title:** `feat(analysis): Advanced compositional methods — ANCOM-BC, ALDEx2, Songbird`

**Labels:** `enhancement`, `analysis`, `deferred`, `scientific-value:high`, `difficulty:hard`

**Body:**

### Scientific Value
CLR/ILR+LM in v1 are basic compositional methods. Advanced methods address specific biases:
- **ANCOM-BC:** Bias correction for sampling fraction, handles zero inflation better than pseudocount
- **ALDEx2:** Bayesian Dirichlet-multinomial, accounts for sampling uncertainty, provides effect size + p-value
- **Songbird:** Multinomial regression for compositional data, ranks taxa by association with covariates

- **Use case:** Gut microbiome with highly variable library sizes and many zeros — ANCOM-BC reduces false positives from pseudocount.
- **Impact:** More accurate differential abundance for compositional data, which is inherently relative.

### Scope
- ANCOM-BC via R `ANCOMBC` package
- ALDEx2 via `ALDEx2` package (CLR + Welch's t + BH, with Dirichlet sampling)
- Songbird via QIIME2 or Python `songbird` (multinomial regression)
- Integration with AnalysisConfig: new methods `ancom_bc`, `aldex2`, `songbird`

### Difficulty
**Hard** — requires:
- R packages `ANCOMBC`, `ALDEx2` (Bioconductor, heavy dependencies)
- Python interop for Songbird (via `PythonCall.jl` or subprocess)
- Zero handling: ANCOM-BC has own zero handling, not pseudocount
- Benchmarking against existing CLR/ILR
- Memory: ALDEx2 Dirichlet sampling 128 samples per taxon x 10k taxa = 1.28M CLR values

### Risks
- **Dependency hell:** ANCOMBC depends on `lme4`, `pbapply`, etc.; may conflict with existing renv.lock
- **Performance:** Songbird multinomial regression is iterative, may take hours for 10k taxa
- **Scientific controversy:** Compositional methods are debated (Gloor et al. vs Morton et al.); need balanced context help, not taking sides
- **Reproducibility:** Songbird uses TensorFlow, non-deterministic unless seed fixed — need to record seed in provenance

### Acceptance Criteria
- [ ] New methods in AnalysisConfig v2
- [ ] BH mandatory, DANGER banner preserved
- [ ] Tests: compare against R reference for 3 datasets (mock, gut, soil)
- [ ] Benchmark: runtime and memory vs CLR_LM, with 10% regression gate for existing methods
- [ ] Docs: explains when to use ANCOM-BC vs CLR vs Songbird, with citations

---

## Issue 4: CladeCumulus — Phylogenetic Tree Integration

**Title:** `feat(cladistics): CladeCumulus phylogenetic integration — tree from taxonomy + phylogeny, not just taxonomy ranks`

**Labels:** `enhancement`, `cladistics`, `deferred`, `scientific-value:medium`, `difficulty:hard`

**Body:**

### Scientific Value
Current CladeCumulus builds tree from taxonomic ranks (Domain, Phylum, ...). True phylogenetic tree (from 16S sequences via FastTree or IQ-TREE) would enable:
- Cumulative frequencies along phylogenetic branches (not just taxonomic)
- Phylogenetic diversity metrics (Faith's PD, UniFrac) in CladeCumulus
- Detection of clades that are phylogenetically clustered but taxonomically dispersed (e.g., convergent evolution)

### Scope
- Build phylogeny from ASV sequences (via `DECIPHER` + `phangorn` or external FastTree)
- Integrate with CladeTree: nodes have both taxonomic and phylogenetic parents
- Cumulative frequencies along phylogeny: sum of counts in clade
- Epistemic colour coding still applies, but residual_count now includes phylogenetic uncertainty

### Difficulty
**Hard** — requires:
- Sequence alignment (MAFFT or DECIPHER)
- Tree building (FastTree, IQ-TREE) — external binary, need provenance like other tools
- Tree parsing (Newick) and integration with existing taxonomy
- Performance: alignment of 10k ASVs O(n^2) memory, tree building O(n^3) worst case

### Risks
- **Performance:** 10k ASVs alignment may take hours and 10GB RAM — need to limit to top N or provide subsampling
- **Provenance:** New tool (FastTree) needs probing and hashing like vsearch/swarm
- **Scientific:** Phylogeny from short 16S V4 amplicons is noisy; need to warn that tree is approximate
- **UI:** Phylogenetic tree + taxonomic tree = two hierarchies, need toggle or combined view — may clutter UI if not behind Evidence Mode

---

## Issue 5: Evidence Mode — Full Epistemic UI

**Title:** `feat(ui): Full Evidence Mode — epistemic status editor, fiber visualizer, residual explorer`

**Labels:** `enhancement`, `ui`, `epistemic`, `deferred`, `scientific-value:medium`, `difficulty:medium`

**Body:**

### Scientific Value
Evidence Mode toggle currently only gates Advanced Analysis and CladeCumulus. Full Evidence Mode would include:
- Editor for `avec_fibre` column (manual curation of which rows carry semantic fibre)
- Fiber visualizer: show Echo fiber for a selected taxon (all candidate worlds consistent with observation)
- Residual explorer: finite model of residual decomposition (like residual-evidence-types explorer.html)
- Warrant editor: what evidence tokens support a claim?

### Scope
- UI for editing avec_fibre boolean per row (in DataTable)
- Fiber visualizer component: shows witnesses (possible true worlds) over observed
- Residual explorer: slider for noise bound, shows candidate count and presence status
- Integration with provenance: fiber edits logged

### Difficulty
**Medium** — mostly frontend, but needs backend API for fiber computation

### Risks
- **UI clutter:** If not carefully designed, Evidence Mode could overwhelm non-expert users. Must keep clean, with progressive disclosure.
- **Performance:** Fiber for 10k taxa x 100 candidate worlds = 1M candidates, need virtualized list
- **Scientific misuse:** Manual editing of avec_fibre could be used to cherry-pick results — need to log edits in provenance and DOI bundle, with DANGER banner if many rows changed

---

## Issue 6: DOI Bundle — Zenodo Integration and Automated DOI Minting

**Title:** `feat(doi): Zenodo integration — automated DOI minting from DOI-ready bundles`

**Labels:** `enhancement`, `doi`, `infra`, `deferred`, `scientific-value:high`, `difficulty:medium`

**Body:**

### Scientific Value
DOI-ready bundles currently create local directory with DataCite JSON. Zenodo integration would:
- Upload bundle to Zenodo via API, mint DOI automatically
- Link DOI to GitHub release, make analysis citable
- Enable reproducibility: anyone with DOI can download exact config + results + provenance

### Scope
- Zenodo API client (via HTTP.jl)
- Upload bundle zip, create deposition, publish, get DOI
- Store DOI in provenance and link to GitHub Project board
- UI: "Mint DOI" button in AnalysisConfigEditor, shows DOI badge

### Difficulty
**Medium** — requires Zenodo token, HTTP client, error handling

### Risks
- **Token security:** Zenodo token must be stored as secret, not in code
- **Cost:** Zenodo is free but has rate limits; need to handle 429
- **Irreversibility:** Publishing to Zenodo is irreversible (DOI minted) — need confirmation dialog with DANGER banner
- **Dependency:** Zenodo API may change; need to pin API version

---

## Issue Template Footer (for all)

**For every issue:**
- [ ] Tests and benchmarks (fail CI on >10% regression)
- [ ] JSON + Nickel + DEED schemas updated
- [ ] Docs and context-sensitive help
- [ ] UI clean, behind Evidence Mode if advanced
- [ ] Provenance-rich, immutable derived objects
- [ ] Linked to Project board "Analysis Layer & Cladistics Development"
- [ ] Milestone report after completion
