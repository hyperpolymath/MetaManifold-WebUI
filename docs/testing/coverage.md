<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Test coverage — MetaManifold-WebUI frontend

Status: updated 2026-09-18 (Europe/London) for the Prompt-7 extension.
Informational metrics only — **no coverage gate** (that decision belongs to
CI maturity, per the infrastructure prompt). The lane layout and discipline
are in `docs/testing/infrastructure.md`; the standards-taxonomy facet states
(REAL/THIN/ABSENT per category) are in `docs/testing/taxonomy-facets.md`;
this file inventories WHAT is covered and what is deliberately not.

Run: `bun test` (577 pass / 5 todo / 0 fail / 3343 assertions, ~300 ms —
Prompt-5 baseline was 67 pass / 204 assertions; the Prompt-7 suites are
additive-only). Metrics snapshot below remains the Prompt-5 one.

Prompt-7 additions (seeded/disciplined ports from `proven-tests-and-benches`
and the standards TESTING-TAXONOMY):

| File | Category | What it proves |
|---|---|---|
| `tests/unit/property-figure-colours.test.ts` | Property / generative | Seeded generators + laws over `figureColours` (totality, immutability, selectivity, application, idempotence; 400 cases, seeds pinned) |
| `tests/unit/fuzz-totality.test.ts` | Fuzz (lite) + chaos-lite | Hostile wire-shaped corpus never throws the boundary adapters; error funnel string contract |
| `tests/unit/reflexive-gates.test.ts` | Reflexive | `check-spdx.sh`/`check-format.sh` executed unmodified against fixture repos — silence AND firing proven for each gate |
| `tests/unit/coupling-api-routes.test.ts` | Coupling / drift | Every TS client endpoint exists in the Julia routes (0 orphans over 61 endpoints / 74 routes) |
| `tests/fixtures/gates/spdx-silence.txt` | Reflexive payload | Harness/payload separation per TEST-DOCTRINE (firing variants are runtime mutations of the silence payload) |

## What is tested — by type boundary

Test files follow `tests/{unit,integration}/`, one `describe` per module
boundary, Arrange/Act/Assert, parameterised blocks for type variants —
the patterns established in Prompt 3.

### 1. API boundary (adapters/parsers)

| Module | File | Contract assertions |
|---|---|---|
| `src/api/figureColours.ts` | `tests/unit/api-boundary-figure-colours.test.ts` | `applyColourOverrides`: name-keyed recolour of marker+line (line only if present), unmatched traces pass by reference, malformed figures (nullish/non-object/no-data) pass by identity, non-object `data` elements untouched, **immutability** of input figure, empty colour map. `applyChartCosmetics`: deep layout merge, array replace-not-merge, per-trace-name overrides with unknown names dropped, immutability of both inputs, empty cosmetics clone, malformed passthrough. |
| `src/api/errorMessage.ts` | `tests/unit/api-error-message.test.ts` | `Error` (incl. api-payload subclasses) → `.message`; raw string passthrough; parameterised non-Error values (null/undefined/number/object/array/symbol) → fallback; default fallback. |
| `src/api/client.ts` (+ `apiUrl`, `gq`) | `tests/integration/api-client.test.ts` | Endpoint wiring scaffolds (Prompt 3) plus: HTTP-error semantics (`{error,message}` body → thrown `Error` with `status`), unparseable error body → `statusText` fallback, `group` param URI-encoding and empty/null omission, `TableQuery` JSON pass-through verbatim, `distinctValues` optional-field absence discipline (never explicit `undefined`), `jobs.list` query construction parameterised over `{study, status}`, TablePage parsing preserves `rows: TableRow[]` exactly. |

### 2. Domain vocabulary and rank helpers

| Module | File | Contract assertions |
|---|---|---|
| `src/components/annotationShared.ts` | `tests/unit/rank-helpers.test.ts` (+ `annotation-shared.test.ts` scaffold) | `RANK_ORDER` equals the seven canonical ranks finest→coarsest (runtime twin of the `TaxonomyRank` union); `RANK_COL` totality over ranks × sources and the exact VSEARCH/`_dada2` naming contract; `CONTAM_STYLE` totality over `ContamStatus`; `findFinestRank`: finest-populated selection, parameterised blank kinds (empty/whitespace/null/undefined), per-source column families, `startRank` resume, unrecognised-start and empty-row safety, non-string cell coercion; `prefillFromRow`: per-source column families, absent/null omission, FUNCDB destination keys incl. lowercase forms, `match_rank`/`unmatched` suppression, TableCell string coercion, **FUNCDB_FIELDS ↔ prefill destination alignment**; `SOURCES` equals the two-backend contract. |

### 3. State transitions

