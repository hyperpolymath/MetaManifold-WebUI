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

### Added — Type-system engineering series (2026-09)

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
