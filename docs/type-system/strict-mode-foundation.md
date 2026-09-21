<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# TypeScript strict-mode foundation — adoption log

**Date:** 2026-09-17
**Base:** migration commit `4eeed8f` (`build: migrate package management from mixed to bun`)
**Scope:** compiler configuration and `frontend/src` type-honesty only. No
domain types added (Prompt 4 scope). No runtime behaviour intentionally changed.
**Supersedes / feeds:** `docs/audit/type-system-reconnaissance.md` (Prompt 0).

## Prompt provenance

The task prompt was truncated after Step 1 (the tsconfig option list); Steps
2+, Deliverables and Constraints were absent. Two decisions were resolved with
the maintainer before starting and are binding on this work:

1. **Emit options (`declaration`, `declarationMap`, `sourceMap`):** delivered
   via a **sidecar** config (`tsconfig.build.json`) rather than the app's
   `tsconfig.json`, which stays `noEmit` as the Vite-adjacent type gate.
2. **`skipLibCheck: false`:** attempted; reverted to `true` with this file as
   the documented gap note, because the remaining failures are unfixable from
   in-repo (see §4).

Everything else follows the stated principles: strict is the goal;
`@ts-expect-error FIXME(types):` allowed for phasing; **never `any`** (use
`unknown` and narrow); **never `@ts-ignore`**; strictest reasonable defaults
where the standards repo has no TypeScript conventions.

## 1. Standards-repo TypeScript conventions: GAP (documented)

The task says to follow the standards repo's TypeScript conventions or note
the gap. **There are none.** Specifically, from `hyperpolymath/standards`
@ `efaec62`:

- No `tsconfig*.json` template anywhere in the repo.
- No TypeScript style/strictness guide. The estate's language position is
  actually anti-TypeScript for new code: `.claude/CLAUDE.md` and
  `LANGUAGE-POLICY.adoc` §1.2 state AffineScript replaces TypeScript
  ("*no typescript … that should not exist at all*", owner ruling 2026-08-27),
  with `.d.ts` files / VS Code extension host / MCP-LSP glue as flagged,
  **unresolved** carve-outs. Bun remains the tier-1 runtime.
- No convention exists for `@ts-expect-error` usage, `unknown`-vs-`any`, or
  strictness flags.

**Consequence:** the "strictest reasonable defaults" rule applied — the
mandated option list, applied in full except where contradicted by this app's
build model (§2, §4), with every deviation recorded here rather than implicit.
The estate-level tension (TS banned long-term vs. this pre-existing TS
frontend) is noted for the maintainer; migrating this frontend to
AffineScript is far outside this prompt and is not recommended here.

## 2. Final configuration

### `frontend/tsconfig.json` (app — pure type gate)

```jsonc
{
  "compilerOptions": {
    "target":                "ES2020",
    "useDefineForClassFields": true,
    "lib":                   ["ES2020", "DOM", "DOM.Iterable"],
    "module":                "ESNext",
    "skipLibCheck":          true,          // documented exception, §4
    "moduleResolution":      "bundler",
    "allowImportingTsExtensions": true,
    "isolatedModules":       true,
    "moduleDetection":       "force",
    "noEmit":                true,
    "jsx":                   "react-jsx",
    "strict":                true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride":    true,
    "noPropertyAccessFromIndexSignature": true,
    "exactOptionalPropertyTypes": true,
    "noUnusedLocals":        true,
    "noUnusedParameters":    true,
    "noFallthroughCasesInSwitch": true,
    "forceConsistentCasingInFileNames": true,
    "verbatimModuleSyntax":  true,
    "baseUrl":               ".",
    "paths": { "@api/*": ["src/api/*"], "@components/*": ["src/components/*"],
               "@views/*": ["src/views/*"], "@hooks/*": ["src/hooks/*"] }
  },
  "include": ["src"]
}
```

Mandated options adopted verbatim: `strict`, `noUncheckedIndexedAccess`,
`noImplicitOverride`, `noPropertyAccessFromIndexSignature`,
`exactOptionalPropertyTypes`, `noFallthroughCasesInSwitch` (pre-existing),
`forceConsistentCasingInFileNames`, `verbatimModuleSyntax`,
`isolatedModules` (pre-existing). Pre-existing options unchanged,
including the currently-unused `paths` aliases (Prompt 0 noted them as
vacuous; removing or wiring them is separate scope).

### `frontend/tsconfig.build.json` (sidecar — opt-in declaration emit)

