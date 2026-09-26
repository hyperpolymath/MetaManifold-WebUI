<!-- berrywiki
id: 0198ba50-0000-7000-8000-000000000034
parent: 0198ba50-0000-7000-8000-000000000030
position: 40
kind: page
tags:
  - developers
  - extending
  - guide
archived: false
-->

# Extending the pipeline

**Status: IN PLACE** (the extension points; the queue of things to add with
them is [Status and Roadmap](Status-and-Roadmap)).

## Adding a pipeline stage

1. New stage module under `src/pipeline/` returning a typed result from
   `src/core/types.jl` (or a new type added there, with its consumers).
2. **Freshness contract first:** declare what outputs the stage writes and
   which config keys invalidate them. The mtime/hash skip logic and the UI's
   stale-flagging both read this; a stage without it will re-run forever or
   never.
3. Wire into `Execution`/the run orchestrator at the right point in the
   graph (the two lanes and their joins are drawn in
   [Design Progression](Deep-Dives--Design-Progression)).
4. Config block: defaults in `config/defaults/pipeline.yml` (canonical, do
   not edit casually) + cascade merge in `core/config.jl` semantics + UI
   accordion section.
5. Tool wrapper (if it shells out): `src/pipeline/tools.jl` pattern — path
   resolution from `config/tools.yml`, optional SSH routing, and a pinned
   record in `config/defaults/tool_versions.yml` (version + URL + sha256) so
   `install.sh` fetches it byte-exactly. An unpinned tool cannot merge.
6. Tests: fixture under `test/fixtures/`, unit test with known outputs,
   negative controls for each refusal.

## Adding a statistical method — the gated path

This is the extension the project cares most about, so it is the most
gated:

1. **Conditions document** in `docs/statistics/method-conditions/` —
   response types accepted (and what happens to zeros and all-zero samples),
   study designs supported (pairing, blocking, repeated measures,
   covariates, depth, compositionality), overdispersion/depth policy,
   uncertainty (interval method, effect size, BH mandatory), diagnostics
   and the assumption most likely to be wrong, computational limits and
   what happens at them (`ResourceLimitError`-style states). Published and
   reviewed **before** code.
2. **Catalogue registration** in `docs/statistics/method-catalogue-v1.md`
   (or its successor) — scope approval is a separate step from behaviour.
3. Implementation that can only refuse or do what the document says. If the
   document and the code disagree, **the document is right and the file is
   the bug** (the standing rule; it has already found real defects).
4. Tests in the estimation suite's idiom: known answers written into the
   fixture data (not read back out of the fit), an independent reference
   (R or Python) compared value-by-value, negative controls for every
   refusal path, and a guard that stubs cannot return.
5. AnalysisConfig surface: new method token + validation + UI copy that
   surfaces refusals as first-class results.

**Queue discipline:** items land in the approved dependency order
([Analysis and Statistics Today](Users--Analysis-and-Statistics-Today)
"coming" list). Jumping the queue requires lifting a deferral in writing (as
happened for TSS/CSS/RSS offsets on 2026-09-25 — see the header of
`method-conditions/scaling-and-offsets.md` for how to do it honestly).

## Adding a composition filter or category set

Edit `config/composition.yml`'s `filters:` library (or add a filter file with
the same shape: `databases:`, `mappings:`, `filters:`, `remove_empty:`) and
reference it from a category set or `merge_taxa.filters`. Filters are
database-scoped (`databases: [pr2]` etc.) and both editable from the
Compositions UI and validatable as YAML. Remember the consensus constraint:
patterns are matched against labels from a specific reference release.

## Adding UI surface

React lane (default): views in `frontend/src/views/`, wire types first
([Type System](Developers--Type-System)). Charts consume server-built Plotly
JSON — build specs server-side (`analysis/` chart builders) unless the
interaction is purely cosmetic (then the chart-editor seam).

Stipple lane (`ui/`, migration): small JS adapters allowed; **no new
application TypeScript**; parity risks (chart editor, custom table,
Euler/UpSet) are named in `docs/migration/STATUS.md` — do not start them
without reading that.

## Adding an API endpoint

Follow the grouped layout in `src/server/routes/`; JSON in/out; SSE only for
event streams; update the endpoint→SOURCE map in `frontend/src/types/api/`
in the same change. [REST API](Developers--REST-API).
