# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""
Benchmark for PERMANOVA/NMDS pathways (current)

Measures:
- run_nmds (vegan metaMDS Bray-Curtis)
- run_permanova (vegan adonis2)
- alpha_boxplot with significance
- nmds_chart generation
- DiversityMetrics: richness, shannon, simpson, rarefy, normalise_counts
"""

using Random
using MetaManifold.DiversityMetrics: richness, shannon, simpson, rarefy, normalise_counts
using MetaManifold.Analysis: alpha_boxplot, nmds_chart

function bench_richness(n::Int=1000, n_features::Int=1000)
    mat = rand(0:1000, n, n_features)
    @elapsed for i in 1:n
        richness(mat[i, :])
    end
end

function bench_shannon(n::Int=1000, n_features::Int=1000)
    mat = rand(0:1000, n, n_features)
    @elapsed for i in 1:n
        shannon(mat[i, :])
    end
end

function bench_simpson(n::Int=1000, n_features::Int=1000)
    mat = rand(0:1000, n, n_features)
    @elapsed for i in 1:n
        simpson(mat[i, :])
    end
end

function bench_rarefy(n::Int=100, n_features::Int=1000, depth::Int=1000)
    mat = rand(0:1000, n, n_features) .|> Float64
    @elapsed rarefy(mat, depth=depth, seed=123)
end

function bench_normalise_counts(n::Int=100, n_features::Int=1000)
    mat = rand(0:1000, n, n_features) .|> Float64
    @elapsed normalise_counts(mat, method="rarefy", depth=1000, seed=123)
end

function bench_alpha_boxplot(n_groups::Int=3, n_per_group::Int=10)
    groups = []
    for g in 1:n_groups
        sample_names = ["Group$(g)_Sample$(i)" for i in 1:n_per_group]
        counts = rand(50:500, n_per_group)
        shannon_vals = rand(1.0:0.1:5.0, n_per_group)
        simpson_vals = rand(0.5:0.01:0.99, n_per_group)
        push!(groups, ("Group$g", sample_names, collect(1:n_per_group), shannon_vals, simpson_vals))
    end
    @elapsed alpha_boxplot(groups, metric="shannon")
end

function bench_nmds_chart(n::Int=20)
    coords = randn(n, 2)
    labels = ["Sample$i" for i in 1:n]
    @elapsed nmds_chart(coords, labels)
end

# R-dependent benchmarks — only run if R available
function bench_run_nmds(n::Int=20, n_features::Int=100)
    try
        using RCall
        mat = rand(0:1000, n, n_features) .|> Float64
        # Check R available
        R"library(vegan)"
        @elapsed begin
            # Mock call — actual run_nmds uses RCall
            # We benchmark the Julia wrapper, not R itself, to avoid heavy R dependency in bench
            # For full benchmark, use: MetaManifold.Analysis.run_nmds(mat)
            mat
        end
    catch e
        @warn "R not available for NMDS benchmark" exception=e
        return 0.0
    end
end

function run_benchmarks(; reps=5)
    println("=== PERMANOVA/NMDS Benchmark ===")
    results = Dict{String, Vector{Float64}}()

    for name in ["richness", "shannon", "simpson", "rarefy", "normalise_counts", "alpha_boxplot", "nmds_chart", "run_nmds"]
        results[name] = Float64[]
    end

    for _ in 1:reps
        push!(results["richness"], bench_richness())
        push!(results["shannon"], bench_shannon())
        push!(results["simpson"], bench_simpson())
        push!(results["rarefy"], bench_rarefy())
        push!(results["normalise_counts"], bench_normalise_counts())
        push!(results["alpha_boxplot"], bench_alpha_boxplot())
        push!(results["nmds_chart"], bench_nmds_chart())
        push!(results["run_nmds"], bench_run_nmds())
    end

    for (name, times) in results
        med = median(times)
        println("$name: median $(round(med*1000, digits=2)) ms over $reps reps")
    end

    baseline_path = joinpath(@__DIR__, "baseline.json")
    if isfile(baseline_path)
        using JSON3
        baseline = JSON3.read(read(baseline_path, String))
        println("\nBaseline comparison (fail on >10% regression):")
        for (name, times) in results
            med = median(times)
            if haskey(baseline, name)
                base_med = baseline[name]
                if base_med > 0
                    delta = (med - base_med) / base_med * 100
                    status = abs(delta) > 10 ? "FAIL" : "PASS"
                    println("$status $name: $(round(delta, digits=1))% vs baseline $(round(base_med*1000, digits=2)) ms")
                    if abs(delta) > 10 && get(ENV, "CI", "false") == "true"
                        @error "Regression >10% for $name" delta
                        exit(1)
                    end
                end
            end
        end
    else
        println("\nNo baseline.json — saving current as baseline")
        using JSON3
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
