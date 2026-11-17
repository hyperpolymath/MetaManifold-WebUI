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
using JSON3, Random
using MetaManifold.Differential

# Whether the environment has the package is asked of the loader, not inferred
# from an import that failed: a failed import cannot tell a package that is not
# there from one that is there and broken. Where the environment has it, the
# import below must succeed, so a broken install fails this file instead of
# reading as a skip.
const HAVE_COMPOSITIONAL_DA = Base.identify_package("CompositionalDA") !== nothing
HAVE_COMPOSITIONAL_DA && @eval import CompositionalDA
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

## The adapter, exercised against a stand-in backend
#
# The two testsets above run only where CompositionalDA is installed, and CI
# cannot install it: the package is not in the General registry. Without the
# testsets below, nothing in CI runs the adapter that turns a DAResult into
# result rows, or the branch that keeps BH from being applied twice.
#
# `differential_abundance(...; native_backend=…)` makes the adapter reachable
# without changing what production does (the default is still the CompositionalDA
# of this environment, or the refusal when it has none). The stand-in in
# `test/support/native_da_stub.jl` offers the real package's entry points,
# columns and verdict strings, so what runs below is the code that runs in
# production; only the estimator behind the boundary is a stand-in, and the
# result names it under `diagnostics.native_method.package`.

@testset "The native backend seam selects the module, and defaults to the package" begin
    @test MetaManifold.Differential._native_backend(NativeDAStub) === NativeDAStub
    @test isnothing(MetaManifold.Differential._native_backend(nothing)) == !HAVE_COMPOSITIONAL_DA
    # An available backend satisfies the guard; an absent one refuses by name.
    @test isnothing(MetaManifold.Differential._native_methods_available("aldex2", NativeDAStub))
    err = try
        MetaManifold.Differential._native_methods_available("ancombc", nothing)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("CompositionalDA", sprint(showerror, err))
end

@testset "Native ALDEx2 rows are wired from the backend's own columns" begin
    NativeDAStub.reset!()
    config = DifferentialConfig(; method="aldex2", mc_samples=32, seed=7)
    actual = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
        reference="z", contrast="a", config, native_backend=NativeDAStub)

    call = NativeDAStub.last_call()
    @test call.method === :aldex2
    @test call.settings[:mc_samples] == 32
    @test call.settings[:seed] == 7
    # The user's groups are relabelled "0"/"1" in the requested direction, so the
    # package's sorted contrast is the contrast the user asked for even though
    # the reference ("z") sorts after the contrast ("a").
    @test call.groups == ["0", "0", "0", "1", "1", "1"]
    @test call.features == NATIVE_TAXA
    @test size(call.counts) == size(NATIVE_COUNTS)
    @test eltype(call.counts) <: Integer

    rows = Dict(String(r["taxon"]) => r for r in actual["rows"])
    @test length(rows) == length(NATIVE_TAXA)
    for (j, taxon) in enumerate(NATIVE_TAXA)
        row = rows[taxon]
        @test row["status"] == "ok"
        @test row["note"] == ""
        @test row["estimate"] == 0.5 * j                 # diff_btw
        @test row["aldex_effect"] == 0.25 * j            # effect
        @test row["aldex_diff_within"] == 0.125 * j      # diff_win
        @test row["aldex_abundance"] == 1.0 * j          # rab_all
        @test row["wilcoxon_pvalue"] == 0.0075 * j       # wi_pvalue
        @test row["wilcoxon_padj"] == 0.00375 * j        # wi_qvalue
        @test row["pvalue"] == 0.01 * j
        # ALDEx2 averages BH within each posterior instance. Applying BH a second
        # time to its expected p-values would implement a different method, so
        # padj is the package's qvalue even where BH would disagree.
        @test row["padj"] == 0.005 * j
        @test row["log2_fold_change"] === nothing
        @test row["standard_error"] === nothing
        @test row["statistic"] === nothing
    end
    @test [rows[t]["padj"] for t in NATIVE_TAXA] != bh_adjust([0.01 * j for j in 1:4])
    @test actual["effect"]["key"] == "estimate"
    @test occursin("ALDEx2", actual["method"])
    @test occursin("32 Dirichlet instances", actual["method"])
    @test isempty(actual["size_factors"])
    @test actual["config"]["method"] == "aldex2"
    @test actual["config"]["mc_samples"] == 32
    @test actual["config"]["seed"] == 7
    @test actual["diagnostics"]["native_method"]["package"] == "NativeDAStub"
    @test actual["diagnostics"]["native_method"]["version"] == "0.0.0-stub"
    @test actual["diagnostics"]["native_method"]["parameters"]["mc_samples"] == 32
    @test actual["diagnostics"]["n_structural_zero"] == 0
    @test actual["diagnostics"]["n_tested"] == 4

    # A feature the caller has no row for is skipped, not invented.
    NativeDAStub.reset!()
    NativeDAStub.EXTRA_FEATURE[] = true
    extra = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
        reference="z", contrast="a", config, native_backend=NativeDAStub)
    @test length(extra["rows"]) == length(NATIVE_TAXA)
    @test !any(r -> String(r["taxon"]) == "not_requested", extra["rows"])
    NativeDAStub.reset!()
