<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Constrained Ordinations (RDA, CCA, CAP, dbRDA)

MetaManifold provides four constrained (canonical) ordination methods via pinned R/`vegan` (`MetaManifold.Ordination`), exposed in the **Diversity -> Advanced Analysis** panel and through `POST /api/v1/studies/{study}/analysis/ordination`.

---

## 1. Constrained vs. Unconstrained Ordination

| Property | Unconstrained Ordination (`NMDS`, `PCoA`, `PCA`) | Constrained Ordination (`RDA`, `CCA`, `CAP`, `dbRDA`) |
|---|---|---|
| Objective | Extract axes capturing the largest **total** variation or rank-order dissimilarity across samples, irrespective of sample metadata. | Project community variation onto the linear subspace spanned by **explicit study covariates** (`~ group + depth + ...`), decomposing total inertia into conditioned, constrained, and residual unconstrained components. |
| Role of covariates | Overlaid *post hoc* via colour/shape or tested separately via `PERMANOVA`. | Enters the eigendecomposition directly; canonical axes are linear combinations of predictors. |
| Pitfall to avoid | Subtle treatment effects can be masked by dominant unmodelled gradients (e.g. batch or inter-individual variation). | Samples often appear separated on canonical axes **even when $R^2_{\text{adj}}$ is tiny**; always inspect $R^2_{\text{adj}}$, residual unconstrained inertia, and permutation $p$-values before making biological claims. |

Constrained ordination in MetaManifold is **explanatory / exploratory multivariate modelling**, not standalone confirmatory causal proof.

---

## 2. Methods and Compositional Geometry

Method/distance compatibility is enforced in `config/defaults/ordination.kyaml`, `MetaManifold.Validation`, `MetaManifold.Ordination`, config cascade `PATCH` checks, and the React UI:

| Method | `vegan` function | Allowed `distance` values | Geometry and appropriate microbiome use |
|---|---|---|---|
| `dbrda` | `vegan::dbrda` | `bray`, `jaccard`, `euclidean`, `aitchison`, `unweighted_unifrac`, `weighted_unifrac` | Direct McArdle & Anderson (2001) Gower-centred decomposition of squared dissimilarities without complex imaginary coordinates. Recommended general-purpose constrained ordination for ecological or phylogenetic dissimilarities. |
| `cap` | `vegan::capscale` | `bray`, `jaccard`, `euclidean`, `aitchison`, `unweighted_unifrac`, `weighted_unifrac` | Metric PCoA followed by linear RDA on real principal coordinates (Anderson & Willis 2003), supporting weighted-average taxon projections. |
| `rda` | `vegan::rda` | `aitchison`, `euclidean` | Linear Euclidean ordination. Accepts zero-replaced centred log-ratio (`aitchison`) coordinates (Gloor et al. 2017) or Euclidean/Hellinger-transformed abundances. **Refuses raw non-Euclidean dissimilarities such as Bray-Curtis.** |
| `cca` | `vegan::cca` | `chisq` | Unimodal ordination weighted by intrinsic chi-square distance on non-negative abundances across broad environmental niche gradients. |

### Zero Replacement for Aitchison (`clr`) Geometry

When `distance = "aitchison"` and the count matrix contains zeros, counts are closed after zero replacement via `MetaManifold.Compositional.replace_zeros` (`bayesian_multiplicative` GBM or `multiplicative_replacement` CZM, `replacement_delta` strictly in `(0, 1)`) before `clr` transformation. Provenance records the exact method, `delta`, and number of imputed cells, alongside an explicit bias caution (see [Zero-handling notes](zero-handling.md)).

### Phylogenetic UniFrac Distances

When `distance` is `unweighted_unifrac` or `weighted_unifrac`, `POST /api/v1/studies/{study}/analysis/ordination` resolves an ASV Newick phylogeny from `cladistics_id`, the study's latest completed Cladistics build, or an explicit `tree_newick`, and computes exact branch-weighted distances via `MetaManifold.CladeCumulus.unifrac_matrix`.

---

## 3. Covariate Formulas and Partial Ordination (`Condition(...)`)

Formulas are validated by a strict covariate-only AST parser (`validate_formula_syntax` and `parse_ordination_formula`) that **never passes arbitrary R code to `eval`**:

- Main effects: `~ group + log_library_size`
- Two-way interactions: `~ group * depth` or `~ group + depth + group:depth`
- Partial constrained ordination: `~ group + Condition(run)` or `~ group + ph + Condition(run + log_library_size)`

In a partial ordination, covariates inside `Condition(...)` are partialled out via QR projection *before* fitting constrained canonical axes, isolating treatment or environmental variance after removing batch, run, or library-size effects. Degrees of freedom are checked before calling R (`df_constrained + df_conditioned < n_samples - 1`).

