<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000036
parent: 0198ba50-0000-7000-8000-000000000030
position: 60
kind: page
tags:
  - developers
  - api
  - reference
archived: false
-->

# REST API

**Status: IN PLACE** (surface summary; route handlers in `src/server/routes/`
are the truth). All responses are JSON; analysis endpoints return Plotly
chart specifications. Base: `/api/v1/`. Single-user, **no authn** — see
[Operator Track](Maintainers--Operator-Track) before binding anywhere but
localhost.

## Endpoint groups

| Group | Endpoints | Description |
|---|---|---|
| Studies | `GET/POST/DELETE /studies`, `POST .../rename` | list, create, rename, delete studies |
| Groups | `POST/DELETE /studies/{study}/groups`, `POST .../rename` | group management (pooled-run navigation) |
| Runs | `GET/POST/DELETE /studies/{study}/runs`, `POST .../rename` | run management; leaves on disk are discovered |
| Config | `GET/PATCH/DELETE .../config`, `GET .../config/overrides` | read/edit any cascade level; list downstream overrides |
| Primers | `GET /primers`, `GET /primers/document`, `PUT /primers` | pair names; whole-document read/replace (validated before write) |
| Pipeline | `POST .../pipeline`, `POST .../stages/{stage}` | launch full study, single run, or one stage (DADA2 substages included) |
| Jobs | `GET/DELETE /jobs`, `GET /jobs/{id}/logs` | monitor, cancel, fetch logs |
| Events | `GET /events` | **SSE** stream: real-time job and stage updates |
| Results | `GET/POST/DELETE .../results/tables/...` | list, query, filter, save, export (`.xlsx`), delete; OTU member drill-down |
| QC | `GET .../results/qc`, `GET .../results/dada2` | MultiQC metadata; DADA2 figures, logs, stats |
| Analysis | `POST .../analysis/{alpha,taxa-bar,venn}`, `GET .../analysis/{pipeline-stats,ranks}` | per-run charts; rank discovery |
| Cross-run | `POST /studies/{study}/analysis/{alpha,taxa-bar,nmds,permanova,venn}` | comparisons, NMDS, PERMANOVA, overlap across runs |
| Composition | `GET /category-sets`, `POST /composition/{source}/{build,query,distinct,analysis}` | category sets; organism-composition tables and charts |
| Annotation | `GET/POST .../annotations/{source}/...`, `POST /funcdb/entries`, `PATCH .../{contamination,blast-assignment}` | generate/query annotations; curate; FuncDB ledger |
| Filter presets | `GET/POST/DELETE /filter-presets` | reusable table filters |
| Databases | `GET /databases`, `GET /databases/document`, `PUT /databases`, `POST /databases/{key}/download` | whole-document read/replace (validated; returns advisory warnings), explicit downloads |
| System | `POST /init`, `GET /capabilities` | project directory initialisation; server capabilities (e.g. R availability) |

## Contracts worth knowing before a client change

- **Plotly JSON is the chart wire format** — server-built specs; the client
  renders (`plotly.js-dist-min`) and may adjust cosmetics via the
  chart-editor seam. A new chart means a server-side builder.
- **Validation is server-side and total** (`core/validate.jl`): primers and
  databases documents are validated whole before any write — a rejected
  document leaves the file untouched. Same for config patches (bad cascade
  keys refuse; dangling renames are *reported*, not blocked).
- **Refusals travel as structured unsuccessful states** on analysis
  endpoints — treat them as first-class responses in every client
  (including the Stipple one), never as empty successes (#31's rule
  generalised).
- **SSE (`/events`)** is the only push channel; reconnect snapshots and
  bounded subscriptions are on the Stipple migration's checklist
  (`docs/migration/STATUS.md`) — design clients to re-sync, not to assume a
  gapless stream.
- **Capabilities** (`/capabilities`) is how a client learns that R is absent
  before offering R-backed methods — check it, do not infer from errors.

## Adoc-era notes

- The endpoint→SOURCE map in `frontend/src/types/api/index.ts` must move in
  the same change as any route (the type estate's rule).
- **COMING:** the API is versioned at `/api/v1/` for the React client; the
  Stipple client consumes the same surface through a validated backend
  adapter (`ui/`), and recoverable Zenodo publication endpoints ride issue
  #8 (draft PR #74).