end

@testset "Native ANCOM-BC keeps units and reports structural decisions separately" begin
    NativeDAStub.reset!()
    samples = ["s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8"]
    taxa = ["spike", "flat", "structural", "half", "structural_both", "absent"]
    groups = ["z", "z", "z", "z", "a", "a", "a", "a"]
    counts = [10 50 0  8   3 0;
              10 50 0  8   3 0;
              10 50 0  9   4 0;
              13 50 0  7   4 0;
              80 50 9  9   3 0;
              80 50 9  8   3 0;
              83 50 8  9   4 0;
              77 50 8  8   3 0]
    config = DifferentialConfig(; method="ancombc")
    actual = differential_abundance(counts, samples, taxa, groups;
        reference="z", contrast="a", config, native_backend=NativeDAStub)

    call = NativeDAStub.last_call()
    @test call.method === :ancombc
    @test call.settings[:prevalence] == 0.0
    @test call.settings[:structural_zeros] === true
    @test call.settings[:conserve] === true
    # "absent" has no reads at all: it is filtered before the backend is called.
    @test call.features == ["spike", "flat", "structural", "half", "structural_both"]
    @test call.groups == ["0", "0", "0", "0", "1", "1", "1", "1"]

    rows = Dict(String(r["taxon"]) => r for r in actual["rows"])
    @test rows["absent"]["status"] == "filtered"
    @test isnothing(rows["absent"]["pvalue"])

    for (j, taxon) in enumerate(call.features)
        row = rows[taxon]
        if row["status"] == "structural_zero"
            @test isnothing(row["estimate"])
            @test isnothing(row["pvalue"])
            @test isnothing(row["padj"])
            continue
        end
        @test row["status"] == "ok"
        @test row["estimate"] == log(2) * j / 2
        @test row["log2_fold_change"] ≈ j / 2
        @test row["standard_error"] == 0.1 * j
        @test row["statistic"] == (log(2) * j / 2) / (0.1 * j)
        @test row["pvalue"] == 0.02 * j
        @test row["padj"] == 0.005 * j
    end

    # Structural absences are decisions, not tests: named as such, and carrying
    # no stand-in p-value.
    @test rows["structural"]["status"] == "structural_zero"
    @test occursin("one condition", rows["structural"]["note"])
    @test rows["structural_both"]["status"] == "structural_zero"
    @test occursin("both conditions", rows["structural_both"]["note"])
    @test actual["diagnostics"]["n_structural_zero"] == 2
    @test actual["diagnostics"]["n_filtered"] == 1
    @test actual["diagnostics"]["n_tested"] == 3   # spike, flat, half
    @test actual["effect"]["key"] == "log2_fold_change"
    @test occursin("ANCOM-BC", actual["method"])
    @test actual["config"]["method"] == "ancombc"
    # ALDEx2's sampling settings have no meaning here and must not be echoed.
    @test !haskey(actual["config"], "mc_samples")
    @test actual["diagnostics"]["native_method"]["package"] == "NativeDAStub"
    @test actual["diagnostics"]["native_method"]["parameters"]["structural_zeros"] === true
    NativeDAStub.reset!()
end

