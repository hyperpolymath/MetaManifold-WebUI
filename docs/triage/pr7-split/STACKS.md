<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Parent PR #7 — the 319-file change as 14 reviewable stacks

Parent PR [JoshuaJewell/MetaManifold-WebUI#7][p7] ("Stipple/Vue migration
with isolated typed studies UI") is one squashed commit plus two tiny
CodeQL-permission fixes: **319 files, +22,662 / −404** against upstream
`main`. It merges cleanly, but nobody can review 319 files at once.

This kit partitions the exact same change into **14 disjoint stacks** whose
union is byte-identical to the branch (verified: applying 01→14 in order
onto upstream `main` reproduces the branch tree exactly — see
`make-stacks.sh`, which regenerates and re-verifies everything).

- Base: upstream `main` @ `ecefb1c` ("Real real CI fix.", 2026-07-21)
- Head: `feat/stipple-typed-studies-ui` @ `eab8ea0`
- Stack definitions: `stacks/*.paths` (one git pathspec per line)
- Generated patches: `patches/*.patch` (git-ignored; regenerate locally)

Reading guide: each stack below lists a suggested PR title, its size, and
the files that actually matter. A recurring pattern: **1-line files are
almost always the added `SPDX-License-Identifier` header** — skim those,
read the big files.

| # | Stack | Files | +/− | Suggested PR title |
|---|-------|------:|-----|--------------------|
| 01 | repo-roots | 27 | +2,822/−43 | chore(repo): licences, manifests, installers and repo roots |
| 02 | ci-governance | 12 | +880/−18 | ci: overhaul workflows, templates, hooks and release policy |
| 03 | backend-core | 37 | +773/−7 | feat(core): epistemic core, lint tooling, SPDX headers |
| 04 | pipeline | 15 | +17/−2 | chore(pipeline): SPDX headers and merge_taxa touch-up |
| 05 | analysis-engine | 8 | +4,357/−0 | feat(analysis): AnalysisConfig v1 engine and execution |
| 06 | analysis-config | 19 | +1,675/−0 | feat(analysis): diversity/clade modules, contracts, routes |
| 07 | server | 18 | +145/−14 | feat(server): studies/runs/jobs routes and integration tests |
| 08 | stipple-ui | 11 | +460/−0 | feat(ui): first Stipple/Vue slice (MetaManifoldUI.jl) |
| 09 | frontend-shell | 41 | +884/−72 | feat(frontend): typed app shell, API client; drop legacy web/ |
| 10 | frontend-views | 11 | +92/−47 | feat(frontend): RunView rework and view headers |
| 11 | frontend-components | 33 | +1,289/−197 | feat(frontend): analysis components (config editor, tables) |
| 12 | frontend-tests | 23 | +1,947/−0 | test(frontend): unit/integration suites, benches, gates |
| 13 | docs | 40 | +5,653/−0 | docs: milestones, migration log, deferred-issue specs |
| 14 | bench-scripts | 24 | +1,668/−4 | chore(bench): Julia benchmarks and repo scripts |

## 01 — repo-roots (27 files, +2,822/−43)

Everything at the repository root plus the licence texts: the three
licence files (AGPL 661 + CC-BY-SA 428 + MPL 373 lines), `Justfile` (391),
editor/git/Guix/Mise/Direnv configs, install scripts, `Project.toml`,
`README`/`CHANGELOG`/`CONTRIBUTING`/`SECURITY`/`CODE_OF_CONDUCT`, and the
`codecov.yml` deletion.

Review notes: `Manifest.toml` renders as a binary patch (estate
`.gitattributes` marks manifests binary) — verify it with
`julia --project=. -e 'using Pkg; Pkg.instantiate()'` rather than by
reading the diff. The rest is new-file prose/config; the signal is
`install.jl`/`install.sh`/`Justfile`.

## 02 — ci-governance (12 files, +880/−18)

`.github/` (both workflows, issue templates, PR template, CODEOWNERS,
dependabot), `.githooks/`, `packaging/`. The one file to read carefully is
`.github/workflows/ci.yml` (+488/−18); `ui.yml` (+31) and the templates are
small; the rest is short new files.

## 03 — backend-core (37 files, +773/−7)

Julia core (`src/core/`, `src/annotation/`, `src/MetaManifold.jl`), the R
dependency files (`R/`, `renv/`), `config/ci/`, and the 15 core test
files. Two files carry the change: `src/core/epistemic.jl` (+352, new)
and `config/ci/lint_source.jl` (+364, new), plus a 27-line touch to
`download_databases.jl`. Nearly every other file is a 1-line SPDX header.

## 04 — pipeline (15 files, +17/−2)

`src/pipeline/`, the MiSeq pipeline fixture, and 5 pipeline tests. Almost
entirely 1-line SPDX headers; the only logic is a 5-line touch to
`src/pipeline/merge_taxa.jl`. Fastest stack to review.

## 05 — analysis-engine (8 files, +4,357/−0)

The core backend change, all new code: `AnalysisConfig.jl` (+1,615),
`Execution.jl` (+1,497), and their three test files (+479/+397/+354).
`analysis.jl` and `analysis_config.jl` gain one line each. Read this stack
as a unit: engine + execution + tests.

## 06 — analysis-config (19 files, +1,675/−0)

Diversity/clade modules (`clade_cumulus.jl` +510, `diversity.jl`), the
config contracts (Nickel +313, JSON Schema +297, DEED +84, defaults),
the two analysis HTTP routes (`analysis_config.jl` +453), and 4 small
tests. This is "configuration as contracts": read the Nickel/Schema/DEED
trio together with the route that serves them.

## 07 — server (18 files, +145/−14)

The remaining `src/server/` routes, `test/unit/test_routes.jl`,
`test/unit/test_jobs.jl`, both integration tests, and `test/runtests.jl`.
Bulk of the lines is `test/integration/test_server.jl` (+105); every route
file changes by ≤9 lines. A small, safe stack.

## 08 — stipple-ui (11 files, +460/−0)

The headline migration piece, isolated as promised: `ui/` —
`MetaManifoldUI.jl` (+125), `Contracts.jl`, `BackendClient.jl`, `serve.jl`,
project files, styles, README, and three tests. `ui/Manifest.toml` is a
binary-rendered manifest (verify by instantiate, not by reading).

## 09 — frontend-shell (41 files, +884/−72)

Typed foundation of the new frontend: configs (`package.json`,
`vite.config.ts`, tsconfigs, playwright), app shell (`App.tsx`,
`main.tsx`, layout, styles), `api/`, `types/` (12 files, incl. the
`analysis_config.ts` contract at +268), `hooks/`, `utils/` — and the
deletion of the 7 legacy `web/dist/` build artefacts plus one stale
`.d.ts`. `frontend/bun.lock` is a binary-rendered lockfile (verify with
`bun install --frozen-lockfile`, not by reading).

## 10 — frontend-views (11 files, +92/−47)

`RunView.tsx` (+76/−41) is the only substantial change; the other ten
views gain a line or two each (headers). Quick stack.

## 11 — frontend-components (33 files, +1,289/−197)

The component catalogue. Three large new components
(`AnalysisConfigEditor` +342, `AdvancedAnalysisExpander` +251,
`CladeCumulus` +218), two reworks (`DataTable` +96/−79, `PipelineStages`
+86/−58) worth reading line-by-line, plus `DangerBanner` (+90) and
`EvidenceModeToggle` (+81). The long tail is 1–14 line touches.

## 12 — frontend-tests (23 files, +1,947/−0)

All new: 20 frontend test files (unit + integration + e2e + fixtures)
and the 3-file `frontend/bench/` harness. Review alongside stacks 09–11;
nothing here changes shipped code.

## 13 — docs (40 files, +5,653/−0)

Prose only, all additive: milestone records (`docs/milestones/`, incl.
the deferred-issues spec that backs fork issues #3–#8), the
`docs/issues/milestone3/` per-issue specs, the `docs/migration/` log,
compliance/testing/type-system notes, and the v0.1.0 release notes.
Largest line count, lightest review weight — read the migration log and
the deferred-issues spec first.

## 14 — bench-scripts (24 files, +1,668/−4)

Eight Julia benchmark suites (`bench/`, incl. `comprehensive_benchmark.jl`)
and seven repo scripts (format/lint/SPDX gates, history-hygiene tooling,
`migrate_composition.jl`). Self-contained; the scripts mirror the CI gates
from stack 02.

[p7]: https://github.com/JoshuaJewell/MetaManifold-WebUI/pull/7
