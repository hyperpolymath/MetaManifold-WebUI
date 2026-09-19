# SPDX-License-Identifier: AGPL-3.0-only
"""
    Benchmark for AnalysisConfig layer

Ensures runtime and memory regression <10% vs baseline.

Measures:
- Config creation + validation
- JSON serialization roundtrip
- DOI bundle creation
- Epistemic validation (present_in_every_admissible_world)
- CladeCumulus tree building

Fail CI on >10% regression.
"""

using BenchmarkTools
using OrderedCollections
using MetaManifold.AnalysisConfig
using MetaManifold.Epistemic
using MetaManifold.CladeCumulus
using Statistics

const SUITE = BenchmarkGroup()

SUITE["config_creation"] = @benchmarkable begin
    norm = AnalysisConfig.NormalizationConfig(method="size_factors")
    cfg = AnalysisConfig.AnalysisConfigStruct(
        method="nb_glm",
        formula="~ group + batch",
        metadata_columns=["group", "batch", "age"],
        normalization=norm,
        created_by="benchmark"
    )
end

SUITE["config_validation"] = @benchmarkable begin
    norm = AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5)
    cfg = AnalysisConfig.AnalysisConfigStruct(
        method="clr_lm",
        formula="~ group",
        metadata_columns=["group"],
        normalization=norm,
    )
    AnalysisConfig.validate_config(cfg, ["group", "batch"]; strict=false)
end

SUITE["json_roundtrip"] = @benchmarkable begin
    norm = AnalysisConfig.NormalizationConfig(method="size_factors")
    cfg = AnalysisConfig.AnalysisConfigStruct(
        method="nb_glm",
        formula="~ group",
        metadata_columns=["group"],
        normalization=norm,
    )
    json = AnalysisConfig.to_json(cfg)
    AnalysisConfig.from_json(json)
end

SUITE["doi_bundle"] = @benchmarkable begin
    norm = AnalysisConfig.NormalizationConfig(method="size_factors")
    cfg = AnalysisConfig.AnalysisConfigStruct(
        method="nb_glm",
        formula="~ group",
        metadata_columns=["group"],
        normalization=norm,
    )
    result = AnalysisConfig.AnalysisResult(
        config_id=cfg.id,
        config_hash=cfg.hash,
        method=cfg.method,
        results=OrderedDict{String,Any}("taxon1" => OrderedDict("p" => 0.01))
    )
    mktempdir() do tmp
        AnalysisConfig.create_doi_bundle(cfg, result, joinpath(tmp, "bundle"); authors=["Bench"], title="Bench")
    end
end

SUITE["epistemic_present_in_every"] = @benchmarkable begin
    c1 = Epistemic.Candidate{Tuple{Int,Int},Int}((1,1), true, true)
    c2 = Epistemic.Candidate{Tuple{Int,Int},Int}((2,0), true, true)
    case_bounded = Epistemic.Case{Tuple{Int,Int},Int}(c1, [c1, c2])
    Epistemic.present_in_every_admissible_world(case_bounded, world -> world[1] != 0)
end

SUITE["clade_tree_build"] = @benchmarkable begin
    rows = [
        Dict{String,Any}("Domain" => "Bacteria", "Phylum" => "Firmicutes", "Genus" => "Lacto$(i)", "total" => Float64(10+i), "avec_fibre" => true, "epistemic_status" => "present_in_every_admissible_world", "residual_count" => i % 5)
        for i in 1:100
    ]
    tree = CladeCumulus.build_clade_tree(rows)
    CladeCumulus.cumulative_frequencies(tree)
end

# Run and check regression
function run_benchmarks(; baseline_path::String=joinpath(@__DIR__, "baseline.json"))
    results = run(SUITE, verbose=true)

    # Save current as new baseline if no baseline exists
    if !isfile(baseline_path)
        BenchmarkTools.save(baseline_path, results)
        println("No baseline found, saved current as baseline at $baseline_path")
        return results
    end

    baseline = BenchmarkTools.load(baseline_path)[1]

    # Compare, fail on >10% regression in time or memory
    for (key, trial) in results
        if haskey(baseline, key)
            base_trial = baseline[key]
            # Median time comparison
            curr_time = BenchmarkTools.prettytime(BenchmarkTools.median(trial).time)
            base_time = BenchmarkTools.prettytime(BenchmarkTools.median(base_trial).time)

            # Ratio
            time_ratio = BenchmarkTools.median(trial).time / BenchmarkTools.median(base_trial).time
            mem_ratio = BenchmarkTools.median(trial).memory / max(1, BenchmarkTools.median(base_trial).memory)

            println("$key: time ratio $(round(time_ratio, digits=3)) (baseline $base_time vs current $curr_time), memory ratio $(round(mem_ratio, digits=3))")

            if time_ratio > 1.10
                error("Benchmark regression >10% in time for $key: ratio $time_ratio (threshold 1.10)")
            end
            if mem_ratio > 1.10
                error("Benchmark regression >10% in memory for $key: ratio $mem_ratio")
            end
        end
    end

    println("All benchmarks within 10% regression threshold — OK")
    return results
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_benchmarks()
end