@testset "Native refusals happen in the right order, whatever the backend" begin
    # Input problems are refused before the backend is consulted, so a malformed
    # matrix gets the same answer on a machine with the package and without it.
    one_taxon = [10 0; 12 0; 9 0; 40 0; 42 0; 38 0]
    for method in ("aldex2", "ancombc")
        config = DifferentialConfig(; method)
        err = try
            differential_abundance(one_taxon, NATIVE_SAMPLES, ["a", "b"], NATIVE_GROUPS;
                reference="z", contrast="a", config, native_backend=NativeDAStub)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("at least two retained taxa", sprint(showerror, err))
    end
    @test isempty(NativeDAStub.CALLS)

    config = DifferentialConfig(; method="aldex2")

    run_stub() = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
        reference="z", contrast="a", config, native_backend=NativeDAStub)
    SV = MetaManifold.Server
    body(response) = JSON3.read(String(response.body))

    # The package's own refusal is an answer about the data. It is returned as
    # a value carrying the package's message, and the route reports that value
    # as 422 no_taxon_fitted.
    NativeDAStub.reset!()
    NativeDAStub.FAILURE[] = :composition
    refused = run_stub()
    @test refused isa NoTaxonFitted
    @test refused.reason == "CompositionError: stub refused the composition"
    response = SV._differential_outcome(run_stub)
    @test response.status == 422
    @test body(response).error == "no_taxon_fitted"
    @test body(response).message == refused.reason

    # Any other failure is the backend's own and is rethrown untouched: a broken
    # backend must not be dressed up as a refusal of the data. The stand-in
    # raises a plain ErrorException, the type the route used to report as 422
    # whoever raised it. It now leaves the route as the exception it is, for
    # the server to report as a fault.
    NativeDAStub.reset!()
    NativeDAStub.FAILURE[] = :other
    for call in (run_stub, () -> SV._differential_outcome(run_stub))
        err = try
            call()
        catch e
            e
        end
        @test err isa ErrorException
        @test err.msg == "stub backend failed for a reason of its own"
    end

    # A statistic that is not finite is refused by name rather than published.
    NativeDAStub.reset!()
    NativeDAStub.FAILURE[] = :nonfinite
    refused = run_stub()
    @test refused isa NoTaxonFitted
    @test occursin("non-finite statistics", refused.reason)
    @test occursin("aldex2", refused.reason)
    @test SV._differential_outcome(run_stub).status == 422
    NativeDAStub.reset!()
end

@testset "The route declines by type and lets every other failure through" begin
    SV = MetaManifold.Server
    D = MetaManifold.Differential
    outcome(f) = SV._differential_outcome(f)
    body(response) = JSON3.read(String(response.body))

    # A result passes through unchanged; it is the same object, not a copy.
    result = Dict{String,Any}("status" => "ok", "rows" => Any[])
    @test outcome(() -> result) === result

    # The comparison's own answer that there is nothing to report.
    response = outcome(() -> NoTaxonFitted("no taxon could be fitted: constant"))
    @test response.status == 422
    @test body(response).error == "no_taxon_fitted"
    @test body(response).message == "no taxon could be fitted: constant"

    # The refusals that have a type of their own keep their status and code.
    for (raised, status, code) in (
            (ArgumentError("bad input"), 400, "invalid_input"),
            (ScalingRefusal("tss", "a sample has no reads"), 422, "scaling_refused"),
            (MASSUnavailable(), 503, "r_unavailable"),
            (ZCompositionsUnavailable(), 503, "r_unavailable"),
            (GlmGamPoiUnavailable(), 503, "r_unavailable"))
        response = outcome(() -> throw(raised))
        @test response.status == status
        @test body(response).error == code
        @test body(response).message == sprint(showerror, raised)
    end

    # Nothing else is a refusal. An ErrorException, whatever its message, is not
    # reported as "no taxon fitted", and neither is a package that failed to
    # load or any other exception: each leaves the route as itself.
    for raised in (ErrorException("no taxon could be fitted: looks like a refusal"),
                   ErrorException("backend failed"),
                   D.NativeBackendLoadError("CompositionalDA", ErrorException("broken checkout")),
                   BoundsError([1], 2), KeyError(:missing), InterruptException())
        err = try
            outcome(() -> throw(raised))
        catch e
            e
        end
        @test err === raised
    end
end

