<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Roadmap

Status as of 2026-09-17. Reflects **actual** repository state — completed
sections are claims you can verify in `docs/compliance/`, not aspirations.

## Done (engineering series, 2026-09)

- [x] Advanced zero handling and the glmGamPoi dispersion port (issue #21): multiplicative and
      Bayesian multiplicative replacement with their refusals, provenance and Agda-checked
      laws; the pure-Julia dispersion pipeline with the un-ported spline refused by name;
      config/Nickel/JSON/frontend surface; tests, fixtures and the 100/1000/10000-taxa bench.
      Documentation: `docs/statistics/zero-handling.md`,
      `docs/statistics/method-conditions/dispersion-glmGamPoi.md`.
- [x] KYAML pilot (owner ruling 2026-09-26): `just use-kyaml` / `just use-yaml` / `just
      check-kyaml`, the drift list, `docs/pilots/kyaml-pilot.md`, and the standalone
      deployment of the toolchain and proof lane (`stapeln.toml`, `Containerfile`).
- [x] Bun toolchain migration (1.3.10 pinned; lockfile text format)
- [x] Strict TypeScript foundation (165 → 0 errors, zero suppressions)
- [x] Test & benchmark infrastructure (proven-tests-and-benchmarks patterns)
- [x] Domain type system (`src/types/*`; 20+ type-level assertions)
- [x] Type-driven behavioural tests (67 pass / 5 e2e-lane todos)
- [x] RSR template & standards alignment (this tree)

## Near term (decision points, not started)

- **Finish the KYAML migration.** The tool, gate and ruling are in; `just use-kyaml` has not
  been run, because it must be run where Julia is (the gate compares bytes against the Julia
  emitter, and the authoring sandbox had no Julia). One command plus the CI step that holds
  the result — see `docs/pilots/kyaml-pilot.md` §8.
- **Enable the proofs lane in CI.** `proofs` job is written and gated on
  `vars.STAPELN_AGDA_IMAGE`; the image (`stapeln.toml`, `Containerfile`) has not been built
  yet. Build it, then set the variable.

- **DOM test lane.** Plotly-chain modules (`PlotlyChart`, `ChartCustomiser`,
  `ChartEditorInner`, `AnnotationPanel`, `RunView`) are import-blocked under
  the DOM-less bun lane. Decision queued for the e2e lane: playwright
  (lane exists, opt-in) vs a DOM harness. Tracked as `TODO(tests/e2e-lane)`
  in `frontend/tests/unit/plotly-chain.todo.test.ts`.
- **Coverage gate.** Metrics are reported in CI artefacts (lcov) but not
  gated — deliberate; a gate lands with CI maturity, against a recorded
  baseline, not an arbitrary number. Baseline: `docs/testing/coverage.md`.
- **`alphaFig` narrowing.** `useAnalysis.alphaFig` is `unknown`; narrowing
  to `PlotFigure` threads the chart response type through analysis state.
  Listed in `docs/types/architecture.md § Known gaps`.
- **skipLibCheck exception.** Documented exception for react-router 6.30.x
  (7 upstream `.d.ts` errors). Retry on `react-router@7` upgrade.
  Tracked in `docs/type-system/` and `docs/compliance/fixme-index.md`.

## Medium term

- **Upstream PR cadence.** This fork's engineering series is delivered as
  patch series; the upstream-review/PR flow is an owner decision (base must
  always be `hyperpolymath`, never direct push to `joshuajewell`).
- **e2e smoke set.** `frontend/tests/e2e/app.e2e.ts` exists; grow only
  after the DOM-lane decision above lands.
- **Benchmark stability window.** Informational bench comparison already
  prints deltas vs `bench/baseline.json`; promotion to a regression
  *alert* (still non-gating) waits for baseline data across several weeks.

## Out of scope here (by portfolio rules)

- Storage/journal/provenance internals — owned by Lithoglyph/GNPL repos.
- Bioinformatics pipeline semantics — upstream `joshuajewell` domain; this
  fork tracks application changes, it does not fork the science.
