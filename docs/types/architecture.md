# Types architecture — MetaManifold-WebUI frontend

Status: baseline established (2026-09-17, prompt 4). All dates Europe/London.

This document is the map of where types live, which layers consume them, and
the rules for adding new ones. It complements
`docs/types/strict-mode-status.md` (error/state accounting) — this file is
about *placement*, not counts.

## 1. Type domain map

```
┌─────────────────────────────────────────────────────────────────────┐
│  src/api/types.ts        canonical REST interfaces (upstream file)  │
└──────────────▲───────────────────────────────────┬──────────────────┘
               │ imports leaves                     │ consumed by api client
┌──────────────┴───────────┐                        ▼
│  src/types/api/          │ DOMAIN A: API boundary        src/api/client.ts
│  ├ index.ts (facade,     │ (leaf wire shapes; endpoint→source map)
│  │  SOURCE map,          │
│  │  re-exports both)     │
│  ├ tables.ts             │ TableCell / TableRow
│  └ cosmetics.ts          │ LayoutOverrides / TraceOverrides
└──────────────▲───────────┘
               │ builds on
┌──────────────┴───────────┐
│  src/types/plotly.ts     │ DOMAIN 0: manual boundary vocabulary
│                          │ (plotly.js subset; SOURCE: plotly.com docs)
└──────────────▲───────────┘
               │ aliases re-exported by
┌──────────────┴───────────┐
│  src/types/declarations  │ module boundary (FIXME(types) stubs — the ONLY
│  .d.ts                   │ place ambient module declarations may live)
└──────────────────────────┘
               ▲
   ┌───────────┴────────────┐
   │                        │
┌──┴───────────────────┐ ┌──┴────────────────────┐
│ src/types/domain/    │ │ src/types/components/ │ ┌─────────────────────┐
│ DOMAIN B: view-model │ │ DOMAIN C: shared      │ │ src/types/state/    │
│ (TaxonomyRank,       │ │ component contracts   │ │ DOMAIN D: store/    │
│ ContamState,         │ │ (SelectionOption,     │ │ hook/navigation     │
│ OtuTableRow)         │ │ ChartEditorState,     │ │ (FetchState,        │
│                      │ │ ChartEditorUpdate-    │ │ FetchResult,        │
│                      │ │ Handler)              │ │ RouteScope)         │
└──────────────────────┘ └───────────────────────┘ └─────────────────────┘
```

Domain rules:

1. **`src/types/plotly.ts`** is the canonical manual vocabulary for the untyped
   plotly.js subset. Defined by hand (no codegen appropriate for the
   `plotly.js-dist-min` bundle); unverifiable attributes are `unknown` behind
   index signatures — `any` never appears.
2. **`src/types/api/`** holds REST boundary details. Every file carries a
   `// SOURCE:` annotation naming its route file or API doc. The canonical
   request/response interfaces remain in `src/api/types.ts` (upstream location;
   moving files is out of scope) and are re-exported through the facade.
3. **`src/types/domain/`** = view-model layer: types the UI *reasons* about,
   always derived from real app values (`TaxonomyRank` derives from the
   `RANK_ORDER` const) or documented wire fixtures (`OtuTableRow` ← the
   committed `tests/fixtures/run-table-payload.json`). Never invent a domain
   shape that no wire or value grounds.
4. **`src/types/components/`** = *shared* cross-component contracts only.
   React convention is co-located props; a prop type stays in its component
   file until a second component needs it. `ChartEditorState` lives here
   because both `ChartCustomiser` (seed producer) and `ChartEditorInner`
   (consumer) depend on it.
5. **`src/types/state/`** = lifecycle/navigation contracts (`FetchState` ← the
   canonical `useApi` implementation; `RouteScope` ← the `useParams` shapes in
   the views).
6. **`src/types/declarations.d.ts`** remains the single home for ambient
   third-party module declarations (FIXME(types) stubs). Inside ambient
   module blocks, reference local types via inline `import('./plotly')` type
   queries — an `import type` *statement* in that position silently fails to
   bind and degrades the export to `any` (observed 2026-09-17; see §6).

## 2. Where types are DEFINED vs CONSUMED

