# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Differential abundance: Benjamini-Hochberg, TSS/RLE size factors, input
# validation, the negative-binomial fit checked against a direct MASS::glm.nb
# call, and clr_welch checked against direct zCompositions::cmultRepl and Welch
# t.test calls. Tests needing R, MASS or zCompositions skip loudly when absent.

using MetaManifold
using MetaManifold.Differential
using RCall
using Test
using DuckDB, DBInterface, JSON3, HTTP, YAML
using OrderedCollections: OrderedDict

"""
    _r_has(pkg) -> Bool

Whether the embedded R session starts and can load `pkg`. Probed directly,
not through `Server.r_available`, which also requires vegan.
"""
function _r_has(pkg::AbstractString)
    try
        rcopy(RCall.reval("requireNamespace('$pkg', quietly = TRUE)"))
    catch
        false
    end
end

const HAVE_R = _r_has("stats")
const HAVE_MASS = HAVE_R && _r_has("MASS")
HAVE_MASS || @info "R or MASS unavailable - the negative-binomial fit tests are SKIPPED"
const HAVE_GLMGAMPOI = HAVE_MASS && _r_has("glmGamPoi")
HAVE_GLMGAMPOI || @info "R, MASS or glmGamPoi unavailable - the shrunken-dispersion fit tests are SKIPPED"
const HAVE_ZCOMP = HAVE_R && _r_has("zCompositions")
HAVE_ZCOMP || @info "R or zCompositions unavailable - the clr_welch tests are SKIPPED"

# The multinomial models are a submodule of MetaManifold and need no R, so
# these tests run everywhere.
const CM = MetaManifold.CompositionalModels

# Rows per run: Up is split over two ASVs so the route must pool them by genus.
const _DA_ROWS = Dict(
    "runA" => [("s1", "Up", [3, 5, 4, 4]), ("s2", "Up", [2, 3, 2, 3]),
               ("s3", "Flat", [30, 25, 35, 28]), ("s4", "Down", [50, 60, 45, 55])],
    "runB" => [("s1", "Up", [20, 30, 20, 30]), ("s2", "Up", [20, 25, 15, 30]),
               ("s3", "Flat", [27, 33, 29, 31]), ("s4", "Down", [6, 4, 9, 5])])

"""
    _da_make_run(root, study, run)

Write `<root>/projects/<study>/<run>/merged/results.duckdb` with four samples
named after the run, plus the data-side run directory the route guards need.
"""
function _da_make_run(root::String, study::String, run::String)
    data_run = joinpath(root, "data", study, run)
    mkpath(data_run)
    samples = ["$(run)_$i" for i in 1:4]
    for s in samples, d in ("R1", "R2")
        touch(joinpath(data_run, "$(s)_$d.fastq.gz"))
    end
    write(joinpath(data_run, "pipeline.yml"), "analysis:\n  exclude_categories: []\n")
    merge_dir = joinpath(root, "projects", study, run, "merged")
    mkpath(merge_dir)
    db = DuckDB.DB(joinpath(merge_dir, "results.duckdb"))
    con = DBInterface.connect(db)
    try
        cols = join(["\"$s\" BIGINT" for s in samples], ", ")
        DBInterface.execute(con, """CREATE TABLE merged ("SeqName" VARCHAR, "sequence" VARCHAR,
                                    "Domain" VARCHAR, "Genus" VARCHAR, $cols)""")
        for (seq, genus, n) in _DA_ROWS[run]
            DBInterface.execute(con, "INSERT INTO merged VALUES ('$seq', 'ACGT', 'Eukaryota', '$genus', $(join(n, ", ")))")
        end
    finally
        DBInterface.close!(con); close(db)
    end
end

"""
    _da_fixture(f)

Run `f()` with the server root pointed at a temporary study `studyD` holding
runs `runA` and `runB`, restoring the previous root afterwards.
"""
function _da_fixture(f::Function)
    SV = MetaManifold.Server
    root = mktempdir()
    old_root = SV.ServerState._root[]
    try
        SV.ServerState.set_root!(root)
        mkpath(joinpath(root, "config"))
        _da_make_run(root, "studyD", "runA")
        _da_make_run(root, "studyD", "runB")
        f()
    finally
        SV.ServerState._root[] = old_root
        rm(root; recursive=true, force=true)
    end
end

"""
    _da_post(study, body) -> HTTP.Response

POST `body` to the study's differential route through Oxygen's in-process router.
"""
function _da_post(study::String, body)
    SV = MetaManifold.Server
    req = SV.HTTP.Request("POST", "/api/v1/studies/$study/analysis/differential",
                          ["Content-Type" => "application/json"], JSON3.write(body))
    SV.Oxygen.internalrequest(req)
end