---

## 4. Biplot Scalings (Scaling 1 vs. Scaling 2)

- **Scaling 1 (`distance`)**: Preserves Euclidean / principal-coordinate distances among sample points. Project sample points at right angles onto quantitative covariate arrows to approximate sample ordering along that covariate.
- **Scaling 2 (`correlation`, default)**: Preserves cosines of angles among covariate arrows (and feature loading vectors) as approximate correlations; inter-sample point distances on the plot do not approximate exact ecological distances.

---

## 5. Permutation Inference and Multiple-Testing Discipline

- Significance is evaluated via `vegan::anova.cca` (`permutations` in `[99, 9999]`, default `999`), seeded deterministically (`RNGkind("Mersenne-Twister", "Inversion", "Rejection")` + study `seed`) under `with_r_lock` with `parallel = 1L`.
- Every run reports:
  1. **Omnibus model test** (`anova.cca(fit)`)
  2. **Sequential term tests** (`by = "terms"`, Type I — order-dependent)
  3. **Marginal term tests** (`by = "margin"`, Type III — order-independent unique variance when $\ge 2$ terms)
  4. **Optional canonical axis tests** (`by = "axis"`, when `test_axes = true`)
- When repeated-measures `individual` blocks are present, permutations are restricted within individuals (`permute::Plots(strata = blocks)`). Any term constant within every block cannot be tested by within-block permutation; its $p$-value is withheld (`null`) with an explicit `untestable_reason` rather than fabricated.
- **Multiple-testing boundary**: Omnibus and term-level `anova.cca` tests are multivariate permutation tests (not adjusted by Benjamini-Hochberg FDR). Per-taxon differential abundance tests in `MetaManifold.Differential` continue to enforce mandatory Benjamini-Hochberg FDR adjustment.

---

## 6. Variance Partitioning (`vegan::varpart`)

When `variance_partitioning = true` and 2 to 4 constraining covariates vary:

- `vegan::varpart` decomposes community variation into unique testable fractions (e.g. `[a] = X1 | X2`, `[b] = X2 | X1`), shared overlap fractions (`[c]`, `0 df`, not individually permutation-testable), and residual unexplained variation (`[d]`) using Ezekiel's unbiased adjusted $R^2$ (Peres-Neto et al. 2006).
- Small **negative adjusted-$R^2$ fractions** can arise legitimately when predictors explain less variance than random normal variates or under suppressor relationships; MetaManifold reports them unclamped with an explanatory note so fractions continue to sum to `1.0`.

---

## 7. Wire Contracts and Verification

- Capability & compatibility contract (KYAML): `config/defaults/ordination.kyaml` (`GET /api/v1/ordination/contract`)
- Canonical response schema (RFC 7493 I-JSON + RFC 8785 JCS): `docs/schemas/constrained-ordination.schema.json`
- Independent Python stdlib reference oracle & canonical fixture: `test/references/check_ordination_references.py` and `test/fixtures/ordination_reference.json`

---

## References

1. Legendre, P. & Anderson, M. J. (1999). Distance-based redundancy analysis: testing multispecies responses in multifactorial ecological experiments. *Ecological Monographs* 69(1), 1–24. `doi:10.1890/0012-9615(1999)069[0001:DBRATM]2.0.CO;2`
2. McArdle, B. H. & Anderson, M. J. (2001). Fitting multivariate models to community data: a comment on distance-based redundancy analysis. *Ecology* 82(1), 290–297. `doi:10.1890/0012-9658(2001)082[0290:FMMTCD]2.0.CO;2`
3. Anderson, M. J. & Willis, T. J. (2003). Canonical analysis of principal coordinates: a useful method of constrained ordination for ecology. *Ecology* 84(2), 511–525. `doi:10.1890/0012-9658(2003)084[0511:CAOPCA]2.0.CO;2`
4. Peres-Neto, P. R., Legendre, P., Dray, S. & Borcard, D. (2006). Variation partitioning of species data matrices: estimation and comparison of fractions. *Ecology* 87(10), 2614–2625. `doi:10.1890/0012-9658(2006)87[2614:VPOSDM]2.0.CO;2`
5. Gloor, G. B., Macklaim, J. M., Pawlowsky-Glahn, V. & Egozcue, J. J. (2017). Microbiome datasets are compositional: and this is not optional. *Frontiers in Microbiology* 8, 2224. `doi:10.3389/fmicb.2017.02224`
6. Oksanen, J. et al. (2025). *vegan: Community Ecology Package* (CRAN). `doi:10.32614/CRAN.package.vegan`
