# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Native differential abundance: the `aldex2` and `ancombc` methods, fitted by
# CompositionalDA and adapted into result rows by `differential_abundance`.
#
# The reference values are the output of the R packages ALDEx2 and ANCOMBC on
# the same counts, kept in `test/fixtures/native_da/` and produced by the
# script beside them (`generate_reference.R`, R 4.5.0, ALDEx2 1.42.0, ANCOMBC
# 2.12.0). R is not run here: the fixtures are plain CSV.
#
# Tolerances, and why:
#
# ALDEx2 draws Dirichlet instances, so two correct runs differ by Monte Carlo
# error even with the same seed and a different random stream. The fixture
# holds the mean of 25 R runs (128 instances each, seeds 1001 to 1025) and, for
# each value, the range of those 25 runs. A native run must lie within one such
# range of the R mean. For 25 draws the range is about four standard
# deviations, so a correct native run passes by a wide margin (the largest
# observed deviation is 0.6 of a range) while a wrong estimator, for example a
# changed prior or the wrong contrast, does not. P-values are compared as
# log10, floored at 1e-10.
#
# The Wilcoxon p-values of taxon11 are not compared. That taxon is absent from
# every sample of one group; ALDEx2 reports an expected Wilcoxon p-value below
# 1e-10 for it, where the package reports 1.55e-4, the smallest p-value that
# exact ranks of 8 against 8 can give. The Welch values for the same taxon are
# compared.
#
# ANCOM-BC is deterministic, but the package and the R function do not share
# code or a stopping rule (tolerance 1e-7 and 1e-5), and their standard errors
# differ slightly in how the bias variance is added. Observed on the fixture:
# the largest effect difference is 0.011 and the largest standard error
# difference 0.0096, so the tolerance is 0.02 on both. The Wald statistic is
# the effect over the standard error, so it inherits both: it is compared to
# within 10 percent of its R value plus 0.15, which is the effect difference
# over a typical standard error of 0.13 (the largest observed difference is
# 7 percent of a large statistic, or 0.12 of a small one). The BH decision at
# 0.05 must be the same.
# P-values are not compared directly: the two differ by up to two orders of
# magnitude where p is below 1e-15, which is the same statistic difference seen
# through the normal tail.

using MetaManifold, Test
using JSON3, Random, CSV, DataFrames
using MetaManifold.Differential

const NATIVE_FIXTURES = joinpath(@__DIR__, "..", "fixtures", "native_da")

const NATIVE_INPUT = CSV.read(joinpath(NATIVE_FIXTURES, "counts.csv"), DataFrame)
const NATIVE_SAMPLES = String.(NATIVE_INPUT.sample)
const NATIVE_TAXA = names(NATIVE_INPUT)[3:end]
const NATIVE_COUNTS = Matrix{Int}(NATIVE_INPUT[:, 3:end])
const NATIVE_GROUPS = String.(NATIVE_INPUT.group)

const ALDEX_REFERENCE = CSV.read(joinpath(NATIVE_FIXTURES, "aldex2_reference.csv"), DataFrame)
const ANCOMBC_REFERENCE = CSV.read(joinpath(NATIVE_FIXTURES, "ancombc_reference.csv"), DataFrame)

const P_FLOOR = 1e-10
_log10p(p) = log10(max(p, P_FLOOR))
_rows_by_taxon(result) = Dict(String(r["taxon"]) => r for r in result["rows"])

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

