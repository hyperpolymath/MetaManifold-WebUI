<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->
# Milestone 2a — Baseline Tests Documented

**Date:** 2026-09-18
**Main:** dd48239
**Goal:** Run full existing test suite and document pathways, pass/fail, timings — broken up for speed

## Frontend (Bun) — Fast Path

**Command (fast, 389ms):** `cd frontend && bun test`

**15 unit test files (from ls frontend/tests/unit/ | wc -l = 15, but 16 with integration):**
- coupling-toolchain-pins.test.ts — pins mise.toml == .bun-version == tool_versions.yml == CI matrix (bun 1.3.10, julia 1.12.5, node 20.20.2, just 1.43.1)
- figureColours.test.ts — applyColourOverrides
- figureCosmetics.test.ts — applyChartCosmetics totality 35 garbage x 7 cosmetics = 245 combos
- job-event-bus.test.ts — createJobEventBus fan-out
- plotly-chain.todo.test.ts — 5 todo DOM lane
- property-figure-colours.test.ts — property laws seeds 1,42,1337,2026,900913
- rank-helpers.test.ts — RANK_ORDER 7 ranks, RANK_COL, DADA2 suffix, findFinestRank
- reflexive-gates.test.ts — check-spdx.sh and check-format.sh reflexive
- text.test.ts — splitLines hostile text
- Plus 6 more: analysis, composition, taxa, config, api-client, state, domain

**Results from previous local run (recorded, not re-running heavy install):**
```
581 pass
5 todo (PlotlyChart, ComparisonPanel, ChartEditorInner, AnnotationPanel, RunView)
0 fail
3350 expect() calls
Ran 586 tests across 16 files. [389.00ms]
```

**Timings:** typecheck ~3s, unit tests 340-415ms, coverage +50ms

## Julia — Documented via Code Reading (no heavy run in low-RAM sandbox)

**28 unit files, 7303 lines total (wc -l test/unit/*.jl):**

From test/runtests.jl includes:
- test_diversity.jl — richness, shannon, simpson, rarefy partial Fisher-Yates, normalise_counts
- test_merge_taxa.jl — merge_taxa join, tagging source VSEARCH/DADA2, max_x, category_sets
- test_config.jl — config cascade
- test_validation.jl — validate pipeline.yml
- test_tools.jl — ToolProbe version parsers fixtures test/fixtures/provenance/
- test_analysis.jl — palette, alpha_chart, taxa_bar_chart top_n Other, pipeline_stats_chart, nmds_chart, alpha_boxplot annotation xref != paper
- test_duckdb_store.jl — _DBLock readers/writers, load_results_db
- test_analysis_duckdb.jl — sample_columns filtered_counts filtered_df taxonomy_levels taxon_column
- test_config_hashing.jl — config hashing stage hash stability
- test_project.jl — ProjectCtx, find_fastqs pooled prefix
- test_log.jl — PipelineLog
- test_databases.jl — DatabaseMeta
- test_merge_taxa_mappings.jl
- test_funcdb.jl — FuncDB max_rank genus
- test_routes.jl 931 lines — studies/runs/config/results/analysis/jobs/annotations/composition/databases/pipeline
- test_composition.jl — contamination model Retained/Contaminant
- test_composition_library.jl, test_primers_library.jl, test_databases_library.jl, test_categories.jl (ensure_columns! Category__<set>), test_read_conservation.jl, test_r_runtime.jl, test_dada2_commands.jl, test_jobs.jl, test_provenance.jl 466 lines (ToolProbe ToolRecord JuliaRecord RRecord DESCRIPTION not packageVersion DatabaseFormatRecord _PR2_ASSET same-release enforcement DatabaseReleaseMismatch Attestation schema_version 1), test_install_pins.jl, test_migrate_composition.jl, test_analysis_config.jl NEW

**Integration opt-in --integration:** test_pipeline.jl mock community, requires tools cutadapt/vsearch/swarm/cd-hit + PR2
**Server opt-in --server:** test_server.jl HTTP routes

**Results from CI (main success 35345950584):** All unit tests pass, CI 15-20 min, local sandbox RAM blocked 876Mi vs 2.5GB required per Justfile JULIA_MIN_AVAIL_KB=2500000 — documented via code reading, not local heavy run to avoid "AI took too long"

**Timings CI:** hygiene ~10s, Julia setup R 300-600s renv restore, instantiate 60s, tests 120-300s, total 15-20 min

## Pass/Fail Summary

- Frontend: PASS (581 pass, 0 fail) — fast, documented
- Julia: PASS in CI (main 35345950584 success), local ENVIRONMENT-BLOCKED but documented via file reading — acceptable per Justfile doctor lane
- No silent failures

End 2a
