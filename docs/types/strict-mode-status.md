# Strict TypeScript migration — status

| Field | Value |
|---|---|
| **Date of migration** | 2026-09-17 (strict foundation + tracked deferrals, handoff series on base `ecefb1c`) |
| **Error count before** | **165** `tsc` errors (baseline recorded in `docs/audit/type-system-reconnaissance.md`) |
| **Error count after** | **0** `tsc` errors (`./node_modules/.bin/tsc`, the strict app config) |
| **Lib-check probe** | `tsc --skipLibCheck false`: 0 in-repo errors; 7 errors confined to `node_modules/react-router/dist/**/*.d.ts` (see Known issues) |
| **Deferred `FIXME(types)` annotations** | **2** |
| **`TODO(types/prompt-4)` placeholders** | **5** |
| **Suppression annotations** | 0 (`@ts-ignore`, `@ts-expect-error`) · new `any` introduced: 0 |

Gate statement per the prompt's acceptance bar: **`bun run typecheck`
(`tsc --noEmit`) passes — exit 0 — with all deferrals in place** (verified
2026-09-17, and wired into CI, below).

## Deferred `FIXME(types)` annotations (2)

Both live in `frontend/src/types/declarations.d.ts`, marked with the
`FIXME(types): <package> has no published types / Tracked in:` pattern,
declared `unknown`-safely (never `any`):

1. `plotly.js-dist-min` — hand-written facade (`react`/`relayout`/`purge`/`newPlot` subset).
2. `react-chart-editor` — typed component surface (`PlotlyEditor`, `PanelMenuWrapper`, four `Style*Panel`s); upstream is archived and will never ship declarations.

Tracking detail: `docs/type-system/category-d-e-closure.md`.

## `TODO(types/prompt-4)` placeholders (5)

Domain types deliberately **not invented** in this prompt:

| # | Location | Placeholder |
|---|---|---|
| 1 | `frontend/src/types/declarations.d.ts` — `plotly.js-dist-min` module | `export type Data = Record<string, unknown>` |
| 2 | `frontend/src/types/declarations.d.ts` — `plotly.js-dist-min` module | `export type Layout = Record<string, unknown>` |
| 3 | `frontend/src/api/types.ts` (`RunTable`) | `rows: Record<string, unknown>[]` |
| 4 | `frontend/src/api/types.ts` (`ChartCosmetics`) | `layout` / `traces` `Record<…>` DTOs |
| 5 | `frontend/src/components/ChartEditorInner.tsx` | inline `state` / `onUpdate` structural shapes |

Related un-marked duplicates (`src/api/client.ts` inline response literals,
`src/api/figureColours.ts` merge helpers) derive from the same shapes and
follow whatever domain types Prompt 4 lands in `src/types/` — the five
markers above are the canonical replacement points.

## CI integration

- `frontend/package.json` gained `"typecheck": "tsc --noEmit"` (tsconfig
  already sets `noEmit`; the script is the explicit, documented gate).
- `.github/workflows/ci.yml` now runs three distinct frontend steps:
  `bun install --frozen-lockfile` → **`bun run typecheck`** (fail-fast on
  type regressions, before the heavier Plotly bundle) → `bun run build`.
- The fork has no `justfile`/`Mustfile` — it is third-party upstream code,
  so estate `just check` integration is not applicable here; CI carries the
  gate.

## Constraint compliance

- **Runtime behaviour unchanged** — this change set contains only comments,
  type-level edits, a manifest script, CI steps, and docs. Dev-server smoke
  (2026-09-17): `/`, `ChartEditorInner.tsx`, `declarations.d.ts`,
  `api/types.ts`, `vite-env.d.ts`, `PlotlyChart.tsx`, `RunView.tsx` all
  return HTTP 200.
- **No structural refactoring** — declaration consolidation
  (`src/types/declarations.d.ts`) only re-homes the two ambient stubs that
  already existed (`src/types/react-chart-editor.d.ts` removed,
  `src/vite-env.d.ts` reduced to the `vite/client` reference).
- **No dependency add/remove except `@types/*`** — removed with the
  manifest untouched otherwise.
- Lockfile: `bun.lock` refreshed in-range to `react-router-dom@6.30.6`
  (manifest unchanged) — used as the re-try vehicle for the `skipLibCheck`
  probe; the `@types/react-plotly.js` / `@types/plotly.js` entries drop with
  the removals.
- `react-plotly.js` stays in `dependencies`: briefly removed during the
  Category-D damage pass and then **restored** after this prompt's
  dependency constraint landed. It is statically unused by `src/` (verified
  by grep) and is earmarked for the dedicated dependencies task —
  noted again under Known issues. Its nested copy inside
  `node_modules/react-chart-editor/node_modules/` is what the chart editor
  actually resolves at runtime.

## Known issues

1. **`skipLibCheck` exception** — `react-router@6.30.x` /
   `@remix-run/router` declaration files are internally inconsistent under
   `exactOptionalPropertyTypes`: exactly 7 `TS2344` errors, all inside
   `node_modules/react-router/dist`, reproducible identically at 6.30.3 and
   6.30.6. Not annotatable from in-repo (errors live outside the tree; no
   suppressions are used anywhere). `skipLibCheck: true` stands as the sole
   documented exception (`frontend/tsconfig.json` comment →
   `docs/type-system/strict-mode-foundation.md` §4). **Retry condition:**
   `react-router@7` or a fixed `@remix-run/router` types release.
2. **`react-plotly.js` statically unused** — retention is constraint-driven
   (see above); removal is deferred to the dedicated dependencies task it
   shares with the Gap/Bun-lockfile audit.
3. **`vite build` not re-run in the authoring sandbox** — the 2 GB sandbox
   OOMs on the Plotly bundle. The merged CI run is the authoritative
   end-to-end confirmation (`typecheck` gate passes ahead of it, and the
   change profile is type-level).
4. **Domain types are placeholders by design** — see the five
   `TODO(types/prompt-4)` markers; replacing them is Prompt 4.