@testset "Native input boundaries" begin
    config = DifferentialConfig(; method="aldex2", mc_samples=16, seed=19)
    for T in (BigInt, Float64)
        oversized = T.(NATIVE_COUNTS)
        oversized[1, 1] = T(big(typemax(Int)) + 1)
        @test_throws ArgumentError differential_abundance(oversized, NATIVE_SAMPLES, NATIVE_TAXA,
            NATIVE_GROUPS; reference="A", contrast="B", config)
    end
    @test_throws ArgumentError DifferentialConfig(; method="aldex2", mc_samples=1)
    @test_throws ArgumentError DifferentialConfig(; method="aldex2", seed=-1)
    @test_throws ArgumentError DifferentialConfig(; method="ancombc", dispersion="glmGamPoi")

    one_taxon = [10 0; 12 0; 9 0; 40 0; 42 0; 38 0]
    for method in ("aldex2", "ancombc")
        err = try
            differential_abundance(one_taxon, ["s$i" for i in 1:6], ["a", "b"],
                ["z", "z", "z", "a", "a", "a"]; reference="z", contrast="a",
                config=DifferentialConfig(; method))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("at least two retained taxa", sprint(showerror, err))
    end
end

@testset "Native ALDEx2 agrees with the R package" begin
    config = DifferentialConfig(; method="aldex2", mc_samples=128, seed=1)
    actual = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
        reference="A", contrast="B", config)
    rows = _rows_by_taxon(actual)
    @test length(rows) == length(NATIVE_TAXA)

    # (row key, R column, compared as log10 of a p-value)
    columns = [("estimate", "diff.btw", false), ("aldex_diff_within", "diff.win", false),
               ("aldex_effect", "effect", false), ("aldex_abundance", "rab.all", false),
               ("pvalue", "we.ep", true), ("padj", "we.eBH", true),
               ("wilcoxon_pvalue", "wi.ep", true), ("wilcoxon_padj", "wi.eBH", true)]
    for ref in eachrow(ALDEX_REFERENCE)
        row = rows[ref.feature]
        @test row["status"] == "ok"
        for (key, rcol, is_p) in columns
            startswith(rcol, "wi.") && ref.feature == "taxon11" && continue
            native = is_p ? _log10p(row[key]) : row[key]
            reference = is_p ? ref[Symbol("log10_" * rcol)] : ref[Symbol(rcol)]
            spread = ref[Symbol((is_p ? "log10_" : "") * rcol * "_range")]
            # A range of zero means every R run agreed to the last digit, so a
            # small absolute allowance stands in for it.
            @test abs(native - reference) <= max(spread, 1e-6)
        end
    end

    # The same decisions as R: which taxa differ at 0.05 on the expected BH.
    r_decisions = Dict(f => 10.0^q < 0.05 for (f, q) in
                       zip(ALDEX_REFERENCE.feature, ALDEX_REFERENCE[!, "log10_we.eBH"]))
    @test Dict(t => r["padj"] < 0.05 for (t, r) in rows) == r_decisions

    @test actual["effect"]["key"] == "estimate"
    @test occursin("ALDEx2", actual["method"])
    @test occursin("128 Dirichlet instances", actual["method"])
    @test actual["config"]["method"] == "aldex2"
    @test actual["config"]["mc_samples"] == 128
    @test actual["config"]["seed"] == 1
    @test actual["diagnostics"]["native_method"]["package"] == "CompositionalDA"
    @test actual["diagnostics"]["native_method"]["parameters"]["mc_samples"] == 128
    @test actual["diagnostics"]["n_tested"] == length(NATIVE_TAXA)
    @test isempty(actual["size_factors"])
    for row in values(rows)
        @test row["log2_fold_change"] === nothing
        @test row["standard_error"] === nothing
        @test row["statistic"] === nothing
    end

    # The result follows the direction the user asked for, not the sort order of
    # the group names: swapping reference and contrast negates the effect.
    swapped = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
        reference="B", contrast="A", config)
    swapped_rows = _rows_by_taxon(swapped)
    for taxon in NATIVE_TAXA
        @test abs(swapped_rows[taxon]["estimate"] + rows[taxon]["estimate"]) <=
              max(ALDEX_REFERENCE[ALDEX_REFERENCE.feature .== taxon, "diff.btw_range"][1], 1e-6)
    end

    # Same seed, same numbers.
    again = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
        reference="A", contrast="B", config)
    @test _rows_by_taxon(again) == rows
end

