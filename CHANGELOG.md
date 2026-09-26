<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Changelog

All notable changes to this repository (the hyperpolymath fork of
MetaManifold-WebUI) are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) conventions.
Application *behaviour* changes belong to upstream release notes
(`docs/release-notes/`); this log records the fork's engineering work on
types, tests, infrastructure, and alignment.

## [Unreleased]

### Added — the README/EXPLAINME pair, the wiki, and the autolink specification (2026-09-26)

- **`README.adoc` replaces `README.md`**, per the estate README/EXPLAINME authoring
  standard (`standards:docs/README-EXPLAINME-STANDARD.adoc`). The README is now the
  three-layer design history — base R/Python design around raw DADA2, the origin
  MetaManifold augmentation (JoshuaJewell), and the fork's honesty/typing steps — with
  diagrammatic progression and shipped/planned markers throughout. The configuration
  chapters moved to the wiki (they made the README unreadable); the third-party tools
  table and acknowledgements moved into `NOTICE` (their natural home).
- **`EXPLAINME.adoc`** (new): the receipts file — claim→implementation→caveat map over
  every README claim, the dogfooding table, known gaps as CAUTION blocks, and an
  evidence index. The type-theory/enhanced-statistics deep material deliberately lives
  in the wiki; EXPLAINME cross-references it rather than re-deriving it.
- **The GitHub wiki is now the full BerryWiki-format documentation**
  (`metadatastician/berrywiki` page format: hidden metadata blocks, generated
  `_Sidebar.md`), sourced from `docs/wikis/` and synced to `MetaManifold-WebUI.wiki.git`:
  three audience sections (users — with academics and lab-professional tracks; platform
  maintainers — operator and steward tracks; developers), seven deep dives (design
  progression, type theory meets statistics, exact arithmetic, maximum likelihood and
  refusals, compositional statistics and offsets, epistemic status, advanced
  functionality), and a Status-and-Roadmap board marking everything IN PLACE / PARTIAL /
  COMING / BLOCKED.
- **`docs/integration/autolink-references.md`** (new): the complete elaboration of the
  repository's Settings → Autolink references set (lineage/estate, upstream tools,
  toolchain, registries), paste-ready and machine-readable, with reserved/omitted cases
  reasoned. Application in Settings needs Administration permission (one human pass);
  the file is the source of truth for it.

### Added — the three deferred ILR bases are implemented, with proofs (#20, 2026-09-26)

- **`phylogenetic` (PhILR), `sequential_binary_partition` and `balance_dendrogram`** are
  computed, no longer refused (`DEFERRED_ILR_BASIS` is now empty; it stays, so a future
  basis can be deferred the same way). `src/analysis/ilr_basis.jl` is one engine for all
  three: each basis is a rooted binary tree, and balances are clade sums in one post-order
  pass, `O(D)` per sample, with no dense basis matrix. Pure Julia; no new dependency.
