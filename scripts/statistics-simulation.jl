#!/usr/bin/env julia
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Simulation, stability and cost study for the exact statistics layer (issue #1).
#
# Three questions, each answered by running the layer rather than reasoning
# about it:
#
#   1. Bias. Is the closed-form expected richness the mean of the thing it
#      claims to be the mean of? For each table and depth, subsamples are drawn
#      without replacement and the simulated mean is compared with the exact
#      value. The tolerance is fixed in advance at four standard errors of the
#      simulated mean, so a correct implementation fails roughly once in 30,000
#      runs and a bias above ~1% is caught. Seeds are fixed, so the study is
#      reproducible rather than flaky.
#
#   2. Precision stability. Does the Shannon index agree across 64, 256 and 1024
#      bits to the precision the narrowest of them can support? Disagreement
#      beyond 53 bits' worth of agreement would mean the precision setting is not
#      being honoured.
#
#   3. Cost. How long does the exact path take, and how much does it allocate, on
#      a table of realistic width? This is reported, and only enforced with
#      --strict-benchmark, because a wall-clock budget on shared CI hardware is a
#      flaky assertion rather than a measurement.
#
# This script is NOT part of the unit suite: it runs for longer than a unit test
# should. The unit suite carries a small version of study 1 with the same
# pre-set tolerance. Run:
#
#     julia --project=. scripts/statistics-simulation.jl
#     julia --project=. scripts/statistics-simulation.jl --strict-benchmark
#
# It exits non-zero if a correctness check fails.

using MetaManifold.ExactNumeric
using MetaManifold.ExactStatistics
using Random

const STRICT = "--strict-benchmark" in ARGS
const EXACT  = NumericPolicy(mode = "exact", max_digits = 100_000)
const BIG    = NumericPolicy(mode = "bigfloat", precision_bits = 256)

"""Draw `n` subsamples of `depth` reads without replacement; return mean and SE."""
function simulate_richness(counts::Vector{Int}, depth::Int; n::Int = 4_000, seed::Int = 12345)
    reads = Int[]
    for (feature, c) in enumerate(counts)
        for _ in 1:c
            push!(reads, feature)
        end
    end
    rng = MersenneTwister(seed)
    values = Vector{Int}(undef, n)
    for i in 1:n
        subset = randperm(rng, length(reads))[1:depth]
        values[i] = length(unique(reads[subset]))
    end
    μ = sum(values) / n
    σ = sqrt(sum((v - μ)^2 for v in values) / (n - 1))
    return μ, σ / sqrt(n)
end

function bias_study(io::IO)
    println(io, "\n1. Expected richness: exact value vs simulated mean")
    println(io, "   tolerance: |simulated - exact| <= 4 standard errors (pre-set)\n")
    println(io, "   ", rpad("counts", 22), rpad("depth", 7), rpad("exact", 20),
                rpad("simulated", 12), "SE        result")
    tables = [
        [4, 6, 2, 8],
        [10, 10],
        [20, 1, 1],
        [30, 20, 10, 5],
        [1, 1, 1, 1, 1, 1, 1, 1],
        [50, 0, 0, 0],
        [12, 7, 3],
    ]
    ok = true
    for counts in tables, depth in unique([1, max(1, sum(counts) ÷ 4), max(1, sum(counts) ÷ 2)])
        exact = expected_richness(BigInt.(counts), depth; policy = EXACT)
        μ, se = simulate_richness(counts, depth)
        tolerance = 4 * se
        passed = abs(μ - Float64(exact)) <= tolerance + 1e-12
        ok &= passed
        println(io, "   ", rpad(string(counts), 22), rpad(depth, 7),
                rpad(display_string(exact; digits = 6), 20),
                rpad(string(round(μ; digits = 4)), 12),
                rpad(string(round(se; sigdigits = 3)), 10),
                passed ? "pass" : "FAIL")
    end
    return ok
end

function precision_study(io::IO)
    println(io, "\n2. Shannon index across precisions")
    tables = [[50, 50], [90, 10], [1, 10^9], [25, 25, 25, 25], [1, 1, 1]]
    ok = true
    for counts in tables
        values = Dict(bits => shannon_index(BigInt.(counts),
                                            NumericPolicy(mode = "bigfloat",
                                                          precision_bits = bits))
                      for bits in (64, 256, 1024))
        narrow = values[64]
        # 64 bits carries about 19 decimal digits; agreement to 1e-17 is what that
        # width supports, and a wider computation that disagrees has lost precision.
        agreement = maximum(abs(values[bits] - narrow) for bits in (256, 1024))
        passed = agreement < big"1e-17"
        ok &= passed
        println(io, "   ", rpad(string(counts), 22),
                " agreement across 64/256/1024 bits: ",
                rpad(string(agreement), 12), passed ? "pass" : "FAIL")
    end
    return ok
end

function cost_study(io::IO)
    println(io, "\n3. Cost of the exact path (reported; enforced only with --strict-benchmark)")
    rng = MersenneTwister(2026)
    samples, features = 200, 50
    mat = [rand(rng, 0:500) for _ in 1:samples, _ in 1:features]
    names_s = ["S$(i)" for i in 1:samples]
    names_f = ["F$(j)" for j in 1:features]

    results = NamedTuple[]
    for (label, method, policy, options) in (
            ("summarise.counts (exact)", "summarise.counts", EXACT, Dict{String,Any}()),
            ("describe.alpha (bigfloat 256)", "describe.alpha", BIG, Dict{String,Any}()),
            ("describe.proportions (exact)", "describe.proportions", EXACT, Dict{String,Any}()),
            ("rarefaction.expected_richness (bigfloat 256)",
             "rarefaction.expected_richness", BIG, Dict{String,Any}("depth" => 100)))
        stats = @timed analyse(mat, names_s, names_f; method = method, policy = policy,
                               options = options)
        record = stats.value
        push!(results, (; label, seconds = stats.time, bytes = stats.bytes,
                          status = record["status"]))
    end

    budgets = Dict("summarise.counts (exact)" => 5.0,
                   "describe.alpha (bigfloat 256)" => 10.0,
                   "describe.proportions (exact)" => 5.0,
                   "rarefaction.expected_richness (bigfloat 256)" => 60.0)
    ok = true
    for r in results
        budget = get(budgets, r.label, 60.0)
        within = r.seconds <= budget
        ok &= within || !STRICT
        println(io, "   ", rpad(r.label, 46),
                rpad(string(round(r.seconds; digits = 3)) * " s", 10),
                rpad(string(round(r.bytes / 2^20; digits = 1)) * " MiB", 10),
                rpad(r.status, 10),
                within ? "within budget" : "OVER BUDGET ($(budget) s)")
    end
    return ok
end

function main(io::IO = stdout)
    println(io, "statistics simulation study (issue #1)")
    println(io, "julia ", VERSION, ", ", Sys.CPU_THREADS, " threads")
    ok = bias_study(io)
    ok &= precision_study(io)
    ok &= cost_study(io)
    println(io, "\n", ok ? "all checks passed" : "at least one check failed")
    return ok
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(main() ? 0 : 1)
end