```jsonc
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "noEmit": false, "emitDeclarationOnly": true,
    "declaration": true, "declarationMap": true, "sourceMap": true,
    "rootDir": "src", "outDir": "dist-types"
  },
  "include": ["src"]
}
```

Rationale per the maintainer decision (§0, decision 1):

- The trio `declaration` / `declarationMap` / `sourceMap` requires emission;
  the app's `tsc` invocation is `noEmit` (Vite emits the runtime bundle).
  Forcing emission through the app config would double the emit pipeline and
  contradict `allowImportingTsExtensions` (valid only with `noEmit` **or**
  `emitDeclarationOnly`) in its current form.
- The sidecar runs only on demand: `bun run dts`. Nothing in
  `tsc && vite build` consumes its output; `frontend/dist-types/` is
  git-ignored. It exists so the emit trio is exercised and available if a
  typed artefact is ever needed.
- Verification: `bun run dts` exits 0, emits **53 `.d.ts` + 53 `.d.ts.map`**
  mirror the `src` tree. (`sourceMap` is accepted but inert with
  `emitDeclarationOnly` — there is no JS emit to map. Kept for verbatim parity
  with the mandated list.)

### `package.json`

Added script `"dts": "tsc -p tsconfig.build.json"` (adjacent to the existing
`dev`/`build`/`preview`; no other script changes).

## 3. What it cost: 165 errors → 0, with zero annotations

Census with the new flags enabled over the pre-change tree:

| Error class | Count | Root cause in this codebase |
|---|---|---|
| TS4111 (`noPropertyAccessFromIndexSignature`) | 84 | `styles.<class>` CSS-module access (64) and `Record` field access on rows/layouts (20) |
| TS2375 + TS2379 (`exactOptionalPropertyTypes`) | 36 | props/DTOs receiving explicit `undefined` |
| TS2532 / TS18048 (`noUncheckedIndexedAccess`) | 18 | unguarded `arr[i]`/`record[k]` use |
| TS2379 on `RequestInit` | 3 | `body: undefined` passed explicitly to `fetch` |
| TS2322 / TS2345 / TS2538 | 15 | index/null-index narrowing fallout |
| TS1484 (`verbatimModuleSyntax`) | 1 | value-import of type `ReactNode` |
| TS4114 (`noImplicitOverride`) | 2 | `ErrorBoundary` members overriding `Component` |
| TS2344 (`react-router` `.d.ts`) | 7 | **inside `node_modules` — unfixable in-repo (§4)** |
| TS2300 (duplicate `classes`) | 2(1) | local `*.module.css` declaration duplicating `vite/client`'s |

(One of the two TS2300 reports is the `node_modules` side of the pair.)

**Fix approach inventory — no `@ts-expect-error`, no `@ts-ignore`, no new
`any`, anywhere.** Every error was fixed at its cause:

