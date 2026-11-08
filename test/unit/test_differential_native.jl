# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Native (CompositionalDA-backed) differential abundance. The configuration
# boundary fuzz and the refusals run everywhere; the adapter comparisons against
# the package run only where it is loadable.
#
# CompositionalDA is not in the General registry yet, so it is not a declared
# dependency (`Project.toml` records why) and `Pkg.instantiate()` does not
# install it: on such a checkout `compositional_da_available()` is false, the two
# native methods refuse by name, and the adapter tests below skip loudly.
# `Pkg.develop(path="/…/CompositionalDA.jl")` in a scratch environment activates
# them.

using MetaManifold, Test
using Random
using MetaManifold.Differential

# "Not installed" is an ArgumentError. Any other failure while loading the
# package (a broken install, say) is a real problem and must not read as a skip.
const HAVE_COMPOSITIONAL_DA = try
    @eval import CompositionalDA
    true
catch err
    err isa ArgumentError || err isa LoadError || rethrow()
    false
end
HAVE_COMPOSITIONAL_DA || @info "CompositionalDA unavailable - the native adapter tests are SKIPPED"

# The module's own probe must agree with the one above, or the refusal path and
# the tests disagree about what is installed.
@test HAVE_COMPOSITIONAL_DA == compositional_da_available()

@testset "Native configuration boundary fuzz" begin
    rng = MersenneTwister(23)
    SV = MetaManifold.Server
    for _ in 1:256
        mc = rand(rng,-128:4352)
        seed = rand(rng,(-1,0,1,17,Int64(typemax(Int32)),Int64(typemax(Int32))+1))
        @test isnothing(SV._config_value_error("analysis.differential.mc_samples",mc)) == (2 <= mc <= 4096)
        @test isnothing(SV._config_value_error("analysis.differential.seed",seed)) == (0 <= seed <= typemax(Int32))
        if 2 <= mc <= 4096 && 0 <= seed <= typemax(Int32)
            config = DifferentialConfig(;method="aldex2",mc_samples=mc,seed)
            @test config.mc_samples == mc && config.seed == seed
        else
            @test_throws ArgumentError DifferentialConfig(;method="aldex2",mc_samples=mc,seed)
        end
    end
    for invalid in (NaN,Inf,-Inf,nothing,missing,[],Dict(),true,false,"128",2.5)
        @test !isnothing(SV._config_value_error("analysis.differential.mc_samples",invalid))
        @test !isnothing(SV._config_value_error("analysis.differential.seed",invalid))
    end
end

# samples x taxa, two groups, four taxa: a valid input for both native methods.
const NATIVE_COUNTS = [10 20 30 8; 12 21 27 9; 9 18 31 7; 40 19 29 8; 42 20 30 9; 38 22 28 7]
const NATIVE_SAMPLES = ["s$i" for i in 1:6]
const NATIVE_TAXA = ["a", "b", "c", "d"]
# Reverse lexical order is deliberate: the user's reference is authoritative.
const NATIVE_GROUPS = ["z", "z", "z", "a", "a", "a"]

@testset "Native input boundaries do not depend on the package" begin
    config = DifferentialConfig(; method="aldex2", mc_samples=16, seed=19)
    # The oversize refusal is an input error raised before the dependency probe,
    # so it is reachable whether or not CompositionalDA is installed.
    for T in (BigInt, Float64)
        oversized = T.(NATIVE_COUNTS)
        oversized[1, 1] = T(big(typemax(Int)) + 1)
        @test_throws ArgumentError differential_abundance(oversized, NATIVE_SAMPLES, NATIVE_TAXA,
            NATIVE_GROUPS; reference="z", contrast="a", config)
    end
    @test_throws ArgumentError DifferentialConfig(; method="aldex2", mc_samples=1)
    @test_throws ArgumentError DifferentialConfig(; method="aldex2", seed=-1)
    @test_throws ArgumentError DifferentialConfig(; method="ancombc", dispersion="glmGamPoi")
end

