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
