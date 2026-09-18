<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->

# Milestone 0 — Full Reconnaissance (2026-09-18 Europe/London)

## Repository State

- **Origin**: `https://github.com/hyperpolymath/MetaManifold-WebUI.git`
- **Fork of**: `JoshuaJewell/MetaManifold-WebUI`
- **Current branch**: `main` @ `10915ef chore: add SPDX headers to post-rebase ui/migration files`
- **Remote branches**: only `main` (no feature branches yet)
- **Workspace**: empty except cloned `hyperpolymath-MetaManifold` under `/home/user`

### Codebase Layout (verified)

```
src/
  MetaManifold.jl (module entry, includes core/*, annotation/*, pipeline/*, analysis/*)
  core/
    types.jl, r_runtime.jl, provenance.jl, log.jl, config.jl, databases.jl,
    duckdb_store.jl, validate.jl, project.jl, categories.jl,
    composition_library.jl, primers_library.jl, databases_library.jl
  analysis/
    analysis.jl (42k lines, Plotly chart builders, alpha, bar, Venn, NMDS, PERMANOVA)
    diversity.jl (richness, shannon, simpson, normalise_counts)
  annotation/
    funcdb.jl
  pipeline/
    tools.jl, merge_taxa.jl, dada2/*, swarm.jl
  server/
    server.jl, jobs.jl, routes/* (analysis, annotations, composition, config, databases, duckdb_helpers, events, jobs, pipeline, results, runs, studies)

frontend/src/
  App.tsx, main.tsx
  api/client.ts (typed REST client)
  components/ (AnalysisControls, AnnotationPanel, CompositionPanel, DataTable, PipelineStages, etc.)
  views/ (RunView 40k, StudyView, GroupView, etc.)
  types/domain, state

config/defaults/
  pipeline.yml, tool_versions.yml (pinned tool archives + sha256), primers.yml, databases.yml, composition.yml, filters/, etc.

test/
  unit/* (test_analysis, test_categories, test_provenance, test_routes 45k, etc.)
  integration/
  fixtures/
bench/layer1_mock_recovery/
```

### Epistemic Layer Claim vs Reality

**Task states**: "The epistemic layer (Echo + Epistemic + Residual Evidence with `avec_fibre` column and `Epistemic.jl`) is already implemented."

**Actual grep** (`grep -R "Epistemic|avec_fibre|present_in_every_admissible_world|Echo" --include="*.jl" --include="*.tsx"`):
- **Zero hits** in Julia or TS sources.
- No `Epistemic.jl` file exists.
- No `avec_fibre` column handling in DuckDB schema.
- No `Evidence Mode` toggle in frontend.

**Conclusion**: Either the epistemic layer lives on a non-pushed branch, or the task description is aspirational. To avoid overwriting colleagues' work, we will:

1. Create new modules without touching `categories.jl`, `composition_library.jl`, or `analysis.jl` internals until the epistemic branch is located.
2. Design `AnalysisConfig` and `CladeCumulus` to be **additive**, importing epistemic types if they appear, but not requiring them at compile time (feature-flagged).
3. Log this gap as a risk in the Project board.

### Analysis Layer — Current State

- **Alpha diversity**: richness, Shannon, Simpson via `DiversityMetrics`
- **Charts**: bar (rank / category), alpha boxplot, NMDS (R/vegan), PERMANOVA (R/vegan), Venn/Euler/UpSet
- **Normalization**: none / rarefaction / relative sum scaling, auto depth via `auto_min_depth`
- **Filtering**: via `Categories.filter_to_sql_conditions` (pattern/regex, min/max/include, remove_empty) with SQL injection hardening
- **No parametric modelling**: No NB GLM, no CLR/ILR+Gaussian LM, no logistic regression, no BH correction enforcement, no AnalysisConfig object.

### Provenance Layer — Relevant for DOI bundles

- `core/provenance.jl` (36k) already implements:
  - `ToolRecord`, `JuliaRecord`, `RRecord`, `DatabaseRecord` with SHA256 hashing
  - `probe_tool`, `probe_julia`, `probe_r`, `probe_database` with strict release agreement checks
  - `probe_host`, `probe_metamanifold` with dirty-tree detection
  - Attestation writing (ordered dict, evidence-rich)
- This can be reused for DOI-ready bundles: we need to add `AnalysisConfig` + `AnalysisResult` attestation and bundle export.

### Frontend Cleanliness

- `RunView.tsx` (40k) is the heavy orchestrator: config accordion, pipeline stages, QC, results explorer, annotation, composition.
- `AnalysisControls.tsx` is minimal (1.2k) — placeholder for future controls.
- No `Evidence Mode` toggle yet. Requirement: advanced options and cladistic visuals only appear when Evidence Mode enabled.

### Standards — JSON + Nickel + DEED

