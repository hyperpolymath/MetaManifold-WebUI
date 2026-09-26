# SPDX-License-Identifier: AGPL-3.0-only
# Evidence for catalogue item 2 of docs/statistics/method-catalogue-v1.md, held to the
# conditions published before the implementation existed in
# docs/statistics/method-conditions/parametric-fits.md:
#
#   * known answers, where the true effect is written into the data rather than read back
#     out of the fit;
#   * an independent reference — the same data fitted directly in R, compared coefficient by
#     coefficient, and BH compared against R's p.adjust;
#   * negative controls — refusals that must throw, and unsuccessful states that must come
#     back as unsuccessful rather than as numbers;
#   * a source-level guard that the placeholder statistics this layer replaced do not return.

@testset "Estimation — parametric fits (catalogue item 2)" begin

    using OrderedCollections
    using RCall
    using MetaManifold.Estimation
    using MetaManifold.RRuntime: with_r_lock

    # ------------------------------------------------------------------
    # Synthetic data with a written-in effect
    #
    # Deterministic on purpose: a fixed table cannot drift under a changed RNG between Julia
    # versions, and the expected log2 fold changes below are arithmetic on the means rather
    # than a recording of what the fit happened to say.
    # ------------------------------------------------------------------
    est_groups = vcat(fill("A", 12), fill("B", 12))

    # taxon 1: mean 10 vs 40 (four-fold up)  -> log2FC ~ +2
    # taxon 2: mean 30 vs 30 (no effect)     -> log2FC ~ 0
    # taxon 3: mean 50 vs 5  (ten-fold down) -> log2FC ~ -3.3
    #
    # Each group block has exactly the stated mean and a variance near mu + mu^2/6, i.e.
    # negative binomial with theta ~ 6. The table this replaces had variance BELOW the mean
    # (10.2 vs 3.1 for taxon 1, group A): under-dispersed, so the NB maximum-likelihood theta
    # is infinite, MASS::theta.ml stops at its iteration limit, and the estimator correctly
    # reported those fits as failed. A fixture for a negative binomial fit has to be data a
    # negative binomial describes. Checked outside R with two independent NB2 maximum-
    # likelihood fits (a direct scipy likelihood and statsmodels), under both offsets used
    # below (log library size and RLE size factors): theta is finite for every taxon
    # (3.0 to 14.9), and the slopes are +1.50/+1.55, +0.16/+0.24 and -2.05/-2.05.
    counts_effect = [
        7.0 17 1 12 10 3 15 14 6 11 15 9   52 18 40 57 25 58 8 43 65 31 47 36;
        32.0 18 44 6 43 27 39 14 30 49 23 35   14 35 27 49 6 32 44 23 43 30 18 39;
        81.0 50 22 65 39 71 59 10 45 73 54 31   4 8 8 2 6 1 5 9 1 7 3 6
    ]
    taxa_effect = ["t_up", "t_flat", "t_down"]
    offsets_effect = log.(vec(sum(counts_effect, dims = 1)))

    meta_effect = OrderedDict{String,Any}("group" => est_groups)

    function nb_config(; dispersion = "parametric", normalization = "size_factors",
                       min_samples = 2)
        norm = AnalysisConfig.NormalizationConfig(method = normalization)
        adv = AnalysisConfig.AdvancedConfig(min_samples_per_group = min_samples,
                                            dispersion_method = dispersion)
        AnalysisConfig.AnalysisConfig(
            method = "nb_glm",
            formula = "~ group",
            metadata_columns = ["group"],
            normalization = norm,
            advanced = adv,
            created_by = "test_estimation",
        )
    end

    pv(entry) = entry["pvalue"] === nothing ? NaN : Float64(entry["pvalue"])
    pa(entry) = entry["padj"] === nothing ? NaN : Float64(entry["padj"])
    rel_err(a, b) = abs(a - b) / max(abs(b), 1e-300)

    @testset "Benjamini-Hochberg, against answers and against R" begin
        # Hand answer: BH with n = 4 on p = (0.01, 0.02, 0.03, 0.04).
        # raw rank-adjusted: 0.04, 0.04, 0.04, 0.04 -> all 0.04.
        @test Estimation.bh_adjust([0.01, 0.02, 0.03, 0.04]) == [0.04, 0.04, 0.04, 0.04]

        # Hand answer with a monotonicity violation to enforce: p = (0.001, 0.5, 0.5) gives
        # 0.003, 0.75, 0.5 before the step-up constraint, and 0.003, 0.5, 0.5 after it,
        # because an adjusted p-value can never be smaller than one with a smaller raw p.
        adjusted = Estimation.bh_adjust([0.001, 0.5, 0.5])
        @test adjusted[1] ≈ 0.003
        @test adjusted[2] ≈ 0.5
        @test adjusted[3] ≈ 0.5
        @test issorted(adjusted)          # monotone in the raw order

        # A p-value that is not a probability is a failed fit, not something to adjust.
        @test_throws ArgumentError Estimation.bh_adjust([0.01, NaN, 0.2])
        @test_throws ArgumentError Estimation.bh_adjust([0.01, 1.4, 0.2])
        @test_throws ArgumentError Estimation.bh_adjust([0.01, -0.2, 0.2])
        @test Estimation.bh_adjust(Float64[]) == Float64[]

        # Independent reference: R's own p.adjust.
        r_ok_bh = try
            with_r_lock(; timeout = 10.0) do
                RCall.reval("t_bh_p <- c(0.001, 0.5, 0.5, 0.02, 0.7, 0.04, 0.0009, 0.31)")
                RCall.rcopy(RCall.reval("p.adjust(t_bh_p, method = \"BH\")"))
            end
        catch
            nothing
        end
        if r_ok_bh === nothing
            @info "SKIPPED (by name): BH comparison against R p.adjust — R is not reachable here."
            @test_skip Estimation.bh_adjust([0.001, 0.5, 0.5, 0.02, 0.7, 0.04, 0.0009, 0.31])
        else
            mine = Estimation.bh_adjust([0.001, 0.5, 0.5, 0.02, 0.7, 0.04, 0.0009, 0.31])
            @test all(rel_err(mine[i], r_ok_bh[i]) < 1e-12 for i in eachindex(mine))
        end
    end

    @testset "the formula subset is small and refusal is by name" begin
        @test Estimation.supported_terms("~ group") == ["group"]
        @test Estimation.supported_terms("~ group + batch") == ["group", "batch"]
        @test Estimation.primary_term("~ batch + group") == "batch"
        @test Estimation.supported_terms("disease ~ group + age") == ["group", "age"]

        for (formula, why) in [
            ("~ group * batch"  => "interaction"),
            ("~ group:batch"    => "interaction"),
            ("~ (1|batch)"      => "random effect"),
            ("~ I(age^2)"       => "transform"),
            ("~ log(abundance)" => "transform"),
            ("~ poly(age, 2)"   => "transform"),
            ("~ group - batch"  => "minus"),
            ("~ group + group"  => "duplicate"),
            ("~ group +"        => "dangling plus"),
            ("group"            => "missing tilde"),
            (raw"~ group$bad"   => "dollar"),
            (raw"~ `group`"     => "backtick"),
        ]
            # The message has to say which construct was refused: a refusal the caller cannot
            # act on is only slightly better than a silent change of design.
            @test_throws Estimation.UnsupportedFormula Estimation.supported_terms(formula)
        end
        err = try
            Estimation.supported_terms("~ group * batch")
        catch e
            e
        end
        @test err isa Estimation.UnsupportedFormula
        @test occursin("interaction", sprint(showerror, err))
    end

    @testset "a design that cannot be built is an unsuccessful state, not a fit" begin
        # No metadata at all.
        no_design = Estimation.estimate_models(nb_config(), counts_effect;
                                               offset = offsets_effect, taxa_ids = taxa_effect)
        @test no_design.status == :not_run
        @test isempty(no_design.results)
        @test occursin("descriptive summary", no_design.reason)

        # Metadata missing the term the formula names.
        wrong_col = Estimation.estimate_models(nb_config(), counts_effect;
                                               sample_metadata = OrderedDict{String,Any}("treatment" => est_groups),
                                               offset = offsets_effect, taxa_ids = taxa_effect)
        @test wrong_col.status == :not_run
        @test occursin("group", wrong_col.reason)

        # Metadata of the wrong length.
        short = Estimation.estimate_models(nb_config(), counts_effect;
                                           sample_metadata = OrderedDict{String,Any}("group" => ["A", "B"]),
                                           offset = offsets_effect, taxa_ids = taxa_effect)
        @test short.status == :not_run
        @test occursin("values for", short.reason)

        # A grouping column with one level has no contrast to estimate.
        one_level = Estimation.estimate_models(nb_config(), counts_effect;
                                               sample_metadata = OrderedDict{String,Any}("group" => fill("A", 24)),
                                               offset = offsets_effect, taxa_ids = taxa_effect)
        @test one_level.status == :not_run
        @test occursin("distinct value", one_level.reason)

        # A hole in the design is refused rather than papered over.
        meta_with_hole = OrderedDict{String,Any}(
            "group" => vcat([x for x in fill("A", 12)], [missing for _ in 1:12]))
        @test_throws ArgumentError Estimation.estimate_models(
            nb_config(), counts_effect; sample_metadata = meta_with_hole,
            offset = offsets_effect, taxa_ids = taxa_effect)
    end

    @testset "glmGamPoi is implemented, and what is not ported is refused by name" begin
        # Issue #21 replaced the by-name refusal with a real path: pass 1 fits the mean sweep
        # with MASS::glm.nb, the pure-Julia port of glmGamPoi's dispersion pipeline runs on
        # those means (src/analysis/dispersion.jl), and pass 2 refits at the fixed dispersion.
        # The refusal that remains is the reference's natural-spline abundance trend, which is
        # not ported, plus the size of the table at which the reference would switch it on.
        err = try
            Estimation.estimate_models(nb_config(dispersion = "glmGamPoi"), counts_effect;
                                       sample_metadata = meta_effect, offset = offsets_effect,
                                       taxa_ids = taxa_effect)
            nothing
        catch e
            e
        end
        # Either the R-backed path ran (no error) or it refused with a reason that names the
        # limitation. What it must NOT do is return per-taxon theta while calling itself
        # glmGamPoi, and it must not refuse merely because the method is named.
        if err !== nothing
            @test err isa ErrorException || err isa ArgumentError
            @test !occursin("not implemented", sprint(showerror, err))
        end

        # Every spelling of the method reaches the same code path: the configuration layer
        # lower-cases what it stores, so a differently-cased request must not fall through to
        # "unknown method" at the door.
        for spelling in ("glmgampoi", "GLMGAMPOI", " glmGamPoi ")
            outcome = try
                Estimation.estimate_models(nb_config(dispersion = spelling), counts_effect;
                                           sample_metadata = meta_effect, offset = offsets_effect,
                                           taxa_ids = taxa_effect)
                nothing
            catch e
                e
            end
            @test outcome === nothing ||
                  occursin("glmGamPoi", sprint(showerror, outcome)) ||
                  occursin("spline", sprint(showerror, outcome))
        end

        # Counting without an offset would compare library sizes instead of groups.
        @test_throws ArgumentError Estimation.estimate_models(
            nb_config(), counts_effect; sample_metadata = meta_effect, taxa_ids = taxa_effect)

        # An offset means nothing to a Gaussian fit on CLR units, so it is refused rather than
        # accepted and ignored.
        clr_norm = AnalysisConfig.NormalizationConfig(method = "clr")
        clr_config = AnalysisConfig.AnalysisConfig(
            method = "clr_lm", formula = "~ group", metadata_columns = ["group"],
            normalization = clr_norm, created_by = "test_estimation_clr")
        @test_throws ArgumentError Estimation.estimate_models(
            clr_config, counts_effect; sample_metadata = meta_effect,
            offset = offsets_effect, taxa_ids = taxa_effect)

        # A binomial fit on proportions has no number of trials unless one is invented.
        logistic_norm = AnalysisConfig.NormalizationConfig(method = "relative")
        logistic_config = AnalysisConfig.AnalysisConfig(
            method = "logistic", formula = "~ group", outcome_column = "group",
            metadata_columns = ["group"], normalization = logistic_norm,
            created_by = "test_estimation_logistic")
        @test_throws ArgumentError Estimation.estimate_models(
            logistic_config, counts_effect; sample_metadata = meta_effect, taxa_ids = taxa_effect)
    end

    # ------------------------------------------------------------------
    # Fits that need R. Skipped loudly and by name where R is absent, because a silent skip
    # would turn a provisioning defect into a green run.
    # ------------------------------------------------------------------
    r_ok = try
        with_r_lock(; timeout = 10.0) do
            RCall.reval("suppressPackageStartupMessages(library(MASS))")
            true
        end
    catch
        false
    end

    if r_ok
        @testset "a written-in effect is recovered, and matches a direct R fit" begin
            outcome = Estimation.estimate_models(nb_config(), counts_effect;
                                                 sample_metadata = meta_effect,
                                                 offset = offsets_effect,
                                                 taxa_ids = taxa_effect)

            @test outcome.status == :ok
            @test length(outcome.results) == 3
            @test outcome.diagnostics["n_tested"] == 3
            @test outcome.diagnostics["n_failed"] == 0
            @test outcome.provenance["status"] == "ok"
            @test outcome.provenance["correction"] == "BH"

            up = outcome.results["t_up"]
            flat = outcome.results["t_flat"]
            down = outcome.results["t_down"]

            # Known answers: four-fold up, no effect, ten-fold down.
            @test up["estimate"] ≈ log(4) atol = 0.5
            @test up["log2FoldChange"] ≈ 2.0 atol = 0.8
            @test down["estimate"] < 0
            @test abs(flat["estimate"]) < 0.6
            @test pv(up) < 0.01
            @test up["status"] == "ok"

            # Adjusted p-values are never smaller than raw ones, and never above 1.
            for entry in values(outcome.results)
                @test pa(entry) >= pv(entry) - 1e-12
                @test pa(entry) <= 1.0
                @test entry["estimate_scale"] isa String
                @test occursin("log_counts", entry["estimate_scale"])
            end

            # The BH family is the three features here, computed by the same function the
            # module used; comparing against it checks the wiring, not the arithmetic (which
            # the p.adjust comparison above covers).
            raw = [pv(outcome.results["t_up"]), pv(outcome.results["t_flat"]), pv(outcome.results["t_down"])]
            expected = Estimation.bh_adjust(raw)
            @test rel_err(pa(outcome.results["t_up"]), expected[1]) < 1e-12
            @test rel_err(pa(outcome.results["t_flat"]), expected[2]) < 1e-12
            @test rel_err(pa(outcome.results["t_down"]), expected[3]) < 1e-12

            # Independent reference: the same fit, written directly in R. If the module wired
            # the offset, the response or the contrast wrongly, these diverge.
            reference = with_r_lock(; timeout = 30.0) do
                RCall.globalEnv[:t_counts] = counts_effect
                RCall.globalEnv[:t_group] = est_groups
                RCall.globalEnv[:t_offset] = offsets_effect
                RCall.reval("""
                    t_group_f <- factor(t_group)
                    t_fit <- MASS::glm.nb(t_counts[1, ] ~ t_group_f + offset(t_offset))
                    t_cf <- summary(t_fit)[["coefficients"]]
                    t_est <- t_cf[2, 1]
                    t_se <- t_cf[2, 2]
                    t_p <- t_cf[2, 4]
                    t_theta <- t_fit[["theta"]]
                """)
                (
                    est = RCall.rcopy(RCall.reval("t_est")),
                    se = RCall.rcopy(RCall.reval("t_se")),
                    p = RCall.rcopy(RCall.reval("t_p")),
                    theta = RCall.rcopy(RCall.reval("t_theta")),
                )
            end
            @test rel_err(up["estimate"], reference.est) < 1e-6
            @test rel_err(up["standard_error"], reference.se) < 1e-6
            @test rel_err(pv(up), reference.p) < 1e-6
            @test rel_err(up["dispersion_theta"], reference.theta) < 1e-6

            # The provenance has to be usable by someone else: which R, which MASS, which
            # family, which offset, and the hashes of the tables the numbers came from.
            for key in ("r_version", "mass_version", "family", "offset", "fits_csv_sha256",
                        "coefficients_csv_sha256", "primary_contrast", "randomness")
                @test haskey(outcome.provenance, key)
            end
            @test length(outcome.provenance["fits_csv_sha256"]) == 64
        end

        @testset "a feature that cannot be fitted is reported, not invented" begin
            counts_with_constant = vcat(counts_effect, permutedims(fill(7.0, 24)))
            outcome = Estimation.estimate_models(nb_config(), counts_with_constant;
                                                 sample_metadata = meta_effect,
                                                 offset = offsets_effect,
                                                 taxa_ids = vcat(taxa_effect, ["t_constant"]))
            @test outcome.status == :partial
            @test outcome.diagnostics["n_failed"] == 1
            @test outcome.diagnostics["n_tested"] == 3

            constant = outcome.results["t_constant"]
            @test constant["status"] == "failed"
            @test constant["pvalue"] === nothing
            @test constant["padj"] === nothing
            @test constant["estimate"] === nothing
            @test occursin("constant", constant["note"])
            @test occursin("excluded", outcome.diagnostics["failure_note"])
        end

        @testset "logistic: presence/absence, with the design stated" begin
            presence = zeros(3, 20)
            presence[1, 1:18] .= 1.0; presence[1, 19:20] .= 0.0     # 18/20 vs 0/20
            presence[2, 1:10] .= 1.0; presence[2, 11:20] .= 1.0     # present everywhere
            presence[3, 1:10] .= 0.0; presence[3, 11:20] .= 0.0     # absent everywhere
            groups = vcat(fill("A", 10), fill("B", 10))

            norm = AnalysisConfig.NormalizationConfig(method = "presence_absence")
            config = AnalysisConfig.AnalysisConfig(
                method = "logistic", formula = "~ group", outcome_column = "group",
                metadata_columns = ["group"], normalization = norm,
                advanced = AnalysisConfig.AdvancedConfig(min_samples_per_group = 2),
                created_by = "test_estimation_logistic")

            outcome = Estimation.estimate_models(config, presence;
                                                 sample_metadata = OrderedDict{String,Any}("group" => groups),
                                                 taxa_ids = ["present_mostly_A", "present_all", "absent_all"])
            @test outcome.status == :partial          # the two constant features are excluded
            @test outcome.diagnostics["n_tested"] == 1

            # The constant features say so and carry no number.
            @test outcome.results["present_all"]["status"] == "failed"
            @test outcome.results["absent_all"]["pvalue"] === nothing

            separator = outcome.results["present_mostly_A"]
            @test separator["status"] in ("ok", "boundary")
            @test separator["odds_ratio"] ≈ exp(separator["estimate"])
            # Separation is not silently forgiven: if R says it happened, the row says so.
            if separator["status"] == "boundary"
                @test occursin("separation", separator["note"])
            end
        end

        @testset "Gaussian fit on CLR units records that its estimate is not a fold change" begin
            clr = similar(counts_effect)
            for j in 1:size(counts_effect, 2)
                column = log.(counts_effect[:, j])
                clr[:, j] = column .- mean(column)
            end
            clr_norm = AnalysisConfig.NormalizationConfig(method = "clr")
            config = AnalysisConfig.AnalysisConfig(
                method = "clr_lm", formula = "~ group", metadata_columns = ["group"],
                normalization = clr_norm,
                advanced = AnalysisConfig.AdvancedConfig(min_samples_per_group = 2),
                created_by = "test_estimation_clr_fit")

            outcome = Estimation.estimate_models(config, clr;
                                                 sample_metadata = meta_effect,
                                                 taxa_ids = taxa_effect)
            @test outcome.status == :ok
            @test outcome.results["t_up"]["estimate"] > 0
            @test outcome.results["t_down"]["estimate"] < 0
            @test occursin("clr_difference", outcome.results["t_up"]["estimate_scale"])
            @test !haskey(outcome.results["t_up"], "log2FoldChange")
            @test outcome.results["t_up"]["statistic_name"] == "t"
        end

        @testset "end to end: prepare_analysis_table -> run_analysis -> a number from the data" begin
            config = nb_config()
            sample_ids = ["s$i" for i in 1:24]

            (prepared, diagnostics, manifest, sids, tids) = Execution.prepare_analysis_table(
                config, counts_effect;
                sample_metadata = meta_effect, sample_ids = sample_ids,
                taxa_ids = taxa_effect, drop_policy = "drop")

            # The offset the manifest carries is what the fit consumes; without it the GLM
            # would compare library sizes.
            @test !isnothing(manifest.offset)
            @test length(manifest.offset) == 24

            result = Execution.run_analysis(
                Execution.RAdapter(method = "nb_glm"), config, prepared;
                sample_metadata = meta_effect, diagnostics = diagnostics, manifest = manifest,
                sample_ids = sids, taxa_ids = tids)

            @test result isa Execution.ExecutionResult
            @test length(result.results) == 3
            @test result.provenance["estimation"]["status"] == "ok"
            @test result.diagnostics.checks["estimation"]["n_tested"] == 3
            @test result.results["t_up"]["pvalue"] < 0.01
            @test result.results["t_up"]["padj"] >= result.results["t_up"]["pvalue"] - 1e-12
            @test result.results["t_up"]["status"] == "ok"

            # Nothing here is a function of the feature's name; the old mock was.
            for (label, entry) in result.results
                @test entry["pvalue"] isa Float64
                @test entry["status"] in ("ok", "boundary")
            end
        end
    else
        @info "SKIPPED (by name): live-R estimation tests — R with MASS is not reachable on this machine. CI installs both; a skip there is a provisioning defect, not a pass."
        @test_skip Estimation.estimate_models(nb_config(), counts_effect;
                                              sample_metadata = meta_effect,
                                              offset = offsets_effect, taxa_ids = taxa_effect)
    end

    # ------------------------------------------------------------------
    # The negative control that matters most: the placeholder statistics cannot come back.
    # ------------------------------------------------------------------
    @testset "no placeholder statistics in the execution path" begin
        execution_source = read(joinpath(@__DIR__, "..", "..", "src", "analysis", "Execution.jl"), String)
        @test !occursin("hash(taxon_id)", execution_source)
        @test !occursin("hash(taxa_id)", execution_source)
        @test !occursin("mock BH", execution_source)
        @test !occursin("Mock results", execution_source)
        # And the estimator really is the one being called.
        @test occursin("Estimation.estimate_models", execution_source)

        estimation_source = read(joinpath(@__DIR__, "..", "..", "src", "analysis", "estimation.jl"), String)
        @test !occursin("hash(", estimation_source)
        # A `rand(` here would mean a resampling step without a recorded seed; these fits have
        # no random component at all, and the provenance says so.
        @test !occursin("rand(", estimation_source)
    end
end
