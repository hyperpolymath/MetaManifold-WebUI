<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000031
parent: 0198ba50-0000-7000-8000-000000000030
position: 10
kind: page
tags:
  - developers
  - architecture
archived: false
-->

# Architecture tour

**Status: IN PLACE.** A walk from an HTTP request to a count table and back
to a chart. Companion: `EXPLAINME.adoc` (claim receipts) and
`docs/types/architecture.md` (frontend type placement).

## The shape

```
frontend/           TypeScript + React + Vite (SPA)
  src/api/          REST client + canonical wire types (src/api/types.ts)
  src/types/        the domain type estate (API boundary, plotly vocabulary)
  src/views/        Run view, results explorer, annotation, composition, ...
  tests/            unit / integration / e2e-lane / fixtures
src/
  core/             types.jl, config.jl (cascade), duckdb_store.jl, project.jl,
                    databases.jl, primers_library.jl, composition_library.jl,
                    validate.jl, r_runtime.jl, epistemic.jl, log.jl
  pipeline/         tools.jl (cutadapt/QC wrappers), dada2/ (R bridge),
                    swarm.jl, merge_taxa.jl — typed stage results
  annotation/       funcdb: dual-classifier consensus, curation, ledger
  analysis/         diversity.jl, analysis.jl, estimation.jl, exact_summaries.jl,
                    numeric_policy.jl, scaling.jl, AnalysisConfig.jl, Execution.jl,
                    clade_cumulus.jl (scaffold)
  server/           Oxygen.jl HTTP server + routes/ (REST + SSE)
config/             defaults/, schemas/ (analysis_config.schema.json + .ncl),
                    composition.yml, databases.yml, primers.yml, tool_versions.yml
data/, projects/    input FASTQs (user) / outputs (generated)
ui/                 the opt-in Stipple/Vue migration slice (PR #73 in flight)
```

## The typed stage spine

Each pipeline stage returns a typed result — `TrimmedReads`, `ASVResult`,
`OTUResult`, `TaxonomyHits`, `MergedTables` (`src/core/types.jl`) — and
skips itself when outputs are current: **mtime freshness for files, content
hash for configuration**. Rerunning after a config change re-executes the
minimum set; the UI flags exactly the stages a change would regenerate and
names the changed keys at their cascade level. This freshness contract is
the quiet backbone: everything user-facing ("why is this stale?") reduces to
it.

## A request's life (analysis chart)

```
browser (Run view)
  → POST /api/v1/.../analysis/{alpha|taxa-bar|venn|nmds|permanova}
  → server/routes (authz-free single-user layer; validation in core/validate.jl)
  → analysis/Execution.run_analysis
       → numeric_policy mode assertion (exact work needs exact mode)
       → diversity/estimation/scaling as the AnalysisConfig directs
       → R bridge (r_runtime.jl) where the method is R-backed
       → refusal (named unsuccessful state) where it cannot run
  → Plotly chart JSON back to the browser → plotly.js-dist-min render
```

Chart JSON, not HTML fragments: the frontend is a thin renderer over
server-built Plotly specifications (with the chart-editor seam for
cosmetics — one of the Stipple migration's known parity risks).

## The R boundary

R (DADA2, vegan, MASS, stats) enters through `src/core/r_runtime.jl` and the
DADA2 module's `dada2_functions.r`. Design rules: the R session is a
capability (its absence is reported, never faked — `GET /api/v1/capabilities`);
R's `NA` is read as missing, not as a value (a real bug once killed every
parametric fit — #66); package availability is decided by `renv.lock`, and
"package absent" yields "Not Implemented", never a guess.

## Where state lives

| State | Home | Notes |
|---|---|---|
| Inputs | `data/{study}/[{group}/]{run}/*.fastq.gz` | user-owned; leaves = runs |
| Outputs | `projects/{study}/{run}/…` | generated; `run_config.yml` is provenance |
| Tables the UI queries | `merged/results.duckdb` (per run) | via `core/duckdb_store.jl` |
| Curation (contamination, BLAST overrides) | separate from derived annotation | survives re-annotation |
| FuncDB ledger | append-only | survives re-annotation |
| Config cascade | `config/`, `data/**/pipeline.yml`, `projects/**/run_config.yml` | merged truth at run_config.yml |
| Jobs | in-memory + logs | cancel via `DELETE /jobs/{id}` |

## Known structural seams (read before moving things)

- The **frontend wire types** (`src/api/types.ts`, upstream file) are the API
  boundary of record; `src/types/api/` fakes nothing — endpoint→source map in
  `src/types/api/index.ts`.
- **Plotly-chain modules** are import-blocked in the DOM-less bun test lane;
  the DOM lane decision (playwright vs harness) is pending before the e2e set
  grows (`frontend/tests/unit/plotly-chain.todo.test.ts`).
- The **Stipple slice** (`ui/`) is intentionally isolated (own Julia
  environment) — do not share the HTTP-2 environment with the Oxygen HTTP-1
  server (a migration-record line).
- **CladeCumulus** (`src/analysis/clade_cumulus.jl`) is scaffolded
  structures only; the real implementation rides its own branch/issue (#6).