@testset "Native ANCOM-BC agrees with the R package" begin
    config = DifferentialConfig(; method="ancombc")
    actual = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
        reference="A", contrast="B", config)
    rows = _rows_by_taxon(actual)
    @test length(rows) == length(NATIVE_TAXA)

    for ref in eachrow(ANCOMBC_REFERENCE)
        row = rows[ref.feature]
        if ref.zero_A || ref.zero_B
            # Both implementations decide this taxon is structurally absent from
            # one group. The package reports the decision and no number: R
            # prints an effect and a p-value of exactly zero, which are not
            # tests.
            @test row["status"] == "structural_zero"
            @test row["pvalue"] === nothing
            @test row["padj"] === nothing
            @test row["estimate"] === nothing
            @test occursin("one condition", row["note"])
            continue
        end
        @test row["status"] == "ok"
        @test abs(row["estimate"] - ref.beta) <= 0.02
        @test abs(row["standard_error"] - ref.se) <= 0.02
        @test abs(row["statistic"] - ref.w) <= 0.10 * abs(ref.w) + 0.15
        @test (row["padj"] < 0.05) == (ref.q < 0.05)
        # The package reports natural-log effects; the row also carries log2.
        @test row["log2_fold_change"] ≈ row["estimate"] / log(2)
    end

    @test actual["effect"]["key"] == "log2_fold_change"
    @test occursin("ANCOM-BC", actual["method"])
    @test actual["diagnostics"]["native_method"]["package"] == "CompositionalDA"
    @test actual["diagnostics"]["n_structural_zero"] == 1
    @test actual["diagnostics"]["n_tested"] == length(NATIVE_TAXA) - 1
end

@testset "Native refusals are values, and every other failure goes through" begin
    SV = MetaManifold.Server
    body(response) = JSON3.read(String(response.body))

    # Only four taxa, one of them a structural decision: fewer than four remain
    # for the bias estimate, and the package refuses the composition. That is an
    # answer about the data, so it is returned as a value with the package's own
    # words, and the route reports it as 422.
    few = NATIVE_TAXA[[1, 4, 7, 11]]
    columns = [findfirst(==(t), NATIVE_TAXA) for t in few]
    refused = differential_abundance(NATIVE_COUNTS[:, columns], NATIVE_SAMPLES, few,
        NATIVE_GROUPS; reference="A", contrast="B", config=DifferentialConfig(; method="ancombc"))
    @test refused isa NoTaxonFitted
    @test occursin("fewer than four", refused.reason)
    response = SV._differential_outcome(() -> refused)
    @test response.status == 422
    @test body(response).error == "no_taxon_fitted"

    # An error that is not the package's refusal of the data is not a refusal.
    @test_throws ErrorException SV._differential_outcome(() -> error("a broken backend"))
    @test_throws MethodError SV._differential_outcome(() -> sqrt(nothing))
end

@testset "ANCOM-BC decisions without a numerical test are still a result" begin
    # Taxa 11 (absent from group A) and a taxon absent from group B, with
    # enough other taxa for the bias estimate.
    counts = copy(NATIVE_COUNTS)
    counts[NATIVE_GROUPS .== "B", 12] .= 0
    result = differential_abundance(counts, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
        reference="A", contrast="B", config=DifferentialConfig(; method="ancombc"))
    rows = _rows_by_taxon(result)
    @test rows["taxon11"]["status"] == "structural_zero"
    @test rows["taxon12"]["status"] == "structural_zero"
    @test result["diagnostics"]["n_structural_zero"] == 2
    @test result["diagnostics"]["n_tested"] == length(NATIVE_TAXA) - 2

    # Present in neither group's samples after removing the groups' counts:
    # a taxon absent from both groups is not retained at all.
    counts[:, 12] .= 0
    both = differential_abundance(counts, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
        reference="A", contrast="B", config=DifferentialConfig(; method="ancombc"))
    @test _rows_by_taxon(both)["taxon12"]["status"] != "ok"
end