@testset "ANCOM-BC decisions without a numerical test are still a result" begin
    # Every retained taxon belongs to one condition only, so each is a
    # structural-zero decision and none has a p-value. Those decisions are what
    # the comparison found; they are returned, not discarded for want of a test.
    NativeDAStub.reset!()
    counts = [10 12 0 0; 9 14 0 0; 11 13 0 0; 0 0 20 25; 0 0 22 24; 0 0 21 26]
    taxa = ["only_z1", "only_z2", "only_a1", "only_a2"]
    compare() = differential_abundance(counts, NATIVE_SAMPLES, taxa, NATIVE_GROUPS;
        reference="z", contrast="a", config=DifferentialConfig(; method="ancombc"),
        native_backend=NativeDAStub)
    actual = compare()
    @test actual isa Dict
    @test actual["status"] == "ok"
    @test length(actual["rows"]) == 4
    for row in actual["rows"]
        @test row["status"] == "structural_zero"
        @test occursin("one condition", row["note"])
        for key in ("estimate", "log2_fold_change", "standard_error", "statistic", "pvalue", "padj")
            @test row[key] === nothing
        end
    end
    # With nothing to rank by, the rows are in taxon order.
    @test [row["taxon"] for row in actual["rows"]] == sort(taxa)
    @test actual["diagnostics"]["n_structural_zero"] == 4
    @test actual["diagnostics"]["n_tested"] == 0
    @test actual["diagnostics"]["n_failed"] == 0
    @test actual["diagnostics"]["n_taxa"] == 4
    # No taxon has a point to plot; the figure is empty, not an error.
    @test isempty(volcano_chart(actual)["data"])
    # The route returns the same result.
    @test MetaManifold.Server._differential_outcome(compare) isa Dict

    # One taxon in both conditions has a test, and joins the decisions.
    mixed = hcat(counts, [5, 6, 7, 8, 9, 10])
    actual = differential_abundance(mixed, NATIVE_SAMPLES, vcat(taxa, "shared"), NATIVE_GROUPS;
        reference="z", contrast="a", config=DifferentialConfig(; method="ancombc"),
        native_backend=NativeDAStub)
    @test actual["diagnostics"]["n_structural_zero"] == 4
    @test actual["diagnostics"]["n_tested"] == 1
    @test first(actual["rows"])["taxon"] == "shared"   # the one row with a padj sorts first

    # ALDEx2 has no structural decisions, so a comparison with no finite
    # statistic is still declined: the exemption is for decisions, not for any
    # empty family.
    NativeDAStub.reset!()
    NativeDAStub.FAILURE[] = :nonfinite
    declined = differential_abundance(counts, NATIVE_SAMPLES, taxa, NATIVE_GROUPS;
        reference="z", contrast="a", config=DifferentialConfig(; method="aldex2"),
        native_backend=NativeDAStub)
    @test declined isa NoTaxonFitted
    NativeDAStub.reset!()
end