| Module | File | Contract assertions |
|---|---|---|
| `createJobEventBus` (`src/hooks/useJobEvents.ts`) | `tests/unit/job-event-bus.test.ts` | Emission delivers the exact `Job` object once per subscriber; parameterised over the full `JobStatus` union (`queued/running/complete/failed/cancelled`); all current subscribers notified, late joiners receive no history; unsubscribe removes exactly that listener; zero-subscriber emission is a no-op. |
| `src/hooks/useApi.ts` (`FetchState`/`FetchResult`) | — | Type-level only (hook requires a React renderer); state machine is a 3-field lifecycle asserted structurally in the `.type-test.ts` suite from Prompt 4. See Not tested. |
| `RouteScope` | — | Type-level only; URL construction around `group` is behaviourally covered via the client integration tests (`gq`). |

### 4. Component contracts (DOM-free lane)

| Component | File | Contract assertions |
|---|---|---|
| `Skeleton` | `tests/unit/component-contracts.test.ts` | `lines` prop drives child count (default 3); width pattern cycles and wraps; stable `skeleton-line` class per row. |
| `ErrorBoundary` | same | Default state is error-free with children passed through by identity; `getDerivedStateFromError` stores the `Error` instance; error state renders the heading, the message, and the recovery button — asserted by walking element descriptors (no DOM mount). |
| `NotFoundView` | same | 404 copy, the `Back to Studies` affordance as a `Link` descriptor with `to='/studies'`. |

## What is NOT tested — and why

1. **Plotly-chain modules** (`PlotlyChart`, `ComparisonPanel`, `ChartEditorInner`,
   `AnnotationPanel`, `RunView`) — cannot even be *imported* under the bun
   lane: `plotly.js-dist-min` touches `document` at module initialisation.
   Five-machine-visible `test.todo` scaffolds track them
   (`TODO(tests/e2e-lane)`). The proven corpus defines no DOM-harness
   pattern and Prompt 3 documented the no-emulated-DOM decision; chart
   rendering verification belongs to the playwright e2e lane.
2. **Hooks requiring a React renderer** — `useApi` lifecycle transitions,
   `useAnalysis` figure state, `useSSE` connection state, and the
   `useJobRefetch` filter loop. No React test renderer exists in the
   estate, and adding one (happy-dom + react-dom testing) is a deliberate
   deferred decision — the bus it delegates to is behaviourally covered,
   and the hooks' contracts are asserted at the type level.
3. **SSE stream parsing** (`src/api/events.ts`) — `EventSource` is a browser
   API; the wrapper is a three-listener adapter with no app logic beyond
   `JSON.parse`. e2e-lane concern.
4. **Interactive table components** — `DataTable` (52 hook usages),
   `NameDialog`, `CardActions`, `Toast`, remaining views. Large surface,
   UI-lane concern; module-graph load smokes from Prompt 3 stand.
5. **Server round-trips** — the backend is never contacted in unit/integration
   lanes (fetch is stubbed); genuine HTTP behaviour is exercised at runtime
   by the app itself and by CI build, per the infrastructure prompt.

## Metrics (informational only, no gate)

`bun test --coverage` at the Prompt-5 commit:

| File | % funcs | % lines |
|---|---|---|
| **All files** | 36.67 | 44.44 |
| src/api/figureColours.ts | 100.00 | 100.00 |
| src/api/errorMessage.ts | 100.00 | 100.00 |
| src/api/client.ts | 15.00 | 57.52 |
| src/api/events.ts | 0.00 | 5.26 |
| src/components/Skeleton.tsx | 100.00 | 100.00 |
| src/components/ErrorBoundary.tsx | 66.67 | 100.00 |
| src/components/annotationShared.ts | 75.00 | 93.48 |
| src/hooks/useJobEvents.ts | 66.67 | 39.39 |
| src/views/NotFoundView.tsx | 100.00 | 100.00 |
| (DataTable, CardActions, NameDialog, Toast, useApi, useAnalysis, useSSE, StudiesView) | 0.00 | <10 |

Reading guide: the targeted adapters/holders of boundary semantics are at or
near 100% **line** coverage; the low-% files are exactly the
DOM/React-renderer lanes listed as Not-tested above. `client.ts` line
coverage reflects the endpoint-wiring breadth (only stubbed endpoints count).
Function-% is low on hook files because hook bodies never execute without a
renderer even when module-level exports are imported.

## Runtime-bug policy outcome

No runtime bug was revealed this prompt. Two test-authoring corrections were
made against first-draft *test* expectations (a `fetch` override dropped the
request capture; a prefill destination assertion used the display label
`Family` instead of the lowercase form key `family`) — both were test-side
mistakes, not app bugs; no `test.todo` bug-skip was needed.
