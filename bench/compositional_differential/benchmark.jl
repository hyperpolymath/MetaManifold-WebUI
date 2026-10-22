#!/usr/bin/env julia
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Runtime and allocation benchmark for MetaManifold's differential abundance
# methods (`nb_glm`, `clr_welch`, `ancom_bc`, `aldex2`, `songbird`) across three
# deterministic synthetic datasets (`mock`, `gut`, `soil`), with an optional
# 10% regression gate on the baseline methods (`nb_glm`, `clr_welch`).
#
# Usage:
#   julia --project=. bench/compositional_differential/benchmark.jl
#   julia --project=. bench/compositional_differential/benchmark.jl --record-baseline baseline.yml
#   julia --project=. bench/compositional_differential/benchmark.jl --baseline baseline.yml

using MetaManifold
using MetaManifold.Differential
using YAML
using OrderedCollections: OrderedDict

const REGRESSION_THRESHOLD = 1.10
const REPEATS = 5

_u01!(st::Base.RefValue{UInt64}) = begin
    st[] = st[] * 0x5851f42d4c957f2d + 0x14057b7ef767814f
    (Float64(st[] >> 11) + 0.5) / Float64(UInt64(1) << 53)
end

_norm!(st::Base.RefValue{UInt64}, mu::Float64=0.0, sd::Float64=1.0) = begin
    u1 = _u01!(st)
    u2 = _u01!(st)
    mu + sd * sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2)
end

function build_datasets()
    out = OrderedDict{String,NamedTuple}()

    # 1. Mock community: 20 samples x 40 taxa
    st1 = Ref(UInt64(20260501))
    m1 = Matrix{Int}(undef, 20, 40)
    b1 = [exp(4.2 + 0.8 * _norm!(st1)) for _ in 1:40]
    r = 0
    for g in (0, 1), _ in 1:10
        r += 1
        sf = exp(_norm!(st1, 0.0, 0.35))
        for j in 1:40
            fc = g == 1 ? (j <= 3 ? 8.0 : (j <= 5 ? 0.25 : 1.0)) : 1.0
            m1[r, j] = max(1, round(Int, sf * b1[j] * fc * exp(_norm!(st1, 0.0, 0.18))))
        end
    end
    out["mock"] = (counts=m1, samples=["s$i" for i in 1:20], taxa=["t$j" for j in 1:40],
                   groups=vcat(fill("A", 10), fill("B", 10)), ref="A", con="B")

    # 2. Gut profile: 24 samples x 60 taxa (sparse tail + asymmetric shift)
    st2 = Ref(UInt64(20260502))
    m2 = Matrix{Int}(undef, 24, 60)
    b2 = [exp(5.4 - 3.6 * ((j - 1) / 59.0)) for j in 1:60]
    r = 0
    for g in (0, 1), _ in 1:12
        r += 1
        sf = (g == 1 ? 0.35 : 1.0) * exp(_norm!(st2, 0.0, 0.30))
        for j in 1:60
            fc = (g == 1 && j <= 8) ? 8.0 : 1.0
            mu = sf * b2[j] * fc * exp(_norm!(st2, 0.0, 0.22))
            m2[r, j] = (j >= 40 && _u01!(st2) < 0.30) ? 0 : max(1, round(Int, mu))
        end
    end
    out["gut"] = (counts=m2, samples=["s$i" for i in 1:24], taxa=["t$j" for j in 1:60],
                  groups=vcat(fill("Control", 12), fill("Case", 12)), ref="Control", con="Case")

    # 3. Soil profile: 20 samples x 100 taxa
    st3 = Ref(UInt64(20260503))
    m3 = Matrix{Int}(undef, 20, 100)
    b3 = [exp(4.0 + 0.5 * _norm!(st3)) for _ in 1:100]
    r = 0
    for g in (0, 1), _ in 1:10
        r += 1
        sf = exp(_norm!(st3, 0.0, 0.25))
        for j in 1:100
            fc = g == 1 ? (j <= 6 ? 6.0 : (j <= 12 ? (1.0 / 6.0) : 1.0)) : 1.0
            m3[r, j] = max(1, round(Int, sf * b3[j] * fc * exp(_norm!(st3, 0.0, 0.16))))
        end
    end
    out["soil"] = (counts=m3, samples=["s$i" for i in 1:20], taxa=["t$j" for j in 1:100],
                   groups=vcat(fill("BulkSoil", 10), fill("Rhizosphere", 10)),
                   ref="BulkSoil", con="Rhizosphere")

    out