- **Inputs and contracts.** `advanced.ilr_phylo_tree_path`, `ilr_sbp_matrix_path`,
  `ilr_balance_dendrogram_method` (plus philr's part/balance weights and the SBP history)
  are identical in the Julia validator, the Nickel contract, the JSON schema, DEED and the
  frontend: each basis requires its input and refuses the others'. Configurations that
  use none of them hash exactly as before; the default Helmert balances are byte-identical.
- **Validity is refused, not repaired.** Trees must be rooted, bifurcating and cover the
  retained taxa (tips outside them are pruned and recorded); an SBP must be the SBP of a
  binary tree (Egozcue & Pawlowsky-Glahn 2005), over exactly the retained taxa.
- **Provenance and guards.** Each run records the tree or SBP SHA-256, the dendrogram
  method, the weights and the balance-id rule. More than 3 distinct SBPs tried in a project
  raises a DANGER (p-hacking guard). BH stays mandatory.
- **Evidence.** Known answers; an independent Julia reference
  (`test/fixtures/ilr/ilr_reference.jl`) that recomputes all 17 committed expectations
  (philr, `compositions::ilr`, R `hclust`) every run; R cross-checks where philr,
  compositions and robCompositions are installed; negative controls. The balance algebra
  (contrast sums, orthonormality, injectivity with its positive-weight hypothesis, scale
  and perturbation invariance, comb = Helmert, SBP validity) is proved in Agda
  (`proofs/agda/`, new `proofs` CI job) and mapped to the tests in
  `docs/formal/verification-plan.md`. The conditions document is
  `docs/statistics/method-conditions/ilr-bases.md`.
- **Benchmarks.** `bench/ilr_bases/benchmark.jl` (100 / 1 000 / 10 000 taxa; warns over
  5 minutes or 1 GiB) and a pull-request gate that fails when CLR or default ILR allocate
  or run more than 10 % worse than the base commit on the same runner.
- **Removed** the Python fixture generator: Python is not permitted by the estate language
  policy; the Julia reference replaces it (`docs/compliance/standards-alignment.md`).

### Added — advanced zero handling and the glmGamPoi dispersion port (issue #21, 2026-09-26)

- **`src/analysis/zero_replacement.jl`** — the two operators the issue names, implemented
  rather than aliased:
  - *multiplicative replacement* (Martín-Fernández et al. 2003), the operator of
    `zCompositions::multRepl`: zeros become `delta x detection limit`, observed parts are
    scaled by `1 - Delta`, and the sample total and the ratios among observed parts are
    preserved **exactly**;
  - *Bayesian multiplicative replacement* (Martín-Fernández et al. 2015), the GBM of
    `cmultRepl`: the inserted value is the posterior mean of a Dirichlet-multinomial whose
    prior mean is the leave-one-out profile and whose concentration is `1/gmean(t)` unless the
    caller supplies `alpha`, with the reference's `frac x colmins` cap and its `adjust`
    switch.
  Both refuse what they cannot do (a delta outside (0,1); an imputed mass that would consume
  the sample, naming the largest admissible delta; all-zero samples; never-observed parts;
  parts seen in fewer than two samples) and both record a full provenance block, including
  the sentence that matters: **all replacement is biased**.
- **`src/analysis/dispersion.jl`** — a pure-Julia port of glmGamPoi's dispersion pipeline
  (Ahlmann-Eltze & Huber 2020): Cox-Reid adjusted NB maximum likelihood with the reference's
  `0.99` factor and its early returns, the `dnorm`-weighted local-median trend, the
  quasi-likelihood conversion, and the inverse-chisquare prior by Nelder-Mead. The reference's
  **natural-spline abundance trend is not ported and is refused by name** rather than being
  silently replaced by the non-trended prior; `glmgampoi_abundance_trend = false` runs the
  reference's own non-trended form and records the deviation.
- **`dispersion_method = "glmGamPoi"` in `estimation.jl`** — the by-name refusal is replaced
  by the real two-pass path: pass 1 fits the mean sweep in R, the port estimates the
  dispersions on those means, pass 2 refits at the fixed dispersion (`theta = 1/alpha`, with
  `stats::glm(poisson())` where alpha is 0).
- **Configuration** — `normalization.bayesian_multiplicative_alpha`, and
  `advanced.{zero_replacement_method, multiplicative_delta, bayesian_alpha,
  glmgampoi_abundance_trend}` in the Julia model, the Nickel contract, the JSON schema and the
  frontend types; validation at the door (`delta` in (0,1), `alpha` > 0), warnings for
  `delta < 0.01` and `delta >= 0.9`, a DEED echo of every value, and the DANGER banner when
  three or more deltas have been tried — the p-hacking case the issue names. The Advanced
  expander gains the delta slider **with a replacement preview**, the alpha field, and the
  trend selector.
- **Proofs** — `proofs/agda/` (Agda 2.7.0.1, stdlib 2.1.1, `--safe`, no postulates):
  `ZeroReplacement.agda` (totals and observed-part ratios preserved, imputed values strictly
  positive and below their detection limit), `NoRigidReplacement.agda` (no rule determined by
  the observed data can be faithful — the theorem behind "all replacement is biased"), and
  `DispersionShrinkage.agda` (the shrinkage lies between the prior and the sample estimate and
  is exact when they coincide). `proofs/agda/README.md` says what each proves, what is
  deliberately *not* proved, and what would falsify them.
- **Tests and benchmarks** — `test/unit/test_zero_replacement.jl` and
  `test/unit/test_dispersion.jl` against the pinned fixture `test/fixtures/issue21/golden.json`
  (with direct comparisons against `zCompositions` and `glmGamPoi` wherever R has them, and
  explicit "this comparison did not run" notices where it does not);
  `bench/zero_replacement/benchmark.jl` at 100/1000/10000 taxa with the issue's 5-minute
  warning and a 10% regression report behind `METAMANIFOLD_BENCH_STRICT`.
- **Docs** — `docs/statistics/zero-handling.md` (what each policy does, its cost, the exact
  relation to the two reference packages, and the alternatives that insert nothing) and
  `docs/statistics/method-conditions/dispersion-glmGamPoi.md` (the conditions of use and the
  residues).

### Added — the KYAML pilot (2026-09-26)

- **`scripts/kyaml/KYAML.jl`** — `just use-kyaml`, `just use-yaml`, `just check-kyaml`: the
  switch between block-style YAML and KYAML (the KEP-5295 strict subset), with comments kept
  and associated with their entries, canonical-form checking that is idempotent by
  construction, and refusals (anchors, aliases, tags, multi-document files, duplicate keys,
  multi-line plain scalars) that name the file and line and write nothing.
- **`docs/pilots/kyaml-pilot.md`** — the operating manual for this repository being the
  estate's KYAML pilot: the owner ruling of 2026-09-26, what the switch guarantees, what it
  refuses, the decisions it takes and prints, the proof obligations from
  `standards :: 3-practice/YAML-POLICY.adoc`, and how to revert.
- **`config/kyaml/drift.txt`** — the two workflow files Dependabot and `gh actions-lock`
  rewrite: converted, not gated, accepted in writing as the policy's §5 step 6 requires.
- **`stapeln.toml` + `Containerfile` + the `proofs` CI job** — the proof lane as a standalone
  deployment (Guix environment, mise pins, Agda from the channels pin) rather than a local
  convenience.

### Fixed — the NB test fixture is data a negative binomial describes (2026-09-26)

- The estimation tests' synthetic table was **under-dispersed** (variance below the mean,
  e.g. 10.2 vs 3.1). The negative binomial maximum-likelihood dispersion is then infinite,
  `MASS::theta.ml` stops at its iteration limit, and the estimator — correctly — reported
  two of the three fits as failed. The tests asserted `status == ok` on those fits. The
  fixture now keeps the same group means with variance near mu + mu^2/6 (theta ~ 6),
  checked outside R with two independent NB2 likelihood fits under both offsets the tests
  use. The estimator's handling of an infinite theta is unchanged.

