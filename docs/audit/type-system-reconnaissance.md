<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Type-System Reconnaissance & Alignment Audit — MetaManifold-WebUI

**Date:** 2026-09-17
**Audit type:** Read-only reconnaissance (no files modified, no dependencies installed, no builds or tests executed)
**Auditor:** Agentic audit of repository contents only

## Confidence

**Certain (verified directly from repository contents or versioned metadata):**

- All file counts, directory structures, lockfile identities, and configuration
  contents quoted below were read from a fresh clone of
  `hyperpolymath/MetaManifold-WebUI` at commit `ecefb1c` (2026-07-21).
- TypeScript file/type counts, `any`/`@ts-ignore`/declaration-merging counts were
  produced by running `grep`/`find` over `frontend/src` and are reproducible.
- The hyperpolymath/MetaManifold-WebUI repository is a **fork** of
  `JoshuaJewell/MetaManifold-WebUI` (GitHub API `fork: true`), which explains
  README badges and the Codecov slug pointing at `JoshuaJewell/…`.
- Reference revisions audited: `rsr-template-repo` @ `b28679e` (2026-09-17),
  `standards` @ `efaec62` (2026-09-17), `proven-tests-and-benches` @ `b38b7ca`
  (2026-09-15).

**Inferred (flagged as inference in-line):**

- Bun compatibility assessments of individual npm packages. Per the task
  constraints I did not install dependencies or run a build; assessments are
  based on package nature (pure JS vs native), lifecycle scripts in the
  lockfile, and the fact that CI already builds the frontend with Bun.
