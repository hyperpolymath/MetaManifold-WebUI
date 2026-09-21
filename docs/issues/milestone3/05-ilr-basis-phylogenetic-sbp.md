<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->
# Issue: ILR basis — phylogenetic, sequential binary partition, balance dendrogram

**Title:** `feat(analysis): ILR basis — phylogenetic ILR (PhILR), sequential binary partition (SBP), balance dendrogram`

**Labels:** `enhancement`, `analysis`, `deferred`, `compositional`, `scientific-value:high`, `difficulty:medium`

**Body:**

### Scientific Value
Current v1 has ILR with `default` basis only (from compositions package). Advanced ILR bases enable biologically meaningful balances:

- **Phylogenetic ILR (PhILR, Silverman et al. 2017):** Uses phylogenetic tree to define balances: each internal node is a balance between its two child clades. Value: balances correspond to evolutionary divergences, interpretable as "clade A vs clade B" where A and B are phylogenetically related. Detects clades that are phylogenetically clustered but taxonomically dispersed.
- **Sequential Binary Partition (SBP, Egozcue & Pawlowsky-Glahn 2005):** User-provided partition matrix defining which taxa go to numerator vs denominator for each balance. Value: allows hypothesis-driven balances, e.g., "Firmicutes vs Bacteroidetes" or "pathogens vs commensals". Enables testing specific compositional hypotheses.
- **Balance Dendrogram:** Hierarchical clustering of taxa (e.g., by co-occurrence or phylogeny) to define balances. Value: data-driven balances that capture co-occurrence structure.

Use case: Gut microbiome with known phylogeny, want to test if balance between Firmicutes and Bacteroidetes associated with disease. PhILR or SBP allows direct test of that balance, not just individual taxa.

Impact: More interpretable compositional analysis, aligns with cladistic thinking (balances as clades), enables testing of higher-level hypotheses (phylum, family level) in ILR space.

### Scope (Deferred)
- Extend NormalizationConfig.ilr_basis enum already includes `phylogenetic`, `sequential_binary_partition`, `balance_dendrogram` (currently allowed but not implemented, warns)
- Implement PhILR: need phylogenetic tree (from CladeCumulus or external), compute ILR basis via `philr` R package or pure Julia via `Phylo` + custom
- Implement SBP: user provides SBP matrix (e.g., CSV with taxa as rows, balances as columns, values -1, 0, 1), validate SBP is valid (each balance has both -1 and 1, no 0-only, etc.)
- Implement balance dendrogram: hierarchical clustering of taxa via `Clustering.jl` or R `hclust`, then compute ILR basis from dendrogram
- AdvancedConfig: add `ilr_sbp_matrix_path`, `ilr_phylo_tree_path`, `ilr_balance_dendrogram_method` (ward, complete, average)
- Nickel: contracts for ilr_basis compatibility with method (must be ilr), and for SBP matrix existence and validity
- DEED: `(normalization :method "ilr" :ilr-basis "phylogenetic" :ilr-phylo-tree-path "tree.nwk")`
- Frontend: context_help explains PhILR vs SBP vs balance dendrogram, when to use, with visualizations of balances
- Provenance: store tree, SBP matrix hash, dendrogram method

### Difficulty
**Medium** — requires:
- Phylogeny: need tree from 16S sequences (FastTree, IQ-TREE) or taxonomy-based tree from CladeCumulus. PhILR needs rooted bifurcating tree, may need to root and bifurcate.
- SBP validation: SBP matrix must be valid (each balance has at least one -1 and one 1, no taxon with all zeros, etc.). Need to implement validation per Egozcue & Pawlowsky-Glahn 2005.
- Performance: PhILR basis computation O(n_taxa^2) for tree traversal, for 10k taxa maybe seconds, okay. SBP matrix multiplication for ILR transform O(n_taxa * n_balances) = O(n_taxa^2) worst case if n_balances = n_taxa-1, for 10k taxa 100M operations, maybe seconds to minutes.
- Memory: ILR basis matrix (n_taxa-1) x n_taxa, for 10k taxa 10k*10k ~ 100M entries ~ 800MB, too large. Need sparse or on-the-fly computation, or limit to top N taxa via max_features.
- Testing: compare PhILR vs R `philr` package for 3 datasets, SBP vs `compositions::ilr` with custom SBP, balance dendrogram vs `robCompositions`.
- R dependency: `philr` is R package, may conflict with renv.lock. Mitigation: pure Julia implementation for PhILR.

