<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

# Stipple/Vue migration: reconnaissance

**Date:** 2026-09-18
**Baseline:** `ecefb1c72b3d2515e7086024b14227ef13329605`
**Repository:** hyperpolymath/MetaManifold-WebUI
**Status:** historical recon baseline. Implementation has now started in `ui/`; see [implementation status](IMPLEMENTATION.md). Recon itself made no remote changes; publication is tracked in Git history.

## Decision summary

Move application-authored UI code from React/TypeScript to Julia using Stipple and StippleUI, with Vue/Quasar supplied by the framework. Keep the existing Oxygen backend and scientific implementation during migration. Start with an opt-in, separate Julia environment/process using the existing API. Do not begin by installing Genie into the root project or deleting the React frontend.

The target is no application-owned TypeScript/React build after parity, NOT a browser without JavaScript. Browser-local integrations may need narrow adapters. No feature cuts are authorised by this recon. Exact chart-editor, set-visualisation and table parity require explicit decisions before cutover.

## Evidence and limits

Inspected frontend routes, API contracts/client/events, hooks, representative views, custom tables/charts/editor/set visualisation, server composition/middleware, route helpers, job state, R coordination, manifests, startup and CI/test entrypoints. Inventory is static, not proof every path works.

- 55 `.ts`/`.tsx` files under `frontend/src`, 8,977 lines including declarations/comments.
- 91 literal HTTP/stream route macro declarations in `src/server/routes/*.jl`.
- [Frontend inventory](frontend-inventory.csv): file sizes, literal `from` imports, and direct `api.x.y` references.
- [API inventory](api-inventory.csv): file, line, macro and path.
- Inventories use regex extraction, not a language parser; dynamic imports, indirect API calls, middleware routes and dynamic registrations are not exhaustively represented. `STREAM` is an Oxygen macro, not an HTTP verb.
- Julia and Bun are not on PATH in the recon workspace; Node is present. No Julia package resolution, frontend build, application launch, pipeline execution or browser tests were performed.
- Working tree was clean at start. Changes in this phase are documentation/inventory only.

## Current architecture

```text
Browser: React + Router + custom CSS + Plotly + React chart editor + UpSet
   | JSON requests / SSE events / file downloads
Oxygen + HTTP + JSON3 (src/server/server.jl)
   | route handlers and shared helpers
MetaManifold modules + job queue + DuckDB/files
   | RCall/shared R runtime and external scientific tools
```

### Frontend routes

Source: `frontend/src/App.tsx`.

| Route | Current destination | Migration considerations |
|---|---|---|
| `/` | redirect to `/studies` | preserve landing behaviour |
| `/studies` | StudiesView | list/create/rename/delete, counts, loading/error/empty states |
| `/jobs` | JobsView | job states, cancellation, updates |
| `/databases` | DatabasesView | definition editor and downloads/jobs |
| `/config` | DefaultConfigView | default config changes and inheritance semantics |
| `/compositions` | CompositionsView | shared filters/category sets |
| `/primers` | PrimersView | document validation and save |
| `/:study` | StudyView | groups/runs, study actions and analyses |
| `/:study/:slug` | SlugResolver | distinguish groups from runs; do not flatten hierarchy |
| `/:study/:group/:run` | RunView | group-aware operations/results |
| unmatched | NotFoundView | real not-found UI |

During the pilot use a separate origin/port, preserving paths there; do not hijack the production SPA catch-all. Test direct page loads, refresh, back/forward, invalid names and groups/pooled runs. Reserved static routes must take precedence over dynamic study slugs.

### Contracts and state ownership

`frontend/src/api/client.ts` maps a broad API: studies/groups/runs, pipeline, jobs, result queries/distinct values/save/export, presets, config inheritance, primer/database documents, annotation edits, composition and analysis, and chart cosmetics. Generic `res.json() as Promise<T>` is an assertion, not payload validation.

Keep backend data authoritative. Session UI models own current selection, loading/errors and edit drafts; they must not become global mutable singletons. Use concrete Julia DTOs and explicit validation at the API adapter. Distinguish missing values from empty values. Preserve `group` in run identity, and reject stale responses after navigation or a newer request.

Initial UI DTOs are transport types in the pilot environment. Later shared domain types belong in a small dependency-light layer, not in a module that loads the entire scientific runtime. Do not serialize internal Job Tasks, locks, filesystem authorities or arbitrary internal state to the browser.