- Whether `standards` LICENCE-POLICY Rule 3 (AGPL for projects shared with the
  owner's son) formally covers MetaManifold. The repo is a fork of Joshua's
  repository and carries AGPL-3.0, which is *consistent* with Rule 3, but
  MetaManifold is not named in the Rule 3 example list in the copy of
  `LICENCE-POLICY.adoc` audited.

**Cannot be determined from repo contents (stated explicitly where it arises):**

- Whether CI is currently green (no access to Actions run history).
- Runtime behaviour of any dependency under Bun beyond what CI configuration
  implies.
- The name/location mismatch noted below: the input list says
  `proven-tests-and-benchmarks`; the actual public repository is
  `hyperpolymath/proven-tests-and-benches`. No repository named
  `proven-tests-and-benchmarks` is public under `hyperpolymath`. All findings
  below use `proven-tests-and-benches`.

---

## 1. Current stack inventory

### 1.1 Framework and version

The frontend is **not** SvelteKit, Astro, or Next.js. It is a client-side React
single-page application:

- **React 18.3.1** with **react-router-dom 6.30.3** (`BrowserRouter`,
  `Routes`, `Route`, `Navigate` in `frontend/src/App.tsx`)
- **Vite 6.4.1** build tooling with `@vitejs/plugin-react` 4.7.0
- No meta-framework (no SSR, no file-system routing); entry is
  `frontend/index.html` → `frontend/src/main.tsx`
- Build output is served by the **Julia backend** (Oxygen.jl HTTP server,
  `src/server/server.jl`) after Vite emits to `web/dist/`
- Backend stack (out of scope for TS type work but relevant to stack
  inventory): Julia 1.12.5, R 4.5.0 via RCall + renv (DADA2, vegan, Biostrings,
  ShortRead, dplyr), DuckDB results store.

Resolved versions below are from `frontend/bun.lock` (the committed lockfile),
not from version ranges in `package.json`.

### 1.2 Language

**TypeScript in strict mode.** Resolved TypeScript version: **5.9.3**
(package.json range `^5.7.2`). There is no JavaScript source in
`frontend/src`; the only `.js` files in the repository are committed build
artifacts under `web/dist/assets/` (3 files). No `.jsx`, `.svelte`, `.astro`,
`.mts`, or `.cts` files exist.

- Files in `frontend/src`: **41 `.tsx`**, **12 `.ts`** (excluding
  declaration files), **2 `.d.ts`**; plus `frontend/vite.config.ts`.
  **~8,977 lines** of TS/TSX total in `src`.
- JSX mode: `react-jsx` (automatic runtime).
- The backend is Julia (78 `.jl` files) and R (1 project `.R` helper,
  `R/_renv_dependencies.R`; root `.Rprofile` sources `renv/activate.R`) — out of
  scope for the TS type audit but relevant for boundary types (§2.5).

### 1.3 Current `tsconfig.json` (verbatim)

`frontend/tsconfig.json`, reproduced in full:

```jsonc
{
  "compilerOptions": {
    "target":                "ES2020",
    "useDefineForClassFields": true,
    "lib":                   ["ES2020", "DOM", "DOM.Iterable"],
    "module":                "ESNext",
    "skipLibCheck":          true,
    "moduleResolution":      "bundler",
    "allowImportingTsExtensions": true,
    "isolatedModules":       true,
    "moduleDetection":       "force",
    "noEmit":                true,
    "jsx":                   "react-jsx",
    "strict":                true,
    "noUnusedLocals":        true,
    "noUnusedParameters":    true,
    "noFallthroughCasesInSwitch": true,
    "baseUrl":               ".",
    "paths": {
      "@api/*":        ["src/api/*"],
      "@components/*": ["src/components/*"],
      "@views/*":      ["src/views/*"],
      "@hooks/*":      ["src/hooks/*"]
    }
  },
  "include": ["src"]
}
```

Observations on settings (facts, with contrast against actual code):

- `strict: true` plus `noUnusedLocals`, `noUnusedParameters`,
  `noFallthroughCasesInSwitch`. No `exactOptionalPropertyTypes`,
  `noUncheckedIndexedAccess`, `noImplicitOverride`, or
  `noPropertyAccessFromIndexSignature` — strictness beyond the `strict` family
  defaults is **not** enabled.
- `skipLibCheck: true`.
- `noEmit: true` — `tsc` runs as a type-check gate only; Vite handles emission
  (`"build": "tsc && vite build"` in `package.json`).
- `allowImportingTsExtensions: true` is enabled, but **no source file imports
  with a `.ts`/`.tsx` extension** (0 matches for `from '…​.tsx?'` across
  `frontend/src`). The setting is currently vacuous.
- `baseUrl` + `paths` declares four aliases (`@api/*`, `@components/*`,
  `@views/*`, `@hooks/*`), but **no import in `src` uses them** (0 alias
  imports; 195 relative/`./../` imports). `frontend/vite.config.ts` configures
  **no** `resolve.alias`, so any future use of these aliases would type-check
  under `tsc` but fail to resolve in the Vite build. This is a latent
  configuration inconsistency, not an active bug.

### 1.4 Package manager and lockfiles

- **Bun** is the JS package manager. One text lockfile: **`frontend/bun.lock`**
  (`lockfileVersion: 1`, `configVersion: 1` — the JSON-style lockfile, included
  in the repository). Bun version is pinned to **1.3.10** in
  `config/defaults/tool_versions.yml` (`toolchain.bun.version`), which the file
  header describes as the single source of truth for external pins; CI
  (`Set up Bun` step) reads that pin via a Julia/YAML step and passes it to
  `oven-sh/setup-bun@v2`.
- No `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`
  (binary lockfile), or `deno.lock` anywhere in the repository.
- One `overrides` block in `package.json` (`@types/react`, `@types/react-dom`
  self-referential pins using the `$` form); resolved consistently per the
  lockfile. No `.npmrc`, no trustedDependencies entry.
- Non-JS lockfiles that also constrain the stack: `Manifest.toml` (Julia;
  `julia_version = "1.12.5"`, `manifest_format = "2.0"`) and `renv.lock` (R;
  `"Version": "4.5.0"`). `Manifest.toml` is deliberately committed, per a
  `.gitignore` comment ("this is an application, not a library").

### 1.5 Test frameworks

- **Julia backend:** Julia stdlib `Test`, driven by `test/runtests.jl`
  (`using Test`, one top-level `@testset`). **27 unit test files** under
  `test/unit/`, **2 integration test files** under `test/integration/`
  (`test_pipeline.jl`, `test_server.jl`), gated behind `--integration` /
  `--server` CLI flags. Text fixtures under `test/fixtures/provenance/`
  (captured `--help`/`--version` outputs of external tools). An integration
  FASTQ dataset exists at `data/MiSeq_SOP/` (6 `.fastq.gz` files, 3 runs per
  `.gitignore` exceptions).
- **TypeScript frontend:** **none.** No test script in `package.json` (`dev`,
  `build`, `preview` only); no Vitest/Jest/react-testing-library dependency in
  `package.json` or the lockfile; no `*.test.*`/`*.spec.*` files under
  `frontend`.
- **R:** no testthat or other R test harness; the sole project R script is the
  renv dependency declaration helper.

### 1.6 Build tool

- **Vite 6.4.1** (Rollup 4.59.0 under the hood; esbuild 0.25.12 platform
  packages present in the lockfile for dependency pre-bundling).
- `frontend/vite.config.ts`: build output `../web/dist`, `emptyOutDir: true`,
  `sourcemap: false`, manual chunk isolating `plotly.js-dist-min`; dev-server
  proxies `/api`, `/files`, and `/api/v1/events` (SSE, buffering explicitly
  disabled) to `http://127.0.0.1:8080`.
- TypeScript emission disabled (`noEmit`); `tsc` runs first in the `build`
  script purely as a gate.

### 1.7 Linter / formatter

- **None for JS/TS.** No ESLint (any flat or legacy config), Prettier, Biome,
  or dprint configuration anywhere in the repository; no related dependencies
  in the lockfile; no lint/format script in `package.json`.
- **No `.editorconfig`** (the template and standards repos both carry one).
- No Julia formatter config (e.g. `.JuliaFormatter.toml`) either.

### 1.8 Node/Deno/Bun version constraints

- `package.json` has **no `engines` field**.
- No `.nvmrc`, `.node-version`, `.tool-versions`, `.mise.toml`, `mise.toml`,
  or asdf config.
- The only JS-runtime version constraint is the **Bun 1.3.10** pin in
  `config/defaults/tool_versions.yml`, consumed by CI and (per its header
  comment) by `install.jl`. Nothing constrains Node.js or Deno versions;
  Node.js is mentioned only as an alternative in the README ("bun or Node.js
  for building the frontend (bun preferred)").
- Adjacent runtime pins (same pin file): Julia 1.12.5, R 4.5.0
  (`apt_version: 4.5.0-3.2404.0`), Bioconductor 3.22, cutadapt 5.2,
  MultiQC 1.33, FastQC 0.12.1, vsearch/swarm/cd-hit with SHA-256-verified
  archives. `test/unit/test_install_pins.jl` exists to fail CI if the pin
  file, `Manifest.toml`, and the `ci.yml` setup-julia step disagree.

---

## 2. Type coverage assessment

### 2.1 File counts

| Scope | `.ts` (non-`.d.ts`) | `.d.ts` | `.tsx` | `.js`/`.jsx` | `.svelte`/`.astro` |
|---|---|---|---|---|---|
| `frontend/src` | 12 | 2 | 41 | 0 | 0 |
| `frontend/` root (`vite.config.ts`) | 1 | — | — | 0 | 0 |
| Whole repository (excl. `.git`, `renv/`) | 15 total | 2 | 41 | 3 (all committed build artifacts in `web/dist/assets/`) | 0 |

### 2.2 `any` types

- **Zero explicit `any` annotations** in all 55 TS/TSX source files:
  no `: any`, no `as any`, no `<any>`, no `any[]` matches.
- The only literal occurrence of the word "any" in a type-relevant position is
  a **comment** in `frontend/src/types/react-chart-editor.d.ts`:
  `"react-chart-editor ships no types; treat its exports as any."` That comment
  accompanies the materially relevant fact that `react-chart-editor` is
  declared as an untyped module (§2.4), which means its exports are
  **implicitly `any`** everywhere they are consumed (`ChartEditorInner.tsx`
  imports `PlotlyEditor` and six panel components from it).
- The codebase instead uses `unknown` extensively at dynamic boundaries
  (18+ files contain `unknown`, including `Record<string, unknown>[]` for
  table rows and `figure: unknown` for Plotly figures) — but see §2.5 on
  unchecked casts of those `unknown` values.

### 2.3 `@ts-ignore` / `@ts-expect-error` / `@ts-nocheck`

**None.** Zero matches for any `@ts-(ignore|expect-error|nocheck)` directive in
`frontend/src`.

### 2.4 `declare module` for untyped dependencies

**Three declarations across two files:**

1. `frontend/src/vite-env.d.ts` — `declare module '*.module.css'` (typed as
   `Record<string, string>`; used by the three `*.module.css` files).
2. `frontend/src/vite-env.d.ts` — `declare module 'plotly.js-dist-min'`: a
   hand-written facade exposing `react`, `relayout`, `purge`, `newPlot`, with
   `Data`/`Layout` aliased to `Record<string, unknown>`. This is deliberately
   weaker than `@types/plotly.js` (which is installed as a devDependency but is
   effectively unused by this facade — `plotly.js-dist-min` is its own module
   name). All Plotly chart content from the backend flows through this
   `Record<string, unknown>`-level typing.
3. `frontend/src/types/react-chart-editor.d.ts` —
   `declare module 'react-chart-editor'` and
   `declare module 'react-chart-editor/lib/react-chart-editor.css'`,
   with no module body — i.e. the entire module surface is implied `any`.

### 2.5 API response types / boundary typing

**Defined, comprehensive, statically typed — but not runtime-validated.**

- `frontend/src/api/types.ts` (~330 lines) defines roughly 55 exported
  interfaces/type aliases covering the whole REST surface: `Study`, `Run`,
  `RunStages`, `Job`, `TableMeta`, `TablePage`, `TableQuery`, `ColFilter`,
  `ConfigMap`, `AnalysisRequest`, `ChartRequest`, `ComparisonRequest`,
  `PermanovaResult`, `ApiError`, `AnnotationMeta`, `CategorySet`,
  `CompositionBuildResult`, `VennResult`, `ChartCosmeticsMap`,
  `PrimerDocument`, `DatabaseDocument`, SSE event payloads
  (`JobUpdateEvent`, `StageUpdateEvent`), etc.
- `frontend/src/api/client.ts` wraps `fetch` in generic
  `request<T>`/`get<T>`/`post<T>`/`patch<T>`/`put<T>`/`del<T>` helpers; every
  endpoint in the exported `api` object specifies its response type parameter.
- **Data at the boundary is typed, not validated:** responses are
  `res.json() as Promise<T>` (a compile-time assertion, no parsing/validation
  library such as zod or io-ts is present). SSE payloads are likewise cast:
  `JSON.parse(e.data) as Job` in `frontend/src/api/events.ts`.
- Dynamic-width data is intentionally `unknown`-based: table **rows** are
  `Record<string, unknown>[]` (columns are data-driven), `ConfigMap` values are
  `unknown`, Plotly figures arrive as `figure: unknown` and are narrowed by
  local casts (`figure as PlotlySpec` in `PlotlyChart.tsx`). So the answer at
  these seams is "typed as `unknown`, not `any`" — ergonomic but with unchecked
  downcasts at the point of use.

### 2.6 Component props

**Typed.** Props are declared as interfaces/types, e.g. `AnalysisControlsProps
extends UseAnalysisResult`, `CategorySetEditorProps`, `DatabaseEditorProps`
(exported), `FormatEditorProps`, `LevelsEditorProps`, `CorrectionEditorProps`,
`LevelSelectProps`, `EditorCardProps`, `FilterEditorProps`, `PairEditorProps`
(exported), `PrimerListEditorProps` — 11 `*Props` interfaces across 9 component
files found in one grep, plus inline-typed props elsewhere (e.g.
`ChartEditorInner({ state, onUpdate }: { … })`, `PlotlyChart`'s `Props`
interface with `heightRatio?: number` default). No `React.FC` usage; props are
typed on function parameters. No props typed as `any`.

### 2.7 Event handlers

**Typed**, both explicitly (`handleSubmit = async (event: React.FormEvent)`,
`React.MouseEvent<HTMLElement>`, `React.ChangeEvent<HTMLInputElement>`) and via
JSX contextual typing for inline handlers. No handler parameter is typed `any`.

### 2.8 Store/state types

**No external state library.** State is React-local plus three typed
contexts/buses, all generically or explicitly typed:

- `JobEventBus` (`subscribe: (fn: (job: Job) => void) => () => void`,
  `emit: (job: Job) => void`) with `JobEventContext =
  createContext<JobEventBus | null>(null)` (`frontend/src/hooks/useJobEvents.ts`).
- `SSEConnectedContext = createContext<boolean>(false)`.
- `ToastContext = createContext<ToastAPI | null>(null)` with
  `Toast`/`ToastAPI` interfaces (`frontend/src/components/Toast.tsx`).
- Fetching hook `useApi<T>(fetcher: () => Promise<T>): State<T> & { refetch:
  () => void }`.

---

## 3. Dependency audit

### 3.1 Direct dependencies (`frontend/package.json`; resolved versions from `bun.lock`)

**dependencies**

| Package | Declared | Resolved | Status in code |
|---|---|---|---|
| `react` | ^18.3.1 | 18.3.1 | imported (`main.tsx`, all components) |
| `react-dom` | ^18.3.1 | 18.3.1 | imported |
| `react-router-dom` | ^6.28.0 | 6.30.3 | imported (`App.tsx`, views) |
| `plotly.js-dist-min` | ^2.35.2 | 2.35.3 | imported (`PlotlyChart.tsx`, `ChartEditorInner.tsx`) |
| `react-chart-editor` | 0.46.1 (exact) | 0.46.1 | imported (`ChartEditorInner.tsx`); **untyped** (§2.4) |
| `@upsetjs/react` | ^1.11.0 | 1.11.0 | imported (`VennPanel.tsx`) |
| `react-plotly.js` | 4.0.0 (exact) | 4.0.0 | **Not imported anywhere in `src`** (dead dependency) |
| `@types/react-plotly.js` | ^2.6.4 | 2.6.4 | types for a package that is itself unused; and it is under `dependencies`, not `devDependencies` |

**devDependencies**

| Package | Declared | Resolved | Notes |
|---|---|---|---|
| `typescript` | ^5.7.2 | 5.9.3 | build-gate only (`noEmit`) |
| `vite` | ^6.1.0 | 6.4.1 | |
| `@vitejs/plugin-react` | ^4.3.4 | 4.7.0 | |
| `@types/react` | ^18.3.18 | 18.3.28 | |
| `react-dom` types `@types/react-dom` | ^18.3.5 | 18.3.7 | |
| `@types/plotly.js` | ^2.33.4 | 2.35.14 | ambient; the code instead types `plotly.js-dist-min` via the hand-written facade in `vite-env.d.ts` |

Notable transitive/peer facts (from the npm registry metadata, as the lockfile
does not record peer ranges):

- `react-plotly.js@4.0.0` declares `peerDependencies: { "react": "^18.0.0 ||
  ^19.0.0", "plotly.js": ">=3.0.0" }`. The installed Plotly is
  `plotly.js-dist-min@2.35.3`, which does **not** satisfy `>=3.0.0` — moot in
  practice because `react-plotly.js` is never imported, but it is an unsatisfied
  peer relationship in the tree (strict-peer package managers would fail).
- `react-chart-editor@0.46.1` declares `peerDependencies: { "react": ">=16.14.0",
  "plotly.js": ">=1.58.5 <3.0.0", "react-dom": ">=16.14.0" }` — satisfied.
  It is a React-16-era package with legacy dependencies (`draft-js`,
  `react-tabs`, `react-color`, `react-select`, `react-dropzone`, `prop-types`,
  `classnames`, `tinycolor2`, etc.), which is where most of the lockfile's
  transitive weight comes from (e.g. `@mapbox/point-geometry`, `@plotly/d3*`
  packages arrive via Plotly itself).
- `@upsetjs/react@1.11.0` peer: `react >= 17` — satisfied.

### 3.2 npm-only packages (no Bun compatibility)

**None identified.** Every dependency is pure JavaScript; the lockfile contains
**no lifecycle scripts** (`preinstall`/`install`/`postinstall`/`prepare`) and no
`node-gyp` references. The only native artefacts are the standard
`@esbuild/*` and `@rollup/*` platform binary packages, which Bun handles. The
frontend is already installed and built with Bun in CI
(`bun install --frozen-lockfile && bun run build`).

### 3.3 Known Bun incompatibilities

**None evidenced in the repository.** (Inference, per the Confidence section:
no install/build was run for this audit; but the project's own CI — and
`start.sh`, whose first-choice build path is Bun — treats the current
dependency set as Bun-compatible. `react-chart-editor`'s React-16-era
dependencies are a *general* maintenance risk, not a Bun-specific one.)

### 3.4 Deno-specific imports

**None.** No `https://` imports, no `import maps` (`import_map.json`/`deno.json`
absent), no `npm:` specifiers. Standard `index.html` + bare-specifier imports
throughout.

### 3.5 Duplicated functionality

- **HTTP client duplication: none** — all requests go through the single
  `fetch` wrapper in `api/client.ts`; no axios or second wrapper exists.
- **Plotly/React duplication: yes.** `react-plotly.js` (and its types, +
  `@types/plotly.js`) duplicate rendering paths that the code actually
  implements directly against `plotly.js-dist-min` with a hand-rolled
  declaration file. The unused trio is dead weight and creates the
  unsatisfied peer range noted in §3.1.
- Overlap between `react-chart-editor` and the in-repo `ChartCustomiser` /
  `alphaMetrics.tsx` cosmetics machinery is by design (editor + curated
  customiser), not a dependency-level duplication.

---

## 4. RSR template alignment

Compared against `rsr-template-repo` @ `b28679e`, read together with the
standards repo's `TEMPLATE-APPLICABILITY-POLICY.adoc`, which defines a
**universal baseline** plus capability-gated modules. MetaManifold-WebUI has
web-ui, api-service and (arguably) benchmarks capabilities, so gates for those
apply in principle. No `.machine_readable/rsr-profile.a2ml` exists in
MetaManifold-WebUI, so the repo has not declared a profile.

### 4.1 Missing files/directories the template expects (universal baseline)

| Expected by baseline | Present? | Notes |
|---|---|---|
| `README.adoc` | **No — `README.md` instead** | format mismatch with estate Adoc convention |
| `EXPLAINME.adoc` | No | |
| `LICENSE` | **Yes** (AGPL-3.0) | |
| `SECURITY.md` / `SECURITY.adoc` | No | |
| `CONTRIBUTING.md/.adoc` | No | |
| `CODE_OF_CONDUCT.md/.adoc` | No | |
| `CHANGELOG.md/.adoc` | No | only `docs/release-notes/v0.1.0.md`; template/standards generate changelogs via git-cliff (`cliff.toml`) |
| `0-AI-MANIFEST.a2ml` | No | |
| `.machine_readable/descriptiles/{STATE,META,ECOSYSTEM,AGENTIC,NEUROSYM,PLAYBOOK}.a2ml` | No (whole `.machine_readable/` tree absent) | template ships the equivalent under `machine-readable/` |
| `.machine_readable/rsr-profile.a2ml` | No | required to opt into the profile gate |
| `.well-known/` | No | |
| `.gitignore` | **Yes**, but non-standard (see §4.3) | |
| `Justfile` | No | |
| `LICENSES/` with `AGPL-3.0-or-later.txt`, `MPL-2.0.txt`, `CC-BY-SA-4.0.txt` | No | only the single `LICENSE` file |
| `.editorconfig` | No | |
| `.gitattributes` | No | |
| `.githooks/`, `.gitmessage`, `.mailmap` | No | |
| `.tool-versions` / `mise.toml` | No | MetaManifold uses `config/defaults/tool_versions.yml` instead (its own pin mechanism) |
| `CITATION.cff` | **Yes** | |
| `benches/` (capability `benchmarks`) | **`bench/` exists (different name, different purpose — see §6.3)** | |
| `tests/` (template dir name) | **`test/` exists (Julia convention name)** | |

### 4.2 Extra files/directories not in the template

Project-specific content (the applicability policy's "UNKNOWN" class — allowed
as the repo's own content, listed here for completeness): `.Rprofile`,
`Project.toml`, `Manifest.toml`, `R/`, `renv/`, `renv.lock`, `renv/` activation
machinery, `codecov.yml`, `config/` (defaults + CI config + `global_configs.md`),
`data/` (MiSeq_SOP integration dataset), `frontend/`, `web/` (including the
**committed build output `web/dist/`** ~7.8 MB), `install.jl`, `install.sh`,
`precompile_exec.jl`, `scripts/migrate_composition.jl`, `start.sh`,
`test/` + `bench/` trees.

### 4.3 Naming-convention mismatches

- `test/` vs template `tests/`; `bench/` vs template `benches/`.
- Docs in Markdown (`README.md`, `docs/release-notes/*.md`) vs estate AsciiDoc.
- `.gitignore` structural incompatibilities with the template:
  - `docs/*` is ignored **except** `docs/release-notes/` — so `docs/audit/`
    (this deliverable's mandated location) and most RSR doc trees would be
    git-ignored without `.gitignore` edits.
  - A blanket `.*` entry ignores **all dotfiles**, with explicit exceptions
    only for `!.github/**` and `!.Rprofile`. Adopting RSR dotfiles
    (`.editorconfig`, `.well-known/`, `.machine_readable/`, etc.) requires
    adding exceptions first.
- Naming relic: `test/runtests.jl` titles the top test set
  `"MetabarcodingPipeline"` and its header comment says
  "MetabarcodingPipeline test suite", while the package/module is
  `MetaManifold`. (Relic of a rename; cosmetic only.)

---

## 5. Standards repo alignment

Compared against `hyperpolymath/standards` @ `efaec62`.

### 5.1 Linting / formatting config

- Standards/template repos carry `.editorconfig` at root; MetaManifold-WebUI
  has **none** and **no linter/formatter at all** for JS/TS or Julia (§1.7).
- The standards repo's `LANGUAGE-POLICY.adoc` ranks JS/TS toolchains
  **Bun > Deno > pnpm > npm**. MetaManifold-WebUI already uses **Bun** with a
  single committed `bun.lock` — **aligned** with tier 1. (The same policy
  ranks *AffineScript* above TypeScript for new application code, with TS a
  transitional carve-out; this pre-existing React/TS frontend predates any
  such migration for the audit's purposes — noted as context, not verdict.)
- No `.githooks`, no pre-commit config in the target repo.

### 5.2 Naming / structure / commit conventions

- **Commit conventions: deviation.** The standards repo's `CONTRIBUTING.adoc`
  mandates Conventional Commits. MetaManifold-WebUI's recent history contains
  e.g. `CI fix.`, `Real CI fix.`, `Real real CI fix.`, `CI debugging.` —
  not Conventional Commits format.
- **Remote URL policy:** `REMOTE-URL-POLICY.adoc` mandates SSH-only remotes
  without embedded credentials. Not assessable from repo contents (remote URL
  lives in local clones and CI secrets, not in tracked files). No token-bearing
  URLs exist in tracked files (checked badges/configs). Observed inconsistent
  provenance instead: README CI/Codecov badges and `codecov-action` `slug:`
  still point to the parent repo `JoshuaJewell/MetaManifold-WebUI` — factually
  correct for a fork, but worth recording in any provenance review.
- **Documentation format:** the estate's prose format is AsciiDoc
  (`*.adoc` with `// SPDX-…` headers); audits in the standards repo live in
  `audits/` as `audit-<topic>-<date>.adoc` or in `docs/AUDIT.adoc`. The task
  mandates this deliverable as **Markdown** at `docs/audit/type-system-reconnaissance.md`;
  that is a known, deliberate deviation from estate format (and additionally
  collides with the `docs/*` gitignore rule, §4.3).

### 5.3 Licence headers (SPDX)

- Policy (`LICENCE-POLICY.adoc`): every code/config/script file carries
  `SPDX-License-Identifier` — estate default `MPL-2.0` for code,
  `CC-BY-SA-4.0` for prose docs (Rule 1); `AGPL-3.0-or-later` for projects
  co-developed with the owner's son (Rule 3) and certain network services /
  games (Rules 4–5); `LICENSES/` holds the canonical licence texts.
- Repo root licence is **AGPL-3.0** (GNU Affero GPLv3 text in `LICENSE`).
  Given the fork-of-`JoshuaJewell` provenance this is *consistent* with Rule 3,
  though MetaManifold is not in the named Rule-3 example list and is not
  registered anywhere in `standards` that this audit found (§Confidence).
- **SPDX header presence: none.** 0 of 55 TS/TSX files and 0 of 40 Julia
  source files contain `SPDX-License-Identifier`. No file anywhere in the
  repository contains the string (excluding `.git`, `renv/`).
- Three frontend files (`ChartCustomiser.tsx`, `ChartEditorInner.tsx`,
  `TaxaCompositionChart.tsx`) carry an informal header
  `// (c) 2026 Joshua Benjamin Jewell. All rights reserved. / Licensed under
  the GNU Affero General Public License version 3 (AGPLv3).` — licence-consistent
  with the root `LICENSE` but **not in SPDX form**, and restricted to those
  three files. No `LICENSES/` directory exists (§4.1).

---

## 6. proven-tests-and-benches alignment

Compared against `hyperpolymath/proven-tests-and-benches` @ `b38b7ca` (an
Idris2 type-safe testing framework: three-tier warrant classification, a
17-category × 14-aspect zigzag co-creation lattice, typed coverage claims).
Note the name correction: no public `proven-tests-and-benchmarks` repo exists
under `hyperpolymath`; `proven-tests-and-benches` is the actual input audited.

### 6.1 References in MetaManifold-WebUI

**None.** A repo-wide search for `proven-tests`, `zigzag`, `property-based`,
and `Supposition` found no reference to the proven-tests framework, its
taxonomies, or its naming anywhere in MetaManifold-WebUI.

### 6.2 Applicable-but-missing test patterns

Patterns from proven-tests-and-benches that transfer to this stack and are
absent here:

- **Warrant classification** (Actually-Proven / Provisionally-Proven /
  Unproven tagging of tests). The Julia suite mixes example-based unit tests
  and heavy integration tests with no explicit classification; nothing marks
  which properties are exhaustively versus exemplarily supported.
- **Property-based testing.** None anywhere: no property-based library in the
  Julia suite (no `Supposition.jl`/`QuickCheck`-style use; tests are
  fixture/example-driven), and no TS-side property tests (`fast-check` or
  similar) — there are no frontend tests at all (§1.5).
- **Boundary/schema round-trip tests.** proven-tests emphasises tests whose
  type-safe coordinates make coverage claims auditable; the closest unmet
  analogue here is runtime-validated API parsing (§2.5) plus round-trip
  tests for the JSON surfaces (`api/types.ts` vs Julia serializers).
- **Machine-readable test-gap registers** (`TEST-NEEDS.adoc`/`PROOFS.adoc`
  style). MetaManifold-WebUI has no test-need or proof-need register.

### 6.3 Benchmark patterns that should be assessed for adoption

- proven-tests carries `benchmarks/` with a committed runner
  (`run_benchmarks.sh`) and a package spec (`benchmark.ipkg`).
- MetaManifold-WebUI's `bench/layer1_mock_recovery/` **is already an evaluation
  harness** — `datasets.yml` manifest + `fetch.jl` + `runner.jl` +
  `evaluate.jl` + `report.jl` — but it measures **pipeline accuracy on mock
  communities** (scientific validation), not **performance**. There is no
  performance benchmark (no `BenchmarkTools.jl` usage, no CI benchmark job, no
  frontend bundle-size/runtime benchmark). If the repo declares the
  `benchmarks` RSR capability (§4), the applicable proven-tests pattern is a
  committed, reproducible runner wired to a recorded baseline — the accuracy
  harness structure is a good substrate for it.

---

## 7. Blockers and risks for Bun migration

Headline: **there is no Bun migration left to do at the JS layer** — Bun is
already the installed, pinned, CI-enforced runtime/package manager. What
follows is the residual-risk inventory I was asked to check.

### 7.1 Postinstall scripts assuming npm

**None.** No lifecycle scripts in `package.json` or anywhere in `bun.lock`
(§3.2). `bun install --frozen-lockfile` is the documented and CI-used path.

### 7.2 Native modules needing Bun-compatible builds

**None in the JS tree.** Only `@esbuild/*`/`@rollup/*` prebuilt platform
binaries (Bun-compatible, already in use). Native-build concerns exist on the
Julia/R side (`RCall` must be rebuilt after R is installed — CI has an explicit
step; `PackageCompiler.jl` for sysimages), but these are orthogonal to Bun.

### 7.3 Deno-specific APIs in use

**None.** No `Deno.*` globals, no `node:*` or bare Node builtin imports in
`frontend/src`, no `https://` imports, no import maps (§3.4). The only
hard-coded hostnames are dev-proxy targets in `vite.config.ts`
(`http://127.0.0.1:8080`), which are build-time, not runtime.

### 7.4 CI runtime assumptions

- CI is **GitHub Actions, `ubuntu-24.04` only**, single job, single Julia
  version (1.12.5), with every external tool version read from the committed
  pin file `config/defaults/tool_versions.yml` and SHA-256-verified downloads.
- The JS toolchain assumption is explicitly **Bun**:
  `oven-sh/setup-bun@v2` with `bun-version` from the pin file; then
  `bun install --frozen-lockfile && bun run build` in `frontend/`. The build
  script's `tsc &&` step is the only frontend type gate in CI.
- No CI step runs frontend tests (none exist), linting, or format checks.
- Codecov upload uses `slug: JoshuaJewell/MetaManifold-WebUI` (parent repo);
  `CODECOV_TOKEN` secret assumed against that slug.
- `start.sh` retains a **non-Bun fallback**: if `bun` is absent it runs
  `frontend/node_modules/.bin/tsc && .bin/vite build`, i.e. it assumes someone
  previously installed with npm/Node. `install.sh`/`install.jl` do **not**
  build the frontend or install Bun; `start.sh` also short-circuits entirely
  when the committed `web/dist/` bundle is present (`BUILD=0` default). These
  are working, deliberate affordances — recorded as the places where a
  Bun-only world would need edits.

### 7.5 Other risks relevant to future type-system work

- `package.json` has no `engines` BUN/Node floor; the only floor is the pin
  file Bun 1.3.10 (CI reads it; local machines rely on README).
- Unused dependencies with an unsatisfied peer range
  (`react-plotly.js@4.0.0` wants `plotly.js >=3`; tree carries dist-min 2.35.x)
  — a future switch to a strict-peer installer would fail on this (§3.1).
- Hand-rolled `plotly.js-dist-min` declaration narrows all chart typing to
  `Record<string, unknown>`; any tightening of figure types must replace or
  widen this facade (§2.4).
- `tsconfig` `paths` aliases without matching Vite `resolve.alias` (§1.3) —
  adopting aliases later requires build-config changes, or removal of the
  dead `paths`/`baseUrl`.

---

## Recommendations

*Separated from findings per the task constraints. Nothing below has been
applied; each item cites the finding it follows from.*

1. **Type tightening (highest value, §2):** enable `noUncheckedIndexedAccess`
   and consider `exactOptionalPropertyTypes`; add runtime parsing at the
   `client.ts`/`events.ts` boundary (zod or hand validators) for
   `Record<string, unknown>`/`unknown` seams; replace the `react-chart-editor`
   `any`-stub (`ChartEditorInner.tsx` props are effectively untyped), and
   replace the hand-rolled Plotly facade with `@types/plotly.js`-derived types
   or a generated subset.
2. **TypeScript config hygiene (§1.3):** either wire Vite `resolve.alias` to
   the existing `paths` (and migrate the 195 relative imports) or delete
   `baseUrl`/`paths` and `allowImportingTsExtensions` to remove vacuous config.
3. **Dependency cleanup (§3):** remove `react-plotly.js`,
   `@types/react-plotly.js`, and (if unused after item 1) `@types/plotly.js`;
   this also removes the unsatisfied peer range. Keep the react-chart-editor
   pin under review given its React-16-era dependency tree.
4. **Testing (§1.5, §6):** add a frontend test runner that runs under Bun
   (Bun test or Vitest), property-based tests for the pure data transforms
   (Julia: `Supposition.jl`-style; TS: `fast-check`), and, in the spirit of
   proven-tests, adopt warrant-tier tagging plus a machine-readable
   test-needs register rather than chasing the Idris2 framework itself, which
   does not target this stack.
5. **Standards alignment (§4, §5):** add `.editorconfig`; add SPDX headers
   (AGPL-3.0-or-later for code, CC-BY-SA-4.0 for prose, per LICENCE-POLICY)
   and a `LICENSES/` directory; add the universal-baseline community files
   (`SECURITY`, `CONTRIBUTING`, `CODE_OF_CONDUCT`, `CHANGELOG` via git-cliff,
   `0-AI-MANIFEST.a2ml`, `.machine_readable/` with `rsr-profile.a2ml`
   declaring e.g. `julia`, `web-ui`, `api-service`, `benchmarks`);
   adopt Conventional Commits. Confirm with the owner whether
   MetaManifold-WebUI should be registered under LICENCE-POLICY Rule 3.
6. **Gitignore surgery (§4.3):** before adding any of item 5 or committing
   this audit, add exceptions for the chosen dotfiles and for `docs/audit/`
   (currently all of `docs/*` except `release-notes/` is ignored, and all
   dotfiles are ignored by the blanket `.*` rule).
7. **Provenance (§5.2, §7.4):** decide whether CI badges/Codecov slug should
   move to `hyperpolymath/MetaManifold-WebUI` or deliberately track the fork
   parent, and record the decision.
8. **Version pinning (§1.8, §7.5):** consider adding an `engines.bun`
   (or `.tool-versions`/`mise.toml`) that mirrors the
   `config/defaults/tool_versions.yml` Bun pin so local tooling picks the same
   floor CI enforces — or document the divergence explicitly.

---

*Method note: findings derive from read-only inspection of cloned repositories
(`git clone --depth`) plus public registry metadata (`api.github.com`,
`registry.npmjs.org`). No files were modified, no dependencies installed, no
build/test executed, in line with the audit constraints. Where a judgement is
an inference rather than a direct observation, it is marked as such in-line and
summarised in the Confidence section.*
