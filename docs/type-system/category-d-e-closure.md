# Category D & E closure — third-party and framework type infrastructure

Date: 2026-09-17 · Scope: follow-up to `strict-mode-foundation.md` (the
prompt-2 strict baseline). Verdict up front: **Category E required no work —
it is machine-enforced. Category D required boundary stubs, dependency
hygiene, and one re-verified upstream exception — all now closed or
explicitly parked with evidence.**

## 1. Category E — framework types import correctly: NO ACTION NEEDED

Framework type import correctness is enforced, not merely tidy:

| Mechanism | What it enforces |
|---|---|
| `verbatimModuleSyntax: true` | Type-only imports must be `import type`; value/type separation is checked by the compiler across every file. |
| `strict` + `jsx: react-jsx` + typed `@types/react` | All framework props/JSX surfaces type-checked. |
| ErrorBoundary `import type { ReactNode }` + `override` modifiers | Prompt-2 fix; representative of the framework-import class, now permanent. |

`tsc` (the CI gate) passes with **0 errors**, so Category E is verifiably
clean by construction. Nothing to fix.

## 2. Category D — third-party type coverage: audit

Type provenance for every package in `frontend/package.json` **after** this
change:

| Package | Type source | Status |
|---|---|---|
| `react` / `react-dom` | `@types/react`, `@types/react-dom` | ✔ installed (devDeps) |
| `react-router-dom` | bundled `./dist/index.d.ts` | ⚠ internally inconsistent under `exactOptionalPropertyTypes` — documented `skipLibCheck` exception, see §3 |
| `@upsetjs/react` | bundled `dist/index.d.ts` | ✔ |
| `plotly.js-dist-min` | **no published types** | ✔ hand-written strict stub in `src/vite-env.d.ts`, marked `FIXME(types)` |
| `react-chart-editor` | **no published types (upstream archived)** | ✔ typed ambient stub in `src/types/react-chart-editor.d.ts`, marked `FIXME(types)` — replaces upstream's own silent "`treat its exports as any`" bare `declare module` |

### The two `FIXME(types)` stubs (owner-specified pattern)

Both stubs follow the mandated pattern — an explicit `FIXME(types)` header,
a tracking pointer (this file), and **`unknown`-safe declarations** (never
`any`) — and both now live in **`frontend/src/types/declarations.d.ts`**
(the prompt-required file name; previously split across
`src/types/react-chart-editor.d.ts`, removed, and `src/vite-env.d.ts`,
reduced to the `vite/client` reference):

- `declarations.d.ts` — `react-chart-editor` block: fully typed minimal
  surface:
  `PlotlyEditor` (default export), `PanelMenuWrapper`, and the four
  `Style*Panel` components, props derived from the actual call site in
  `ChartEditorInner.tsx`. The previous stub (`declare module 'react-chart-editor'`
  with no body) exported implicit `any` — the exact Category-D smell this
  exercise exists to remove. `import type { ComponentType, ReactNode } from
  'react'` is nested inside the ambient block, so the file stays a global
  declaration file.
- `declarations.d.ts` — `plotly.js-dist-min` block: the facade (unchanged
  strictly-
  typed subset of `react`/`relayout`/`purge`/`newPlot`) carries the same
  marker header. Its exported `Data` / `Layout` aliases are the two flagship
  `TODO(types/prompt-4)` domain-type placeholders (see
  `docs/types/strict-mode-status.md` for the full placeholder inventory).

### Dependency hygiene (Prompt-0 "dead trio" finding — partially executed)

Final state (the deferral prompt's constraint *"do not add or remove
dependencies (except `@types/*` packages)"* landed after this pass and is
authoritative):

- `@types/react-plotly.js` — **removed** (allowed `@types/*` change).
- `@types/plotly.js` — **removed** (allowed `@types/*` change; nothing
  imports `plotly.js` statically — the `-dist-min` stub covers the surface).
- `react-plotly.js` — **retained** in `dependencies`. It was removed during
  this pass and then restored specifically because it is not an `@types/*`
  package and the constraint forbids removing it here. Zero imports in
  `src/` (verified by grep) — its removal is earmarked for the dedicated
  dependencies task.

**`react-plotly.js` is NOT dead for the bundle, though.** It is a declared
dependency of `react-chart-editor` (`^2.6.0`), whose `PlotlyEditor.js`
does `require('react-plotly.js/factory')` at runtime — while never declaring
it as a peer. Resolution re-verified after the manifest changes (retained
root copy at 4.0.0, nested copy for the editor):

```
require.resolve('react-plotly.js/factory', from react-chart-editor)
  → node_modules/react-chart-editor/node_modules/react-plotly.js/factory.js   (nested 2.x — present ✔)
require.resolve('plotly.js/src/lib/nested_property', from react-chart-editor)
  → node_modules/plotly.js/src/lib/nested_property.js                          (shame.js runtime need ✔)
```

The editor view therefore still works, and the manifest now matches upstream
exactly apart from the two allowed `@types/*` removals — all movement is
accounted in `docs/types/strict-mode-status.md`.

## 3. `skipLibCheck` exception — re-tried on `react-router-dom` 6.30.6, stands

Per the standing follow-up in `strict-mode-foundation.md` §4, the lockfile
was refreshed in-range (6.30.3 → **6.30.6**, allowed by the existing
`^6.28.0` spec) and `tsc --skipLibCheck false` was re-run. Result:
**identical 7 TS2344 errors, same seven locations** in
`react-router/dist/**/*.d.ts` — the defect lives in `@remix-run/router`'s
`AgnosticRouteObject` vs `exactOptionalPropertyTypes`, and no 6.30 patch
release touches it. `"skipLibCheck": true` therefore stands as the single
documented exception. Retry condition for the future: `react-router@7` (or a
fixed `@remix-run/router` types release).

## 4. Verification after this commit

| Check | Result |
|---|---|
| `tsc` (CI gate) | **0 errors** |
| `tsc --skipLibCheck false` | 0 in-repo errors; the documented 7 react-router errors (unchanged at 6.30.6) |
| `bun run dts` | 53 `.d.ts` + 53 `.d.ts.map` |
| suppression/`any` audit | 0 `@ts-ignore`, 0 `@ts-expect-error`, 0 "`treat as any`" stubs |
| dev-server transforms | `/`, `ChartEditorInner.tsx`, `react-chart-editor.d.ts`, `PlotlyChart.tsx` all HTTP 200 (touched files compile under esbuild) |

## 5. What this hands to Prompt 4 (domain types)

Clean runway: the only remaining category-C structural work is replacing the
`Record<string, unknown>` plotly/table facades with real domain types — now
with a compliant `FIXME(types)` stub pattern already established for any
package that turns out to need a local boundary declaration.
