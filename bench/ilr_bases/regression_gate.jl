# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# CLR/ILR performance regression gate (issue #20: "fail CI if CLR/ILR performance regresses
# more than 10%").
#
# Why this shape. This repository deliberately has no hard timing gate against a committed
# baseline: a baseline recorded on one machine says nothing about a shared CI runner (see the
# frontend benchmark comment in ci.yml). So the gate never compares with a stored number. It
# measures the PR's BASE commit and its HEAD on the SAME runner, in the same job, interleaved
# A B A B so that drift in the runner (thermal, noisy neighbours) hits both sides equally,
# and compares:
#
#   * bytes allocated — deterministic for a given Julia version and input, so a >10% growth
#     is a real change, not noise;
#   * minimum wall time over k repetitions per round, minimum across rounds — the minimum is
#     the least noise-sensitive location statistic for "how fast can this code go".
#
# Either ratio above 1.10 fails the job. Both sides run this same script from the HEAD
# checkout, so a change to the gate cannot favour one side; the only difference is which
# MetaManifold `--project` resolves to. Only APIs present on main before #20 are used
# (`prepare_analysis_table` with the CLR and default Helmert ILR configurations), so the base
# side always runs.
#
# Usage:
#   julia --project=<checkout> bench/ilr_bases/regression_gate.jl measure <label> <out.json>
#   julia --project=. bench/ilr_bases/regression_gate.jl compare --base b1.json b2.json --head h1.json h2.json

using MetaManifold
using MetaManifold: AnalysisConfig, Execution
using JSON3
using Logging
using OrderedCollections

const THRESHOLD = 1.10
const REPS = 7
# (label, normalization, method, taxa, samples): large enough that the transform dominates
# fixed overhead, small enough that the default Helmert loop (O(D^2) per sample) stays quick.
const WORKLOADS = [
    ("clr", "clr", "clr_lm", 5000, 60),
    ("ilr_default", "ilr", "ilr_lm", 1500, 40),
]

synth(D, n) = [1.5 + mod(i * 7919 + j * 104729, 997) + 0.25 * mod(i * j, 7) for i in 1:D, j in 1:n]

function workload(norm, method, D, n)
    cfg = AnalysisConfig.AnalysisConfig(
        method = method, formula = "~ group", metadata_columns = ["group"],
        normalization = AnalysisConfig.NormalizationConfig(method = norm, pseudocount = 0.5),
        advanced = AnalysisConfig.AdvancedConfig(min_prevalence = 0.0, min_abundance = 0.0),
        created_by = "bench/ilr_bases/regression_gate")
    X = synth(D, n)
    taxa = ["t$i" for i in 1:D]
    samples = ["s$j" for j in 1:n]
    return () -> Execution.prepare_analysis_table(cfg, X; sample_ids = samples, taxa_ids = taxa, drop_policy = "drop")
end

function measure(label::String, out::String)
    result = OrderedDict{String,Any}("label" => label, "julia" => string(VERSION),
                                     "metamanifold" => pathof(MetaManifold), "reps" => REPS,
                                     "workloads" => OrderedDict{String,Any}())
    with_logger(NullLogger()) do
        for (name, norm, method, D, n) in WORKLOADS
            f = workload(norm, method, D, n)
            f(); f()                         # compile and warm caches
            bytes = @allocated f()
            times = Float64[]
            for _ in 1:REPS
                GC.gc()
                push!(times, @elapsed f())
            end
            result["workloads"][name] = OrderedDict{String,Any}(
                "taxa" => D, "samples" => n, "allocated_bytes" => bytes,
                "min_seconds" => minimum(times), "median_seconds" => sort(times)[(REPS + 1) ÷ 2])
        end
    end
    mkpath(dirname(abspath(out)))
    open(io -> JSON3.pretty(io, result), out, "w")
    println("[$label] ", pathof(MetaManifold))
    for (name, w) in result["workloads"]
        println("  $name: min $(round(w["min_seconds"]; digits = 4)) s, $(w["allocated_bytes"]) bytes")
    end
end

function compare(args::Vector{String})
    i_base = findfirst(==("--base"), args)
    i_head = findfirst(==("--head"), args)
    (i_base === nothing || i_head === nothing || i_head < i_base) && error("usage: compare --base <json>... --head <json>...")
    base = [JSON3.read(read(p, String)) for p in args[(i_base + 1):(i_head - 1)]]
    head = [JSON3.read(read(p, String)) for p in args[(i_head + 1):end]]
    (isempty(base) || isempty(head)) && error("compare needs at least one base and one head measurement")
    lines = ["| workload | base min s | head min s | time ratio | base bytes | head bytes | alloc ratio | verdict |",
             "|---|---:|---:|---:|---:|---:|---:|---|"]
    failed = String[]
    for w in WORKLOADS
        name = w[1]
        bt = minimum(r["workloads"][name]["min_seconds"] for r in base)
        ht = minimum(r["workloads"][name]["min_seconds"] for r in head)
        ba = minimum(r["workloads"][name]["allocated_bytes"] for r in base)
        ha = minimum(r["workloads"][name]["allocated_bytes"] for r in head)
        tr, ar = ht / bt, ha / max(ba, 1)
        bad = String[]
        tr > THRESHOLD && push!(bad, "time +$(round((tr - 1) * 100; digits = 1))%")
        ar > THRESHOLD && push!(bad, "allocations +$(round((ar - 1) * 100; digits = 1))%")
        isempty(bad) || push!(failed, "$name: " * join(bad, ", "))
        push!(lines, "| $name | $(round(bt; digits = 4)) | $(round(ht; digits = 4)) | $(round(tr; digits = 3)) | $ba | $ha | $(round(ar; digits = 3)) | $(isempty(bad) ? "ok" : "REGRESSION") |")
    end
    report = "### CLR/ILR regression gate (same runner, base vs head, threshold +10%)\n\n" * join(lines, "\n") * "\n"
    print(report)
    summary = get(ENV, "GITHUB_STEP_SUMMARY", "")
    isempty(summary) || open(io -> write(io, report), summary, "a")
    if !isempty(failed)
        for f in failed
            println(haskey(ENV, "GITHUB_ACTIONS") ? "::error::CLR/ILR performance regression, $f (limit +10%)" : "REGRESSION: $f")
        end
        exit(1)
    end
end

function main(args)
    if length(args) == 3 && args[1] == "measure"
        measure(args[2], args[3])
    elseif !isempty(args) && args[1] == "compare"
        compare(args[2:end])
    else
        error("usage: regression_gate.jl measure <label> <out.json> | compare --base <json>... --head <json>...")
    end
end

main(ARGS)