### Fixed — every parametric fit returned `not_run`; CI failures are now readable (2026-09-26)

- **R's `NA` is read as missing.** The estimator writes its fits with
  `write.csv(..., na = "NA")` and read them back with CSV.jl's default
  `missingstring = ""`. One `NA` in a numeric column made the whole column a string
  column, `isfinite` threw, and every NB/logistic/Gaussian fit came back as `not_run`
  with no statistics. The Julia side now reads `"NA"` as missing (`R_NA_STRINGS`).
  Julia tests on `main` had been red since #60 for this reason.
- **`glmGamPoi` reaches its by-name refusal.** The configuration lower-cases
  `dispersion_method` but compared it against a table spelling `glmGamPoi`, so the name
  was turned away as unknown and the issue #21 explanation was never shown. The compare
  is now lower-case against lower-case, and the estimator looks its refusals up
  case-insensitively. A test covers three spellings.
- **Source-scan tests no longer trip on comments.** Comments quoting the removed
  hash-derived p-value code were reworded so the "no placeholder statistics" scan stays
  strict without flagging its own history.
- **CI names the failing assertion.** The "Run tests" step posts one annotation per
  `Test Failed` / `Error During Test` block and one with only the failing summary rows.
  The old single annotation was cut to 4096 bytes by the checks API, which removed the
  failing testset, and the job log is served from a host some environments cannot reach.

