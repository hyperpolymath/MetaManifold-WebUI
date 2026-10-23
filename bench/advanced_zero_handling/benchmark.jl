#!/usr/bin/env julia
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

# Opt-in scaling benchmark for issue #21. No result file is written unless
# --output=PATH is supplied. See README.md in this directory.

using MetaManifold
using MetaManifold.Differential
using JSON3

function arg_value(prefix::AbstractString)
    for arg in ARGS
        startswith(arg, prefix) && return arg[length(prefix) + 1:end]
    end
    nothing
end

"""A deterministic 24-sample table with common and sparse taxa."""
function fixture(n_taxa::Int; n_samples::Int=24)
    n_taxa >= 6 || throw(ArgumentError("the benchmark fixture needs at least 6 taxa"))
    counts = zeros(Int, n_samples, n_taxa)
    for j in 1:n_taxa, i in 1:n_samples
        guaranteed = i == (j % n_samples + 1) || i == ((j + 7) % n_samples + 1)
        present = j <= 6 || guaranteed || (i + 3j) % 8 == 0
        present || continue
        counts[i, j] = 1 + (17i + 31j) % 50
        j == 1 && i > n_samples ÷ 2 && (counts[i, j] *= 4)
    end
    counts
end

function replacement_benchmark(counts, method::String, alpha)
    out = replace_zeros(counts; method, alpha)
    # Consume the result so a future implementation cannot win by doing no work.
    (sum(out.proportions), out.zeros_replaced)
end

function dispersion_benchmark(counts, samples, groups, dispersion::String)
    factors = tss_factors(counts, samples)
    fits = fit_nb(counts, groups, log.(factors); levels=("A", "B"), dispersion)
    size(fits, 1)
end

function main()
    sizes = parse.(Int, split(something(arg_value("--sizes="), "100,1000,10000"), ','))
    all(>=(6), sizes) || throw(ArgumentError("all --sizes must be at least 6"))
    include_dispersion = "--dispersion" in ARGS
    output = arg_value("--output=")
    baseline_path = arg_value("--baseline=")
    results = Dict{String,Any}[]
    samples = ["sample $i" for i in 1:24]
    groups = vcat(fill("A", 12), fill("B", 12))

    for n_taxa in sizes
        counts = fixture(n_taxa)
        scenarios = Any[
            ("replacement/bayesian_multiplicative", () -> replacement_benchmark(
                counts, "bayesian_multiplicative", nothing)),
            ("replacement/bayesian_alpha_2.5", () -> replacement_benchmark(
                counts, "bayesian_multiplicative", 2.5)),
            ("replacement/multiplicative_replacement", () -> replacement_benchmark(
                counts, "multiplicative_replacement", nothing)),
        ]
        if include_dispersion
            push!(scenarios, ("dispersion/ml", () -> dispersion_benchmark(counts, samples, groups, "ml")))
            push!(scenarios, ("dispersion/glmGamPoi", () -> dispersion_benchmark(counts, samples, groups, "glmGamPoi")))
        end
        for (operation, f) in scenarios
            n_taxa == first(sizes) && f()  # warm up each method before timing it
            GC.gc()
            timed = @timed f()
            timed.time > 300 && @warn "Benchmark operation exceeded five minutes" operation n_taxa seconds=timed.time
            push!(results, Dict{String,Any}(
                "operation" => operation,
                "n_taxa" => n_taxa,
                "n_samples" => 24,
                "seconds" => timed.time,
                # @timed measures Julia allocations, including RCall copies. It
                # cannot measure allocations inside the embedded R runtime.
                "julia_allocated_bytes" => timed.bytes,
                "input_matrix_bytes" => Base.summarysize(counts),
                "gc_seconds" => timed.gctime,
            ))
            println(stderr, "$operation, $n_taxa taxa: $(round(timed.time; digits=3)) s, " *
                            "$(timed.bytes) Julia bytes allocated")
        end
    end

    document = Dict("kind" => "advanced_zero_handling_benchmark", "results" => results)
    rendered = JSON3.write(document)
    isnothing(output) ? println(rendered) : write(output, rendered * "\n")

    if !isnothing(baseline_path)
        # A baseline is an input like any other: a truncated or hand-edited file
        # must name itself in the error rather than escape as a JSON3 parse
        # failure from inside the benchmark loop.
        baseline = try
            JSON3.read(read(baseline_path, String))
        catch err
            error("could not read benchmark baseline $(baseline_path): $(sprint(showerror, err))")
        end
        regressions = String[]
        for old in baseline.results
            old.operation in ("replacement/bayesian_multiplicative", "dispersion/ml") || continue
            new = findfirst(r -> r["operation"] == old.operation && r["n_taxa"] == old.n_taxa, results)
            isnothing(new) && error("baseline operation $(old.operation) at $(old.n_taxa) taxa was not measured")
            ratio = results[new]["seconds"] / old.seconds
            ratio > 1.10 && push!(regressions,
                "$(old.operation) at $(old.n_taxa) taxa: $(round(100 * ratio; digits=1))% of baseline")
        end
        isempty(regressions) || error("Existing-method runtime regressed by more than 10%: " * join(regressions, "; "))
    end
    nothing
end

abspath(PROGRAM_FILE) == @__FILE__ && main()