### Jobs and events

Sources: `src/server/jobs.jl`, `src/server/routes/events.jl`, `frontend/src/api/events.ts`, `frontend/src/hooks/useJobEvents.ts`.

- Existing queue is in-memory, explicitly designed for a single-user local server.
- JobStatus enum: queued, running, complete, failed, cancelled. Terminal transitions are guarded; cancellation can precede actual task settlement.
- Global SSE transports `job_update` and `stage_update`; browser EventSource reconnects automatically. Client parsing does not runtime-validate the event DTOs.
- React refetch listeners react to running/complete/failed jobs. The replacement must deliberately specify cancellation and reconnection refresh behaviour rather than blindly reproduce omissions.
- Preserve SSE for the old app. A separate UI process may begin with bounded polling of existing API snapshots, explicitly labelled as such. Subsequently use one managed backend event feed plus per-session fan-out, or another tested subscription design.
- On reconnect, fetch authoritative state: event transport alone is not durable history. Close subscriptions/timers with sessions. Slow/disconnected clients must not block jobs. Debounce/coalesce updates.
- Never submit a second pipeline because a reactive model reinitialised or a socket reconnected.

### Scientific/runtime boundary

`src/MetaManifold.jl` includes core, pipeline and analysis modules. `src/core/r_runtime.jl` serialises access to embedded R and supports bounded waits; server middleware translates RBusyError to HTTP 503 `r_busy`. Keep all scientific operations in the existing backend during the pilot. Do not accidentally create a second R runtime/job queue by importing the whole server into the UI process. Do not move work into a synchronous UI callback or bypass the lock/cancellation/provenance logic.

## Feature-parity risk map

| Surface / source | Risk | Required proof before replacement |
|---|---|---|
| Studies and naming dialogs | Low–medium | create/rename/delete validation, confirmation, refresh, route consistency |
| Run/group/pooled navigation | Medium | group identity and pooled child naming match API |
| ConfigAccordion and editor components | Medium | inheritance, override deletion, false/zero/null, failed-save recovery, round trips |
| DataTable.tsx | **High** | server pagination/sort/filter, distinct-value filters, numeric filters, column presets/visibility, sessionStorage persistence, highlights, popups/clipboard, OTU details, export semantics |
| AnnotationPanel / controls | High | contamination and assignment edits, affected-row counts, source/table context, exports |
| CompositionPanel / category/filter editors | Medium–high | shared library persistence, invalid filters, cross-run selections |
| PlotlyChart.tsx | Medium–high | raw Plotly figure compatibility, defaults, resize handle, pixel dimension inputs, ResizeObserver behaviour, cleanup/export |
| ChartEditorInner / ChartCustomiser | **High** | replacement for React style panels; cosmetics persist/reset without changing trace data |
| VennPanel.tsx | **High** | Euler and UpSet layouts, taxonomy-rank intersection, rendering and actual interactions |
| Jobs + SSE | High | cancellation, reconnect refresh, no duplicate submissions, session cleanup |
| Downloads and reports | Medium | XLSX POST response handling, CSV links, PDFs/logs, headers/filenames, safe file routing |

Correction to a coarse dependency-level description: `react-plotly.js` is declared, but the inspected `PlotlyChart.tsx` directly calls Plotly.react/relayout/purge. Preserve this custom behaviour rather than assuming a stock React wrapper is the whole chart layer.

StipplePlotly is a candidate renderer, not a replacement for react-chart-editor. No verified Julia-only drop-in editor or equivalent set renderer was established in recon. Investigate exact support before promising parity. Keeping an old React island is an interim option, not completion of React removal.

## Dependency compatibility gate

Root Manifest records Julia 1.12.5, HTTP 1.11.0, Oxygen 1.10.1 and JSON3 1.14.3. Root Project has broad/partial compat constraints; do not opportunistically update it during UI work.

Upstream main Project.toml files inspected on 2026-09-18 (moving branch snapshots; NOT resolved package versions):

| Package | Declared version | Relevant compat |
|---|---|---|
| Stipple | 1.0.4 | Genie `5.35.15, 6`; Julia 1.6 |
| StippleUI | 1.0.1 | Stipple `0.28 - 0.31, 1` |
| StipplePlotly | 1.0.0 | Stipple `0.28 - 0.31, 1`; PlotlyBase 0.8.19 |
| Genie | 6.0.5 | HTTP `2.1`; Julia 1.10 |