### Fixed — the ILR path stops substituting a basis it was not asked for (2026-09-25)

- **Unimplemented ILR bases are refused rather than substituted.** The configuration
  accepted `phylogenetic`, `sequential_binary_partition` and `balance_dendrogram`, and
  the execution path warned and computed the default Helmert basis instead. An ILR
  balance is only interpretable under the basis that defined it, so substituting a
  basis computes numbers that mean something other than what the analyst asked for.
  The three deferred bases (`DEFERRED_ILR_BASIS`) are refused at construction and in
  `prepare_analysis_table`.
- **Balances are labelled as balances.** An ILR table of $n$ taxa has $n-1$ balances,
  not $n$ features. The rows are relabelled `balance_1`..`balance_n-1`,
  `diagnostics.checks["ilr"]` records the basis, definition, input taxa count and
  taxa order, and the all-zero-taxa healing block no longer restores taxon labels onto
  balance rows.

### Fixed — `method = "TSS"` was refused by the layer that claimed to have shipped it (2026-09-25)

- **The allowed-normalisation table held the three names in a different case from the
  one the configuration stored.** `NormalizationConfig` canonicalises its method to
  lower case (`"TSS"` becomes `"tss"`), while `VALID_NORMALIZATION_FOR_METHOD` listed
  `"TSS"`, `"CSS"`, `"RSS"`. The membership test therefore failed for every one of those
  spellings, and `AnalysisConfig` raised
  `normalization.method 'tss' incompatible with method 'nb_glm'` — including for
  `test/unit/test_execution.jl`'s `TSS offset for NB_GLM` testset, which constructed
  `method="TSS"` exactly as the documentation instructs. That failure is what reddened
  the CI run for the merged TSS-offsets commit; it was not a flaky test.
- Both the table and the two comparisons (`AnalysisConfig` constructor, `validate_config`)
  are lower case now, `test/unit/test_scaling.jl` asserts that every admissible spelling
  of every method name is accepted, and the JSON schema enum still accepts the upper-case
  spellings for existing documents.

### Added — TSS/CSS/RSS are computed as offsets and recorded as such (2026-09-25)