end

_median_sorted(v::Vector{Float64}) = begin
    s = sort(v)
    n = length(s)
    isodd(n) ? s[(n + 1) ÷ 2] : 0.5 * (s[n ÷ 2] + s[n ÷ 2 + 1])
end

function measure(ds, cfg::DifferentialConfig)
    # Warmup
    differential_abundance(ds.counts, ds.samples, ds.taxa, ds.groups;
                           reference=ds.ref, contrast=ds.con, config=cfg, seed=123)
    times_ms = Float64[]
    allocs_kb = Float64[]
    for _ in 1:REPEATS
        GC.gc(false)
        stats = @timed differential_abundance(ds.counts, ds.samples, ds.taxa, ds.groups;
                                              reference=ds.ref, contrast=ds.con,
                                              config=cfg, seed=123)
        push!(times_ms, 1000.0 * stats.time)
        push!(allocs_kb, stats.bytes / 1024.0)
    end
    (median_ms=round(_median_sorted(times_ms); digits=2),
     median_kb=round(_median_sorted(allocs_kb); digits=1))
end

function main(args::Vector{String})
    record_path = nothing
    baseline_path = nothing
    i = 1
    while i <= length(args)
        if args[i] == "--record-baseline" && i < length(args)
            record_path = args[i + 1]; i += 2
        elseif args[i] == "--baseline" && i < length(args)
            baseline_path = args[i + 1]; i += 2
        else
            error("Unknown or incomplete argument: $(args[i])")
        end
    end

    datasets = build_datasets()
    configs = OrderedDict(
        "nb_glm"    => DifferentialConfig(; method="nb_glm"),
        "clr_welch" => DifferentialConfig(; method="clr_welch"),
        "ancom_bc"  => DifferentialConfig(; method="ancom_bc"),
        "aldex2"    => DifferentialConfig(; method="aldex2", mc_samples=128),
        "songbird"  => DifferentialConfig(; method="songbird"),
    )

    recorded = OrderedDict{String,Any}()
    println("| Dataset | Method | Median runtime (ms) | Julia allocations (KiB) | Ratio vs clr_welch |")
    println("|---|---|---:|---:|---:|")

    for (dname, ds) in datasets
        recorded[dname] = OrderedDict{String,Any}()
        clr_metrics = measure(ds, configs["clr_welch"])
        for (mname, cfg) in configs
            met = mname == "clr_welch" ? clr_metrics : measure(ds, cfg)
            recorded[dname][mname] = OrderedDict(
                "median_ms" => met.median_ms,
                "median_kb" => met.median_kb,
            )
            ratio = round(met.median_ms / max(clr_metrics.median_ms, 0.01); digits=2)
            println("| $dname | $mname | $(met.median_ms) | $(met.median_kb) | $(ratio)x |")
        end
    end

    if !isnothing(record_path)
        YAML.write_file(record_path, recorded)
        println("\nWrote baseline metrics to $record_path")
    end

    if !isnothing(baseline_path)
        base = YAML.load_file(baseline_path)
        failures = String[]
        for (dname, _) in datasets, mname in ("nb_glm", "clr_welch")
            b_ms = Float64(base[dname][mname]["median_ms"])
            c_ms = Float64(recorded[dname][mname]["median_ms"])
            if c_ms > REGRESSION_THRESHOLD * b_ms
                push!(failures, "$dname/$mname regressed: $(c_ms) ms > $(round(REGRESSION_THRESHOLD * b_ms; digits=2)) ms (10% gate over $b_ms ms)")
            end
        end
        if !isempty(failures)
            error("Benchmark regression gate failed:\n  " * join(failures, "\n  "))
        end
        println("\n10% regression gate passed for existing methods (nb_glm, clr_welch).")
    end
end

abspath(PROGRAM_FILE) == @__FILE__ && main(ARGS)
