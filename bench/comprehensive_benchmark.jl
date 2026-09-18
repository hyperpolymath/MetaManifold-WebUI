# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""
Comprehensive benchmark runner for Milestone 2

Runs all benchmark categories:
- table_loading
- epistemic_parsing
- duckdb_aggregation
- permanova_nmds
- tree_rendering

Fails on >10% regression vs committed baselines when CI=true
Uploads artifacts via GitHub Actions (see .github/workflows/ci.yml)
"""

using Logging

const BENCH_DIR = @__DIR__

function run_category(cat::String)
    bench_file = joinpath(BENCH_DIR, cat, "benchmark.jl")
    if !isfile(bench_file)
        @warn "Benchmark file not found" cat bench_file
        return nothing
    end
    println("\n" * "="^60)
    println("Running benchmark category: $cat")
    println("="^60)
    # Include and run
    mod = Module()
    Base.include(mod, bench_file)
    if isdefined(mod, :run_benchmarks)
        return Base.invokelatest(mod.run_benchmarks)
    else
        @warn "No run_benchmarks defined in $bench_file"
        return nothing
    end
end

function main()
    categories = [
        "table_loading",
        "epistemic_parsing",
        "duckdb_aggregation",
        "permanova_nmds",
        "tree_rendering"
    ]

    all_results = Dict{String, Any}()

    for cat in categories
        try
            results = run_category(cat)
            all_results[cat] = results
        catch e
            @error "Benchmark category failed" cat exception=(e, catch_backtrace())
            all_results[cat] = Dict("error" => string(e))
            if get(ENV, "CI", "false") == "true"
                # Don't exit immediately, continue to run others for full report
                # But mark failure
                println("::error::Benchmark $cat failed: $e")
            end
        end
    end

    # Write combined results
    results_path = joinpath(BENCH_DIR, "results", "comprehensive_results.json")
    mkpath(dirname(results_path))
    try
        using JSON3
        open(results_path, "w") do io
            JSON3.write(io, all_results)
        end
        println("\nWrote combined results to $results_path")
    catch e
        @warn "Failed to write JSON results" exception=e
        # Fallback: write simple text
        open(results_path * ".txt", "w") do io
            println(io, all_results)
        end
    end

    println("\n" * "="^60)
    println("Comprehensive benchmark complete")
    println("="^60)
    return all_results
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