@testset "Differential abundance" begin

    @testset "BH adjustment: known answers" begin
        @test bh_adjust([0.01, 0.02, 0.03, 0.04]) ≈ fill(0.04, 4)
        @test bh_adjust([0.001, 0.5, 0.5]) ≈ [0.003, 0.5, 0.5]
        # Order of the input is preserved, monotonicity enforced by the step-up.
        @test bh_adjust([0.04, 0.01]) ≈ [0.04, 0.02]
        @test bh_adjust([1.0]) == [1.0]
        @test isempty(bh_adjust(Float64[]))
        @test_throws ArgumentError bh_adjust([0.1, NaN])
        @test_throws ArgumentError bh_adjust([1.4])
        @test_throws ArgumentError bh_adjust([-0.2])
    end

    @testset "BH adjustment: parity with R p.adjust" begin
        if !HAVE_R
            @info "R unavailable - p.adjust parity SKIPPED"
            @test_skip false
        else
            p = [0.001, 0.5, 0.5, 0.02, 0.7, 0.04, 0.0009, 0.31]
            ref = rcopy(R"p.adjust($p, method = 'BH')")
            @test maximum(abs.(bh_adjust(p) .- ref)) < 1e-12
        end
    end

    # samples x taxa
    fixture = [10 20 30; 20 20 60; 40 10 50]
    samples = ["s1", "s2", "s3"]

    @testset "TSS size factors" begin
        f = tss_factors(fixture, samples)
        @test f ≈ [0.711378660898012, 1.185631101496687, 1.185631101496687] rtol=1e-12
        @test exp(sum(log.(f)) / 3) ≈ 1.0
        @test tss_factors(7.5 .* fixture, samples) ≈ f
        e = try tss_factors([1 2; 0 0], ["a", "empty"]); nothing catch err; err end
        @test e isa ScalingRefusal
        @test occursin("empty", sprint(showerror, e))
    end

    @testset "RLE size factors" begin
        f = rle_factors(fixture, samples)
        @test f ≈ [0.683132584572384, 1.285704749170459, 1.13855430762064] rtol=1e-12
        raw = [0.6694329500821695, 1.259921049894873, 1.1157215834702825]
        @test f ./ f[1] ≈ raw ./ raw[1]
        @test exp(sum(log.(f)) / 3) ≈ 1.0
        @test rle_factors(7.5 .* fixture, samples) ≈ f
        doubled = copy(fixture); doubled[2, :] .*= 2
        g = rle_factors(doubled, samples)
        @test (g[2] / g[1]) ≈ 2 * (f[2] / f[1])
        e = try rle_factors([1 2; 0 0], ["a", "b"]); nothing catch err; err end
        @test e isa ScalingRefusal
        @test occursin("geometric mean", sprint(showerror, e))
        @test size_factors(fixture, samples, "rle") == f
        @test_throws ArgumentError size_factors(fixture, samples, "css")
    end

    @testset "Configuration" begin
        @test DifferentialConfig().offset == "tss"
        @test DifferentialConfig().min_prevalence == 0.0
        @test DifferentialConfig("rle", 0.5).offset == "rle"
        @test_throws ArgumentError DifferentialConfig("css")
        @test_throws ArgumentError DifferentialConfig("tss", 1.5)
        @test_throws ArgumentError DifferentialConfig("tss", NaN)
        @test DifferentialConfig().method == "nb_glm"
        @test DifferentialConfig().replacement_delta == 0.65
        @test DifferentialConfig().replacement_method == "bayesian_multiplicative"
        @test isnothing(DifferentialConfig().bayesian_alpha)
        @test DifferentialConfig(; method="clr_welch", replacement_delta=0.3).replacement_delta == 0.3
        @test DifferentialConfig(method="clr_welch",
            replacement_method=" MULTIPLICATIVE_REPLACEMENT ").replacement_method == "multiplicative_replacement"
        @test DifferentialConfig(method="clr_welch", bayesian_alpha=2.5).bayesian_alpha == 2.5
        @test_throws ArgumentError DifferentialConfig(replacement_method="pseudocount")
        for alpha in (0, -1, NaN, Inf, true)
            @test_throws ArgumentError DifferentialConfig(method="clr_welch", bayesian_alpha=alpha)
        end
        @test_throws ArgumentError DifferentialConfig(; method="ancombc")
        # The pre-review name, never released, is not accepted.
        @test_throws ArgumentError DifferentialConfig(; method="clr_lm")
        # The dispersion option: ml is the default, glmGamPoi is the alternative,
        # and it is a negative-binomial setting only.
        @test DifferentialConfig().dispersion == "ml"
        @test DifferentialConfig(dispersion="glmGamPoi").dispersion == "glmGamPoi"
        @test DifferentialConfig(dispersion="  GLMGAMPOI ").dispersion == "glmGamPoi"
        @test_throws ArgumentError DifferentialConfig(dispersion="shrinkage")
        @test_throws ArgumentError DifferentialConfig(method="clr_welch", dispersion="glmGamPoi")
        @test DifferentialConfig(method="clr_welch").dispersion == "ml"
        for d in (0, 1, -0.5, NaN, Inf)
            @test_throws ArgumentError DifferentialConfig(; method="clr_welch", replacement_delta=d)
        end
        @test occursin("underflow", only(MetaManifold.Differential._delta_warnings(0.005)))
        @test occursin("substantial mass", only(MetaManifold.Differential._delta_warnings(0.9)))
        @test isempty(MetaManifold.Differential._delta_warnings(0.65))
        @test_throws ArgumentError replace_zeros([0 1; 2 3]; frac=0)
        @test_throws ArgumentError replace_zeros([0 1; 2 3]; frac=1)
        @test_throws ArgumentError replace_zeros([0 1; 2 3]; alpha=0)
        @test_throws ArgumentError replace_zeros([0 1; 2 3]; method="pseudocount")
    end

    @testset "Input validation" begin
        taxa = ["a", "b", "c"]
        groups = ["A", "A", "B"]
        kw = (reference="A", contrast="B")
        @test_throws ArgumentError validate_counts([1.5 2 3; 1 2 3; 1 2 3], samples, taxa)
        @test_throws ArgumentError validate_counts([-1 2 3; 1 2 3; 1 2 3], samples, taxa)
        msg = try validate_counts([1 2 3; 1 2.5 3; 1 2 3], samples, taxa); "" catch e; e.msg end
        @test occursin("'b'", msg) && occursin("'s2'", msg)
        @test_throws ArgumentError differential_abundance(fixture, samples, taxa, groups;
                                                         reference="A", contrast="A")
        @test_throws ArgumentError differential_abundance(fixture, samples, taxa, ["A", "B", "C"]; kw...)
        @test_throws ArgumentError differential_abundance(fixture, samples, taxa, ["A", "A", "A"]; kw...)
        @test_throws ArgumentError differential_abundance(fixture[1:2, :], samples[1:2], taxa, ["A", "B"]; kw...)
        @test_throws ArgumentError differential_abundance(fixture, samples, String[], groups; kw...)
        @test_throws ArgumentError differential_abundance(Float64.(fixture) .+ 0.5, samples, taxa, groups; kw...)
    end

    # taxa x samples as written, transposed to samples x taxa.
    effect_groups = vcat(fill("A", 12), fill("B", 12))
    effect_samples = ["s$i" for i in 1:24]
    effect_taxa = ["t_up", "t_flat", "t_down"]
    effect = permutedims(Int.(
        [7 17 1 12 10 3 15 14 6 11 15 9 52 18 40 57 25 58 8 43 65 31 47 36;
         32 18 44 6 43 27 39 14 30 49 23 35 14 35 27 49 6 32 44 23 43 30 18 39;
         81 50 22 65 39 71 59 10 45 73 54 31 4 8 8 2 6 1 5 9 1 7 3 6]))

    @testset "Negative-binomial fit recovers an injected effect" begin
        if !HAVE_MASS
            @test_skip false
        else
            res = differential_abundance(effect, effect_samples, effect_taxa, effect_groups;
                                         reference="A", contrast="B")
            byt = Dict(r["taxon"] => r for r in res["rows"])
            @test res["status"] == "ok"
            @test res["method"] == "Negative-binomial GLM per taxon (MASS::glm.nb, log link) with a " *
                                   "TSS size-factor offset; Wald test of the group coefficient; " *
                                   "Benjamini-Hochberg adjustment over the fitted taxa"
            @test res["diagnostics"]["n_tested"] == 3
            @test all(r -> r["status"] == "ok", res["rows"])
            @test isapprox(byt["t_up"]["estimate"], log(4); atol=0.5)
            @test isapprox(byt["t_up"]["log2_fold_change"], 2; atol=0.8)
            @test byt["t_up"]["pvalue"] < 0.01
            @test byt["t_down"]["estimate"] < 0
            @test abs(byt["t_flat"]["estimate"]) < 0.6
            @test [byt[t]["padj"] for t in effect_taxa] ≈
                  bh_adjust([byt[t]["pvalue"] for t in effect_taxa])
            # Swapping the reference flips the sign.
            swapped = differential_abundance(effect, effect_samples, effect_taxa, effect_groups;
                                             reference="B", contrast="A")
            sb = Dict(r["taxon"] => r for r in swapped["rows"])
            @test sb["t_up"]["estimate"] ≈ -byt["t_up"]["estimate"] rtol=1e-6

            @testset "matches a direct MASS::glm.nb call" begin
                off = log.(tss_factors(effect, effect_samples))
                for (j, t) in enumerate(effect_taxa)
                    y = effect[:, j]
                    g = effect_groups
                    direct = rcopy(R"""
                        local({
                          fit <- MASS::glm.nb($y ~ factor($g, levels = c("A", "B")) + offset($off),
                                              control = glm.control(maxit = 100))
                          co <- summary(fit)$coefficients[2, ]
                          c(co[[1]], co[[2]], co[[4]], fit$theta)
                        })
                    """)
                    r = byt[t]
                    @test r["estimate"] ≈ direct[1] rtol=1e-6
                    @test r["standard_error"] ≈ direct[2] rtol=1e-6
                    @test r["pvalue"] ≈ direct[3] rtol=1e-6
                    @test r["dispersion_theta"] ≈ direct[4] rtol=1e-6
                end
            end
        end
    end

    @testset "glmGamPoi matches a direct negative-binomial GLM with fixed dispersion" begin
        if !HAVE_GLMGAMPOI
            @test get(ENV, "CI", "false") != "true" # the pinned dependency is required in CI
            @test_skip false
        else
            res = differential_abundance(effect, effect_samples, effect_taxa, effect_groups;
                                         reference="A", contrast="B",
                                         config=DifferentialConfig(dispersion="glmGamPoi"))
            @test res["status"] == "ok"
            @test res["method"] == "Negative-binomial GLM per taxon (MASS::negative.binomial " *
                                   "with dispersion trend from glmGamPoi::glm_gp, log link) with a " *
                                   "TSS size-factor offset; Wald test of the group coefficient; " *
                                   "Benjamini-Hochberg adjustment over the fitted taxa"
            byt = Dict(r["taxon"] => r for r in res["rows"])
            off = log.(tss_factors(effect, effect_samples))
            g = effect_groups
            phi = rcopy(R"""
                local({
                  gp <- glmGamPoi::glm_gp(t($effect),
                          design = model.matrix(~ factor($g, levels = c("A", "B"))),
                          size_factors = exp($off), overdispersion_shrinkage = TRUE)
                  as.numeric(gp$overdispersion_shrinkage_list$dispersion_trend)
                })
            """)
            for (j, t) in enumerate(effect_taxa)
                y = effect[:, j]
                theta = 1 / phi[j]
                direct = rcopy(R"""
                    local({
                      fit <- glm($y ~ factor($g, levels = c("A", "B")) + offset($off),
                                 family = MASS::negative.binomial(theta = $theta),
                                 control = glm.control(maxit = 100))
                      unname(summary(fit, dispersion = 1)$coefficients[2, ])
                    })
                """)
                r = byt[t]
                @test r["status"] == "ok"
                @test r["estimate"] ≈ direct[1] rtol=1e-6
                @test r["standard_error"] ≈ direct[2] rtol=1e-6
                @test r["statistic"] ≈ direct[3] rtol=1e-6
                @test r["pvalue"] ≈ direct[4] rtol=1e-6
                @test r["dispersion_theta"] ≈ theta rtol=1e-6
            end
        end
    end

    @testset "glmGamPoi dispersion parity on two additional count scales" begin
        if !HAVE_GLMGAMPOI
            @test_skip false
        else
            # Together with the unscaled fixture above, these are three
            # independent end-to-end comparisons against the R reference.
            for counts in (2 .* effect, 3 .* effect)
                off = log.(tss_factors(counts, effect_samples))
                rows = fit_nb(counts, effect_groups, off; levels=("A", "B"), dispersion="glmGamPoi")
                g = effect_groups
                phi = rcopy(R"""
                    local({
                      gp <- glmGamPoi::glm_gp(t($counts),
                              design = model.matrix(~ factor($g, levels = c("A", "B"))),
                              size_factors = exp($off), overdispersion_shrinkage = TRUE)
                      as.numeric(gp$overdispersion_shrinkage_list$dispersion_trend)
                    })
                """)
                for j in axes(counts, 2)
                    y = counts[:, j]
                    theta = 1 / phi[j]
                    direct = rcopy(R"""
                        local({
                          fit <- glm($y ~ factor($g, levels = c("A", "B")) + offset($off),
                                     family = MASS::negative.binomial(theta = $theta),
                                     control = glm.control(maxit = 100))
                          unname(summary(fit, dispersion = 1)$coefficients[2, ])
                        })
                    """)
                    @test rows.status[j] == "ok"
                    @test rows.estimate[j] ≈ direct[1] rtol=1e-6
                    @test rows.se[j] ≈ direct[2] rtol=1e-6
                    @test rows.statistic[j] ≈ direct[3] rtol=1e-6
                    @test rows.pvalue[j] ≈ direct[4] rtol=1e-6
                    @test rows.theta[j] ≈ theta rtol=1e-6
                end
            end
        end
    end

    @testset "glmGamPoi invalid trends are isolated per taxon" begin
        if !HAVE_GLMGAMPOI
            @test_skip false
        else
            MetaManifold.RRuntime.with_r_lock() do
                reval(raw"""
                    test_original_gp <- get("glm_gp", asNamespace("glmGamPoi"))
                    test_phi <- 0
                    assignInNamespace("glm_gp", function(...) {
                        fit <- test_original_gp(...)
                        fit$overdispersion_shrinkage_list$dispersion_trend[1] <- test_phi
                        fit
                    }, ns="glmGamPoi")
                """)
                try
                    off = log.(tss_factors(effect, effect_samples))
                    for (phi, status) in ((0.0, "boundary"), (-1.0, "failed"), (NaN, "failed"))
                        RCall.globalEnv[:test_phi] = phi
                        rows = fit_nb(effect, effect_groups, off; levels=("A", "B"), dispersion="glmGamPoi")
                        @test rows.status[1] == status
                        @test isnothing(rows.pvalue[1])
                        @test all(rows.status[2:end] .== "ok")
                    end
                finally
                    reval(raw"""
                        assignInNamespace("glm_gp", test_original_gp, ns="glmGamPoi")
                        rm(test_original_gp, test_phi)
                    """)
                end
            end
        end
    end

    @testset "Degenerate and filtered taxa are reported, not dropped" begin
        if !HAVE_MASS
            @test_skip false
        else
            counts = hcat(effect, fill(5, 24), vcat(fill(0, 20), [3, 0, 1, 0]))
            taxa = vcat(effect_taxa, ["t_const", "t_rare"])
            res = differential_abundance(counts, effect_samples, taxa, effect_groups;
                                         reference="A", contrast="B",
                                         config=DifferentialConfig("tss", 0.2))
            byt = Dict(r["taxon"] => r for r in res["rows"])
            @test length(res["rows"]) == 5
            @test res["status"] == "partial"
            c = byt["t_const"]
            @test c["status"] == "failed"
            @test occursin("constant", c["note"])
            @test all(isnothing, (c["estimate"], c["standard_error"], c["pvalue"], c["padj"]))
            r = byt["t_rare"]
            @test r["status"] == "filtered"
            @test occursin("min_prevalence", r["note"])
            @test isnothing(r["padj"])
            @test r["prevalence"] ≈ 2 / 24
            d = res["diagnostics"]
            @test (d["n_taxa"], d["n_tested"], d["n_failed"], d["n_filtered"]) == (5, 3, 1, 1)
            # The BH family is the three fitted taxa only.
            @test [byt[t]["padj"] for t in effect_taxa] ≈
                  bh_adjust([byt[t]["pvalue"] for t in effect_taxa])
            # Unfitted rows sort last.
            @test [x["taxon"] for x in res["rows"][4:5]] ⊆ ["t_const", "t_rare"]
        end
    end

    @testset "A taxon absent from one group is refused, not reported as p≈1" begin
        if !HAVE_MASS
            @test_skip false
        else
            # 'only_b' has no reads in any A sample: complete separation.
            only_b = vcat(fill(0, 12), [50, 80, 120, 30, 60, 90, 40, 70, 110, 55, 65, 85])
            counts = hcat(effect, only_b)
            taxa = vcat(effect_taxa, ["only_b"])
            res = differential_abundance(counts, effect_samples, taxa, effect_groups;
                                         reference="A", contrast="B")
            byt = Dict(r["taxon"] => r for r in res["rows"])
            s = byt["only_b"]
            @test s["status"] == "failed"
            @test occursin("'A'", s["note"]) && occursin("complete separation", s["note"])
            @test all(isnothing, (s["estimate"], s["standard_error"], s["pvalue"], s["padj"]))
            # The BH family is the three other taxa only.
            @test res["diagnostics"]["n_tested"] == 3
            @test [byt[t]["padj"] for t in effect_taxa] ≈
                  bh_adjust([byt[t]["pvalue"] for t in effect_taxa])

            # Control: the direct fit converges and reports p near 1, which is
            # the value the check above keeps out of the results.
            off = log.(tss_factors(counts, effect_samples))
            g = effect_groups
            direct = rcopy(R"""
                local({
                  fit <- MASS::glm.nb($only_b ~ factor($g, levels = c("A", "B")) + offset($off),
                                      control = glm.control(maxit = 100))
                  c(as.numeric(fit$converged), summary(fit)$coefficients[2, 4])
                })
            """)
            @test direct[1] == 1 && direct[2] > 0.9
        end
    end

    @testset "No fittable taxon is an explicit error" begin
        if !HAVE_MASS
            @test_skip false
        else
            e = try
                differential_abundance(fill(5, 4, 2), ["a", "b", "c", "d"], ["x", "y"],
                                       ["A", "A", "B", "B"]; reference="A", contrast="B")
                nothing
            catch err
                err
            end
            @test e isa ErrorException
            @test occursin("no taxon could be fitted", e.msg)
        end
    end

    @testset "Volcano chart" begin
        res = Dict{String,Any}(
            "groups" => Dict("reference" => "A", "contrast" => "B"),
            "rows" => [
                Dict{String,Any}("taxon" => "x", "log2_fold_change" => 2.0, "pvalue" => 1e-4, "padj" => 1e-3),
                Dict{String,Any}("taxon" => "y", "log2_fold_change" => -0.1, "pvalue" => 0.6, "padj" => 0.6),
                Dict{String,Any}("taxon" => "z", "log2_fold_change" => nothing, "pvalue" => nothing, "padj" => nothing),
            ])
        fig = volcano_chart(res)
        @test length(fig["data"]) == 2
        xs = reduce(vcat, [collect(t["x"]) for t in fig["data"]])
        @test sort(xs) == [-0.1, 2.0]
        @test occursin("B vs A", fig["layout"]["title"]["text"])
    end

    @testset "Config value checks" begin
        SV = MetaManifold.Server
        @test isnothing(SV._config_value_error("analysis.differential.offset", "rle"))
        @test !isnothing(SV._config_value_error("analysis.differential.offset", "css"))
        @test isnothing(SV._config_value_error("analysis.differential.min_prevalence", 0.1))
        @test isnothing(SV._config_value_error("analysis.differential.method", "clr_welch"))
        @test !isnothing(SV._config_value_error("analysis.differential.method", "ancombc"))
        for dispersion in ("ml", "glmGamPoi", " ML ", "  GLMGAMPOI ")
            @test isnothing(SV._config_value_error("analysis.differential.dispersion", dispersion))
        end
        for dispersion in ("shrinkage", "", nothing, 1, true, ["ml"])
            @test !isnothing(SV._config_value_error("analysis.differential.dispersion", dispersion))
        end
        for method in Differential.REPLACEMENT_METHODS
            @test isnothing(SV._config_value_error("analysis.differential.replacement_method", method))
            @test isnothing(SV._config_value_error("analysis.differential.replacement_method", "  $(uppercase(method)) "))
        end
        @test !isnothing(SV._config_value_error("analysis.differential.replacement_method", "pseudocount"))
        for delta in (0.01, 0.65, 0.99)
            @test isnothing(SV._config_value_error("analysis.differential.replacement_delta", delta))
        end
        for delta in (0, 1, -0.1, Inf, NaN, true, "0.65", nothing)
            @test !isnothing(SV._config_value_error("analysis.differential.replacement_delta", delta))
        end
        @test isnothing(SV._config_value_error("analysis.differential.bayesian_alpha", nothing))
        @test isnothing(SV._config_value_error("analysis.differential.bayesian_alpha", 0.5))
        for alpha in (0, -1, Inf, NaN, true, "1", [])
            @test !isnothing(SV._config_value_error("analysis.differential.bayesian_alpha", alpha))
        end
    end

    @testset "Config PATCH validates and records advanced zero handling" begin
        SV = MetaManifold.Server
        _da_fixture() do
            url = "/api/v1/studies/studyD/config"
            path = joinpath(SV.ServerState._root[], "data", "studyD", "pipeline.yml")
            response = SV.Oxygen.internalrequest(HTTP.Request("PATCH", url,
                ["Content-Type" => "application/json"], JSON3.write(Dict(
                    "analysis.differential.replacement_method" => " MULTIPLICATIVE_REPLACEMENT ",
                    "analysis.differential.replacement_delta" => 0.7,
                    "analysis.differential.bayesian_alpha" => 2.5))))
            @test response.status == 200
            body = JSON3.read(String(response.body))
            @test body["analysis.differential.replacement_method"].value == "multiplicative_replacement"
            saved = YAML.load_file(path)["analysis"]["differential"]
            @test saved["replacement_method"] == "multiplicative_replacement"
            @test saved["replacement_delta"] == 0.7 && saved["bayesian_alpha"] == 2.5

            response = SV.Oxygen.internalrequest(HTTP.Request("PATCH", url,
                ["Content-Type" => "application/json"], JSON3.write(Dict(
                    "analysis.differential.bayesian_alpha" => nothing))))
            @test response.status == 200
            @test YAML.load_file(path)["analysis"]["differential"]["bayesian_alpha"] === nothing

            before = read(path, String)
            for (key, value) in (("analysis.differential.replacement_delta", 0),
                                 ("analysis.differential.replacement_delta", 1),
                                 ("analysis.differential.bayesian_alpha", -1),
                                 ("analysis.differential.replacement_method", "pseudocount"))
                response = SV.Oxygen.internalrequest(HTTP.Request("PATCH", url,
                    ["Content-Type" => "application/json"], JSON3.write(Dict(key => value))))
                @test response.status == 400
                @test JSON3.read(String(response.body)).error == "invalid_config_value"
                @test read(path, String) == before
            end
        end
    end

    @testset "Config rejects incompatible effective dispersion pairs" begin
        SV = MetaManifold.Server
        keym, keyd = "analysis.differential.method", "analysis.differential.dispersion"
        @test SV._differential_pair_error(Dict(keym=>"clr_welch"), Dict(keyd=>"glmGamPoi")) !== nothing
        @test SV._differential_pair_error(Dict(keyd=>"glmGamPoi"), Dict(keym=>"clr_welch")) !== nothing
        @test SV._differential_pair_error(Dict(keym=>(; value="clr_welch",source="study")), Dict(keyd=>" GLMGAMPOI ")) !== nothing
        @test SV._differential_pair_error(Dict(keym=>"clr_welch"), Dict(keym=>"nb_glm",keyd=>"glmGamPoi")) === nothing
        @test SV._differential_pair_error(Dict(keyd=>"glmGamPoi"), Dict(keym=>"clr_welch",keyd=>"ml")) === nothing
        _da_fixture() do
            root = SV.ServerState._root[]
            path = joinpath(root,"data","studyD","pipeline.yml")
            write(path,"analysis:\n  differential:\n    method: clr_welch\n")
            before = read(path,String)
            response = SV.Oxygen.internalrequest(HTTP.Request("PATCH", "/api/v1/studies/studyD/config", ["Content-Type"=>"application/json"], JSON3.write(Dict(keyd=>"glmGamPoi"))))
            @test response.status == 400
            @test read(path,String) == before
            # A batch can change both options together, irrespective of key order.
            batch = Dict(keyd=>"glmGamPoi", keym=>"nb_glm")
            response = SV.Oxygen.internalrequest(HTTP.Request("PATCH", "/api/v1/studies/studyD/config", ["Content-Type"=>"application/json"], JSON3.write(batch)))
            @test response.status == 200
            before = read(path,String)
            response = SV.Oxygen.internalrequest(HTTP.Request("PATCH", "/api/v1/studies/studyD/config", ["Content-Type"=>"application/json"], JSON3.write(Dict(keym=>"clr_welch"))))
            @test response.status == 400
            @test read(path,String) == before
        end
    end

    @testset "Config PATCH publishes canonical, complete documents" begin
        SV = MetaManifold.Server
        keym, keyd = "analysis.differential.method", "analysis.differential.dispersion"
        _da_fixture() do
            root = SV.ServerState._root[]
            group_dir = joinpath(root, "data", "studyD", "groupG")
            run_dir = joinpath(group_dir, "runG")
            mkpath(run_dir)
            touch(joinpath(group_dir, ".group"))
            touch(joinpath(run_dir, "sample_R1.fastq.gz"))
            touch(joinpath(run_dir, "sample_R2.fastq.gz"))
            scopes = [("/api/v1/config", joinpath(root, "config", "pipeline.yml")),
                      ("/api/v1/studies/studyD/config", joinpath(root, "data", "studyD", "pipeline.yml")),
                      ("/api/v1/studies/studyD/groups/groupG/config", joinpath(group_dir, "pipeline.yml")),
                      ("/api/v1/studies/studyD/runs/runG/config?group=groupG", joinpath(run_dir, "pipeline.yml"))]
            for (url, path) in scopes
                for (submitted, expected) in ((" ML ", "ml"), (" GLMGAMPOI ", "glmGamPoi"))
                    response = SV.Oxygen.internalrequest(HTTP.Request("PATCH", url,
                        ["Content-Type"=>"application/json"], JSON3.write(Dict(keym=>"nb_glm", keyd=>submitted, "seed"=>456))))
                    @test response.status == 200
                    @test JSON3.read(String(response.body))[keyd].value == expected
                    @test YAML.load_file(path)["analysis"]["differential"]["dispersion"] == expected
                    response = SV.Oxygen.internalrequest(HTTP.Request("GET", url))
                    @test response.status == 200
                    @test JSON3.read(String(response.body))[keyd].value == expected
                    @test YAML.load_file(path)["seed"] == 456
                end
            end
            # Both transitions must preserve unrelated fields. Explicit ordering
            # exercises the formerly invalid intermediate clr_welch/glmGamPoi pair.
            path = scopes[2][2]
            for changes in (OrderedDict(keyd=>"ml", keym=>"clr_welch"),
                            OrderedDict(keyd=>"glmGamPoi", keym=>"nb_glm"),
                            OrderedDict(keym=>"clr_welch", keyd=>"ml"))
                @test SV._write_config_updates(path, changes) === nothing
                saved = YAML.load_file(path)
                @test saved["seed"] == 456
                @test saved["analysis"]["differential"]["method"] == changes[keym]
                @test saved["analysis"]["differential"]["dispersion"] == changes[keyd]
            end
            before = read(path, String)
            bad = SV._write_config_updates(path, Dict(keyd=>"glmGamPoi"))
            @test bad.status == 400
            @test read(path, String) == before

            run_url, run_path = scopes[4]
            before_run = read(run_path, String)
            response = SV.Oxygen.internalrequest(HTTP.Request("PATCH", run_url,
                ["Content-Type"=>"application/json"], JSON3.write(Dict(keym=>"clr_welch"))))
            @test response.status == 400
            @test read(run_path, String) == before_run

            # The first valid key must stay unpublished when a later setter fails.
            YAML.write_file(path, Dict("phylogeny"=>"not-a-section", "seed"=>456))
            before = read(path, String)
            @test_throws ErrorException SV._write_config_updates(path,
                OrderedDict("seed"=>789, "phylogeny.reference.trim.method"=>"none"))
            @test read(path, String) == before
        end
    end

    @testset "Parent PATCH validates affected descendants before publication" begin
        SV = MetaManifold.Server
        keym, keyd = "analysis.differential.method", "analysis.differential.dispersion"
        _da_fixture() do
            root = SV.ServerState._root[]
            global_path = joinpath(root, "config", "pipeline.yml")
            study_path = joinpath(root, "data", "studyD", "pipeline.yml")
            group_dir = joinpath(dirname(study_path), "groupG")
            run_dir = joinpath(group_dir, "runG")
            mkpath(run_dir); touch(joinpath(group_dir, ".group"))
            touch(joinpath(run_dir, "sample_R1.fastq.gz"))
            group_path, run_path = joinpath(group_dir, "pipeline.yml"), joinpath(run_dir, "pipeline.yml")
            save(path, values) = YAML.write_file(path, Dict("analysis"=>Dict("differential"=>values)))
            patch(url, changes) = SV.Oxygen.internalrequest(HTTP.Request("PATCH", url,
                ["Content-Type"=>"application/json"], JSON3.write(changes)))
            save(global_path, Dict("method"=>"nb_glm", "dispersion"=>"ml"))
            save(study_path, Dict("dispersion"=>"glmGamPoi"))
            before = read(global_path, String)
            response = patch("/api/v1/config", Dict(keym=>"clr_welch", "seed"=>789))
            @test response.status == 400
            @test occursin("studyD", JSON3.read(String(response.body)).message)
            @test read(global_path, String) == before
            # A deeper complete pair shields that subtree from a parent edit.
            save(study_path, Dict("method"=>"nb_glm", "dispersion"=>"glmGamPoi"))
            @test patch("/api/v1/config", Dict(keym=>"clr_welch", keyd=>"ml")).status == 200

            save(global_path, Dict("method"=>"nb_glm", "dispersion"=>"ml"))
            save(study_path, Dict("method"=>"nb_glm", "dispersion"=>"ml"))
            save(group_path, Dict("dispersion"=>"glmGamPoi"))
            before = read(study_path, String)
            @test patch("/api/v1/studies/studyD/config", Dict(keym=>"clr_welch")).status == 400
            @test read(study_path, String) == before
            save(group_path, Dict("method"=>"nb_glm", "dispersion"=>"ml"))
            save(run_path, Dict("dispersion"=>"glmGamPoi"))
            before = read(group_path, String)
            group_url = "/api/v1/studies/studyD/groups/groupG/config"
            response = patch(group_url, Dict(keym=>"clr_welch"))
            @test response.status == 400
            @test occursin("runG", JSON3.read(String(response.body)).message)
            @test read(group_path, String) == before
            save(run_path, Dict("method"=>"nb_glm", "dispersion"=>"glmGamPoi"))
            @test patch(group_url, Dict(keym=>"clr_welch")).status == 200

            # A run without an override file still inherits a validated cascade.
            run_a = joinpath(root, "data", "studyD", "runA", "pipeline.yml")
            rm(run_a)
            @test patch("/api/v1/studies/studyD/config", Dict(keyd=>"glmGamPoi")).status == 200
            response = SV.Oxygen.internalrequest(HTTP.Request("GET", "/api/v1/studies/studyD/runs/runA/config"))
            @test response.status == 200
            @test JSON3.read(String(response.body))[keyd].value == "glmGamPoi"

            # A malformed sibling is outside a run edit's affected subtree.
            write(joinpath(root,"data","studyD","runB","pipeline.yml"), "analysis: [broken")
            @test SV._write_config_updates(run_a, Dict(keyd=>"ml")) === nothing
        end
    end

    @testset "DELETE validates inherited values at every config scope" begin
        SV = MetaManifold.Server
        keym, keyd = "analysis.differential.method", "analysis.differential.dispersion"
        for scope in 1:4, deleted in (keym, keyd, "valid")
            _da_fixture() do
                root = SV.ServerState._root[]
                group_dir = joinpath(root, "data", "studyD", "groupG")
                run_dir = joinpath(group_dir, "runG")
                mkpath(run_dir); touch(joinpath(group_dir, ".group"))
                touch(joinpath(run_dir, "sample_R1.fastq.gz"))
                factory = joinpath(root, "config", "defaults", "pipeline.yml")
                mkpath(dirname(factory))
                paths = [joinpath(root,"config","pipeline.yml"),
                         joinpath(root,"data","studyD","pipeline.yml"),
                         joinpath(group_dir,"pipeline.yml"), joinpath(run_dir,"pipeline.yml")]
                urls = ["/api/v1/config", "/api/v1/studies/studyD/config",
                        "/api/v1/studies/studyD/groups/groupG/config",
                        "/api/v1/studies/studyD/runs/runG/config"]
                query = scope == 4 ? "?group=groupG" : ""
                method, dispersion = deleted == keym ? ("clr_welch", "ml") :
                                     deleted == keyd ? ("nb_glm", "glmGamPoi") : ("nb_glm", "ml")
                doc(m, d, seed) = Dict("seed"=>seed, "analysis"=>Dict("differential"=>Dict("method"=>m, "dispersion"=>d)))
                for path in [factory; paths]
                    YAML.write_file(path, doc(method, dispersion, 123))
                end
                target_method, target_dispersion = deleted == keym ? ("nb_glm", "glmGamPoi") :
                                                    deleted == keyd ? ("clr_welch", "ml") : ("nb_glm", "ml")
                YAML.write_file(paths[scope], doc(target_method, target_dispersion, 456))
                before = Dict(p=>read(p,String) for p in [factory; paths])
                if deleted != "valid"
                    response = SV.Oxygen.internalrequest(HTTP.Request("DELETE", "$(urls[scope])/$deleted$query"))
                    @test response.status == 400
                    @test JSON3.read(String(response.body)).error == "invalid_config_value"
                    @test all(read(p,String) == text for (p,text) in before)
                else
                    for (key, expected) in ((keym,"nb_glm"), (keyd,"ml"), ("seed",123))
                        response = SV.Oxygen.internalrequest(HTTP.Request("DELETE", "$(urls[scope])/$key$query"))
                        @test response.status == 200
                        @test JSON3.read(String(response.body))[key].value == expected
                    end
                    unchanged = read(paths[scope], String)
                    @test SV.Oxygen.internalrequest(HTTP.Request("DELETE", "$(urls[scope])/seed$query")).status == 200
                    @test read(paths[scope], String) == unchanged
                end
            end
        end
    end

    @testset "CLR transform" begin
        @test clr_transform([1.0 exp(1) exp(2)]) ≈ [-1.0 0.0 1.0]
        z = clr_transform([1.0 2 3 4; 5 1 1 9; 0.5 0.25 8 2])
        @test all(abs.(sum(z; dims=2)) .< 1e-12)
        # Scale invariance: a sample's CLR does not depend on its library size.
        @test clr_transform([10.0 20 30 40]) ≈ clr_transform([1.0 2 3 4])
        @test_throws ArgumentError clr_transform([0.0 1 2])
        @test_throws ArgumentError clr_transform([NaN 1 2])
    end

    clr_config = DifferentialConfig(; method="clr_welch")

    @testset "CLR + Welch: estimate is the difference of group mean CLRs" begin
        if !HAVE_ZCOMP
            @test_skip false
        else
            res = differential_abundance(effect, effect_samples, effect_taxa, effect_groups;
                                         reference="A", contrast="B", config=clr_config)
            @test res["effect"] == Dict("key" => "estimate", "label" => "CLR difference")
            @test isempty(res["size_factors"])
            @test res["config"]["method"] == "clr_welch" && !haskey(res["config"], "offset")
            @test res["diagnostics"]["zero_replacement"]["zeros_replaced"] == 0
            @test occursin("Welch", res["method"]) && occursin("cmultRepl", res["method"])
            # Known answer, independent of R: the estimate is mean(B) - mean(A)
            # of each taxon's CLR.
            z = clr_transform(Float64.(effect))
            a = effect_groups .== "A"; b = .!a
            expected = vec(sum(z[b, :]; dims=1)) ./ count(b) .- vec(sum(z[a, :]; dims=1)) ./ count(a)
            byt = Dict(r["taxon"] => r for r in res["rows"])
            for (j, t) in enumerate(effect_taxa)
                @test byt[t]["status"] == "ok"
                @test byt[t]["estimate"] ≈ expected[j] rtol=1e-8
                @test isnothing(byt[t]["log2_fold_change"]) && isnothing(byt[t]["dispersion_theta"])
                @test 0 <= byt[t]["pvalue"] <= 1 && !isnothing(byt[t]["padj"])
            end
            @test byt["t_up"]["estimate"] > 0 && byt["t_down"]["estimate"] < 0
            @test byt["t_up"]["padj"] < 0.05 && byt["t_down"]["padj"] < 0.05

            @testset "matches a direct Welch t.test, with unequal groups" begin
                # 12 A against 3 B: the case where pooled and Welch variances differ.
                keep = 1:15
                g = effect_groups[keep]
                un = differential_abundance(effect[keep, :], effect_samples[keep], effect_taxa, g;
                                            reference="A", contrast="B", config=clr_config)
                ub = Dict(r["taxon"] => r for r in un["rows"])
                zk = clr_transform(Float64.(effect[keep, :]))
                for (j, t) in enumerate(effect_taxa)
                    y = zk[:, j]
                    direct = rcopy(R"""
                        local({
                          tt <- stats::t.test($y[$g == "B"], $y[$g == "A"], var.equal = FALSE)
                          c(tt$estimate[[1]] - tt$estimate[[2]], tt$stderr, tt$statistic[[1]], tt$p.value)
                        })
                    """)
                    @test ub[t]["estimate"] ≈ direct[1] rtol=1e-10
                    @test ub[t]["standard_error"] ≈ direct[2] rtol=1e-10
                    @test ub[t]["statistic"] ≈ direct[3] rtol=1e-10
                    @test ub[t]["pvalue"] ≈ direct[4] rtol=1e-8
                end
                # Control: the pooled-variance test gives a different p-value
                # here, so the parity above can tell the two apart.
                y = zk[:, 1]
                pooled = rcopy(R"stats::t.test($y[$g == 'B'], $y[$g == 'A'], var.equal = TRUE)$p.value")
                @test !isapprox(ub["t_up"]["pvalue"], pooled; rtol=1e-3)
            end
        end
        # Refused before R is reached: Welch needs a variance in each group.
        @test_throws ArgumentError differential_abundance(effect[[1, 2, 13], :], effect_samples[[1, 2, 13]],
            effect_taxa, ["A", "A", "B"]; reference="A", contrast="B", config=clr_config)
    end

    @testset "Zero replacement matches direct zCompositions calls on three datasets" begin
        if !HAVE_ZCOMP
            @test_skip false
        else
            datasets = (
                [0 3 0 12 5; 7 0 1 0 9; 2 2 2 2 2; 0 6 4 30 1; 5 1 0 3 0],
                [0 1 0 4; 2 0 3 1; 5 2 0 0; 1 3 2 2; 0 4 1 3],
                [0 0 5; 1 0 4; 2 3 0; 0 2 3; 4 1 0; 2 2 2],
            )
            scenarios = (("bayesian_multiplicative", nothing),
                         ("bayesian_multiplicative", 2.5),
                         ("multiplicative_replacement", nothing))
            for x in datasets, (method, alpha) in scenarios
                out = replace_zeros(x; method, frac=0.65, alpha)
                totals = vec(sum(Float64.(x); dims=1))
                prior = [(totals[j] - x[i, j]) / (sum(totals) - sum(x[i, :]))
                         for i in axes(x, 1), j in axes(x, 2)]
                concentration = [isnothing(alpha) ? exp(-sum(log.(prior[i, :])) / size(x, 2)) :
                                 Float64(alpha) for i in axes(x, 1)]
                direct = if method == "multiplicative_replacement"
                    rcopy(R"""
                        as.matrix(zCompositions::cmultRepl($(Float64.(x)), label = 0, method = "CZM",
                                  output = "prop", frac = 0.65, z.warning = 1, z.delete = FALSE,
                                  suppress.print = TRUE))
                    """)
                elseif isnothing(alpha)
                    rcopy(R"""
                        as.matrix(zCompositions::cmultRepl($(Float64.(x)), label = 0, method = "GBM",
                                  output = "prop", frac = 0.65, z.warning = 1, z.delete = FALSE,
                                  suppress.print = TRUE))
                    """)
                else
                    rcopy(R"""
                        as.matrix(zCompositions::cmultRepl($(Float64.(x)), label = 0, method = "user",
                                  output = "prop", frac = 0.65, t = $prior, s = $concentration,
                                  z.warning = 1, z.delete = FALSE, suppress.print = TRUE))
                    """)
                end
                @test out.proportions ≈ direct rtol=1e-12 atol=1e-14
                @test out.zeros_replaced == count(==(0), x)
                @test out.method == method && out.delta == 0.65 && out.alpha == alpha
                @test all(>(0), out.proportions)
                @test vec(sum(out.proportions; dims=2)) ≈ ones(size(x, 1))
                # Every observed pair in every sample keeps its original ratio.
                for i in axes(x, 1), j in axes(x, 2), k in axes(x, 2)
                    if x[i, j] > 0 && x[i, k] > 0
                        @test out.proportions[i, j] / out.proportions[i, k] ≈ x[i, j] / x[i, k] rtol=1e-10
                    end
                end
                if method == "multiplicative_replacement"
                    @test isnothing(out.posterior)
                else
                    @test out.posterior.prior_mean ≈ prior rtol=1e-12
                    @test out.posterior.concentration ≈ concentration rtol=1e-12
                    # The returned parameters are sufficient to reconstruct a
                    # zero's Dirichlet marginal, independently of the output.
                    i, j = 1, findfirst(==(0), x[1, :])
                    shape = concentration[i] * prior[i, j]
                    total_shape = sum(x[i, :]) + concentration[i]
                    variance = shape * (total_shape - shape) / (total_shape^2 * (total_shape + 1))
                    @test 0 < variance < 1
                end
            end

            # A sample without zeros is its closure; it has no imputed mass.
            first_out = replace_zeros(datasets[1]; frac=0.65)
            @test first_out.proportions[3, :] ≈ fill(0.2, 5)
            @test first_out.imputed_mass[3] == 0.0
            @test first_out.imputed_mass[1] ≈ first_out.proportions[1, 1] + first_out.proportions[1, 3]
            # No zero at all: cmultRepl is not called, the closure is returned.
            no_zero = replace_zeros([1 3; 2 2])
            @test no_zero.proportions ≈ [0.25 0.75; 0.5 0.5]
            @test isnothing(no_zero.posterior)

            sparse = [0 3 4; 1 0 5; 0 2 6]
            msg = try replace_zeros(sparse; taxa=["lone", "q", "r"]); "" catch e; e.msg end
            @test occursin("'lone'", msg) && occursin("min_prevalence", msg)
            # CZM does not use the leave-one-out prior, so a taxon observed in
            # one sample is valid; a taxon never observed is still refused.
            @test all(>(0), replace_zeros(sparse; method="multiplicative_replacement").proportions)
            @test_throws ArgumentError replace_zeros([0 1; 0 2; 0 3]; method="multiplicative_replacement")
            msg = try replace_zeros([0 0; 3 4; 1 2]; samples=["empty", "b", "c"]); "" catch e; e.msg end
            @test occursin("'empty'", msg)
            @test_throws ArgumentError replace_zeros(reshape([1, 2, 3], 3, 1))
            @test_throws ArgumentError replace_zeros([0 1])
            @test any(occursin("underflow", w) for w in replace_zeros(datasets[1]; frac=0.005).warnings)
            @test any(occursin("substantial mass", w) for w in replace_zeros(datasets[1]; frac=0.9).warnings)
        end
    end

    @testset "CLR: cmultRepl output is checked sample by sample" begin
        # Pure Julia: no R is needed to check what cmultRepl hands back.
        check = MetaManifold.Differential._check_compositions
        mask = Bool[1 0 0; 0 0 0]
        good = [0.1 0.3 0.6; 0.2 0.3 0.5]
        @test check(good, mask, ["a", "b"]) === good
        for (bad, why) in (([0.0 0.4 0.6; 0.2 0.3 0.5], "a replaced zero left at 0"),
                           ([NaN 0.4 0.6; 0.2 0.3 0.5], "a non-finite value"),
                           ([0.1 0.4 0.6; 0.2 0.3 0.5], "a row that does not sum to 1"))
            msg = try check(bad, mask, ["first", "second"]); "" catch e; e.msg end
            @test occursin("'first'", msg) && occursin("min_prevalence", msg)
        end
        # The failing sample is the one named, not always the first.
        msg = try check([0.1 0.3 0.6; 0.2 0.3 0.6], mask, ["a", "b"]); "" catch e; e.msg end
        @test occursin("'b'", msg) && occursin("0 replaced zeros", msg)
        @test_throws ErrorException check(good[:, 1:2], mask, ["a", "b"])
    end

    @testset "CLR: min_prevalence is applied before zero replacement" begin
        if !HAVE_ZCOMP
            @test_skip false
        else
            # Six samples x five taxa: 'ghost' has no reads anywhere, 'rare' one
            # read in one sample, 'r' is in four of six, 'p' and 'q' in all.
            x = [10 20 2 0 0; 12 18 0 0 0; 11 19 3 3 0; 30 8 0 0 0; 28 9 4 0 0; 33 7 5 0 0]
            s = ["s$i" for i in 1:6]
            taxa = ["p", "q", "r", "rare", "ghost"]
            g = ["A", "A", "A", "B", "B", "B"]
            res = differential_abundance(x, s, taxa, g; reference="A", contrast="B",
                                         config=DifferentialConfig("tss", 0.5; method="clr_welch"))
            byt = Dict(r["taxon"] => r for r in res["rows"])
            @test byt["ghost"]["status"] == "filtered"
            @test occursin("not part of the composition", byt["ghost"]["note"])
            @test byt["rare"]["status"] == "filtered"
            @test occursin("min_prevalence", byt["rare"]["note"])
            @test all(t -> byt[t]["status"] == "ok", ("p", "q", "r"))
            zr = res["diagnostics"]["zero_replacement"]
            @test zr["n_taxa_in_composition"] == 3 && zr["n_taxa_unobserved"] == 1
            # Only r's two zeros are replaced; rare's five zeros are not.
            @test zr["zeros_replaced"] == 2
            @test 0 < zr["max_imputed_fraction"] < 1
            @test zr["median_imputed_fraction"] == 0.0

            # The fit saw the 3-taxon composition: 'rare' contributed nothing.
            z = clr_transform(replace_zeros(x[:, 1:3]).proportions)
            a = g .== "A"
            @test byt["p"]["estimate"] ≈ sum(z[.!a, 1]) / 3 - sum(z[a, 1]) / 3 rtol=1e-8

            # Without the threshold, 'rare' (one sample) reaches cmultRepl,
            # whose prior is undefined for it; the refusal names the fix.
            msg = try
                differential_abundance(x, s, taxa, g; reference="A", contrast="B", config=clr_config)
                ""
            catch e
                e.msg
            end
            @test occursin("'rare'", msg) && occursin("min_prevalence", msg)

            @test_throws ArgumentError differential_abundance(x[:, [1, 5]], s, ["p", "ghost"], g;
                reference="A", contrast="B", config=clr_config)
        end
    end

    @testset "CLR: replacement policy and Bayesian alpha are honoured end to end" begin
        if !HAVE_ZCOMP
            @test_skip false
        else
            x = [10 20 2; 12 18 0; 11 19 3; 30 8 0; 28 9 4; 33 7 5]
            s = ["s$i" for i in 1:6]
            taxa = ["p", "q", "r"]
            g = ["A", "A", "A", "B", "B", "B"]
            for (method, alpha, r_name) in (("multiplicative_replacement", nothing, "CZM"),
                                            ("bayesian_multiplicative", 2.5, "user"))
                config = DifferentialConfig("tss", 0.5; method="clr_welch",
                    replacement_method=method, bayesian_alpha=alpha)
                res = differential_abundance(x, s, taxa, g; reference="A", contrast="B", config)
                @test res["config"]["replacement_method"] == method
                @test res["config"]["bayesian_alpha"] == alpha
                @test occursin("($r_name, frac = 0.65", res["method"])
                zr = res["diagnostics"]["zero_replacement"]
                @test zr["method"] == "zCompositions::cmultRepl ($r_name)"
                @test zr["alpha"] == alpha
                if method == "bayesian_multiplicative"
                    @test zr["posterior"]["family"] == "Dirichlet"
                    @test length(zr["posterior"]["concentration"]) == 6
                    @test all(row -> row["value"] == 2.5, zr["posterior"]["concentration"])
                else
                    @test !haskey(zr, "posterior")
                end
                replaced = replace_zeros(x; method, alpha)
                z = clr_transform(replaced.proportions)
                a = g .== "A"
                byt = Dict(r["taxon"] => r for r in res["rows"])
                for (j, taxon) in enumerate(taxa)
                    expected = sum(z[.!a, j]) / 3 - sum(z[a, j]) / 3
                    @test byt[taxon]["estimate"] ≈ expected rtol=1e-8
                end
            end
        end
    end

    @testset "CLR: a sparse table with rare taxa runs once min_prevalence is set" begin
        if !HAVE_ZCOMP
            @test_skip false
        else
            # 24 samples (12 A, 12 B) x 211 taxa, about 90% zeros, built from a
            # fixed formula: 6 common taxa in every sample ('c1' is four times
            # as abundant in B), 4 moderate taxa in two thirds of the samples,
            # one sparse taxon in 3 of 24 samples (87.5% zeros, which cmultRepl's
            # default z.delete would drop), and 200 rare taxa in 1 or 2 samples.
            n = 24
            grp = vcat(fill("A", 12), fill("B", 12))
            common = [100 + (37i + 11j) % 200 for i in 1:n, j in 1:6]
            common[13:24, 1] .*= 4
            moderate = [(i + j) % 3 == 0 ? 0 : 5 + (i * j) % 7 for i in 1:n, j in 1:4]
            sparse = [i in (1, 9, 17) ? 4 : 0 for i in 1:n]
            rare = zeros(Int, n, 200)
            for k in 1:200
                rare[(7k) % n + 1, k] = 1 + k % 3
                iseven(k) && (rare[(13k) % n + 1, k] = 1 + k % 2)
            end
            counts = hcat(common, moderate, sparse, rare)
            taxa = vcat(["c$j" for j in 1:6], ["m$j" for j in 1:4], ["sparse"], ["rare$k" for k in 1:200])
            samples = ["s$i" for i in 1:n]
            @test count(==(0), counts) / length(counts) > 0.85
            @test all(k -> 1 <= count(>(0), rare[:, k]) <= 2, 1:200)

            # Unfiltered, the rare taxa reach the replacement and are refused.
            msg = try
                differential_abundance(counts, samples, taxa, grp; reference="A", contrast="B",
                                       config=clr_config)
                ""
            catch e
                e.msg
            end
            @test occursin("min_prevalence", msg)

            # min_prevalence = 0.1 keeps taxa seen in 3 or more of 24 samples.
            res = differential_abundance(counts, samples, taxa, grp; reference="A", contrast="B",
                                         config=DifferentialConfig("tss", 0.1; method="clr_welch"))
            byt = Dict(r["taxon"] => r for r in res["rows"])
            d = res["diagnostics"]
            @test d["n_tested"] == 11 && d["n_filtered"] == 200 && d["n_failed"] == 0
            @test res["status"] == "ok"
            @test all(k -> byt["rare$k"]["status"] == "filtered", 1:200)
            # The sparse taxon is tested, not silently dropped by cmultRepl.
            @test byt["sparse"]["status"] == "ok" && !isnothing(byt["sparse"]["pvalue"])
            @test byt["c1"]["estimate"] > 0 && byt["c1"]["padj"] < 0.05
            zr = d["zero_replacement"]
            @test zr["n_taxa_in_composition"] == 11
            @test zr["zeros_replaced"] == count(==(0), counts[:, 1:11])
            @test isempty(zr["warnings"])

            # What filtering bought: replacing over every taxon seen in 2 or
            # more samples instead puts far more imputed mass in each sample.
            wide = findall(j -> count(>(0), counts[:, j]) >= 2, axes(counts, 2))
            unfiltered = replace_zeros(counts[:, wide])
            med(v) = (s = sort(v); (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
            @test med(unfiltered.imputed_mass) > 5 * zr["median_imputed_fraction"]
            @test maximum(unfiltered.imputed_mass) > zr["max_imputed_fraction"]
        end
    end

    @testset "CLR: constant log-ratios are refused with their reason" begin
        if !HAVE_ZCOMP
            @test_skip false
        else
            # p and q in the same 1:1 ratio everywhere: both CLRs are constant
            # (zero), so neither can be fitted and the whole test is refused.
            e = try
                differential_abundance([5 5; 7 7; 9 9; 4 4], ["a", "b", "c", "d"], ["p", "q"],
                                       ["A", "A", "B", "B"]; reference="A", contrast="B", config=clr_config)
                nothing
            catch err
                err
            end
            @test e isa ErrorException
            @test occursin("no taxon could be fitted", e.msg)
            @test occursin("constant", e.msg)
        end
    end


    # ---- Multinomial and Dirichlet-multinomial regression -------------------
    # The reference values below come from an independent numpy port of
    # src/analysis/compositional.jl (same Newton steps, same alternation, same
    # special functions), quoted to 12 digits, and from mpmath at 40 digits for
    # the special functions themselves. They pin the models without R: MGLM's
    # MGLMreg is what a reviewer should compare against, and the tables here are
    # the gate that keeps the Julia and the reference implementation together.
    #
    # 6 samples x 4 taxa in two groups, taxon 1 as the reference: the sample is
    # overdispersed, so the Dirichlet-multinomial beats the multinomial and its
    # concentration is identifiable deep inside (CONCENTRATION_MIN, MAX).
    mn_counts = [12 40 8 3; 9 51 11 2; 20 30 5 4; 3 18 22 9; 7 25 15 5; 11 12 9 20]
    mn_design = [1.0 0.0; 1.0 0.0; 1.0 0.0; 1.0 1.0; 1.0 1.0; 1.0 1.0]
    # 8 samples x 3 taxa whose counts are multinomial to the eye: nothing to
    # overdisperse, so the Dirichlet concentration runs to its upper bound.
    flat_counts = [5 30 50; 8 25 60; 6 35 45; 7 28 55;
                   40 27 6; 55 33 4; 35 29 9; 60 31 5]
    flat_design = [1.0 0.0; 1.0 0.0; 1.0 0.0; 1.0 0.0;
                   1.0 1.0; 1.0 1.0; 1.0 1.0; 1.0 1.0]

    @testset "Multinomial configuration" begin
        # Both methods are selectable names, and the two are told apart from the
        # per-taxon models by one tuple.
        @test Differential.METHODS ==
              ("nb_glm", "clr_welch", "multinomial", "dirichlet_multinomial")
        @test Differential.COMPOSITIONAL_METHODS == ("multinomial", "dirichlet_multinomial")
        c = DifferentialConfig(; method="multinomial")
        @test c.method == "multinomial"
        @test c.mn_reference_taxon === nothing
        @test c.mn_penalty == 0.0
        @test c.dm_overdispersion_method == "mle"
        # The optimiser defaults are documented twice: once here, once in
        # CompositionalModels. They must not drift apart.
        @test c.max_iter == CM.DEFAULT_MAX_ITER == 500
        @test c.tol == CM.DEFAULT_TOL == 1e-8
        @test c.max_seconds == CM.DEFAULT_MAX_SECONDS == 300.0
        @test CM.DM_METHODS == ("mle", "mom")
        # Names reach the model canonically, whatever case or padding arrives.
        @test DifferentialConfig(; method="  MULTINOMIAL ").method == "multinomial"
        @test DifferentialConfig(; method="Dirichlet_Multinomial").method == "dirichlet_multinomial"
        @test DifferentialConfig(; method="dirichlet_multinomial",
                                   dm_overdispersion_method=" MOM ").dm_overdispersion_method == "mom"
        @test DifferentialConfig(; method="multinomial", mn_penalty=0.5).mn_penalty == 0.5
        @test DifferentialConfig(; method="multinomial", mn_reference_taxon=" Bacteroides ").mn_reference_taxon ==
              "Bacteroides"
        # An empty reference is the automatic one, so clearing it works.
        @test DifferentialConfig(; method="multinomial", mn_reference_taxon="  ").mn_reference_taxon === nothing
        @test DifferentialConfig(; method="dirichlet_multinomial", max_iter=12).max_iter == 12
        @test DifferentialConfig(; method="multinomial", tol=1e-6).tol == 1e-6
        # Settings that belong to another method are refused, not ignored.
        e = try
            DifferentialConfig(; method="nb_glm", mn_reference_taxon="Bacteroides")
            nothing
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("mn_reference_taxon", sprint(showerror, e))
        @test_throws ArgumentError DifferentialConfig(; method="nb_glm", mn_penalty=1.0)
        @test_throws ArgumentError DifferentialConfig(; method="clr_welch", mn_penalty=1.0)
        @test_throws ArgumentError DifferentialConfig(; method="multinomial", dispersion="glmGamPoi")
        @test_throws ArgumentError DifferentialConfig(; method="multinomial",
                                                       dm_overdispersion_method="mom")
        @test_throws ArgumentError DifferentialConfig(; method="dirichlet_multinomial",
                                                       dm_overdispersion_method="reml")
        # Out-of-range numbers.
        for bad in (-1.0, NaN, Inf)
            @test_throws ArgumentError DifferentialConfig(; method="multinomial", mn_penalty=bad)
        end
        for bad in (0, -3)
            @test_throws ArgumentError DifferentialConfig(; method="multinomial", max_iter=bad)
        end
        for bad in (0.0, -1.0, NaN)
            @test_throws ArgumentError DifferentialConfig(; method="multinomial", tol=bad)
            @test_throws ArgumentError DifferentialConfig(; method="multinomial", max_seconds=bad)
        end
        # The config route publishes the new keys with their enum values, so the
        # editor offers exactly what the model accepts.
        @test MetaManifold.Server._ENUM_VALUES["analysis.differential.method"] ==
              Differential.METHODS
        @test MetaManifold.Server._ENUM_VALUES["analysis.differential.dm_overdispersion_method"] ==
              Differential.DM_METHODS
    end

    @testset "Multinomial: coefficients, standard errors and likelihood" begin
        fit = CM.fit_multinomial(mn_counts, mn_design; reference=1)
        @test fit.converged
        @test 1 <= fit.iterations <= 20          # 6 in the reference run
        @test fit.n_parameters == 6
        # No concentration and no overdispersion: the multinomial is the c -> Inf
        # end of the family.
        @test fit.concentration == Inf
        @test fit.overdispersion == 0.0
        @test fit.alternations == 0
        @test fit.coefficients ≈ [ 1.082218478892 -0.119407731383;
                                  -0.535518236356  1.319637195122;
                                  -1.516347489368  1.998185576261] rtol=1e-7
        @test fit.standard_errors ≈ [0.180706133577 0.313776309675;
                                     0.257015389751 0.367987891952;
                                     0.368105086916 0.461012111922] rtol=1e-7
        @test fit.statistic ≈ [ 5.988830912766 -0.380550499517;
                                -2.083603775144  3.586088629503;
                                -4.119333155843  4.334345073780] rtol=1e-7
        @test fit.pvalue ≈ [2.113547511001e-09 7.035368178484e-01;
                            3.719622334023e-02 3.356749143897e-04;
                            3.799704360231e-05 1.461947018922e-05] rtol=1e-6
        @test fit.loglik ≈ -407.0649687189738 rtol=1e-12
        # The ridge penalty shrinks every coefficient towards zero, costs
        # likelihood, and leaves the Wald statistic of the penalised fit.
        pen = CM.fit_multinomial(mn_counts, mn_design; reference=1, penalty=0.5)
        @test pen.converged
        @test maximum(abs.(pen.coefficients)) < maximum(abs.(fit.coefficients))
        @test pen.loglik < fit.loglik
        @test pen.loglik ≈ -407.28567750994813 rtol=1e-10
        @test pen.coefficients ≈ [ 1.118161966957 -0.215012653567;
                                  -0.460636409664  1.170338505343;
                                  -1.319158248268  1.713855339132] rtol=1e-7
        # A penalty of 0 is exactly maximum likelihood; a negative one is refused.
        @test CM.fit_multinomial(mn_counts, mn_design; reference=1, penalty=0.0).coefficients ≈
              fit.coefficients rtol=1e-12
    end

    @testset "Multinomial: observed information matches a numerical Hessian" begin
        fit = CM.fit_multinomial(mn_counts, mn_design; reference=1)
        info = CM.observed_information(mn_counts, mn_design, fit.coefficients; reference=1)
        p = 6
        @test size(info) == (p, p)
        @test info ≈ info' rtol=1e-14          # symmetric, so a caller can invert it
        # Parameters are ordered (taxon, covariate) with the covariate fastest,
        # the order `statistic` and `pvalue` use.
        lk(t) = (div(t - 1, 2) + 1, mod(t - 1, 2) + 1)
        function objective(a, b, da, db)
            B = copy(fit.coefficients)
            (la, ka) = lk(a)
            (lb, kb) = lk(b)
            B[la, ka] += da
            B[lb, kb] += db
            -CM.multinomial_loglik(mn_counts,
                                   CM.composition_probabilities(mn_design, B; reference=1))
        end
        h = 1e-5
        num = [(objective(a, b, h, h) - objective(a, b, h, -h) -
                objective(a, b, -h, h) + objective(a, b, -h, -h)) / (4 * h^2)
               for a in 1:p, b in 1:p]
        @test maximum(abs.(info - num)) <= 1e-4 * maximum(abs.(num))
        # The ridge penalty is a diagonal term and nothing else.
        pen = CM.observed_information(mn_counts, mn_design, fit.coefficients;
                                      reference=1, penalty=2.0)
        @test pen - info ≈ [i == j ? 2.0 : 0.0 for i in 1:p, j in 1:p] rtol=1e-12
        # ... which is why a ridge fit's standard errors are the ridge ones:
        # smaller than the unpenalised fit's, and finite even where the
        # likelihood alone is flat.
        penfit = CM.fit_multinomial(mn_counts, mn_design; reference=1, penalty=2.0)
        @test all(penfit.standard_errors .< fit.standard_errors)
    end

    @testset "Dirichlet-multinomial: overdispersion is estimated, not assumed" begin
        mn = CM.fit_multinomial(mn_counts, mn_design; reference=1)
        dm = CM.fit_dirichlet_multinomial(mn_counts, mn_design; reference=1)
        @test dm.converged
        @test 1 <= dm.alternations <= 20         # 6 in the reference run
        # The extra parameter has to pay for itself: the Dirichlet-multinomial
        # likelihood is higher by 2.9 on one degree of freedom.
        @test dm.loglik > mn.loglik
        @test dm.n_parameters == mn.n_parameters + 1
        @test dm.loglik ≈ -404.20997824942896 rtol=1e-10
        @test dm.concentration ≈ 53.362066917711644 rtol=1e-3
        @test dm.overdispersion ≈ 0.01839517988735986 rtol=1e-3
        @test 0.0 < dm.overdispersion < 1.0
        @test dm.coefficients ≈ [ 1.071032144989 -0.114066335487;
                                 -0.501173931974  1.275343318453;
                                 -1.368474581812  1.805519460437] rtol=1e-6
        @test dm.standard_errors ≈ [0.265587018181 0.441717024040;
                                    0.368657299554 0.517219391431;
                                    0.481355112438 0.617114850217] rtol=1e-6
        @test dm.statistic ≈ [ 4.032697653391 -0.258233958120;
                              -1.359457503161  2.465768568586;
                              -2.842962599651  2.925743011698] rtol=1e-6
        # Between-sample variation widens every standard error: the multinomial's
        # are too small by the square root of the overdispersion factor.
        @test all(dm.standard_errors .> mn.standard_errors)
        # The method of moments is a one-shot alternative: no alternation, a
        # smaller concentration here, and the same sign and scale of effect.
        mom = CM.fit_dirichlet_multinomial(mn_counts, mn_design; reference=1,
                                           overdispersion_method="mom")
        @test mom.converged
        @test mom.alternations == 0
        @test mom.concentration ≈ 42.76597063846098 rtol=1e-4
        @test mom.overdispersion ≈ 0.02284880205812716 rtol=1e-4
        @test mom.loglik ≈ -404.2698986845995 rtol=1e-10
        @test mom.coefficients ≈ [ 1.065395681465 -0.114069708300;
                                  -0.493938545821  1.262656401027;
                                  -1.338569035064  1.768148887907] rtol=1e-6
        @test dm.loglik > mom.loglik             # profiling beats one moment
        @test sign.(dm.coefficients) == sign.(mn.coefficients)
    end

    @testset "Dirichlet-multinomial: a table with no overdispersion is multinomial" begin
        mn = CM.fit_multinomial(flat_counts, flat_design; reference=2)
        dm = CM.fit_dirichlet_multinomial(flat_counts, flat_design; reference=2)
        # The concentration runs to the top of its range and the fit is reported
        # as that bound; the coefficients are the multinomial's exactly, because
        # a flat Dirichlet is the multinomial at double precision.
        @test dm.concentration >= CM.CONCENTRATION_MAX * (1 - 1e-6)
        @test dm.overdispersion < 1e-5
        @test dm.alternations == 0
        @test dm.converged
        @test dm.coefficients == mn.coefficients
        @test dm.loglik == mn.loglik
        @test dm.n_parameters == mn.n_parameters + 1
        # Both references agree with the reference table for this table.
        @test mn.coefficients ≈ [-1.512588086416 1.972120415794;
                                  0.576422906252 -2.185860818556] rtol=1e-8
        @test mn.standard_errors ≈ [0.216647443400 0.246033749636;
                                     0.115049906706 0.251468648201] rtol=1e-8
        @test mn.loglik ≈ -600.4014470047102 rtol=1e-12
    end

    @testset "Multinomial: the reference taxon is only a reparameterisation" begin
        f1 = CM.fit_multinomial(flat_counts, flat_design; reference=1)
        f2 = CM.fit_multinomial(flat_counts, flat_design; reference=2)
        f3 = CM.fit_multinomial(flat_counts, flat_design; reference=3)
        # The composition, and so the likelihood, does not depend on the choice.
        @test f1.loglik ≈ f2.loglik rtol=1e-10
        @test f2.loglik ≈ f3.loglik rtol=1e-10
        # Swapping the reference negates the log ratio between the two taxa.
        @test f2.coefficients[1, 2] ≈ -f1.coefficients[1, 2] rtol=1e-8
        @test f3.coefficients[1, 2] ≈ -f1.coefficients[2, 2] rtol=1e-8
        # A third taxon's log ratio against the reference is the difference of
        # the two log ratios through the third, which is why a log ratio is
        # coherent under compositionality and a raw abundance is not.
        @test f2.coefficients[2, 2] ≈ f1.coefficients[2, 2] - f1.coefficients[1, 2] rtol=1e-8
        @test f3.coefficients[2, 2] ≈ f1.coefficients[1, 2] - f1.coefficients[2, 2] rtol=1e-8
        @test f1.coefficients[1, 2] ≈ -1.972120415794 rtol=1e-8
        @test f1.coefficients[2, 2] ≈ -4.157981234350 rtol=1e-8
    end

    @testset "Multinomial: unusable input is refused with its reason" begin
        @test_throws ArgumentError CM.fit_multinomial(mn_counts, mn_design; reference=0)
        @test_throws ArgumentError CM.fit_multinomial(mn_counts, mn_design; reference=5)
        @test_throws ArgumentError CM.fit_multinomial(mn_counts, mn_design; penalty=-1.0)
        @test_throws ArgumentError CM.fit_multinomial(mn_counts, mn_design; penalty=NaN)
        @test_throws ArgumentError CM.fit_multinomial(mn_counts, mn_design; max_iter=0)
        @test_throws ArgumentError CM.fit_multinomial(mn_counts, mn_design; tol=0.0)
        @test_throws ArgumentError CM.fit_multinomial(mn_counts, mn_design; max_seconds=0.0)
        @test_throws ArgumentError CM.fit_multinomial(mn_counts .+ 0.5, mn_design)
        @test_throws ArgumentError CM.fit_multinomial(vcat(zeros(1, 4), mn_counts[2:end, :]),
                                                      mn_design)
        @test_throws ArgumentError CM.fit_multinomial(mn_counts, mn_design[1:5, :])
        e = try
            CM.fit_dirichlet_multinomial(mn_counts, mn_design; overdispersion_method="reml")
            nothing
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("dm_overdispersion_method", sprint(showerror, e))
        # More taxa than the dense information matrix allows is an explicit
        # refusal, not an out-of-memory crash.
        big = ones(Int, 2, CM.MAX_TAXA + 2)
        e = try
            CM.fit_multinomial(big, ones(2, 2))
            nothing
        catch err
            err
        end
        @test e isa CM.CompositionalRefusal
        @test occursin(string(CM.MAX_TAXA), sprint(showerror, e))
        # The wall-clock budget is enforced inside the optimiser and says so.
        @test_throws CM.RuntimeRefusal CM.fit_multinomial(mn_counts, mn_design; max_seconds=1e-9)
        # The special functions this module carries are the ones it documents.
        # The recurrence plus the Stirling series is good to a few times 1e-14
        # relative, worst near 1 where the recurrence shift is largest and the
        # subtraction loses the most, so the bound here is 1e-12: it catches a
        # wrong series or a missing recurrence step without pinning the last
        # two bits of a Float64.
        @test CM.compositional_loggamma(0.5) ≈ 0.5723649429247001 rtol=1e-12
        @test CM.compositional_loggamma(10.0) ≈ 12.801827480081469 rtol=1e-12
        @test CM.compositional_digamma(1.0) ≈ -0.5772156649015329 rtol=1e-12
        @test CM.compositional_digamma(10.0) ≈ 2.251752589066721 rtol=1e-12
        @test CM.compositional_digamma(0.5) ≈ -1.9635100260214235 rtol=1e-12
    end

    @testset "Multinomial: the DA engine reports a composition, not per-taxon fits" begin
        taxa3 = ["Up", "Flat", "Down"]
        samples8 = ["s$i" for i in 1:8]
        groups8 = vcat(fill("A", 4), fill("B", 4))
        # Down has reads in group A and none in group B: its log fold change is
        # unbounded, so the engine refuses it by name and models the rest.
        sep = [5 30 50; 8 25 60; 6 35 45; 7 28 55;
               40 27 0; 55 33 0; 35 29 0; 60 31 0]
        res = differential_abundance(sep, samples8, taxa3, groups8;
                                     reference="A", contrast="B",
                                     config=DifferentialConfig(; method="multinomial"))
        byt = Dict(r["taxon"] => r for r in res["rows"])
        @test Set(keys(byt)) == Set(taxa3)
        @test byt["Down"]["status"] == "failed"
        @test occursin("complete separation", byt["Down"]["note"])
        @test byt["Down"]["padj"] === nothing
        @test byt["Down"]["estimate"] === nothing
        # The automatic reference is the most abundant taxon that is fitted.
        @test byt["Flat"]["status"] == "reference"
        @test byt["Flat"]["estimate"] == 0.0
        @test byt["Flat"]["log2_fold_change"] == 0.0
        @test byt["Flat"]["pvalue"] === nothing
        @test byt["Up"]["status"] == "ok"
        # Dropping a taxon from a multinomial leaves the log ratio between the
        # others alone: this is the three-taxon fit's Up-vs-Flat coefficient.
        @test byt["Up"]["estimate"] ≈ 1.972120415794 rtol=1e-6
        @test byt["Up"]["log2_fold_change"] ≈ 1.972120415794 / log(2) rtol=1e-6
        @test byt["Up"]["standard_error"] ≈ 0.246033749636 rtol=1e-6
        # BH is applied to whatever was fitted, and here that is one taxon.
        @test byt["Up"]["padj"] ≈ byt["Up"]["pvalue"] rtol=1e-12
        @test res["status"] == "partial"
        @test res["effect"]["key"] == "log2_fold_change"
        @test occursin("Flat", res["effect"]["label"])
        @test occursin("Morton et al. 2019", res["method"])
        @test isempty(res["size_factors"])
        @test res["config"]["method"] == "multinomial"
        @test res["config"]["mn_reference_taxon"] == "Flat"
        @test res["config"]["mn_penalty"] == 0.0
        @test res["config"]["max_iter"] == 500
        @test res["config"]["max_seconds"] == 300.0
        @test !haskey(res["config"], "dm_overdispersion_method")
        model = res["diagnostics"]["model"]
        @test model["reference_taxon"] == "Flat"
        @test model["n_taxa_fitted"] == 2
        @test model["n_parameters"] == 2
        @test model["converged"]
        @test model["log_likelihood"] ≈ -274.90564883764876 rtol=1e-8
        @test 0.0 <= model["runtime_seconds"] < 60.0
        # The same table with the Dirichlet-multinomial is also effectively
        # multinomial, and the engine says so through the row status.
        dres = differential_abundance(sep, samples8, taxa3, groups8;
                                      reference="A", contrast="B",
                                      config=DifferentialConfig(; method="dirichlet_multinomial"))
        dbyt = Dict(r["taxon"] => r for r in dres["rows"])
        @test dbyt["Up"]["status"] == "boundary"
        @test occursin("upper bound", dbyt["Up"]["note"])
        @test dbyt["Up"]["estimate"] ≈ 1.972120415794 rtol=1e-6
        over = dres["diagnostics"]["overdispersion"]
        @test over["method"] == "mle"
        @test over["at_bound"]
        @test over["concentration"] >= CM.CONCENTRATION_MAX * (1 - 1e-6)
        @test dres["config"]["dm_overdispersion_method"] == "mle"
    end

    @testset "Multinomial: reference taxon validation in the engine" begin
        taxa3 = ["Up", "Flat", "Down"]
        samples8 = ["s$i" for i in 1:8]
        groups8 = vcat(fill("A", 4), fill("B", 4))
        base = [5 30 50; 8 25 60; 6 35 45; 7 28 55;
                40 27 6; 55 33 4; 35 29 9; 60 31 5]
        kw = (reference="A", contrast="B")
        cfg(ref) = DifferentialConfig(; method="multinomial", mn_reference_taxon=ref)
        e = try
            differential_abundance(base, samples8, taxa3, groups8; kw..., config=cfg("Nope"))
            nothing
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("is not a taxon at this rank", sprint(showerror, e))
        # A reference seen in 2 of 8 samples anchors unstable ratios.
        thin = copy(base)
        thin[:, 1] .= 0
        thin[1, 1] = 1
        thin[5, 1] = 1
        e = try
            differential_abundance(thin, samples8, taxa3, groups8; kw..., config=cfg("Up"))
            nothing
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("at least half the samples", sprint(showerror, e))
        # A reference with no reads at all in one group is separated, so it is
        # not in the composition and cannot be its reference either.
        gone = copy(base)
        gone[:, 3] .= 0
        gone[1:4, 3] .= 1
        e = try
            differential_abundance(gone, samples8, taxa3, groups8; kw..., config=cfg("Down"))
            nothing
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("is not fitted", sprint(showerror, e))
        # Every taxon filtered out is an explicit error, not an empty table.
        e = try
            differential_abundance([1 0; 2 3; 0 4; 5 0], ["s1", "s2", "s3", "s4"],
                                   ["a", "b"], groups8[1:4];
                                   kw..., config=DifferentialConfig(; method="multinomial",
                                                                    min_prevalence=1.0))
            nothing
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("no composition to model", sprint(showerror, e))
    end

    @testset "Route: two runs through the in-process router" begin
        _da_fixture() do
            # The factory default is an explicitly null Bayesian alpha. Config
            # resolution must preserve it rather than something(nothing, nothing).
            @test MetaManifold.Server._differential_config("studyD").bayesian_alpha === nothing
            r = _da_post("studyD", Dict("runs" => [Dict("run" => "runA"), Dict("run" => "runB")],
                                        "table" => "merged", "rank" => "Genus"))
            body = JSON3.read(String(r.body))
            if !HAVE_MASS
                @test r.status == 503
                @test body.error == "r_unavailable"
            else
                @test r.status == 200
                @test body.rank == "Genus"
                @test body.groups.reference == "runA" && body.groups.contrast == "runB"
                @test body.n_samples.runA == 4 && body.n_samples.runB == 4
                @test length(body.size_factors) == 8
                byt = Dict(String(x.taxon) => x for x in body.rows)
                @test Set(keys(byt)) == Set(["Up", "Flat", "Down"])
                @test byt["Up"].estimate > 0 && byt["Down"].estimate < 0
                @test all(x -> x.padj !== nothing, body.rows)
                @test haskey(body, :figure) && length(body.figure.data) >= 1
                # Aggregation pooled the two Up rows: the route's estimate is the
                # library's on the summed counts.
                up_a = [5, 8, 6, 7]; up_b = [40, 55, 35, 60]
                mat = hcat(vcat(up_a, up_b), vcat([30, 25, 35, 28], [27, 33, 29, 31]),
                           vcat([50, 60, 45, 55], [6, 4, 9, 5]))
                direct = differential_abundance(mat, ["a$i" for i in 1:8], ["Up", "Flat", "Down"],
                                                vcat(fill("runA", 4), fill("runB", 4));
                                                reference="runA", contrast="runB")
                up = only(filter(x -> x["taxon"] == "Up", direct["rows"]))
                @test byt["Up"].estimate ≈ up["estimate"] rtol=1e-8
            end

            r = _da_post("studyD", Dict("runs" => [Dict("run" => "runA")], "table" => "merged"))
            @test r.status == 400
            @test JSON3.read(String(r.body)).error == "two_conditions_required"

            r = _da_post("noSuchStudy", Dict("runs" => [Dict("run" => "runA"), Dict("run" => "runB")]))
            @test r.status == 404
        end
    end

    @testset "Route: clr_welch selected by the study config" begin
        _da_fixture() do
            root = MetaManifold.Server.ServerState._root[]
            write(joinpath(root, "data", "studyD", "pipeline.yml"),
                  "analysis:\n  differential:\n    method: clr_welch\n    replacement_method: multiplicative_replacement\n    replacement_delta: 0.5\n    bayesian_alpha: ~\n")
            r = _da_post("studyD", Dict("runs" => [Dict("run" => "runA"), Dict("run" => "runB")],
                                        "table" => "merged", "rank" => "Genus"))
            body = JSON3.read(String(r.body))
            if !HAVE_ZCOMP
                HAVE_R ? (@test r.status == 503 && body.error == "r_unavailable") :
                         (@test_skip r.status == 200)
            else
                @test r.status == 200
                @test body.effect.key == "estimate" && body.effect.label == "CLR difference"
                @test body.config.method == "clr_welch" && body.config.replacement_delta == 0.5
                @test body.config.replacement_method == "multiplicative_replacement"
                @test body.config.bayesian_alpha === nothing
                @test body.diagnostics.zero_replacement.method == "zCompositions::cmultRepl (CZM)"
                @test isempty(body.size_factors)
                @test body.diagnostics.zero_replacement.zeros_replaced == 0
                @test body.diagnostics.zero_replacement.median_imputed_fraction == 0
                byt = Dict(String(x.taxon) => x for x in body.rows)
                @test byt["Up"].estimate > 0 && byt["Down"].estimate < 0
                @test all(x -> x.log2_fold_change === nothing, body.rows)
                @test occursin("CLR difference", body.figure.layout.xaxis.title)

                write(joinpath(root, "data", "studyD", "pipeline.yml"),
                      "analysis:\n  differential:\n    method: clr_welch\n    replacement_method: bayesian_multiplicative\n    bayesian_alpha: 2.5\n")
                response = _da_post("studyD", Dict("runs" => [Dict("run" => "runA"), Dict("run" => "runB")],
                                                   "table" => "merged", "rank" => "Genus"))
                @test response.status == 200
                custom = JSON3.read(String(response.body))
                @test custom.config.bayesian_alpha == 2.5
                @test occursin("(user, frac = 0.65, alpha = 2.5)", custom.method)
            end

            write(joinpath(root, "data", "studyD", "pipeline.yml"),
                  "analysis:\n  differential:\n    method: clr_welch\n    replacement_delta: 1.5\n")
            r = _da_post("studyD", Dict("runs" => [Dict("run" => "runA"), Dict("run" => "runB")],
                                        "table" => "merged", "rank" => "Genus"))
            @test r.status == 400
            @test JSON3.read(String(r.body)).error == "invalid_config"

            write(joinpath(root, "data", "studyD", "pipeline.yml"),
                  "analysis:\n  differential:\n    method: clr_welch\n    bayesian_alpha: 0\n")
            r = _da_post("studyD", Dict("runs" => [Dict("run" => "runA"), Dict("run" => "runB")],
                                        "table" => "merged", "rank" => "Genus"))
            @test r.status == 400
            @test JSON3.read(String(r.body)).error == "invalid_config"
        end
    end

    ## Without zCompositions, clr_welch refuses with ZCompositionsUnavailable and
    # the route answers 503. CI installs the package into R's base library, where
    # it cannot be hidden from .libPaths(), so the testset instead binds a
    # `requireNamespace` in R's global environment that reports zCompositions
    # missing and defers to base for every other package. reval evaluates there,
    # so the production probe sees the package as absent on any machine.
    @testset "Route: multinomial selected by the study config" begin
        _da_fixture() do
            root = MetaManifold.Server.ServerState._root[]
            write(joinpath(root, "data", "studyD", "pipeline.yml"),
                  "analysis:\n  differential:\n    method: multinomial\n")
            r = _da_post("studyD", Dict("runs" => [Dict("run" => "runA"), Dict("run" => "runB")],
                                        "table" => "merged", "rank" => "Genus"))
            body = JSON3.read(String(r.body))
            # The multinomial models need no R package, so this route runs even on
            # a machine without MASS.
            @test r.status == 200
            @test body.method isa AbstractString
            @test occursin("reference taxon", body.method)
            @test occursin("Morton et al. 2019", body.method)
            byt = Dict(String(x.taxon) => x for x in body.rows)
            @test Set(keys(byt)) == Set(["Up", "Flat", "Down"])
            # Flat carries the largest column total (238 reads against 216 and
            # 234), so it is the automatic reference.
            @test byt["Flat"].status == "reference"
            @test byt["Flat"].estimate == 0.0
            @test byt["Up"].status == "ok" && byt["Down"].status == "ok"
            @test byt["Up"].estimate ≈ 1.972120415794 rtol=1e-6
            @test byt["Down"].estimate ≈ -2.185860818556 rtol=1e-6
            @test body.config.mn_reference_taxon == "Flat"
            @test body.diagnostics.model.reference_taxon == "Flat"
            @test body.diagnostics.model.n_taxa_fitted == 3
            @test isempty(body.size_factors)
            # BH adjustment is not optional: every fitted row carries a padj, and
            # no row carries one without a p-value.
            @test all(x -> (x.padj !== nothing) == (x.pvalue !== nothing), body.rows)
            @test all(x -> x.padj !== nothing, body.rows)
            @test haskey(body, :figure) && length(body.figure.data) >= 1
            # An explicit reference reparameterises the same fit: the log ratio
            # between Up and Down (a difference of two coefficients) must not
            # change with the choice.
            write(joinpath(root, "data", "studyD", "pipeline.yml"),
                  "analysis:\n  differential:\n    method: multinomial\n    mn_reference_taxon: Down\n")
            r2 = _da_post("studyD", Dict("runs" => [Dict("run" => "runA"), Dict("run" => "runB")],
                                         "table" => "merged", "rank" => "Genus"))
            @test r2.status == 200
            b2 = JSON3.read(String(r2.body))
            by2 = Dict(String(x.taxon) => x for x in b2.rows)
            @test by2["Down"].status == "reference"
            @test by2["Up"].estimate - by2["Down"].estimate ≈
                  byt["Up"].estimate - byt["Down"].estimate rtol=1e-8
            @test by2["Up"].estimate ≈ byt["Up"].estimate - byt["Down"].estimate rtol=1e-8
            # A reference that cannot be found is a 400 with the reason.
            write(joinpath(root, "data", "studyD", "pipeline.yml"),
                  "analysis:\n  differential:\n    method: multinomial\n    mn_reference_taxon: Nonexistent\n")
            r3 = _da_post("studyD", Dict("runs" => [Dict("run" => "runA"), Dict("run" => "runB")],
                                         "table" => "merged", "rank" => "Genus"))
            @test r3.status == 400
            @test JSON3.read(String(r3.body)).error == "invalid_input"
        end
    end

    @testset "clr_welch without zCompositions is a 503" begin
        if !HAVE_R
            @test_skip false    # the clr_welch route test above covers this case
        else
            reval("""requireNamespace <- function(package, ...) {
                if (identical(package, "zCompositions")) FALSE
                else base::requireNamespace(package, ...)
            }""")
            try
                @test !rcopy(Bool, reval("requireNamespace('zCompositions', quietly = TRUE)"))
                e = try
                    differential_abundance([5 6; 7 3; 9 4; 4 8], ["a", "b", "c", "d"], ["p", "q"],
                                           ["A", "A", "B", "B"]; reference="A", contrast="B",
                                           config=DifferentialConfig(; method="clr_welch"))
                    nothing
                catch err
                    err
                end
                @test e isa ZCompositionsUnavailable
                @test occursin("renv::restore()", sprint(showerror, e))

                _da_fixture() do
                    root = MetaManifold.Server.ServerState._root[]
                    write(joinpath(root, "data", "studyD", "pipeline.yml"),
                          "analysis:\n  differential:\n    method: clr_welch\n")
                    r = _da_post("studyD", Dict("runs" => [Dict("run" => "runA"), Dict("run" => "runB")],
                                                "table" => "merged", "rank" => "Genus"))
                    body = JSON3.read(String(r.body))
                    @test r.status == 503
                    @test body.error == "r_unavailable"
                    @test occursin("zCompositions", body.message)
                end
            finally
                reval("rm(requireNamespace)")
            end
            @test !rcopy(Bool, reval("exists('requireNamespace', envir = globalenv(), inherits = FALSE)"))
            @test rcopy(Bool, reval("requireNamespace('zCompositions', quietly = TRUE)")) == HAVE_ZCOMP
        end
    end

    ## Without glmGamPoi, dispersion: glmGamPoi refuses with
    # GlmGamPoiUnavailable and the route answers 503. As above, a
    # `requireNamespace` bound in R's global environment reports glmGamPoi
    # missing and defers to base for every other package, so the production
    # probe sees the package as absent on any machine. MASS is probed first
    # and must be real, so this testset needs it.
    @testset "nb_glm without glmGamPoi refuses with GlmGamPoiUnavailable and a 503" begin
        if !HAVE_MASS
            @test_skip false    # no MASS means the ml path's own guard fires first
        else
            reval("""requireNamespace <- function(package, ...) {
                if (identical(package, "glmGamPoi")) FALSE
                else base::requireNamespace(package, ...)
            }""")
            try
                @test !rcopy(Bool, reval("requireNamespace('glmGamPoi', quietly = TRUE)"))
                e = try
                    fit_nb([5 6; 7 3; 9 4; 4 8], ["A", "A", "B", "B"], [0.0, 0.0, 0.0, 0.0];
                           levels=("A", "B"), dispersion="glmGamPoi")
                    nothing
                catch err
                    err
                end
                @test e isa GlmGamPoiUnavailable
                @test occursin("renv::restore()", sprint(showerror, e))
                _da_fixture() do
                    root = MetaManifold.Server.ServerState._root[]
                    write(joinpath(root, "data", "studyD", "pipeline.yml"),
                          "analysis:\n  differential:\n    dispersion: glmGamPoi\n")
                    response = _da_post("studyD", Dict("runs" => [Dict("run" => "runA"), Dict("run" => "runB")],
                                                       "table" => "merged", "rank" => "Genus"))
                    body = JSON3.read(String(response.body))
                    @test response.status == 503
                    @test body.error == "r_unavailable"
                    @test occursin("glmGamPoi", body.message)
                end
                # The override defers to base for everything else, so the default
                # dispersion must still fit normally with it in place. The
                # injected-effect dataset, not the minimal matrix above:
                # MEASURED with MASS::glm.nb, with 4 samples of small counts the
                # alternating fit runs theta to its upper bound (status boundary)
                # and one taxon's fit even produced NaNs (status failed), so that
                # data never reaches status ok on any machine; the dataset
                # "Negative-binomial fit recovers an injected effect" already
                # proves fits.
                r = fit_nb(effect, effect_groups, log.(tss_factors(effect, effect_samples));
                           levels=("A", "B"))
                @test all(r.status .== "ok")
            finally
                reval("rm(requireNamespace)")
            end
            @test !rcopy(Bool, reval("exists('requireNamespace', envir = globalenv(), inherits = FALSE)"))
        end
    end
end