@testset "Native methods refuse by name when the package is absent" begin
    if HAVE_COMPOSITIONAL_DA
        @test_skip false    # the adapter tests below cover the available case
    else
        for method in ("aldex2", "ancombc")
            config = DifferentialConfig(; method)
            err = try
                differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA,
                    NATIVE_GROUPS; reference="z", contrast="a", config)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("CompositionalDA", sprint(showerror, err))
            @test occursin(method, sprint(showerror, err))
            # The message has to point at what does work, not just refuse.
            @test occursin("nb_glm", sprint(showerror, err))
        end
    end
end

@testset "Native compositional DA adapter" begin
    if !HAVE_COMPOSITIONAL_DA
        @test_skip false
    else
        counts = NATIVE_COUNTS
        samples = NATIVE_SAMPLES
        taxa = NATIVE_TAXA
        groups = NATIVE_GROUPS
        config = DifferentialConfig(; method="aldex2", mc_samples=16, seed=19)
        actual = differential_abundance(counts, samples, taxa, groups;
            reference="z", contrast="a", config)
        expected = CompositionalDA.aldex2(counts, taxa, ["0", "0", "0", "1", "1", "1"];
            mc_samples=16, seed=19)
        for row in actual["rows"]
            i = findfirst(==(row["taxon"]), expected.table.feature)
            @test row["estimate"] == expected.table.diff_btw[i]
            @test row["pvalue"] == expected.table.pvalue[i]
            @test row["padj"] == expected.table.qvalue[i]
            @test row["log2_fold_change"] === nothing
            @test row["aldex_effect"] == expected.table.effect[i]
            @test row["aldex_diff_within"] == expected.table.diff_win[i]
            @test row["aldex_abundance"] == expected.table.rab_all[i]
            @test row["wilcoxon_pvalue"] == expected.table.wi_pvalue[i]
            @test row["wilcoxon_padj"] == expected.table.wi_qvalue[i]
        end
        @test actual["config"]["seed"] == 19
        @test actual["config"]["mc_samples"] == 16
        @test isempty(actual["size_factors"])
        @test actual["groups"]["reference"] == "z"
        @test actual["diagnostics"]["native_method"]["package"] == "CompositionalDA"
    end
end

@testset "ANCOM-BC adapter preserves units and structural decisions" begin
    if !HAVE_COMPOSITIONAL_DA
        @test_skip false
    else
        rng = MersenneTwister(2026)
        counts = round.(Int, permutedims(collect(range(1000, 5000; length=40))) .*
            exp.(0.25 .* randn(rng, 20, 40)))
        counts[11:20, 1:3] .*= 8
        counts[11:20, 4:5] .= max.(1, counts[11:20, 4:5] .÷ 4)
        counts = hcat(counts, vcat(zeros(Int, 10), fill(200, 10)), zeros(Int, 20))
        taxa = vcat(["f$j" for j in 1:40], ["structural", "all_zero"])
        groups = vcat(fill("z", 10), fill("a", 10))
        actual = differential_abundance(counts, ["s$i" for i in 1:20], taxa, groups;
            reference="z", contrast="a", config=DifferentialConfig(; method="ancombc"))
        expected = CompositionalDA.ancombc(counts, taxa, vcat(fill("0", 10), fill("1", 10));
            prevalence=0.0, structural_zeros=true)
        by_taxon = Dict(row["taxon"] => row for row in actual["rows"])
        for i in 1:40
            row = by_taxon[taxa[i]]
            @test row["estimate"] == expected.table.effect[i]
            @test row["log2_fold_change"] == expected.table.effect[i] / log(2)
            @test row["standard_error"] == expected.table.se[i]
            @test row["padj"] == expected.table.qvalue[i]
        end
        @test by_taxon["structural"]["status"] == "structural_zero"
        @test by_taxon["structural"]["pvalue"] === nothing
        @test by_taxon["structural"]["padj"] === nothing
        @test by_taxon["all_zero"]["status"] == "filtered"
        @test actual["diagnostics"]["n_structural_zero"] == 1
        @test actual["diagnostics"]["n_filtered"] == 1
        @test actual["diagnostics"]["n_tested"] == 40
    end
end
