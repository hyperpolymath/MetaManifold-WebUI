#!/usr/bin/env julia
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Representative biological validation for the validated statistics layer.
#
# The layer is checked against the repository's existing Float64 diversity
# implementation (DiversityMetrics) on the same real count matrix. The two
# implementations share no arithmetic: one uses exact integers and rationals
# plus MPFR, the other Float64. Agreement within a pre-set tolerance is
# therefore evidence about the new layer, not a tautology.
#
# This script does NOT create data. It requires a real count matrix and a
# provenance string naming where it came from. A table with no provenance is
# refused, because an unnamed matrix is not biological validation.
#
# Usage:
#   julia --project=. scripts/statistics/biological_validation.jl \
#       --input counts.csv --source "study/run or DOI" [--tolerance 1e-9] \
#       [--output report.json] [--precision 256]
#
# The CSV is features × samples: the first column holds feature identifiers and
# each remaining column is one sample. Counts must be non-negative integers.
#
# Exit status: 0 = within tolerance, 1 = a comparison failed, 2 = bad input.

using CSV
using DataFrames
using JSON3
using Dates

using MetaManifold
using MetaManifold.Canonical
using MetaManifold.NumericPolicy
using MetaManifold.ExactSummaries
using MetaManifold.HighPrecision
using MetaManifold.DiversityMetrics

function _usage(message)
    println(stderr, "biological_validation: ", message)
    println(stderr, "usage: --input counts.csv --source \"provenance\" [--tolerance 1e-9] ",
                   "[--precision 256] [--output report.json]")
    exit(2)
end

function main(args::Vector{String})
    input = nothing
    source = nothing
    tolerance = 1e-9
    precision_bits = 256
    output = nothing
    index = 1
    while index <= length(args)
        argument = args[index]
        index < length(args) || _usage("missing value for $argument")
        value = args[index + 1]
        if argument == "--input"
            input = value
        elseif argument == "--source"
            source = value
        elseif argument == "--tolerance"
            tolerance = parse(Float64, value)
        elseif argument == "--precision"
            precision_bits = parse(Int, value)
        elseif argument == "--output"
            output = value
        else
            _usage("unknown argument '$argument'")
        end
        index += 2
    end
    isnothing(input) && _usage("--input is required")
    isnothing(source) && _usage("--source is required; an unnamed matrix is not validation")
    isempty(strip(source)) && _usage("--source must not be blank")
    isfile(input) || _usage("no such file: $input")
    0 < tolerance < 1 || _usage("--tolerance must be in (0, 1)")

    table = CSV.read(input, DataFrame; copycols=false)
    ncol(table) >= 2 || _usage("the CSV needs an identifier column and at least one sample")
    feature_names = String.(string.(table[!, 1]))
    sample_names = String.(names(table)[2:end])
    allunique(feature_names) || _usage("feature identifiers must be unique")
    allunique(sample_names) || _usage("sample names must be unique")

    counts = Matrix{BigInt}(undef, length(feature_names), length(sample_names))
    for (j, name) in enumerate(sample_names)
        column = table[!, name]
        for (i, value) in enumerate(column)
            (value isa Integer && !(value isa Bool)) ||
                _usage("column '$name' row $i is not an integer count: $(repr(value))")
            value >= 0 || _usage("column '$name' row $i is negative")
            counts[i, j] = BigInt(value)
        end
    end

    exact_policy = numeric_policy(; mode=:exact_counts,
        max_denominator_bits=DEFAULT_MAX_DENOMINATOR_BITS)
    exact = exact_summary(counts; sample_labels=sample_names,
        feature_labels=feature_names, policy=exact_policy)
    high = high_precision_summary(counts; sample_labels=sample_names,
        feature_labels=feature_names,
        policy=numeric_policy(; mode=:high_precision, precision_bits=precision_bits))

    comparisons = Vector{Dict{String,Any}}()
    failures = String[]
    for (j, name) in enumerate(sample_names)
        column = Float64.(counts[:, j])
        legacy_shannon = DiversityMetrics.shannon(column)
        legacy_simpson = DiversityMetrics.simpson(column)
        sample = high.samples[j]
        if iszero(sample.total)
            # The legacy function reports 0.0 for an empty sample; this layer
            # reports undefined. The divergence is intentional and is recorded,
            # not smoothed over.
            push!(comparisons, Dict{String,Any}(
                "sample" => name, "total" => "0", "status" => "undefined_zero_total",
                "legacy_shannon" => legacy_shannon, "legacy_simpson" => legacy_simpson,
                "agreement" => "not compared: legacy reports 0.0 where the validated layer reports undefined",
            ))
            continue
        end
        shannon = Float64(sample.shannon)
        simpson = Float64(sample.gini_simpson)
        shannon_error = abs(shannon - legacy_shannon) / max(1.0, abs(legacy_shannon))
        simpson_error = abs(simpson - legacy_simpson) / max(1.0, abs(legacy_simpson))
        shannon_ok = shannon_error <= tolerance
        simpson_ok = simpson_error <= tolerance
        shannon_ok || push!(failures,
            "sample '$name': Shannon differs by $shannon_error > $tolerance")
        simpson_ok || push!(failures,
            "sample '$name': Gini-Simpson differs by $simpson_error > $tolerance")
        push!(comparisons, Dict{String,Any}(
            "sample" => name,
            "total" => to_storage(exact_value(sample.total)),
            "richness" => sample.richness,
            "shannon" => string(sample.shannon),
            "shannon_legacy" => legacy_shannon,
            "shannon_relative_error" => shannon_error,
            "simpson" => string(sample.gini_simpson),
            "simpson_legacy" => legacy_simpson,
            "simpson_relative_error" => simpson_error,
            "within_tolerance" => shannon_ok && simpson_ok,
        ))
        # Exactness of the same matrix is a zero-tolerance check.
        exact_sample = exact.samples[j]
        for i in eachindex(feature_names)
            exact_sample.proportions[i] * exact_sample.total == counts[i, j] ||
                push!(failures, "sample '$name': exact proportion $i does not reconstruct its count")
        end
    end

    report = Dict{String,Any}(
        "schema" => "metamanifold.statistics-biological-validation.v1",
        "source" => String(source),
        "input_file" => abspath(input),
        "input_sha256" => jcs_sha256(Dict(
            "sample_labels" => sample_names,
            "feature_labels" => feature_names,
            "counts" => [[string(counts[i, j]) for j in eachindex(sample_names)]
                         for i in eachindex(feature_names)],
        )),
        "samples" => length(sample_names),
        "features" => length(feature_names),
        "precision_bits" => high.achieved_bits,
        "tolerance" => tolerance,
        "comparisons" => comparisons,
        "failures" => failures,
        "complete" => isempty(failures),
        "software" => Dict("julia" => string(VERSION), "mpfr" => string(Base.MPFR.version()),
                           "generated" => string(Dates.now(UTC))),
    )
    if isnothing(output)
        println(JSON3.write(report))
    else
        open(output, "w") do io
            println(io, JSON3.pretty(report))
        end
        println("biological_validation: $(length(sample_names)) samples from '$(source)'; ",
                isempty(failures) ? "within tolerance $tolerance" : "FAILED", "; report ", output)
    end
    for failure in failures
        println(stderr, "biological_validation: ", failure)
    end
    return isempty(failures) ? 0 : 1
end

exit(main(ARGS))
