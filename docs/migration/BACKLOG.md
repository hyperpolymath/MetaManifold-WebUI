# Stipple/Vue implementation backlog

Baseline and architecture: [recon report](README.md). Implementation has started in `ui/`; see [current evidence and limits](IMPLEMENTATION.md). Unchecked tasks remain pending. Suggested work packages, not remote issues or commitments to dates.

## Phase 0 — Recon (complete)
- [x] Inspect architecture, dependencies, routes and representative interactions.
- [x] Inventory frontend source and literal backend endpoints.
- [x] Identify dependency, custom-table, chart-editor and set-rendering risks.
- [x] Document preservation rules, rollout and testing gaps.

## M1 — Isolated framework and read-only studies pilot
**Dependency:** Julia runtime provisioned; working existing backend against disposable data.

- [x] Create ui/ as a separate Julia environment, not a root dependency update.
- [x] Resolve released Genie/Stipple/StippleUI versions; write UI manifest and document Julia version (included in the migration changeset).
- [ ] Prove page rendering, local assets and reactive transport work through the intended host/proxy.
- [x] Keep UI launcher opt-in. Do not change start.sh default.
- [x] Introduce typed StudySummary/Study transport representations and validate against current endpoint shapes. Run details are deferred.
- [x] Implement a configurable fixed-backend client with timeouts and user-visible error mapping. No arbitrary browser-controlled backend URLs.
- [x] Read-only /studies and /studies/:study with loading/empty/error states, counts and navigation. Legacy /:study compatibility remains deferred.
- [ ] Unit-test decoding and errors against fixtures; browser-test independent sessions, direct links and backend outages.

**Acceptance:** root Project/Manifest unchanged; legacy UI still works; new UI runs without loading scientific modules; no mutations or fake success responses; no application-authored TypeScript; documented reproducible launch command. No implicit upgrade to HTTP 2 in the backend.

## M2 — Study/group/run operations
- [ ] Port name validation and modal flow without duplicating backend authority.
- [ ] Create/rename/delete with explicit confirmations, failure recovery, stale-request suppression and submit guards.
- [ ] Preserve group context, pooled runs and slug resolution.
- [ ] Add browser regression checks with disposable study roots.

**Acceptance:** no differences in file layout or API semantics; rename navigates consistently; errors do not erase edit drafts; repeated clicks do not duplicate actions.

## M3 — Jobs and first full workflow
- [ ] Job list/status, submission, cancellation and pipeline stages.
- [ ] Begin with documented polling or implement managed SSE consumption; preserve legacy SSE.
- [ ] Snapshot refresh on reconnect; task/timer cleanup on session exit; bounded update fan-out.
- [ ] Show R-busy/503 distinctly; no scientific computation inside UI callbacks.
- [ ] Read-only paginated results table sufficient to prove studies -> run -> submit -> progress -> results.

**Acceptance:** background execution survives page navigation; cancellation semantics retained; no automatic resubmission on reconnect; tab state isolated; abandoned subscriptions cleaned up.

## M4 — Configuration and libraries
- [ ] Defaults/study/run/group override editing and deletion semantics.
- [ ] Primer/database document editors and download jobs.
- [ ] Composition sets, filter presets and category definitions.
- [ ] Round-trip and inheritance tests for false, zero, empty, null and unknown/invalid values.

**Acceptance:** saved formats remain compatible with old UI and pipeline; rejected saves preserve drafts and provide actionable errors.

## M5 — Full results/annotation interface
- [ ] DataTable parity checklist: pagination, sorting, keyword and per-column filters, distinct values, numeric ranges, visibility/presets, persistence, highlighting, popups/copy and OTU expansion.
- [ ] XLSX/CSV export and filtered saves, downloads/reports/logs.
- [ ] Annotation editing and contamination statistics with correct source/table/group context.
- [ ] Decide how sessionStorage behaviour maps to server session state. Refresh/tab behaviour must be tested, not silently changed.

**Acceptance:** query/export equivalence on fixtures; large datasets remain server-paginated; browser memory does not grow with the entire dataset.

## M6 — Scientific charts and specialised components
- [ ] StipplePlotly spike against real stored/generated figures (no scientific recomputation changes).
- [ ] Preserve plot defaults, pixel-size controls, resizing, export, cleanup and cosmetics.
- [ ] Inventory actual React editor options and implement a Julia-authored settings panel; explicitly approve any reduced feature scope before cutover.
- [ ] Spike Euler/UpSet renderer; test actual layout and interactions. Do not equate a static figure with full parity.
- [ ] If browser adapters are unavoidable, isolate and document them, including dependency licenses/build/asset requirements.

**Acceptance:** analyses agree numerically; cosmetics never mutate scientific data; retained React islands are marked incomplete migration, not presented as React-free.

## M7 — Deployment, cutover and removal
- [ ] Browser regression suite covering critical workflows and errors.
- [ ] Verify local-only default, remote origin/authentication policy, WebSocket proxying and file routing.
- [ ] Verify reconnect/session lifecycle and asset availability with CDN access disabled.
- [ ] Confirm API stability and existing Julia suite including --server and appropriate pipeline integrations.
- [ ] Make Stipple default only after acceptance; document rollback and shared-data implications.
- [ ] Remove frontend/ and bundled React output only when no retained component requires them.
- [ ] Remove application Bun/Vite/TypeScript build references and amend toolchain pins/tests/CI/startup/docs.
- [ ] Consider consolidating services/processes only as a separate, tested follow-up.

## Outstanding decisions (not blocking read-only M1)

1. Is exact chart-editor parity required, or will a smaller explicit settings panel be acceptable?
2. Must Euler/UpSet match current interactive behaviour exactly?
3. Is deployment strictly single-user/local, or is authenticated remote/multiuser use required?
4. Are small reviewed browser adapters acceptable when they avoid feature loss?

Defaults until decided: preserve current behaviour, retain local single-user assumptions, keep legacy components available, do not silently downgrade features or expose a public unauthenticated service.