| Approach | Where | Count (approx.) |
|---|---|---|
| `styles.x` → `styles['x']` (scripted, verified) | `DataTable.tsx` 56, `PipelineStages.tsx` 7, `JobBadge.tsx` 1 | 64 |
| Record-field access → bracket (`row['match_rank']`, `item['xref']`, `cfg['your_name']`, `spec.layout?.['font']`, …) | `annotationShared`, `alphaMetrics`, `AnnotationPanel`, `PlotlyChart`, `ChartCustomiser`, `AnnotationPanelControls` | ~20 |
| Optional prop/DTO types widened with `\| undefined` (declaration-side honesty; call sites pass `undefined` legitimately) | `api/types.ts` (AnalysisRequest, ComparisonRunSpec, ColFilter, CompositionSet, CompositionCategory, ChartCosmetics, VennRequest), `useAnalysis` (UseAnalysisOpts), `api/client.ts` (ranks opts), `figureColours`, `NameDialog`, `PlotlyChart`, `DataTable` props, `PipelineStages` props (group/patchFn/deleteFn/tooltip/sourceLevel/overrides), `TaxaCompositionChart`, `CompositionPanel`, `RunView` inline panel props, `CategorySetEditor`-adjacent types | ~40 declarations |
| Conditional construction instead of explicit `undefined` | `api/client.ts` post/patch/put (`body` omitted, not `undefined`) | 3 |
| `undefined`-guards on index access (early-return/`??`-coalesce/`first !== undefined`) | `RunView` (median cell, `figNames[i]`, `tables[0]`, import-filter parser block), `annotationShared` (`RANK_ORDER[i]`), `DatabaseEditor` (`moveAt`, `after[i]` compare), `PrimersView`, `EditorCard` (`counts[n] ?? 0`), `CategorySetEditor` (swap), `ComparisonPanel` (`options[0]?.label ?? ''`), `CompositionsView` (`?? {}` / `?? { categories: [] }`), `DatabasesView` (`keyProblems[i] ?? null`), `DataTable` (`copiedCls` guard) | ~24 sites |
| Type-only import + `override` modifiers (`verbatimModuleSyntax`, `noImplicitOverride`) | `ErrorBoundary.tsx` | 3 |
| Removed duplicate `*.module.css` module declaration (identical to `vite/client`'s; caused TS2300) | `vite-env.d.ts` | 1 block |

Semantics notes:

- **No `any` was added**; the pre-existing untyped `react-chart-editor`
  surface (Prompt 0) is unchanged — it is documented debt, not new debt.
- Widening `x?: T` to `x?: T | undefined` does not change emitted JSON
  (`JSON.stringify` drops `undefined` keys) and is the compiler-recommended
  resolution for callers that legitimately pass `undefined`.
- Rendering is unchanged except for unreachable-path fallbacks introduced by
  guards (`options[0]?.label ?? ''`, `figName || i`, early-empty median cell,
  `?? {}` library lookups) — these only alter output in cases that were
  previously crashes or meaningless `undefined`s.

## 4. `skipLibCheck: false` — attempted, reverted, documented

With `skipLibCheck: false` after all in-repo fixes, exactly **7 errors**
remain, all inside `node_modules/react-router/dist/**/*.d.ts`:

```
index.d.ts(15,95), index.d.ts(16,87), components.d.ts(60,30),
components.d.ts(81,30), context.d.ts(20,30), context.d.ts(39,30),
context.d.ts(46,151)  — all TS2344: type does not satisfy constraint
'AgnosticRouteObject'
```

react-router 6.30.x's own declaration files are internally inconsistent under
`exactOptionalPropertyTypes`. Per the principles, `@ts-expect-error` cannot be
used (the errors are outside the repo) and patching node_modules is not
acceptable. Therefore `"skipLibCheck": true` is retained as a **documented
exception** (comment in `tsconfig.json` points here). **Re-tried 2026-09-17
at `react-router-dom` 6.30.6** (in-range lockfile refresh; see
`category-d-e-closure.md`): identical 7 errors at the same seven locations —
the defect lives in `@remix-run/router`'s `AgnosticRouteObject` declarations
and ships unchanged in every 6.30 patch. Retry condition: `react-router@7`
or a fixed router-types release. Everything else (all own `.d.ts` files, all
other packages) passes lib-checking — the only losses are these seven
upstream diagnostics.

## 5. Verification

| Check | Result |
|---|---|
| `tsc` (app config, the CI gate) | **0 errors** (was 165 before fixes) |
| `tsc --skipLibCheck false` | 0 in-repo errors; 7 react-router `.d.ts` errors (§4) |
| `bun run dts` (sidecar) | exit 0; 53 `.d.ts` + 53 `.d.ts.map` |
| No-new-`any` / no-suppression audit (`git diff` + grep) | 0 `any` added; 0 `@ts-expect-error` / `@ts-ignore` in tree |
| `bun install --frozen-lockfile` | unaffected (no dependency changes; `bun.lock` hash unchanged) |
| Dev-server smoke test (`bun run dev`) | Vite ready ~0.2 s; `/`, `/src/views/RunView.tsx`, `/src/components/DataTable.tsx`, `/src/components/ComparisonPanel.tsx` all 200 (esbuild transforms every heavily-edited file) |
| `vite build` bundle step | **not re-run here** — the sandbox lacks RAM for the Plotly bundle (documented in `docs/migration/npm-deno-to-bun.md`); the change profile is type-level + syntax-naïve edits already proven by `tsc` + esbuild dev transforms, but a CI run on the normal runner is the real confirmation |

## 6. Follow-ups handed to later prompts

- **Prompt 4 (domain types):** replace the `Record<string, unknown>` facades
  at the five `TODO(types/prompt-4)` markers (inventory:
  `docs/types/strict-mode-status.md`) with real domain types.
  ~~type the `react-chart-editor` surface instead of the bare
  `declare module`~~ **DONE** — typed `FIXME(types)` stub in
  `src/types/declarations.d.ts`.
- **Dependencies task:** ~~remove dead `@types/*` pair (Prompt 0 finding)~~
  **DONE** 2026-09-17. Still open: `react-plotly.js` (statically unused,
  retained per the deferral prompt's dependency constraint) and
  `react-router@7` (or fixed router types) → re-try `skipLibCheck: false`.
- **Prompt 3 (tests):** none exist frontend-side; `bun test` finds none (as
  recorded in the migration log).