### Risks
- **Performance regression:** PhILR and SBP with 10k taxa may be memory heavy (800MB for basis matrix). Must be behind Advanced Analysis, with max_features warning, and benchmarked: fail CI if existing CLR/ILR methods regress >10%.
- **Scientific misuse:** PhILR assumes phylogeny accurate, but 16S V4 short amplicons give noisy phylogeny. Need context help explaining that PhILR balances are only as good as tree, and that SBP is hypothesis-driven, not data-driven, so need to pre-register SBP to avoid p-hacking.
- **SBP p-hacking:** User could try many SBP matrices until one significant, then report only that. Need to log SBP matrix in provenance and DOI bundle, with DANGER banner if SBP changed many times (e.g., more than 3 SBP matrices tried). Risk of cherry-picking.
- **Dependency:** `philr` depends on `ape`, `phyloseq`, may conflict. Mitigation: pure Julia fallback.
- **Provenance:** Must store tree file hash, SBP matrix hash, dendrogram method, otherwise not reproducible. Missing provenance breaks DOI bundle.
- **UI:** Visualizing balances (e.g., PhILR balance between Firmicutes and Bacteroidetes) needs tree visualization with balance highlighted, similar to CladeCumulus but for ILR basis. Current frontend has CladeCumulus for taxonomy, but not for ILR balances. Need new component, behind Evidence Mode.

### Acceptance Criteria
- [ ] ILR basis `phylogenetic`, `sequential_binary_partition`, `balance_dendrogram` implemented, not just allowed
- [ ] PhILR: compute ILR basis from tree, transform counts to balances, test vs R `philr` within 1e-6 for 3 datasets
- [ ] SBP: user provides SBP matrix CSV, validate per Egozcue, transform, test vs `compositions::ilr` with custom SBP
- [ ] Balance dendrogram: hierarchical clustering via `ward`, `complete`, `average`, compute ILR basis, test vs `robCompositions`
- [ ] Validation: ilr_basis only for ILR method, tree must be rooted bifurcating, SBP matrix valid, dendrogram method in enum
- [ ] BH mandatory, DANGER banner preserved
- [ ] Tests: unit tests for SBP validation, integration tests for PhILR vs R, performance for 100, 1000 taxa
- [ ] Benchmark: runtime and memory for 100, 1000, 10000 taxa, with warning if >5 min or >1GB, fail CI if existing CLR/ILR regress >10%
- [ ] Nickel, DEED, JSON schemas updated (already enum includes these, but need contracts for tree/SBP existence)
- [ ] Context help explains PhILR vs SBP vs balance dendrogram, with citations (Silverman et al. 2017 PhILR, Egozcue & Pawlowsky-Glahn 2005 SBP, Pawlowsky-Glahn et al. 2015 compositional), when to use, with visualizations
- [ ] Frontend: Advanced Analysis expander, ilr_basis selector, tree file upload for PhILR, SBP matrix upload for SBP, dendrogram method selector, estimated runtime, balance visualization
- [ ] Docs: explains ILR basis, how to create SBP matrix, how to interpret balances, and that PhILR is still debated (some argue phylogeny not needed for compositional)

### Related
- Blocked by: AnalysisConfig v1, CladeCumulus phylogenetic integration (needs tree), TSS/CSS/RSS (needs normalization comparison)
- Blocks: Advanced compositional (ANCOM-BC vs PhILR), DOI bundle v2
- References: Silverman et al. 2017 PLoS Comp Bio PhILR, Egozcue & Pawlowsky-Glahn 2005 Math Geol SBP, Pawlowsky-Glahn et al. 2015 Compositional Data Analysis
