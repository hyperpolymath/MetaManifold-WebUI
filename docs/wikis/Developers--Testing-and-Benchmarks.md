<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000035
parent: 0198ba50-0000-7000-8000-000000000030
position: 50
kind: page
tags:
  - developers
  - testing
  - benchmarks
archived: false
-->

# Testing and benchmarks

**Status: IN PLACE** (with two deliberate COMING gates named below). Test
inventory and metrics: `docs/testing/coverage.md`; infrastructure:
`docs/testing/infrastructure.md`; facet taxonomy: `docs/testing/taxonomy-facets.md`.

## The lanes

| Lane | Command | Gate? | Notes |
|---|---|---|---|
| Frontend unit + integration | `bun test` (in `frontend/`) | yes | DOM-less lane; type-level assertions included |
| Frontend combined | `bun run check` | yes (pre-push) | typecheck + tests + bench invocation |
| Julia unit/integration | `just` test recipes | yes | fixtures under `test/fixtures/` |
| e2e | `just test-e2e` | opt-in | fails loudly without browsers (by design) |
| Benchmarks | `bun run bench/`, `bench/` | **informational** | compares vs `bench/*/baseline.json`; no gate |
| Repo hygiene | `just ci` | yes | SPDX, format, lint, pins drift |

Everything CI runs is `just ci`. If a lane is missing its tool it fails
loudly rather than skipping — silence would be a lie about coverage.

## The four test idioms that matter most

1. **Known answers written into the data.** Estimation fixtures embed
   outcomes in the counts; the test reads the fit against the planted truth
   — never a snapshot read-back of whatever the fit produced.
2. **Independent reference comparison.** The same fixtures fitted directly
   in R (coefficients, then BH against `p.adjust`), or exact summaries
   compared against Python's `fractions.Fraction` (skipping loudly by name
   when `python3` is absent).
3. **Negative controls for every refusal path.** Each unsuccessful state has
   a test that *provokes* it. A refusal path without a test is a rumour.
4. **Guards against regression to dishonesty.** Source-level guard: the
   placeholder-statistics pattern cannot return (estimation suite); the
   "pipeline does not call `exact_summaries` unless selected" property;
   the silent-substitution regressions (TSS/CSS/RSS aliases) cannot return
   (scaling suite).

Boundary values are **measured, not assumed** — the numeric-boundary suite
(#52's lesson) asserts where Float64/int behaviour actually breaks (counts
beyond 2⁵³−1, denominator budgets, rounding).

## Type-level assertions

20+ assertions pin the frontend domain model (`frontend/tests/`). They are
tests of *shape* — the compiler-adjacent half of the honesty contract. The
DOM-less lane's blind spot is bounded and known: Plotly-chain modules
(`PlotlyChart`, `ChartCustomiser`, `ChartEditorInner`, `AnnotationPanel`,
`RunView`) are import-blocked there; `TODO(tests/e2e-lane)` marks the spot.

## Benchmarks

`bench/` carries baselines for: table loading, duckdb aggregation, tree
rendering, PERMANOVA/NMDS, epistemic parsing, analysis config — plus a
comprehensive lane and a layer-1 mock-recovery harness (fetch/evaluate/
report over `datasets.yml`). Comparison output is informational; promotion
to a non-gating regression **alert** waits for a multi-week stability window
(deliberate, per the roadmap).

**COMING (gates, deliberately deferred):** the **DOM test lane** decision
(playwright vs a DOM harness — queued at the e2e-lane TODO) and the
**coverage gate** (lands against a recorded baseline in
`docs/testing/coverage.md`, never an arbitrary percentage).

## Writing a test for this repo (cheat sheet)

- Julia statistical code → idioms 1–4 above; if you cannot plant a known
  answer, the method is not ready for a test, which usually means its
  conditions document is not ready either.
- Frontend → DOM-less lane first; if the module touches Plotly chains, it
  joins the import-blocked list *explicitly* (with a TODO) rather than
  quietly skipping.
- Fixtures stay small (`test/fixtures/`, `frontend/tests/fixtures/`) — the
  MiSeq SOP sample data is for runs, not unit tests.
- CI names failing assertions since #65 — write assertions you would want
  named in red.