- **`src/analysis/scaling.jl` is wired into the execution path** (issue #16). Under
  `nb_glm` the response stays the counts and the offset is the declared scaling factor's
  logarithm: `tss` = log library size, `css` = log cumulative sum at the declared
  `css_quantile` (Paulson et al. 2013), `rss` = log of the trimmed weighted mean of
  log-ratios to a reference sample (TMM, Robinson & Oshlack 2010), `size_factors` =
  median-of-ratios (DESeq2/RLE) — the estimator the name claimed all along and the code
  did not compute. `none` keeps the plain log library size it has always meant.
- **The declared parameters travel with the configuration**: `css_quantile` (default
  0.75), `tmm_ref_column` (default: chosen the way edgeR chooses it, and recorded),
  `tmm_log_ratio_trim` (0.3) and `tmm_sum_trim` (0.05) are validated in the constructor,
  included in the config hash and canonical JSON, round-tripped through `to_json`/
  `from_json`/Nickel/DEED, mirrored in the JSON schema and the Nickel contracts, exposed
  through the server's configuration route, and documented in `context_help` and the
  frontend help. A run that asked for a different quantile is a different run.
- **What was computed is recorded**: `diagnostics.checks["scaling"]` and the manifest
  provenance carry the kind, the definition sentence, the parameters, the raw quantities
  before centring and a SHA-256 of the offset vector, so two runs can be shown to agree
  and a run whose offset changed is detectable from the manifest alone.
- **Refusals instead of substitutions**: `css` and `rss` are refused for a response with
  no counts to offset (a non-count response is what the old alias silently produced),
  a zero or non-finite sample total is refused by name, a CSS cumulative sum of zero is
  refused as `log(0)` rather than replaced, and an unknown `tmm_ref_column` is refused
  with the real sample names instead of falling back to the data-driven choice.
- Evidence: `test/unit/test_scaling.jl` (known answers with the arithmetic written
  beside them, properties a wrong implementation fails, the CSS robustness property,
  negative controls, the integration path through `prepare_analysis_table`, and a
  base-R transcription of the same conditions), plus the conditions document
  `docs/statistics/method-conditions/scaling-and-offsets.md`. Parity with
  `metagenomeSeq::cumNorm` and `edgeR::calcNormFactors` is **not** claimed: neither
  package is in `renv.lock`, and the outstanding condition is recorded in issue #16.

### Fixed — the analysis path no longer returns placeholder statistics (2026-09-25)

- **`run_analysis` computed nothing and returned numbers anyway.** It derived
  `pvalue` from `0.01 + (hash(taxon_id) % 100) / 1000.0`, `padj` from
  `pvalue * 1.5` and `log2FoldChange` from `(hash % 20) / 10 - 1`: every one of
  those is a deterministic function of the feature's *name*, carrying no
  information about the counts, and they were returned to callers as results. The
  placeholder is deleted, not deprecated, and `test/unit/test_estimation.jl`
  reads `Execution.jl` as source and asserts it does not come back.
- **Real estimation** (`src/analysis/estimation.jl`, catalogue item 2): per-feature
  `MASS::glm.nb` for `nb_glm` (with a required offset), `stats::lm` for
  `clr_lm`/`ilr_lm`, and `stats::glm(family = binomial)` for `logistic` on a 0/1
  response — all through the shared R runtime lock, all with R and MASS versions,
  offset hash and result-table hashes in the provenance.
- **Unsuccessful states are states.** A feature whose fit fails gets
  `status = "failed"`, a note naming the cause, and `null` for every statistic; it
  is excluded from the BH family and counted. A run that cannot happen at all —
  no design, R unreachable, R busy past the timeout — returns `status =
  "not_run"` with a reason and an empty result set, never an empty table that
  reads as "nothing was significant".
- **Refusals instead of substitutions**: unsupported formula syntax
  (interactions, transformations, random effects, nesting), a `glmGamPoi`/
  `local`/`mean`/`pooled` dispersion method that has no implementation here, an
  offset on a non-count model, a count model without one, and a binomial fit on
  proportions all raise with the reason attached.
- BH is implemented in Julia and compared against R's `p.adjust(method = "BH")`
  in the tests; conditions are published in
  `docs/statistics/method-conditions/parametric-fits.md`.

### Added — Type-system engineering series (2026-09)

- **Epistemic claims with receipts**: added `Standpoint`, `TaxonWarrant`,
  `ProjectionY`, `Receipt`, and SHA-256 signing/verification (`make_receipt`,
  `verify_receipt`) in `src/core/epistemic.jl`, with compact `echo:v1?...`
  encoding/parsing for the `avec_fibre` column. Aligned directly with
  `EpistemicTypes.jl` and `echo-types`.
- **Zero observation disambiguation**: added `disambiguate_zero`
  (`Val(:true_absence)` vs `Val(:undetected)`), grounding presence/absence
  claims in sequencing depth and formalizing the boundary between biological
  absence and observation limits (`absolute-zero` and Issue #18).
- **Exact Multiplicative and Bayesian Zero Replacement**: implemented exact
  Martín-Fernández (2003) multiplicative replacement and Martín-Fernández (2015)
  Bayesian Dirichlet prior replacement in `Execution.prepare_analysis_table`,
  strictly preserving total sample depth and subcompositional ratios between all
  non-zero components (Issue #21).
- **Exact TSS offsets for count models**: implemented exact Total Sum Scaling
  offsets for `NB_GLM` in `Execution.prepare_analysis_table`, preserving the
  count nature of response tables and providing `log(lib_sizes)` offsets to
  prevent double-normalization and retain negative binomial model
  interpretability (Issue #16).
- **bun migration**: `package.json`/`bun.lock` replace the mixed npm+Deno
  tooling; bun 1.3.10 pinned via `.bun-version`; CI installs bun.
  `docs/migration/npm-deno-to-bun.md`.
- **Strict TypeScript foundation**: 165 type errors → 0 without
  suppressions; `exactOptionalPropertyTypes`, `noUncheckedIndexedAccess`,
  `verbatimModuleSyntax` et al. `docs/type-system/strict-mode-foundation.md`.
- **Type-estate closure**: ambient `FIXME(types)` stubs consolidated in
  `src/types/declarations.d.ts`; dead `@types/*` removed; skipLibCheck
  exception documented; CI gains a `bun run typecheck` gate.
- **Test + benchmark infrastructure**: bun:test battery (unit/integration
  lanes), proven-discipline benchmark harness with frozen workloads and
  checksums, JUnit+lcov CI artefacts, playwright e2e lane (opt-in), and
  `docs/testing/infrastructure.md`.
- **Domain type system**: `src/types/api` boundary leaves with SOURCE
  anchors, `src/types/plotly.ts` manual vocabulary, domain/component/state
  layers, type-level assertion suite, `docs/types/architecture.md`.
- **Type-driven behavioural tests**: 204 assertions across the
  prompt-4 boundaries (67 pass / 5 DOM-lane todos / 0 fail);
  `docs/testing/coverage.md`.
- **RSR/standards alignment** (this commit): estate `.editorconfig`,
  `.gitattributes`, `.gitmessage`, `LICENSES/`, SPDX identifier sweep,
  community files (`NOTICE`, `SECURITY.md`, `CODE_OF_CONDUCT.md`,
  `CONTRIBUTING.md`, `ROADMAP.md`), issue/PR templates, dependabot,
  licence/format/lint/commit-convention CI gates, and
  `docs/reproducibility.md` + `docs/compliance/` checklist documents.

### Changed

- CI: pipeline extended to licence-header, formatting, lint, and commit
  convention checks ahead of typecheck/test/bench/build.

### Fixed

- **Zero-depth samples poisoned the transform stage.** A sample with no reads
  reached the transform, where every transform divides by a sample total:
  `relative` wrote `0.0` for every feature (a value where the answer is
  *undefined*), `rarefy` took `min_lib = minimum(lib_sizes) = 0` and scaled
  **every** sample by zero, and `clr` took `log(0) = -Inf` that the NaN/Inf
  healing later replaced with `epsilon`. All-zero samples are now healed
  *before* the transform rather than after, which also removes the
  inconsistency where `prepared` and `filtered_counts` described different
  data under `drop_policy=impute`. Visible results change only for `impute`
  runs over inputs containing a zero-depth sample; `drop` and `refuse` are
  unchanged. Owner-authorised behaviour change, recorded in
  `docs/statistics/behaviour-change-zero-depth-samples.md`.

## [0.1.0] — 2026-05-21 (upstream baseline)

Initial public state of the application as inherited from upstream
(`JoshuaJewell/MetaManifold-WebUI`): Julia orchestrator wrapping cutadapt,
DADA2, SWARM, vsearch, and cd-hit-est; DuckDB-backed per-run results;
React frontend with results explorer, annotation, composition building,
cross-run charts, and configuration views. Application-level history
continues in `docs/release-notes/`.

[Unreleased]: https://github.com/hyperpolymath/MetaManifold-WebUI/compare/main...HEAD
[0.1.0]: https://github.com/hyperpolymath/MetaManifold-WebUI/releases
