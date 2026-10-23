#!/usr/bin/env julia
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Scaling and baseline-regression benchmark for Issue #19 constrained ordinations
# (RDA, CCA, CAP, dbRDA, permutation ANOVA, and variance partitioning).
#
# Usage:
#   julia --project=. bench/constrained_ordination/benchmark.jl
#   julia --project=. bench/constrained_ordination/benchmark.jl --include-1000
#   julia --project=. bench/constrained_ordination/benchmark.jl --json

using DataFrames
using Dates
using MetaManifold
using MetaManifold.Analysis: r_available
using MetaManifold.Canonical
using MetaManifold.DiversityMetrics: transform_counts, shannon, simpson
using MetaManifold.Ordination
using Random

const FIVE_MINUTE_WARN_SECONDS = 300.0

"""
Generate a reproducible sample-by-feature count matrix and aligned group, batch
and pH metadata using a local RNG. For positive dimensions, ensure every sample
and feature has positive total abundance.
"""
function _synthetic_microbiome(n_samples::Int, n_features::Int; seed::Int = 20261023)
    rng = MersenneTwister(seed)
    groups = [i <= div(n_samples, 2) ? "Control" : "Treatment" for i in 1:n_samples]
    batches = [mod1(i, 3) == 1 ? "BatchA" : (mod1(i, 3) == 2 ? "BatchB" : "BatchC") for i in 1:n_samples]
    ph = [6.2 + 1.4 * (i / n_samples) + 0.15 * randn(rng) for i in 1:n_samples]

    counts = Matrix{Float64}(undef, n_samples, n_features)
    for i in 1:n_samples
        g_shift = groups[i] == "Treatment" ? 0.85 : -0.85
        for j in 1:n_features
            base_rate = exp(3.5 - 2.4 * (j / n_features) + (j <= 25 ? g_shift : 0.0) + 0.2 * (ph[i] - 6.9))
            c = floor(Int, base_rate * (0.5 + rand(rng)))
            counts[i, j] = Float64(max(0, c))
        end
        # Guarantee strictly positive sample depth
        if sum(@view counts[i, :]) == 0.0
            counts[i, 1] = 10.0
        end
    end
    for j in 1:n_features
        if sum(@view counts[:, j]) == 0.0
            counts[1, j] = 1.0
        end
    end

    meta = DataFrame(
        sample = ["S$(lpad(i, 4, '0'))" for i in 1:n_samples],
        group = groups,
        batch = batches,
        ph = ph,
    )
    (counts, meta)
end

"""Return the median of a non-empty timing vector without changing it; empty input raises `BoundsError`."""
function _median(xs::Vector{Float64})::Float64
    s = sort(xs)
    n = length(s)
    iseven(n) ? 0.5 * (s[div(n, 2)] + s[div(n, 2) + 1]) : s[div(n + 1, 2)]
end

"""
Return median elapsed seconds over positive `reps` for Hellinger transformation
and per-sample Shannon, Simpson and squared-norm summaries, excluding warm-up.
"""
function _bench_existing_diversity(counts::Matrix{Float64}; reps::Int = 5)
    # Warm-up
    _ = transform_counts(counts; method="hellinger")
    _ = shannon(vec(counts[1, :]))

    times = Float64[]
    for _ in 1:reps
        t0 = time_ns()
        h = transform_counts(counts; method="hellinger")
        # Pairwise Euclidean on Hellinger + Shannon + Simpson across all samples
        acc = 0.0
        for i in axes(counts, 1)
            acc += shannon(@view counts[i, :])
            acc += simpson(@view counts[i, :])
            acc += sum(abs2, @view h[i, :])
        end
        acc >= 0.0 || error("unreachable")
        push!(times, (time_ns() - t0) / 1e9)
    end
    _median(times)
end

"""
Return median fit time in seconds over positive `reps` for Hellinger RDA with
group/pH constraints and a BatchA indicator as the conditioning column.
Transformation, design preparation and warm-up are excluded; fit errors propagate.
"""
function _bench_pure_julia_rda(counts::Matrix{Float64}, meta::DataFrame; reps::Int = 5)
    hel = transform_counts(counts; method="hellinger")
    n = size(counts, 1)
    X = hcat([g == "Treatment" ? 1.0 : 0.0 for g in meta.group], Float64.(meta.ph))
    Z = reshape([b == "BatchA" ? 1.0 : 0.0 for b in meta.batch], n, 1)
    _ = pure_linear_rda(hel, X; Z=Z)

    times = Float64[]
    for _ in 1:reps
        t0 = time_ns()
        _ = pure_linear_rda(hel, X; Z=Z)
        push!(times, (time_ns() - t0) / 1e9)
    end
    _median(times)
end

