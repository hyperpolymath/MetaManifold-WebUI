<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Annotation tracking index — FIXME(*) / TODO(*) / [VERIFY]

Status: live inventory at 2026-09-17. This is the single index the
standards-alignment prompt requires; annotations below are the *active*
set (historical mentions inside docs prose are excluded).

## FIXME(types) — 2 active

Both live in `frontend/src/types/declarations.d.ts` and are *known-unknowable*
boundary stubs, each with its own tracking comment in-file:

| # | Stub | Why it stays | Exit condition |
|---|---|---|---|
| 1 | `plotly.js-dist-min` ambient module | The minified bundle publishes no types by design | Frontend switches to full `plotly.js` package (would allow `@types/plotly.js`) |
| 2 | `react-chart-editor` ambient module | Upstream archived; will never ship types | Component replaced or vendored |

Cross-references: `docs/types/architecture.md §6`, `docs/types/strict-mode-status.md`,
`docs/type-system/category-d-e-closure.md`.

## FIXME(api-contract) — 0 active

The policy (define `Partial<>` + annotate instead of guessing) is in
`docs/types/architecture.md §3`; no site currently requires it.

## TODO(tests/e2e-lane) — 5 active

`frontend/tests/unit/plotly-chain.todo.test.ts`: PlotlyChart,
ComparisonPanel, ChartEditorInner, AnnotationPanel, RunView cannot be
imported in the DOM-less bun lane (plotly.js touches `document` at module
initialisation). Exit: the DOM-lane decision on `ROADMAP.md` — playwright
lane exists and is the current direction.
Cross-reference: `docs/testing/coverage.md § Not tested`.

## [VERIFY] markers — 0 found

Repo-wide scan at this commit returns none; nothing to resolve or escalate.

## House rule for adding annotations

1. New active `FIXME(scope)` or `TODO(scope/name)` **must** be added here
   in the same PR, or CI hygiene will eventually flag it (index-keeping is
   currently manual-by-convention).
2. Annotations without a scope are treated as defects in review.
3. When an annotation closes, remove in code **and** here together
   (the two `TODO(types/prompt-4)`-era entries were closed in prompt 4 and
   their markers removed; this line is the record).