Sources: https://github.com/GenieFramework/Stipple.jl/blob/main/Project.toml ; https://github.com/GenieFramework/StippleUI.jl/blob/main/Project.toml ; https://github.com/GenieFramework/StipplePlotly.jl/blob/main/Project.toml ; https://github.com/GenieFramework/Genie.jl/blob/main/Project.toml .

**Important:** current Genie 6 requirements do not match the root's locked HTTP 1 version. This is a demonstrated version mismatch, not a completed solver result proving every combination impossible. Stipple also declares a Genie 5 path. A separate environment/process avoids requiring either route in the backend now. Resolve released package versions in that environment, commit its manifest, and test actual browser assets/transport before selecting versions. Do not invent pins from moving main metadata.

## Proposed pilot topology

```text
Browser -> opt-in Stipple UI process (separate ui/ Project + Manifest)
                     -> server-side HTTP adapter -> existing Oxygen API
Browser downloads -> explicit same-origin streaming proxy or tested backend links
Legacy browser -> unchanged Oxygen SPA/API/files
```

Proposed paths (not created/implemented by recon):

```text
ui/Project.toml, Manifest.toml
ui/src/MetaManifoldUI.jl
ui/src/Contracts.jl        # narrow validated transport types
ui/src/BackendClient.jl    # allowlisted fixed-backend API adapter
ui/src/models/Studies.jl
ui/src/pages/Studies.jl
ui/test/runtests.jl
ui/serve.jl
```

Backend address is server configuration, never a browser-supplied arbitrary URL (SSRF risk). Browser URLs must not contain sandbox/server localhost addresses. For remote hosting, configure exact host/origin handling and authenticate as a separate deployment requirement: the existing local-only CORS middleware rejects non-localhost Origin values, including requests that carry such an Origin on a remote same-origin deployment. CORS is not authentication. Do not change it to `*` as a shortcut. WebSocket origin validation, reverse proxy upgrade handling, and session boundaries require testing.

A Julia-only application build does not remove third-party JS/CSS assets; verify local asset availability without a CDN. Leave old startup/default UI unchanged until cutover.

## Tests and baseline

`test/runtests.jl` always includes unit suites, including routes/jobs/config/analysis/R runtime/provenance. `--integration` selects pipeline tests; **`--server` selects server smoke tests**. The header in test/integration/test_server.jl mentioning only --integration is not the authoritative switch.

`test/unit/test_routes.jl` includes the Server module and exercises helpers. Preserve these tests and their module identity assumptions. `.github/workflows/ci.yml` builds the frontend and runs Julia tests with both --integration and --server. frontend/package.json has dev/build/preview scripts but no declared frontend test script; no dedicated browser test suite was found in this checkout. Existing CI passing would therefore not establish UI parity.

Before writes are exposed in the pilot:
1. Capture JSON fixtures from a disposable synthetic backend root (no real study data).
2. Add adapter/DTO tests for empty/error/malformed responses, timeouts and grouped runs.
3. Browser checks for first render, direct link, refresh, disconnected backend, and independent tabs.
4. Mutation checks with disposable data: invalid name, successful create, duplicate create, failed rename/delete and recovery.
5. Add bounded event/reconnect and job-state checks before pipeline controls.
6. Use scientific result comparisons/golden fixtures for later analysis migration; visual similarity is insufficient.

Julia test execution remains pending; recon did not modify or run scientific data.

## Backlog and gates

See [implementation backlog](BACKLOG.md). First implementation is deliberately smaller than a complete pipeline workflow: dependency/bootstrap proof plus read-only Studies/Study navigation. This isolates framework and transport risks before destructive actions or long-running jobs.

## Cutover and rollback

Retain frontend/, web/dist serving, start.sh and existing CI build during pilot. Start/stop the opt-in UI independently; rollback is returning to the existing UI. Both UIs share backend data, so rollback does NOT undo writes; test with disposable roots and back up data before user trials. Avoid schema/config-format changes in the UI migration.

Only after feature acceptance remove React/TS source and Vite/Bun requirements. Audit start.sh, .github/workflows/ci.yml, frontend/vite.config.ts, frontend/public/config.json, web/dist serving in server.jl, README/release docs, and config/defaults/tool_versions.yml plus its pin tests. Keep scientific tool/runtime pins and provenance. Review installer/precompile paths without assuming they all contain frontend build steps. Preserve AGPL notices and upstream attribution.
