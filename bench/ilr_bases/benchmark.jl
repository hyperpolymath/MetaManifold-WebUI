# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""
ILR-basis scaling benchmark (issue #20) — 100, 1 000 and 10 000 taxa.

Measures, per size, the CLR transform and the default (Helmert) ILR through
`Execution.prepare_analysis_table`, and each new basis through the engine
(`ILRBasis.ilr_transform`, file read and SHA-256 included):

  * phylogenetic — a balanced rooted bifurcating tree;
  * sequential_binary_partition — the SBP CSV of the same tree (D x (D-1) cells: the
    format the issue specifies is dense, 10^8 cells at 10 000 taxa; the reader streams it);
  * balance_dendrogram — ward, complete and average on the variation matrix.

Reported per workload: wall time, bytes allocated, and growth of the process's peak
resident set. A workload over 5 minutes, or over 1 GiB of allocation or of peak-RSS growth,
is WARNED about (a GitHub `::warning::` annotation in CI), as the issue asks. Like every
other Julia benchmark in this repository the result is informational (cross-host timings
are noise; see the comment above the frontend benchmark step in ci.yml): the hard >10%
CLR/ILR regression gate is the same-runner base-vs-head comparison in
bench/ilr_bases/regression_gate.jl.

Run:  julia --project=. bench/ilr_bases/benchmark.jl
      ILR_BENCH_TAXA=100,1000 julia --project=. bench/ilr_bases/benchmark.jl
Writes bench/results/ilr_bases_results.json.
"""

using MetaManifold
using MetaManifold: AnalysisConfig, Execution
using JSON3
using Logging
using OrderedCollections

const ILR = MetaManifold.ILRBasis
const WARN_SECONDS = 300.0
const WARN_BYTES = 1 << 30
const SAMPLES = 20

sizes() = parse.(Int, split(get(ENV, "ILR_BENCH_TAXA", "100,1000,10000"), ','))

# Deterministic strictly positive taxa x samples table (no RNG: identical on every host).
synth(D, n) = [1.5 + mod(i * 7919 + j * 104729, 997) + 0.25 * mod(i * j, 7) for i in 1:D, j in 1:n]

function balanced_newick(names::Vector{String}, lo::Int, hi::Int)
    lo == hi && return names[lo]
    mid = (lo + hi) >>> 1
    return "(" * balanced_newick(names, lo, mid) * ":0.1," * balanced_newick(names, mid + 1, hi) * ":0.1)"
end

function write_sbp(path, taxa, W)
    open(path, "w") do io
        println(io, "taxon,", join(("b$k" for k in 1:size(W, 2)), ","))
        for i in eachindex(taxa)
            print(io, taxa[i])
            for k in 1:size(W, 2)
                print(io, ',', W[i, k])
            end
            println(io)
        end
    end
end

function config(norm::String, method::String)
    AnalysisConfig.AnalysisConfig(
        method = method, formula = "~ group", metadata_columns = ["group"],
        normalization = AnalysisConfig.NormalizationConfig(method = norm, pseudocount = 0.5),
        advanced = AnalysisConfig.AdvancedConfig(min_prevalence = 0.0, min_abundance = 0.0),
        created_by = "bench/ilr_bases")
end

function measure(f)
    GC.gc()
    rss0 = Sys.maxrss()
    stats = @timed f()
    return (seconds = stats.time, allocated_bytes = stats.bytes, gc_seconds = stats.gctime,
            peak_rss_growth_bytes = max(0, Int(Sys.maxrss()) - Int(rss0)))
end

function workloads(D::Int, dir::String)
    X = synth(D, SAMPLES)
    taxa = ["t$i" for i in 1:D]
    samples = ["s$j" for j in 1:SAMPLES]
    tree = joinpath(dir, "tree_$D.nwk")
    write(tree, balanced_newick(taxa, 1, D) * ";")
    sbp = joinpath(dir, "sbp_$D.csv")
    write_sbp(sbp, taxa, ILR.sbp_matrix(first(ILR.phylo_balance_tree(ILR.parse_newick(read(tree, String)), taxa))))
    prep(cfg) = () -> Execution.prepare_analysis_table(cfg, X; sample_ids = samples, taxa_ids = taxa, drop_policy = "drop")
    clr, ilr = config("clr", "clr_lm"), config("ilr", "ilr_lm")
    w = OrderedDict{String,Any}(
        "clr (prepare_analysis_table)" => prep(clr),
        "ilr default Helmert (prepare_analysis_table)" => prep(ilr),
        "phylogenetic" => () -> ILR.ilr_transform(X, taxa; basis = "phylogenetic", tree_path = tree),
        "sequential_binary_partition" => () -> ILR.ilr_transform(X, taxa; basis = "sequential_binary_partition", sbp_path = sbp),
    )
    for m in ILR.VALID_DENDROGRAM_METHODS
        w["balance_dendrogram $m"] = () -> ILR.ilr_transform(X, taxa; basis = "balance_dendrogram", dendrogram_method = m)
    end
    return w
end

function main()
    in_ci = haskey(ENV, "GITHUB_ACTIONS")
    results = OrderedDict{String,Any}("julia" => string(VERSION), "samples" => SAMPLES,
                                      "warn_seconds" => WARN_SECONDS, "warn_bytes" => WARN_BYTES,
                                      "runs" => Any[])
    warnings = String[]
    mktempdir() do dir
        with_logger(NullLogger()) do
            # compile everything once on a small problem so no size pays for compilation
            foreach(f -> f(), values(workloads(20, dir)))
            for D in sizes()
                for (name, f) in workloads(D, dir)
                    m = measure(f)
                    push!(results["runs"], OrderedDict{String,Any}("taxa" => D, "workload" => name, pairs(m)...))
                    flags = String[]
                    m.seconds > WARN_SECONDS && push!(flags, "took $(round(m.seconds; digits = 1)) s (> 5 min)")
                    m.allocated_bytes > WARN_BYTES && push!(flags, "allocated $(round(m.allocated_bytes / 2^30; digits = 2)) GiB (> 1 GiB)")
                    m.peak_rss_growth_bytes > WARN_BYTES && push!(flags, "grew peak RSS by $(round(m.peak_rss_growth_bytes / 2^30; digits = 2)) GiB (> 1 GiB)")
                    isempty(flags) || push!(warnings, "ILR benchmark, $D taxa, $name: " * join(flags, "; "))
                end
            end
        end
    end
    println("=== ILR bases: scaling (", SAMPLES, " samples) ===")
    println(rpad("taxa", 7), rpad("workload", 48), lpad("time s", 10), lpad("alloc MiB", 12), lpad("ΔpeakRSS MiB", 14))
    for r in results["runs"]
        println(rpad(string(r["taxa"]), 7), rpad(r["workload"], 48), lpad(string(round(r["seconds"]; digits = 3)), 10),
                lpad(string(round(r["allocated_bytes"] / 2^20; digits = 1)), 12),
                lpad(string(round(r["peak_rss_growth_bytes"] / 2^20; digits = 1)), 14))
    end
    results["warnings"] = warnings
    for w in warnings
        println(in_ci ? "::warning::$w" : "WARNING: $w")
    end
    out = joinpath(@__DIR__, "..", "results", "ilr_bases_results.json")
    mkpath(dirname(out))
    open(io -> JSON3.pretty(io, results), out, "w")
    println("results: ", normpath(out))
end

main()
