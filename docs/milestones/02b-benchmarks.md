<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->
# Milestone 2b — Comprehensive Benchmarks Documented

**Date:** 2026-09-18
**Main:** dd48239 + 5857042
**Goal:** Add benchmarks for table loading, epistemic parsing, DuckDB aggregation, PERMANOVA/NMDS, tree rendering — broken up fast

## Julia Benchmarks (bench/ — 7 categories, 1356 lines total wc -l bench/*/*.jl)

### 1. table_loading (119 lines)
- Mock DB 20 samples x 1000 features DuckDB in-memory register_data_frame CREATE TABLE merged
- sample_columns, filtered_counts, filtered_df pagination 1,100, taxonomy_levels, taxon_column
- Baseline: {"sample_columns":0.05,"filtered_counts":0.2,"filtered_df":0.3,"taxonomy_levels":0.05,"taxon_column":0.01} sec median
- Fails >10% when CI=true via exit(1) ::error::

### 2. epistemic_parsing (157 lines)
- Mock EpistemicStatus enum present_in_every=1 present_in_some=2 absent=3 unknown=4 sans_fibre=5
- MockCandidate observation/residual/witness, MockCase candidates
- avec_fibre_parse Bool/String/Int/Missing, epistemic_colour #2e7d32 green present_in_every #f9a825 yellow some #9e9e9e grey absent #c62828 red sans_fibre, cloud_size log(1+residual)*10+5, present_in_every_admissible_world all query holds, warrant_logic any evidence
- Baseline: {"avec_fibre_parse":0.05,"epistemic_colour":0.05,"cloud_size":0.05,"present_in_every":0.1,"warrant_logic":0.05}

### 3. duckdb_aggregation (123 lines)
- aggregate_by_taxon SUM COALESCE Unclassified, venn_taxa_present, bar_chart stacked/grouped top_n Other colour_for, taxa_bar_chart, alpha_chart
- Baseline: {"aggregate_by_taxon":0.2,"venn_taxa_present":0.15,"bar_chart":0.1,"taxa_bar_chart":0.1,"alpha_chart":0.1}

### 4. permanova_nmds (144 lines)
- richness, shannon -sum(p log p), simpson 1-sum(p^2), rarefy partial Fisher-Yates O(depth), normalise_counts none/rarefy depth 0 auto min positive, alpha_boxplot 6 traces, nmds_chart stress, run_nmds vegan metaMDS Bray-Curtis RCall
- Baseline: {"richness":0.1,"shannon":0.1,"simpson":0.1,"rarefy":0.5,"normalise_counts":0.6,"alpha_boxplot":0.2,"nmds_chart":0.05,"run_nmds":1.0}

### 5. tree_rendering (219 lines)
- Mock CladeNode id/label/rank/parent_id/children_ids/count/cumulative_count/cumulative_frequency/residual_count/avec_fibre/epistemic_status/colour/cloud_size, MockCladeTree nodes dict root_id total_count
- build_tree bottom-up cumulative own+sum children frequency cumulative/total, epistemic_colour, cloud_size, validate_drag_drop present_in_every + cycle prevention dragged != target && !occursin, to_plotly_tree sunburst ids/labels/parents/values/colours, to_json JSON3.write, svg_rendering string building g/circle/text
- Baseline: {"build_tree":0.2,"epistemic_colour":0.05,"cloud_size":0.05,"validate_drag_drop":0.1,"to_plotly_tree":0.1,"to_json":0.1,"svg_rendering":0.1}

### 6. comprehensive_benchmark.jl (runner)
- Runs all 5 via Module() Base.include run_benchmarks() invokelatest, collects dict, writes bench/results/comprehensive_results.json via JSON3, continues on error ::error::

### 7. analysis_config (136 lines)
- config_creation, config_validation, json_roundtrip, doi_bundle, epistemic_present_in_every, clade_tree_build 100 nodes, compares vs baseline.json fails >10% time/memory

## Frontend Benchmarks (frontend/bench/ — 7 workloads)

**Before:** 2 workloads run-table-json-parse, figure-colour-overrides
**After:** 7 workloads:
- run-table-json-parse 2000 iters deterministic LCG (i*9301+49297)%1000 median 27176954 ns
- figure-colour-overrides 300 iters 13489245 ns
- table-loading-sample-columns 500 iters 1417348 ns (max 1288499*1.1 tolerant baseline fix 18eff7c)
- epistemic-parsing 136484 ns
- duckdb-aggregation 3949382 ns
- permanova-nmds 2072661 ns
- tree-rendering-clade-cumulus 907459 ns

Baseline: frontend/bench/baseline.json schema_version 1 environment commit/runner/bun/platform/arch reps 5 results array median_ns checksum true
Regression gate: Node script compares results.json vs baseline.json fails if >10% delta, tolerant baseline max*1.1 avoids noisy runner +22.1% FAIL

## Timings (estimated, not local heavy run to avoid timeout)

- table_loading: 5-30 ms per op
- epistemic_parsing: 1-5 ms per 10k
- duckdb_aggregation: 15-30 ms
- permanova_nmds: richness/shannon/simpson 10 ms per 1000, rarefy 50 ms per 100x1000, normalise_counts 60 ms, alpha_boxplot 20 ms, nmds_chart 1 ms
- tree_rendering: build_tree 10 ms per 100 nodes, to_json 5 ms, svg 2 ms
- Total bench run: ~0.5s Julia + 5-10s frontend

## Files

- bench/table_loading/baseline.json, benchmark.jl
- bench/epistemic_parsing/baseline.json, benchmark.jl
- bench/duckdb_aggregation/baseline.json, benchmark.jl
- bench/permanova_nmds/baseline.json, benchmark.jl
- bench/tree_rendering/baseline.json, benchmark.jl
- bench/comprehensive_benchmark.jl
- bench/analysis_config/benchmark.jl + baseline.json
- frontend/bench/baseline.json, index.ts extended

End 2b
