<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->
# Milestone 3 — Deferred Features Ready-to-Paste GitHub Issues

These issues are deferred from Milestone 3 (AnalysisConfig v1) and have clear scientific value, difficulty, risks, and acceptance criteria. Each issue is ready-to-paste into GitHub with labels and body.

## Milestone 3 Context

Milestone 3 implemented:
- Immutable AnalysisConfig struct exactly matching user's answers (NB GLM, CLR/ILR+Gaussian, logistic v1, BH mandatory hard-stop DANGER banner, Advanced Analysis section heavy validation/help/warnings for custom pseudocount/epsilon/zero_policy/etc.)
- Nickel schema validation, DEED scheme for manifests, validators refusing meaningless inputs, scary DANGER banner logging, full DOI-ready JSON manifest bundles
- JSON + Nickel + DEED schemes from hyperpolymath/standards
- Unit tests for validators, manifest creation, DANGER banner logging

Deferred features are those that were in VALID_* enums as allowed but aliased or not fully implemented, with warnings pointing to GitHub issues.

## Issues

### 01 — TSS/CSS/RSS offsets
**File:** `01-tss-css-rss-offsets.md`
**Title:** `feat(analysis): TSS/CSS/RSS offsets — exact normalization with DESeq2-style offsets, not alias to relative`
**Value:** High — reduces compositional bias without full CLR/ILR, retains NB_GLM interpretability
**Difficulty:** Medium — R packages metagenomeSeq, edgeR, or pure Julia
**Risks:** Misuse as compositional solution, dependency, numerical zero median, provenance

### 02 — Multinomial and Dirichlet-Multinomial
**File:** `02-multinomial-dirichlet-multinomial.md`
**Title:** `feat(analysis): Multinomial and Dirichlet-Multinomial models — Songbird-like multinomial regression, DM for overdispersed compositions`
**Value:** High — bridges count-based and compositional, compositionally coherent effect sizes, avoids pseudocount
**Difficulty:** Hard — optimization high-dimensional, non-convex DM, performance, reference taxon choice
**Risks:** Performance 10-100x slower, controversy, numerical overflow, TensorFlow non-determinism, reference taxon instability

### 03 — Occupancy models
**File:** `03-occupancy-models.md`
**Title:** `feat(analysis): Occupancy models — presence/absence with imperfect detection, zero-inflated NB, hurdle models`
**Value:** High — distinguishes true absence from undetected, reduces false negatives for rare taxa
**Difficulty:** Hard — identifiability, single-visit adaptation, performance, dependency
**Risks:** Non-identifiable if detection=occupancy, single-visit controversy, overfitting ZINB vs NB, dependency

### 04 — Constrained ordinations
**File:** `04-constrained-ordinations.md`
**Title:** `feat(analysis): Constrained ordinations — RDA, CCA, CAP, dbRDA, with permutation tests and variance partitioning`
**Value:** High — beta-diversity explained by covariates, community-level test complements per-taxon
**Difficulty:** Hard — eigen-decomposition, permutation, R vegan, performance 999 permutations
**Risks:** Performance, misuse RDA with Bray-Curtis, permutation p-value interpretation, dependency, UI biplot

### 05 — ILR basis phylogenetic/SBP/balance dendrogram
**File:** `05-ilr-basis-phylogenetic-sbp.md`
**Title:** `feat(analysis): ILR basis — phylogenetic ILR (PhILR), sequential binary partition (SBP), balance dendrogram`
**Value:** High — biologically meaningful balances, interpretable as clades, hypothesis-driven
**Difficulty:** Medium — phylogeny, SBP validation, performance O(n^2), memory 800MB for 10k taxa
**Risks:** Performance memory, SBP p-hacking, phylogeny accuracy, dependency, UI balance visualization

### 06 — Advanced zero handling and dispersion
**File:** `06-glm-gam-poi-bayesian-multiplicative.md`
**Title:** `feat(analysis): Advanced zero handling — glmGamPoi dispersion, Bayesian multiplicative replacement, multiplicative replacement with delta`
**Value:** Medium — faster dispersion, less distortion than pseudocount, accounts for uncertainty
**Difficulty:** Medium — R glmGamPoi, zCompositions, validation, performance trivial
**Risks:** Misuse as solving zero problem, delta p-hacking, dependency, numerical underflow

## Cross-cutting

All issues include:
- Scientific value with use case and impact
- Scope deferred, not to be implemented in Milestone 3
- Difficulty with required packages, performance, memory, validation
- Risks with misuse, dependency, performance, provenance
- Acceptance criteria with tests, benchmarks, schemas, context help, frontend, docs
- Related blocked by / blocks, references

## Project Board

Link every issue to Project board "Analysis Layer & Cladistics Development" https://github.com/users/hyperpolymath/projects/45

Update status on every PR, remove completed when closed.

## How to Create Issues

1. Go to https://github.com/hyperpolymath/MetaManifold-WebUI/issues/new
2. Copy Title from file
3. Copy Body from file (between **Body:** and next section)
4. Add Labels from file
5. Create issue
6. Add to Project board 45, set Status = Todo, link to Milestone 3

## Standards Alignment

All issues follow hyperpolymath/standards:
- JSON + Nickel + DEED schemes
- BH mandatory, DANGER banner
- Advanced Analysis behind Evidence Mode
- Heavy validation, refusal of meaningless inputs
- DOI-ready bundles with provenance
- Tests and benchmarks, fail CI on >10% regression
- UI clean, advanced only when Evidence Mode enabled
- No silent switching, every analysis explicit, immutable, provenance-rich
