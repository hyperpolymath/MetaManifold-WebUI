# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""
Benchmark for table loading pathways

Measures:
- DuckDB in-memory DB creation and table loading
- sample_columns identification
- filtered_counts matrix extraction
- filtered_df DataFrame extraction
- taxonomy_levels and taxon_column resolution
"""

using DuckDB, DataFrames, DBInterface
using MetaManifold.Analysis: sample_columns, filtered_counts, filtered_df, taxonomy_levels, taxon_column
using Random
using JSON3
using Statistics

function _create_mock_db(n_samples::Int=20, n_features::Int=1000)
    db = DuckDB.DB()
    con = DBInterface.connect(db)
    # Create mock merged table similar to real results.duckdb
    # Columns: SeqName, Domain, Phylum, Genus, plus per-sample counts
    sample_cols = ["Sample$(i)" for i in 1:n_samples]
    # Build DataFrame
    df = DataFrame()
    df.SeqName = ["ASV$(i)" for i in 1:n_features]
    df.Domain = rand(["Bacteria", "Archaea", "Eukaryota"], n_features)
    df.Phylum = rand(["Firmicutes", "Bacteroidetes", "Proteobacteria"], n_features)
    df.Genus = rand(["Bacteroides", "Prevotella", "Faecalibacterium"], n_features)
    df.Pident = rand(80.0:0.1:100.0, n_features)
    for (j, sc) in enumerate(sample_cols)
        df[!, sc] = rand(0:1000, n_features)
    end
    DuckDB.register_data_frame(con, df, "merged_df")
    DBInterface.execute(con, "CREATE TABLE merged AS SELECT * FROM merged_df")
    return con, sample_cols
end

function bench_sample_columns(con, table::String="merged")
    @elapsed sample_columns(con, table)
end

function bench_filtered_counts(con, sample_cols, table::String="merged")
    @elapsed filtered_counts(con, table, sample_cols, "", [])
end

function bench_filtered_df(con, sample_cols, table::String="merged")
    @elapsed filtered_df(con, table, sample_cols, "", [], 1, 100)
end

function bench_taxonomy_levels(con, table::String="merged")
    @elapsed taxonomy_levels(con, table)
end

function bench_taxon_column()
    cols = ["Domain", "Phylum", "Class", "Order", "Family", "Genus", "Species", "Sample1", "SeqName"]
    @elapsed taxon_column(cols, "Genus")
end

function run_benchmarks(; n_samples=20, n_features=1000, reps=5)
    println("=== Table Loading Benchmark ===")
    println("Creating mock DB with $n_samples samples x $n_features features")
    con, sample_cols = _create_mock_db(n_samples, n_features)

    results = Dict{String, Vector{Float64}}()
    for name in ["sample_columns", "filtered_counts", "filtered_df", "taxonomy_levels", "taxon_column"]
        results[name] = Float64[]
    end

    for _ in 1:reps
        push!(results["sample_columns"], bench_sample_columns(con))
        push!(results["filtered_counts"], bench_filtered_counts(con, sample_cols))
        push!(results["filtered_df"], bench_filtered_df(con, sample_cols))
        push!(results["taxonomy_levels"], bench_taxonomy_levels(con))
        push!(results["taxon_column"], bench_taxon_column())
    end

    for (name, times) in results
        med = median(times)
        println("$name: median $(round(med*1000, digits=2)) ms over $reps reps (samples: $(round.(times.*1000, digits=2)))")
    end

    # Baseline comparison
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
        println("\nNo baseline.json found — saving current as baseline")
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