| Type | Defined in | Consumed by |
|---|---|---|
| `Study`, `Run`, `Job`, `TablePage`, `ChartCosmetics`, requests… | `src/api/types.ts` | `src/api/client.ts`, views, hooks |
| `TableCell`, `TableRow` | `src/types/api/tables.ts` | `src/api/types.ts` (import), `DataTable`, annotation components |
| `LayoutOverrides`, `TraceOverrides` | `src/types/api/cosmetics.ts` | `src/api/types.ts`, `applyChartCosmetics`, `ChartCustomiser` |
| `PlotTrace`, `PlotLayout`, `PlotFigure` | `src/types/plotly.ts` | facade (`Data`/`Layout` aliases), cosmetics, component contracts |
| `Data`, `Layout` (facade) | `src/types/declarations.d.ts` | `PlotlyChart.tsx` and any `plotly.js-dist-min` importer |
| `TaxonomyRank`, `OtuTableRow` | `src/types/domain/index.ts` | annotation/table UI |
| `SelectionOption`, `ChartEditorState`, `ChartEditorUpdateHandler` | `src/types/components/index.ts` | selectors, `ChartCustomiser`, `ChartEditorInner` |
| `FetchState`, `FetchResult`, `RouteScope` | `src/types/state/index.ts` | hooks, views |

Dependency direction is strictly upward in the diagram: boundary layers never
import from domain/component/state layers. Component files import *from*
`src/types/*`; nothing in `src/types/*` imports *from* component files —
except *type-introspection references* documented with SOURCE comments
(`TaxonomyRank` derives `(typeof RANK_ORDER)[number]` from the canonical
const in `annotationShared.ts`; this imports no code).

## 3. Adding a new type

1. **Decide the domain** by answering: "what produces this value?" —
   REST boundary → `types/api/`; derived display model → `types/domain/`;
   shared by ≥2 components → `types/components/`; hook/router lifecycle →
   `types/state/`. A type used by one component stays co-located there.
2. **Anchor it**: every boundary type needs a `// SOURCE:` comment naming the
   .jl route file (for REST) or the canonical const/fixture it derives from.
3. **Unknown, not any**: fields unverifiable from the SOURCE stay `unknown`
   (or the type gets an `[key: string]: unknown` index signature if the shape
   is genuinely open).
4. **Undocumented API region**: use `Partial<>` + a `FIXME(api-contract)`
   comment naming what needs server-side verification. Never guess a contract.
5. **Extend, don't widen**: a new UI need that narrows an API type lives in
   `types/domain/` (like `OtuTableRow`); do not weaken the boundary type.
6. **Gate it**: add an assertion to `src/types/__tests__/`. Type-level tests
   use the local `Equal`/`Expect`/`Assignable` helpers
   (`api-boundary.type-test.ts` shows the pattern) and run inside
   `bun run typecheck`; the `.type-test.ts` suffix keeps them out of
   `bun test` discovery.

## 4. Relationship to portfolio type contracts

This repo's type estate is intentionally **view-model and boundary only**.
Cross-portfolio contracts — provenance shapes, storage/journal envelopes,
schema-versioned payloads, the GNPL-UT utilities — are defined in
Lithoglyph/GNPL repos, not here. MetaManifold-WebUI must not grow copies of
those contracts; where the frontend later consumes such payloads, the type
arrives via the GNPL contract first and this layer maps it to a view model.
Prompt-4 explicitly excluded storage, journals, and provenance internals from
scope for this reason.

## 5. Relationship to strict-mode accounting

`docs/types/strict-mode-status.md` tracks error counts and the suppression
ban. As of this baseline: `tsc --noEmit` 0 errors, 169:0; zero
`@ts-nocheck`/`@ts-ignore`/`@ts-expect-error`; two surviving **FIXME(types)**
unknowable-boundary stubs (plotly.js-dist-min facade body, react-chart-editor
surface) with permanent tracking comments; zero `TODO(types/prompt-4)`
placeholders.

## 6. Known gaps and future work

- **Facade body is structural**: the `react`/`relayout`/`newPlot` signatures in
  the plotly facade accept `Record<string, unknown>` rather than narrowed
  traces/layouts; PlotlyChart casts at its seams. Tightening is cosmetic,
  tracked with the FIXME(types) stub. Deferred (prompt 5+).
- **Plotly-chart module import chain untestable under bun**: filed as
  `test.todo` ×5, see `docs/testing/infrastructure.md`.
- **`useAnalysis.alphaFig` is `unknown`**: the alpha-diversity figure flows
  untyped through the hook; a `PlotFigure`-typed return is the known next
  narrowing (requires threading the chart-request response type through
  analysis state; prompt 5+).
- **expect-type deviation**: prompt suggested the `expect-type` package for
  type-level tests; the repo uses the 12-line `Equal`/`Expect`/`Assignable`
  harness instead — zero new dependencies, identical gate semantics (a false
  assertion is a compile error under `bun run typecheck`).
- **inline-import-query rule** (§1 point 6): inside ambient module blocks in
  `src/types/declarations.d.ts`, prefer `import('./plotly').PlotTrace` type
  queries over `import type` statements — the statement form was observed to
  silently bind as `any` inside the plotly.js-dist-min block while working in
  the react-chart-editor block. Inline queries bind reliably in both.