- **Standards repo cloned** to `/tmp/standards` (depth 1)
- **DEED spec**: `1-formats/deed/spec/DEED-GRAMMAR-SPEC.adoc` v0.2.0 DRAFT, normative ABNF at `abnf/deed.anbf`
- **Key DEED rules**:
  - Single extension `.deed`, dispatch by stem (`estate_chora.deed` exact, `*_chora.deed`, `ATLAS.deed`, `*_praxis.deed`)
  - Header `;; SPDX-*` required, `:schema-version` structurally first
  - No `key = value`, no `[section]`, only `(` `)`, booleans `#t/#f`, keywords `:kebab-case`
  - Identity maps to `BaseRecord` (Idris2 typed core) — anti-desync primitive
  - `lax`/`strict`/`attested` modes, `strict` default for `.deed`
- **JSON schemas**: `1-formats/a2ml/*/spec/schema/*.schema.json` (draft 2020-12), used for STATE, META, etc.
- **Nickel schemas**: `1-formats/k9/*.ncl`, `.machine_readable/contractiles/**/*.ncl` (runner base contracts, trust/must/intend etc.)
- **Implication for AnalysisConfig**:
  - JSON schema: draft 2020-12, with `$id`, `$defs`, required fields, `anyOf` for method union
  - Nickel: contract with ` | { field | Type, ... }`, plus validators for BH mandatory, dangerous overrides
  - DEED: `(repo-deed :schema-version "1.0.0" :canonical-name "analysis-config" ... (method ...) (correction ...) (provenance ...))` — must follow filename dispatch `analysis_config_chora.deed` or similar.

### CI & Quality Gates

- `ci.yml`: repo-hygiene (SPDX, format, lint, commit convention) + Julia test matrix (1.12.5 pinned) + R apt pin + bun 1.3.10 + bench checksum
- `codecov.yml` exists, token needed for upload
- `bench/baseline.json` referenced but not yet present? Need to check `bench/`
- `Justfile` is task runner, 15k lines, recipes: `bootstrap`, `ci`, `drift`, `sync-pins`, `setup-full`, `start`
- Tests: 577 pass / 5 todo per ROADMAP, coverage reported but not gated.

### Missing Secrets / Blockers

- **GitHub PAT**: required with `repo` + `workflow` + `project` scopes to:
  - Create & maintain Project board "Analysis Layer & Cladistics Development" via GraphQL
  - Link issues/PRs to board, update status, remove completed
  - Push feature branches, open PRs
- **CODECOV_TOKEN**: for coverage upload (from `codecov.yml`)
- **Cache keys**: Julia depot, bun, R renv — CI uses `julia-actions/cache@v2`, but local cache invalidation keys unknown
- **No existing GitHub Project**: verified via `gh` CLI not available, and no `project` data in repo. Must be created via GraphQL `createProjectV2`.

### Risk Register (for issue bodies)

1. **Epistemic layer absent** — if it lands on main while we work, merge conflicts. Mitigation: additive modules, feature-flagged imports.
2. **Exact stats layer deferred** — must not implement symbolic engine / exact tests here; keep AnalysisConfig v1 limited to NB GLM, CLR/ILR+LM, logistic.
3. **UI cleanliness** — Advanced Analysis expander must be hidden behind Evidence Mode; otherwise violates rule.
4. **Benchmark regression gate** — need baseline memory/runtime measurement for new analysis methods (R-backed NB GLM may be heavy).
5. **DOI bundles** — need `DataCite` metadata, license, authorship from `CITATION.cff`.

### Next Steps (Pending Tokens)

1. **Create feature branch** `feat/analysis-config-v1` (never force-push main)
2. **Implement AnalysisConfig layer**:
   - Julia: `src/analysis/analysis_config.jl` — immutable struct, versioned, provenance-rich, with JSON/Nickel/DEED serialization, BH mandatory, DANGER banner logic, validation refusing meaningless inputs
   - Tests: `test/unit/test_analysis_config.jl` + benchmarks `bench/analysis_config/`
   - Frontend: `EvidenceModeToggle`, `AdvancedAnalysisExpander`, `AnalysisConfigEditor`, DANGER banner component, context-sensitive help
   - Schemas: `config/schemas/analysis_config.schema.json`, `config/schemas/analysis_config.ncl`, `analysis_config_chora.deed` template
   - DOI bundle: `src/core/doi_bundle.jl` or extension to provenance
3. **Implement CladeCumulus**:
   - Backend: cumulative frequencies over cladistic tree, epistemic colour coding (needs epistemic types or fallback), cloud sizing by residual count, `present_in_every_admissible_world` validation
   - Frontend: `CladeCumulus.tsx` — tree with D3/Plotly, drag-and-drop, live validation, Evidence Mode toggle
4. **Project board via GraphQL**: create board, columns (Backlog, In Progress, Review, Done), link issues/PRs, auto-update on PR events
5. **Generate deferred feature issue bodies**: exact stats, symbolic engine, etc.

### Ready-to-Paste GraphQL Mutations (Prepared)

Will be executed once PAT provided — see `docs/milestones/01-project-board-graphql.md` for full mutation set.

## Compliance

- No code changes made in this milestone (recon only)
- No overwrite of colleagues' work
- Branching strategy respected
- UI cleanliness rule noted for future work
