# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""
Benchmark for DuckDB aggregation pathways

Measures:
- aggregate_by_taxon (SUM COALESCE, Unclassified fallback)
- combined_counts_across_runs
- venn_taxa_present
- bar_chart and taxa_bar_chart generation
- alpha_chart generation
"""

using DuckDB, DataFrames, DBInterface
using MetaManifold.Analysis: aggregate_by_taxon, venn_taxa_present, alpha_chart, bar_chart, taxa_bar_chart, sample_columns, filtered_counts
using Random
using JSON3
using Statistics

function _create_mock_db(n_samples::Int=20, n_features::Int=1000)
    db = DuckDB.DB()
    con = DBInterface.connect(db)
    sample_cols = ["Sample$(i)" for i in 1:n_samples]
    df = DataFrame()
    df.SeqName = ["ASV$(i)" for i in 1:n_features]
    df.Domain = rand(["Bacteria", "Archaea"], n_features)
    df.Phylum = rand(["Firmicutes", "Bacteroidetes", "Proteobacteria"], n_features)
    df.Genus = rand(["Bacteroides", "Prevotella", "Faecalibacterium", "Escherichia"], n_features)
    df.Species = rand(["B. fragilis", "P. copri", "F. prausnitzii", "E. coli"], n_features)
    for sc in sample_cols
        df[!, sc] = rand(0:1000, n_features)
    end
    DuckDB.register_data_frame(con, df, "merged_df")
    DBInterface.execute(con, "CREATE TABLE merged AS SELECT * FROM merged_df")
    return con, sample_cols
end

function bench_aggregate_by_taxon(con, sample_cols)
    # `aggregate_by_taxon(con, table, sample_cols, rank, where_clause, where_params)`
    # -- six arguments. This previously passed four, omitting the trailing filter
    # pair. `src/analysis/analysis.jl:141` has required all six since the function
    # was introduced, and `test/unit/test_analysis_duckdb.jl` calls it that way.
    # The call was unreachable until the bench steps were wired into CI, so it
    # failed the moment it first ran. An empty filter benchmarks the unfiltered
    # aggregation, which is what the header comment says this measures.
    @elapsed aggregate_by_taxon(con, "merged", sample_cols, "Genus", "", [])
end

function bench_venn_taxa_present(con, sample_cols)
    # Split samples into 2 groups
    g1 = sample_cols[1:div(length(sample_cols),2)]
    g2 = sample_cols[div(length(sample_cols),2)+1:end]
    # `venn_taxa_present(con, table, sample_cols, rank_col, where_clause, where_params)`
    # returns the taxa present in ONE sample set (`src/analysis/analysis.jl:161`).
    # It has never accepted a list of groups: the previous call passed `[g1, g2]`
    # as a fourth argument in a five-argument form that matches no method. A Venn
    # is assembled by calling it once per group, which is what this now measures.
    @elapsed begin
        venn_taxa_present(con, "merged", g1, "Genus", "", [])
        venn_taxa_present(con, "merged", g2, "Genus", "", [])
    end
end

function bench_bar_chart()
    # `bar_chart(segment_labels, sample_names, counts; top_n, ...)` -- the counts
    # matrix is (segments x samples), as `src/analysis/analysis.jl:403` (column
    # totals are per-sample) and `test/unit/test_analysis.jl:35` ("2 taxa x 2
    # samples") both establish. The previous call passed (labels, counts, names),
    # putting the matrix in the `sample_names` position, so no method matched.
    # The 100x3 matrix means 100 segments (taxa) across 3 samples (groups), so the
    # taxon vector is the segment labels and the group vector the sample names.
    segment_labels = ["Taxon$i" for i in 1:100]
    sample_names = ["GroupA", "GroupB", "GroupC"]
    counts = rand(100, 3) * 1000
    @elapsed bar_chart(segment_labels, sample_names, counts, top_n=20)
end

function bench_taxa_bar_chart()
    labels = ["Taxon$i" for i in 1:50]
    counts = rand(50, 10) * 100
    sample_names = ["Sample$i" for i in 1:10]
    # `taxa_bar_chart(taxon_labels, sample_names, counts; ...)` -- arguments 2 and
    # 3 were transposed here. The 50x10 matrix is already (taxa x samples), which
    # is the orientation the function wants; only the call order was wrong.
    @elapsed taxa_bar_chart(labels, sample_names, counts, top_n=20)
end

function bench_alpha_chart()
    sample_names = ["Sample$i" for i in 1:20]
    richness = rand(50:500, 20)
    shannon = rand(1.0:0.1:5.0, 20)
    simpson = rand(0.5:0.01:0.99, 20)
    # `alpha_chart(sample_names, richness, shannon, simpson)` takes exactly four
    # arguments (`src/analysis/analysis.jl:312`); it has no grouping parameter, and
    # the `groups` vector built here was never consumed by any method. Grouped
    # alpha display is `alpha_boxplot`'s job, benchmarked in permanova_nmds.
    @elapsed alpha_chart(sample_names, richness, shannon, simpson)
end

function run_benchmarks(; n_samples=20, n_features=1000, reps=5)
    println("=== DuckDB Aggregation Benchmark ===")
    con, sample_cols = _create_mock_db(n_samples, n_features)

    results = Dict{String, Vector{Float64}}()
    for name in ["aggregate_by_taxon", "venn_taxa_present", "bar_chart", "taxa_bar_chart", "alpha_chart"]
        results[name] = Float64[]
    end

    for _ in 1:reps
        push!(results["aggregate_by_taxon"], bench_aggregate_by_taxon(con, sample_cols))
        push!(results["venn_taxa_present"], bench_venn_taxa_present(con, sample_cols))
        push!(results["bar_chart"], bench_bar_chart())
        push!(results["taxa_bar_chart"], bench_taxa_bar_chart())
        push!(results["alpha_chart"], bench_alpha_chart())
    end

    for (name, times) in results
        med = median(times)
        println("$name: median $(round(med*1000, digits=2)) ms over $reps reps")
    end

    baseline_path = joinpath(@__DIR__, "baseline.json")
    if isfile(baseline_path)
        baseline = JSON3.read(read(baseline_path, String))
        println("\nBaseline comparison (informational):")
        for (name, times) in results
            med = median(times)
            if haskey(baseline, name)
                base_med = baseline[name]
                delta = (med - base_med) / base_med * 100
                status = delta > 10 ? "NOTE" : "ok"
                println("$status $name: $(round(delta, digits=1))% vs baseline $(round(base_med*1000, digits=2)) ms")
                if delta > 10
                    # Informational — absolute ns vs a committed baseline measures the host, not the change (see the benchmark step comment in .github/workflows/ci.yml). Never gates in CI.
                    @warn "Delta >10% vs baseline for $name (informational)" delta
                end
            end
        end
    else
        println("\nNo baseline.json — saving current as baseline")
        baseline = Dict(name => median(times) for (name, times) in results)
        open(baseline_path, "w") do io
            JSON3.write(io, baseline)
        end
    end

    return results
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_benchmarks()
end