@testset "The native package is looked up when it is needed, never remembered" begin
    D = MetaManifold.Differential
    # Nothing about the package is fixed when the module is loaded: there is no
    # constant holding the answer for a precompile cache or a system image to
    # freeze. This is what makes a package added after a system image was built
    # visible to it.
    @test !isdefined(D, :_COMPOSITIONAL_DA_AVAILABLE)
    @test !isdefined(D, :_DEFAULT_NATIVE_BACKEND)
    @test D.NATIVE_PACKAGE == "CompositionalDA"

    # The environment either has the package or it does not, and both the
    # module and this file ask the loader the same question.
    @test (D._native_package() !== nothing) == HAVE_COMPOSITIONAL_DA
    @test compositional_da_available() == HAVE_COMPOSITIONAL_DA
    @test isnothing(D._load_native_backend(nothing))
    # Installed means there is a source to load. A package the environment
    # names but has not installed counts as not installed; one it has is found.
    @test isnothing(D._installed(nothing))
    @test isnothing(D._installed(
        Base.PkgId(Base.UUID("00000000-0000-4000-8000-000000000070"), "MMNamedButNotInstalled")))
    dataframes = Base.PkgId(MetaManifold.Differential.DataFrames)
    @test D._installed(dataframes) === dataframes

    @test D.NATIVE_ENTRY_POINTS == (:aldex2, :ancombc, :CompositionError)
    @test isempty(D._missing_entry_points(NativeDAStub))
    @test D._missing_entry_points(Base) == ["aldex2", "ancombc", "CompositionError"]

    mktempdir() do root
        # Packages the loader can find by name: one that loads and can be
        # called, one whose source raises while loading, one whose source does
        # not parse, and one that loads but is not something the adapter can
        # call.
        write_package(name, source) = (mkpath(joinpath(root, name, "src"));
            write(joinpath(root, name, "src", "$name.jl"), source))
        write_package("MMFreshNativeDA", """
            module MMFreshNativeDA
            using DataFrames
            struct CompositionError <: Exception
                msg::String
            end
            Base.showerror(io::IO, e::CompositionError) = print(io, "CompositionError: ", e.msg)
            function aldex2(counts, features, groups; mc_samples=128, seed=1)
                seed == 99 && throw(CompositionError("fresh package refused the composition"))
                n = length(features)
                p = [0.01 * j for j in 1:n]
                (table = DataFrame(feature=String.(features), effect=fill(0.5, n), pvalue=p,
                     qvalue=p, wi_pvalue=p, wi_qvalue=p, diff_btw=fill(1.0, n),
                     diff_win=fill(0.25, n), rab_all=fill(2.0, n)),
                 provenance = (package_version = v"0.0.0-fresh",
                               parameters = Dict{Symbol,Any}(:seed => seed)))
            end
            ancombc(args...; kwargs...) = throw(CompositionError("not used by this test"))
            end
            """)
        write_package("MMBrokenNativeDA", """
            module MMBrokenNativeDA
            aldex2() = nothing
            error("this checkout is incompatible")
            end
            """)
        write_package("MMUnparsableNativeDA", "module MMUnparsableNativeDA\nfunction (\nend\n")
        write_package("MMIncompleteNativeDA", """
            module MMIncompleteNativeDA
            struct CompositionError <: Exception end
            aldex2(args...; kwargs...) = nothing
            end
            """)
        push!(LOAD_PATH, root)
        try
            fresh = Base.identify_package("MMFreshNativeDA")
            broken = Base.identify_package("MMBrokenNativeDA")
            unparsable = Base.identify_package("MMUnparsableNativeDA")
            incomplete = Base.identify_package("MMIncompleteNativeDA")
            @test all(!isnothing, (fresh, broken, unparsable, incomplete))
            @test Base.identify_package("MMAbsentNativeDA") === nothing

            # A package that is there and cannot be used is a fault with a type
            # of its own. It is not `nothing`, so it can never be reported as
            # "not installed", whatever the loader raised underneath. It is
            # asked for three times: a source that raises part-way can leave a
            # half-built module behind, which a later request must not accept.
            for pkg in (broken, unparsable, incomplete), attempt in 1:3
                err = try
                    D._load_native_backend(pkg)
                catch e
                    e
                end
                @test err isa D.NativeBackendLoadError
                @test err.package == pkg.name
                @test err.cause isa Exception
                message = sprint(showerror, err)
                @test occursin("is installed in this environment but could not be loaded", message)
                @test occursin(pkg.name, message)
                @test !occursin("not installed", message)
            end
            # The module that loaded without one of the adapter's entry points
            # says which is missing.
            @test occursin("does not define ancombc",
                sprint(showerror, try D._load_native_backend(incomplete) catch e; e end))
            # The same fault reaches the caller of the comparison, and leaves
            # the route as itself: not a refusal, and not a missing package.
            for pkg in (broken, unparsable, incomplete)
                compare() = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA,
                    NATIVE_GROUPS; reference="z", contrast="a",
                    config=DifferentialConfig(; method="aldex2"), native_backend=pkg)
                @test_throws D.NativeBackendLoadError compare()
                @test_throws D.NativeBackendLoadError MetaManifold.Server._differential_outcome(compare)
            end

            # A package this session has never loaded is loaded inside the call
            # that needs it, and its functions are called in that same call.
            # This is a server's first native request.
            @test !haskey(Base.loaded_modules, fresh)
            actual = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
                reference="z", contrast="a",
                config=DifferentialConfig(; method="aldex2", mc_samples=16, seed=7),
                native_backend=fresh)
            @test haskey(Base.loaded_modules, fresh)
            @test actual["diagnostics"]["native_method"]["package"] == "MMFreshNativeDA"
            @test actual["diagnostics"]["native_method"]["version"] == "0.0.0-fresh"
            @test actual["diagnostics"]["n_tested"] == 4
            @test all(row -> row["estimate"] == 1.0, actual["rows"])
            # Its own refusal type, defined by the load a moment ago, is
            # recognised too.
            refused = differential_abundance(NATIVE_COUNTS, NATIVE_SAMPLES, NATIVE_TAXA, NATIVE_GROUPS;
                reference="z", contrast="a",
                config=DifferentialConfig(; method="aldex2", mc_samples=16, seed=99),
                native_backend=fresh)
            @test refused isa NoTaxonFitted
            @test refused.reason == "CompositionError: fresh package refused the composition"
            # Asking again finds the module already loaded: the same one.
            @test D._load_native_backend(fresh) === D._native_backend(fresh)
            @test D._native_backend(fresh) === Base.loaded_modules[fresh]
        finally
            filter!(!=(root), LOAD_PATH)
        end
    end
end
