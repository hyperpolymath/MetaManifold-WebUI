<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000032
parent: 0198ba50-0000-7000-8000-000000000030
position: 20
kind: page
tags:
  - developers
  - types
archived: false
-->

# Type system

**Status: PARTIAL — strict foundation IN PLACE; two documented exceptions.**
This page is the placement map and the rules; the reasoning that connects
types to *statistical claims* is
[Deep Dives — Type Theory Meets Statistics](Deep-Dives--Type-Theory-Meets-Statistics).

## The two type estates

### Frontend (TypeScript) — strict by gate

`frontend/tsconfig.json` (no-emit gate) + `tsconfig.build.json` sidecar;
`bun run typecheck` is CI-gated at **0 errors** under `strict` +
`exactOptionalPropertyTypes` + `verbatimModuleSyntax`. Placement hierarchy
(mapped in `docs/types/architecture.md`):

```
src/api/types.ts        canonical REST wire types (upstream file, boundary of record)
src/types/api/          DOMAIN A — API boundary leaves (tables, cosmetics, SOURCE map)
src/types/plotly.ts     DOMAIN 0 — hand-written plotly.js subset vocabulary
src/types/declarations.d.ts  the ONLY home of ambient module declarations
```

Rules of the estate (enforced in review and mostly in compiler):

- **Never `any`. Never `@ts-ignore`.** Use `unknown` and narrow. Type-only
  imports must be `import type` (machine-checked via `verbatimModuleSyntax`).
- The two third-party libraries with no published types
  (`plotly.js-dist-min`, `react-chart-editor`) carry `FIXME(types)`
  **unknown-safe** stubs in `declarations.d.ts` — replacing upstream's own
  silent `treat its exports as any` — each with a tracking pointer in
  `docs/type-system/category-d-e-closure.md`.
- Category D/E closure (third-party and framework type coverage) is audited
  and closed or explicitly parked with evidence — see that document.

**The two documented exceptions (PARTIAL's meaning):**

1. `skipLibCheck: true` — react-router 6.30.x bundles 7 erroneous `.d.ts`
   entries, unfixable in-repo; retried on react-router 7. Tracked with exit
   criteria in `docs/compliance/fixme-index.md`.
2. `useAnalysis.alphaFig` is `unknown` — narrowing to `PlotFigure` requires
   threading the chart response type through analysis state; listed in
   `docs/types/architecture.md § Known gaps`.

20+ type-level assertions pin the domain model (the strict-TS foundation's
165→0 error journey is logged in `docs/type-system/strict-mode-foundation.md`).

### Julia — the typed stage spine

`src/core/types.jl` defines the pipeline's result types (`TrimmedReads`,
`ASVResult`, `OTUResult`, `TaxonomyHits`, `MergedTables`); `AnalysisConfig`
is an immutable struct whose construction validates. Julia's dispatch and
the validation layer together do the work dependent types would do in Idris:
the *shape* of a result is checked at boundaries (config construction, R
returns, table loads), not assumed.

### The epistemic shadow types

`src/core/epistemic.jl` is where the type-theoretic material becomes
executable: finite Julia shadows of the Agda lineages (echo-types:
`EchoFiber` as a Σ-type Σ(x:A), (f x ≡ y); epistemic-types: `Modality`,
`FactiveModality`, `Warrant` *without soundness*; residual-evidence-types:
`Candidate`, `Holds`, `Identified`). The wire column `avec_fibre`, statuses
like `present_in_every_admissible_world`, and the DANGER-banner discipline
all hang off this module. Deep end:
[Deep Dives — Epistemic Status](Deep-Dives--Epistemic-Status).

## Adding a type — the checklist

**Frontend:** leaf types go in `src/types/api/`; wire types extend
`src/api/types.ts` *with the endpoint→SOURCE map updated*; plotly vocabulary
extends `src/types/plotly.ts`. Ambient declarations go nowhere except
`declarations.d.ts` (with `FIXME(types)` header if third-party). Grep for
`any` before pushing — `bun run check` will not catch a creative escape.

**Julia:** stage results extend `src/core/types.jl` and the stage's
freshness contract; config keys extend the schema (`config/schemas/`) and
`core/config.jl` merge semantics together or the cascade will lie.

**Both:** if the type encodes a *statistical claim* (exactness, refusal,
status), it needs a line in the relevant method-conditions document first —
types are how the honesty rules stop being conventions.