"""
Run the 100-sample benchmark and optionally the 1,000-sample tier when
`--include-1000` is present or `BENCH_INCLUDE_1000=1`. Print canonical JSON with
`--json`, otherwise a text summary. Skip R fits when R/vegan is unavailable;
errors during selected benchmark fits propagate. Timings above 300 seconds
produce warnings in the summary without stopping the benchmark.
"""
function main(args::Vector{String})
    include_1000 = "--include-1000" in args || get(ENV, "BENCH_INCLUDE_1000", "0") == "1"
    emit_json = "--json" in args
    sample_tiers = include_1000 ? [100, 1000] : [100]
    n_features = 200
    n_perm = 999

    results = Dict{String,Any}[]
    warnings = String[]

    for n_samples in sample_tiers
        counts, meta = _synthetic_microbiome(n_samples, n_features)
        div_sec = _bench_existing_diversity(counts; reps = n_samples >= 1000 ? 2 : 5)
        pure_rda_sec = _bench_pure_julia_rda(counts, meta; reps = n_samples >= 1000 ? 2 : 5)

        push!(results, Dict{String,Any}(
            "tier_samples" => n_samples,
            "n_features" => n_features,
            "engine" => "julia_baseline_diversity",
            "method" => "hellinger_bray_shannon_simpson",
            "permutations" => 0,
            "elapsed_seconds" => round(div_sec; digits=6),
            "exceeds_five_minutes" => div_sec > FIVE_MINUTE_WARN_SECONDS,
        ))
        push!(results, Dict{String,Any}(
            "tier_samples" => n_samples,
            "n_features" => n_features,
            "engine" => "pure_julia_oracle",
            "method" => "pure_linear_rda_partial",
            "permutations" => 0,
            "elapsed_seconds" => round(pure_rda_sec; digits=6),
            "exceeds_five_minutes" => pure_rda_sec > FIVE_MINUTE_WARN_SECONDS,
        ))

        if r_available() && vegan_available()
            specs = [
                (:rda, :aitchison, "~ group + ph", true),
                (:cca, :chisq, "~ group + ph", false),
                (:cap, :bray, "~ group + Condition(batch)", false),
                (:dbrda, :bray, "~ group + ph", true),
            ]
            for (m, d, form, vp) in specs
                cfg = OrdinationConfig(;
                    ordination_method = m,
                    ordination_distance = d,
                    ordination_formula = form,
                    ordination_scaling = 2,
                    permutations = n_perm,
                    variance_partitioning = vp,
                    seed = 42,
                )
                est = estimate_ordination_seconds(;
                    method = m,
                    distance = d,
                    n_samples = n_samples,
                    n_features = n_features,
                    permutations = n_perm,
                    n_terms = 2,
                    variance_partitioning = vp,
                )
                t0 = time_ns()
                res = run_constrained_ordination(counts, meta, cfg; beta_transform = (d === :euclidean ? "hellinger" : "none"))
                elapsed = (time_ns() - t0) / 1e9
                slow = elapsed > FIVE_MINUTE_WARN_SECONDS
                if slow
                    push!(warnings, "$(m)($(d)) at N=$(n_samples), perms=$(n_perm) took $(round(elapsed; digits=1))s (> 300s threshold)")
                end
                push!(results, Dict{String,Any}(
                    "tier_samples" => n_samples,
                    "n_features" => n_features,
                    "engine" => "r_vegan",
                    "method" => String(m),
                    "distance" => String(d),
                    "formula" => form,
                    "variance_partitioning" => vp,
                    "permutations" => n_perm,
                    "r2" => res.r2,
                    "adj_r2" => res.adj_r2,
                    "estimated_seconds" => est.estimated_seconds,
                    "elapsed_seconds" => round(elapsed; digits=4),
                    "exceeds_five_minutes" => slow,
                ))
            end
        end
    end

    summary_doc = Dict{String,Any}(
        "benchmark" => "constrained_ordination",
        "timestamp_utc" => Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ"),
        "r_vegan_available" => (r_available() && vegan_available()),
        "five_minute_threshold_seconds" => FIVE_MINUTE_WARN_SECONDS,
        "warnings" => warnings,
        "runs" => results,
    )

    if emit_json
        println(String(jcs_bytes(summary_doc)))
    else
        println("=== Constrained Ordination Benchmark ===")
        println("R + vegan available: ", summary_doc["r_vegan_available"])
        for row in results
            println("  N=", row["tier_samples"],
                    " | ", row["engine"],
                    " | ", row["method"],
                    " | ", row["elapsed_seconds"], " s",
                    row["exceeds_five_minutes"] ? " [WARN > 5 min]" : "")
        end
        for w in warnings
            println("WARNING: ", w)
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
