# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# SPDX-License-Identifier: AGPL-3.0-or-later

using MetaManifold, Test
using Random
import CompositionalDA
using MetaManifold.Differential

@testset "Native compositional DA adapter" begin
    counts = [10 20 30 8; 12 21 27 9; 9 18 31 7; 40 19 29 8; 42 20 30 9; 38 22 28 7]
    samples = ["s$i" for i in 1:6]
    taxa = ["a", "b", "c", "d"]
    # Reverse lexical order is deliberate: the user's reference is authoritative.
    groups = ["z", "z", "z", "a", "a", "a"]
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
    end
    @test actual["config"]["seed"] == 19
    @test actual["config"]["mc_samples"] == 16
    @test isempty(actual["size_factors"])
    @test actual["groups"]["reference"] == "z"
    @test_throws ArgumentError DifferentialConfig(; method="aldex2", mc_samples=1)
    @test_throws ArgumentError DifferentialConfig(; method="aldex2", seed=-1)
    @test_throws ArgumentError DifferentialConfig(; method="ancombc", dispersion="glmGamPoi")
end

@testset "ANCOM-BC adapter preserves units and structural decisions" begin
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
