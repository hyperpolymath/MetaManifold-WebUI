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
