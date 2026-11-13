# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# SPDX-License-Identifier: MPL-2.0

# The native aldex2 method of `differential_abundance`: the adapter around
# CompositionalDA.aldex2, checked against direct calls to the package. The
# package is a declared dependency, so a missing install fails the run at the
# `import` below; nothing here skips when it is absent.

using MetaManifold, Test
import CompositionalDA
using MetaManifold.Differential

# samples x taxa, two groups, four taxa.
const NATIVE_COUNTS = [10 20 30 8; 12 21 27 9; 9 18 31 7; 40 19 29 8; 42 20 30 9; 38 22 28 7]
const NATIVE_SAMPLES = ["s$i" for i in 1:6]
const NATIVE_TAXA = ["a", "b", "c", "d"]
# Reverse lexical order is deliberate: the user's reference is authoritative.
const NATIVE_GROUPS = ["z", "z", "z", "a", "a", "a"]

# The exception, if any, that `f` throws.
function _thrown(f)
    try
        f()
        nothing
    catch e
        e
    end
end

@testset "Native aldex2 input boundaries" begin
    config = DifferentialConfig(; method="aldex2", mc_samples=16, seed=19)
    # Counts that do not fit Int are an input error, not an overflow.
    for T in (BigInt, Float64)
        oversized = T.(NATIVE_COUNTS)
        oversized[1, 1] = T(big(typemax(Int)) + 1)
        @test_throws ArgumentError differential_abundance(oversized, NATIVE_SAMPLES, NATIVE_TAXA,
            NATIVE_GROUPS; reference="z", contrast="a", config)
    end
    # Fewer than two retained taxa are refused by name.
    one_taxon = [10 0; 12 0; 9 0; 40 0; 42 0; 38 0]
    err = _thrown(() -> differential_abundance(one_taxon, NATIVE_SAMPLES, ["a", "b"],
        NATIVE_GROUPS; reference="z", contrast="a", config))
    @test err isa ArgumentError
    @test occursin("at least two retained taxa", sprint(showerror, err))
    # A sample with no reads is left out and named, not fitted.
    with_empty = vcat(NATIVE_COUNTS, zeros(Int, 1, 4))
    result = differential_abundance(with_empty, vcat(NATIVE_SAMPLES, "blank"), NATIVE_TAXA,
        vcat(NATIVE_GROUPS, "a"); reference="z", contrast="a", config)
    @test result["diagnostics"]["samples_without_reads"] == ["blank"]
end

@testset "Native aldex2 refusals" begin
    config = DifferentialConfig(; method="aldex2", mc_samples=16, seed=19)
    # The package's own refusal (here, one sample in a group) is unusable input:
    # an ArgumentError carrying its message, which the route reports as a 400.
    err = _thrown(() -> differential_abundance(NATIVE_COUNTS[1:4, :], NATIVE_SAMPLES[1:4], NATIVE_TAXA,
        ["z", "z", "z", "a"]; reference="z", contrast="a", config))
    @test err isa ArgumentError
    @test occursin("CompositionError: each group needs at least two samples", sprint(showerror, err))
end

@testset "Native aldex2 adapter matches the package" begin
    config = DifferentialConfig(; method="aldex2", mc_samples=16, seed=19)
    actual = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
        reference="z", contrast="a", config)
    # The user's groups are relabelled "0"/"1" in the requested direction, so the
    # package's sorted contrast is the one the user asked for even though the
    # reference ("z") sorts after the contrast ("a").
    expected = CompositionalDA.aldex2(NATIVE_COUNTS, NATIVE_TAXA, ["0", "0", "0", "1", "1", "1"];
        mc_samples=16, seed=19)
    @test length(actual["rows"]) == length(NATIVE_TAXA)
    for row in actual["rows"]
        i = findfirst(==(row["taxon"]), expected.table.feature)
        @test row["status"] == "ok"
        @test row["estimate"] == expected.table.diff_btw[i]
        @test row["pvalue"] == expected.table.pvalue[i]
        # ALDEx2 averages BH within each posterior instance; applying BH again
        # to the expected p-values would be a different method, so padj is the
        # package's own qvalue.
        @test row["padj"] == expected.table.qvalue[i]
        @test row["log2_fold_change"] === nothing
        @test row["standard_error"] === nothing
        @test row["statistic"] === nothing
        @test row["aldex_effect"] == expected.table.effect[i]
        @test row["aldex_diff_within"] == expected.table.diff_win[i]
        @test row["aldex_abundance"] == expected.table.rab_all[i]
        @test row["wilcoxon_pvalue"] == expected.table.wi_pvalue[i]
        @test row["wilcoxon_padj"] == expected.table.wi_qvalue[i]
    end
    @test actual["effect"]["key"] == "estimate"
    @test occursin("ALDEx2", actual["method"])
    @test occursin("16 Dirichlet instances", actual["method"])
    @test actual["config"]["method"] == "aldex2"
    @test actual["config"]["mc_samples"] == 16
    @test actual["config"]["seed"] == 19
    @test isempty(actual["size_factors"])
    @test actual["groups"]["reference"] == "z"
    native = actual["diagnostics"]["native_method"]
    @test native["package"] == "CompositionalDA"
    @test native["version"] == string(pkgversion(CompositionalDA))
    @test native["parameters"]["mc_samples"] == 16
    @test native["seed"] == 19

    # The sign follows the requested direction: swapping reference and contrast
    # swaps the groups the package sees, and flips the between-group difference.
    flipped = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
        reference="a", contrast="z", config)
    by_taxon(r) = Dict(row["taxon"] => row["estimate"] for row in r["rows"])
    forward, backward = by_taxon(actual), by_taxon(flipped)
    for taxon in NATIVE_TAXA
        @test sign(forward[taxon]) == -sign(backward[taxon])
    end
end

@testset "Native aldex2 is reproducible for a seed" begin
    run(seed) = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
        reference="z", contrast="a",
        config=DifferentialConfig(; method="aldex2", mc_samples=16, seed))["rows"]
    @test run(5) == run(5)
    @test run(5) != run(6)
end
