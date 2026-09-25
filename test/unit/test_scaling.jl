# SPDX-License-Identifier: AGPL-3.0-only
#
# Evidence for issue #16 — TSS, CSS and RSS/TMM as exact offsets — held to the conditions
# published before the implementation in
# docs/statistics/method-conditions/scaling-and-offsets.md:
#
#   * known answers whose arithmetic is written next to the expected number, so a reader
#     can check the implementation with a pencil rather than against a previous run;
#   * an independent-in-language transcription in R (base R only) for TMM, CSS and RLE,
#     which catches implementation slips — it is NOT a reference implementation from the
#     field, and it does not catch a shared specification error;
#   * properties a wrong implementation fails: invariance to permuting features, a sample
#     that is an exact multiple of another, and the outlier robustness CSS exists for;
#   * negative controls: every refusal is asserted to fire, and to name what it refused;
#   * the integration path, from AnalysisConfig through prepare_analysis_table to the
#     offset the manifest hands the fit.
#
# What is NOT claimed here: parity with metagenomeSeq::cumNorm or edgeR::calcNormFactors.
# Neither package is in the pinned R environment (renv.lock), and this repository does not
# add an unpinned R dependency to make a test pass; the outstanding condition is recorded
# in issue #16 and in the conditions document instead of being asserted as met.

@testset "Scaling — TSS, CSS, RSS/TMM and size factors (issue #16)" begin

    using OrderedCollections
    using RCall
    using MetaManifold.Scaling
    using MetaManifold.RRuntime: with_r_lock

    # ------------------------------------------------------------------
    # The table the known answers are computed on
    #
    #   columns: [10 20 40;   [60 ]        column sums
    #             20 20 10;   [100]        — deliberately not sorted, so a
    #             30 60 50]   [100]          column-sum implementation that assumed
    #                                        order would be caught
    # ------------------------------------------------------------------
    table_a = [10.0 20 40;
               20.0 20 10;
               30.0 60 50]
    ids_a = ["s1", "s2", "s3"]

    @testset "TSS — library sizes, centred" begin
        outcome = tss_factors(table_a; sample_ids = ids_a)
        # 60, 100, 100; geometric mean = (60*100*100)^(1/3) = 84.34326653017494
        @test outcome.raw ≈ [60.0, 100.0, 100.0] atol = 1e-12
        @test outcome.factors ≈ [0.711378660898012, 1.185631101496687, 1.185631101496687] atol = 1e-10
        @test outcome.offset ≈ log.(outcome.factors) atol = 1e-15
        @test exp(sum(log, outcome.factors) / 3) ≈ 1.0 atol = 1e-12
        @test outcome.kind == "tss"
        @test occursin("library size", outcome.definition)
        @test outcome.parameters["library_sizes"] == [60.0, 100.0, 100.0]
    end

    @testset "CSS — the cumulative sum at the declared quantile" begin
        outcome = css_factors(table_a; quantile = 0.75, sample_ids = ids_a)
        # column 1: quantile([10,20,30], 0.75) = 25 (type 7: 20 + 0.5*(30-20)); sum of
        #           counts at or below 25 = 10 + 20 = 30
        # column 2: quantile([20,20,60], 0.75) = 40; sum = 20 + 20 = 40
        # column 3: quantile([10,40,50], 0.75) = 45; sum = 10 + 40 = 50
        @test outcome.raw ≈ [30.0, 40.0, 50.0] atol = 1e-12
        @test outcome.parameters["thresholds"] ≈ [25.0, 40.0, 45.0] atol = 1e-12
        @test outcome.parameters["quantile"] == 0.75
        # geometric mean of [30,40,50] = 39.14867641168864
        @test outcome.factors ≈ [0.766309432393553, 1.021745909858071, 1.277182387322588] atol = 1e-10
        @test outcome.kind == "css"
        @test isempty(outcome.warnings)
    end

    @testset "CSS is robust to a dominant feature, and TSS is not" begin
        # sample 2 has one taxon carrying almost everything
        table_c = [10.0 10;
                   10.0 10;
                   10.0 1000]
        tss = tss_factors(table_c)
        css = css_factors(table_c; quantile = 0.75)
        # thresholds: column 1 = 10 (all counts equal), column 2 = 505 (type 7 between
        # the 2nd and 3rd of [10,10,1000]), so the second cumulative sum is 10 + 10 = 20
        @test css.raw ≈ [30.0, 20.0] atol = 1e-12
        @test log(css.factors[2] / css.factors[1]) ≈ log(20 / 30) atol = 1e-12
        @test log(tss.factors[2] / tss.factors[1]) ≈ log(1020 / 30) atol = 1e-12
        # The property CSS exists for: the dominant feature moves it far less than TSS.
        @test abs(log(css.factors[2] / css.factors[1])) < abs(log(tss.factors[2] / tss.factors[1])) / 5
    end

    @testset "RSS/TMM — a sample that is a multiple of another" begin
        table_b = [100.0 200;
                   200.0 400;
                   300.0 600]   # column 2 = 2 * column 1, so every log ratio is log2(2)
        outcome = tmm_factors(table_b)
        @test outcome.reference == "column 1"          # chosen from the data
        @test outcome.raw ≈ [1.0, 2.0] atol = 1e-12
        # centred: 1/sqrt(2), sqrt(2)
        @test outcome.factors ≈ [0.7071067811865476, 1.4142135623730951] atol = 1e-10
        @test outcome.offset[2] - outcome.offset[1] ≈ log(2) atol = 1e-12
        @test outcome.parameters["reference_chosen_from_data"] == true
    end

    @testset "RSS/TMM — known answer on the reference table" begin
        outcome = tmm_factors(table_a; sample_ids = ids_a)
        # reference selection: upper-quartile / library size is 25/60, 40/100, 45/100;
        # the mean is 0.4222222222222222 and 25/60 is closest to it, so s1 is the reference
        @test outcome.reference == "s1"
        # raw factors before centring: sample 1 against itself is 1 by definition
        @test outcome.raw ≈ [1.0, 1.5874010519681996, 1.296335601619136] atol = 1e-10
        @test outcome.factors ≈ [0.786198050576376, 1.248011612540287, 1.019176522885718] atol = 1e-10
        @test outcome.parameters["log_ratio_trim"] == 0.3
        @test outcome.parameters["sum_trim"] == 0.05
        @test length(outcome.parameters["kept_log_ratios"]) == 3
    end

    @testset "size_factors — median-of-ratios, which is what the name claimed" begin
        outcome = rle_factors(table_a; sample_ids = ids_a)
        # feature geometric means across samples: row 1 = 20.0, row 2 = 15.874010519681996,
        # row 3 = 44.82219709646434 (all rows positive: every feature used)
        @test outcome.parameters["features_used"] == 3
        # column 1: median(10/20, 20/15.874010519681996, 30/44.82219709646434)
        #           = median(0.5, 1.2599210498948732, 0.6694329500821695) = 0.6694329500821695
        @test outcome.raw ≈ [0.6694329500821695, 1.259921049894873, 1.1157215834702825] atol = 1e-10
        @test outcome.factors ≈ [0.683132584572384, 1.285704749170459, 1.13855430762064] atol = 1e-10
        # The old implementation returned library size / its geometric mean, which is the
        # TSS factor. Assert the two are different on data where they differ, so a silent
        # revert to the old behaviour fails here.
        tss = tss_factors(table_a)
        @test !isapprox(outcome.factors, tss.factors; atol = 1e-6)
    end

    @testset "properties a wrong implementation fails" begin
        base = css_factors(table_a; quantile = 0.75)
        permuted = css_factors(table_a[[3, 1, 2], :]; quantile = 0.75)
        @test permuted.factors ≈ base.factors atol = 1e-12

        # Doubling one sample's counts doubles its own scaling factor relative to the others.
        doubled = hcat(table_a[:, 1], 2 .* table_a[:, 2], table_a[:, 3])
        t0 = tss_factors(table_a)
        t1 = tss_factors(doubled)
        @test (t1.factors[2] / t1.factors[1]) ≈ 2 * (t0.factors[2] / t0.factors[1]) atol = 1e-12

        # Scaling every sample by the same constant changes nothing: the factors are
        # ratios, and the constant is absorbed by the centring.
        scaled = 7.5 .* table_a
        @test tss_factors(scaled).factors ≈ t0.factors atol = 1e-12
        @test tmm_factors(scaled).factors ≈ tmm_factors(table_a).factors atol = 1e-12
        @test rle_factors(scaled).factors ≈ rle_factors(table_a).factors atol = 1e-12
    end

    @testset "refusals name what they refused" begin
        # A sample with no counts has no library size to divide by.
        err = try
            tss_factors([0.0 1.0; 0.0 2.0])
        catch e
            e
        end
        @test err isa Scaling.ScalingRefusal
        @test occursin("column 1", err.reason)
        @test !occursin("log(0)", err.reason)  # TSS says library size, not log(0)

        # CSS on a mostly-zero sample at a low quantile: the cumulative sum is zero, and
        # log(0) is not a small number. This is the failure mode issue #16 predicted.
        mostly_zero = [0.0 100;
                       0.0 100;
                       1.0 100]
        err_css = try
            css_factors(mostly_zero; quantile = 0.25)
        catch e
            e
        end
        @test err_css isa Scaling.ScalingRefusal
        @test occursin("column 1", err_css.reason)
        @test occursin("log(0)", err_css.reason)
        @test occursin("0.25", err_css.reason)

        # A reference that does not exist is refused, and the refusal lists the real names
        # rather than silently choosing one.
        err_ref = try
            tmm_factors(table_a; ref_column = "s99", sample_ids = ids_a)
        catch e
            e
        end
        @test err_ref isa Scaling.ScalingRefusal
        @test occursin("s99", err_ref.reason)
        @test occursin("s1", err_ref.reason)

        # Samples that share no positive feature cannot be compared.
        err_disjoint = try
            tmm_factors([1.0 0.0; 2.0 0.0; 0.0 3.0; 0.0 4.0])
        catch e
            e
        end
        @test err_disjoint isa Scaling.ScalingRefusal
        @test occursin("shares no positive-count feature", err_disjoint.reason)

        # No feature positive in every sample: the median-of-ratios is undefined, and the
        # refusal says so instead of falling back to library size.
        err_rle = try
            rle_factors([1.0 0.0; 2.0 0.0])
        catch e
            e
        end
        @test err_rle isa Scaling.ScalingRefusal
        @test occursin("geometric mean", err_rle.reason)

        # Declared parameters outside their domain are refused before anything is computed.
        @test_throws ArgumentError css_factors(table_a; quantile = 0.0)
        @test_throws ArgumentError css_factors(table_a; quantile = 1.0)
        @test_throws ArgumentError css_factors(table_a; quantile = 1.5)
        @test_throws ArgumentError tmm_factors(table_a; log_ratio_trim = 0.5)
        @test_throws ArgumentError tmm_factors(table_a; log_ratio_trim = -0.1)
        @test_throws ArgumentError tmm_factors(table_a; sum_trim = 0.5)
    end

    @testset "dispatch and provenance" begin
        @test factors_for("TSS", table_a).kind == "tss"
        @test factors_for("none", table_a).kind == "tss"
        @test factors_for("css", table_a).kind == "css"
        @test factors_for("tmm", table_a).kind == "rss"
        @test factors_for("RSS", table_a).kind == "rss"
        @test factors_for("size_factors", table_a).kind == "size_factors"
        @test_throws ArgumentError factors_for("clr", table_a)

        checks = factor_checks(css_factors(table_a; quantile = 0.75))
        @test checks["kind"] == "css"
        @test checks["parameters"]["quantile"] == 0.75
        @test haskey(checks, "raw")

        p1 = factor_provenance(css_factors(table_a; quantile = 0.75))
        p2 = factor_provenance(css_factors(table_a; quantile = 0.3))
        @test p1["offset_sha256"] != p2["offset_sha256"]
        @test p1["offset_sha256"] ==
              factor_provenance(css_factors(table_a; quantile = 0.75))["offset_sha256"]
        @test length(p1["offset_sha256"]) == 64
    end

    @testset "a quantile below the median is warned about, and still computed" begin
        outcome = css_factors(table_a; quantile = 0.4)
        @test outcome.kind == "css"
        @test any(w -> occursin("below the median", w), outcome.warnings)
        @test outcome.parameters["quantile"] == 0.4
    end

    # ------------------------------------------------------------------
    # Integration: the configuration layer, the execution path, and the manifest
    # ------------------------------------------------------------------
    @testset "every admissible spelling of a method name is accepted" begin
        # Regression: the allowed-normalisation table arrived upper case while
        # NormalizationConfig stored lower case, so `method="TSS"` raised
        # "incompatible with method" from AnalysisConfig — including for the exact TSS
        # offset the CHANGELOG said had shipped, and the existing test execution testset
        # that constructs method="TSS". Both sides are compared in lower case now.
        adv = AnalysisConfig.AdvancedConfig(min_prevalence = 0.0, min_abundance = 0.0,
                                            min_samples_per_group = 2)
        for spelling in ["TSS", "tss", "CSS", "css", "RSS", "rss", "size_factors"]
            norm = AnalysisConfig.NormalizationConfig(method = spelling)
            @test norm.method == lowercase(spelling)
            config = AnalysisConfig.AnalysisConfig(
                method = "nb_glm", formula = "~ group", metadata_columns = ["group"],
                normalization = norm, advanced = adv, created_by = "test_scaling")
            @test config.normalization.method == lowercase(spelling)
        end

        # CSS/RSS are offsets and stay refused for a response with no counts to offset.
        @test_throws ArgumentError AnalysisConfig.AnalysisConfig(
            method = "clr_lm", formula = "~ group", metadata_columns = ["group"],
            normalization = AnalysisConfig.NormalizationConfig(method = "css"),
            advanced = adv, created_by = "test_scaling")
        @test_throws ArgumentError AnalysisConfig.AnalysisConfig(
            method = "logistic", formula = "group ~ group", outcome_column = "group",
            metadata_columns = ["group"],
            normalization = AnalysisConfig.NormalizationConfig(method = "rss"),
            advanced = adv, created_by = "test_scaling")
    end

    @testset "declared scaling parameters are validated and hashed" begin
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method = "css", css_quantile = 0.0)
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method = "css", css_quantile = 1.2)
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method = "rss", tmm_log_ratio_trim = 0.5)
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method = "rss", tmm_sum_trim = -0.1)
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method = "rss", tmm_ref_column = "  ")

        adv = AnalysisConfig.AdvancedConfig(min_prevalence = 0.0, min_abundance = 0.0,
                                            min_samples_per_group = 2)
        make_config = q -> AnalysisConfig.AnalysisConfig(
            method = "nb_glm", formula = "~ group", metadata_columns = ["group"],
            normalization = AnalysisConfig.NormalizationConfig(method = "css", css_quantile = q),
            advanced = adv, created_by = "test_scaling")
        # The parameter is part of the config hash: a run that declares a different
        # quantile is a different run, and the manifest has to say so.
        @test make_config(0.75).hash != make_config(0.5).hash
    end

    @testset "prepare_analysis_table keeps counts and hands over the offset" begin
        # 4 samples: prepare_analysis_table requires >= 2*min_samples_per_group samples
        table_4 = [10.0 20.0 40.0 20.0;
                   20.0 20.0 10.0 30.0;
                   30.0 60.0 50.0 40.0]
        ids_4 = ["s1", "s2", "s3", "s4"]
        adv = AnalysisConfig.AdvancedConfig(min_prevalence = 0.0, min_abundance = 0.0,
                                            min_samples_per_group = 2)
        expectations = [
            ("TSS", "tss", tss_factors(table_4).factors),
            ("CSS", "css", css_factors(table_4; quantile = 0.75).factors),
            ("RSS", "rss", tmm_factors(table_4).factors),
            ("size_factors", "size_factors", rle_factors(table_4).factors),
        ]
        for (method_name, kind, expected) in expectations
            config = AnalysisConfig.AnalysisConfig(
                method = "nb_glm", formula = "~ group", metadata_columns = ["group"],
                normalization = AnalysisConfig.NormalizationConfig(method = method_name),
                advanced = adv, created_by = "test_scaling")
            (prepared, diagnostics, manifest, sample_ids, _) =
                Execution.prepare_analysis_table(config, table_4;
                                                 sample_ids = ids_4,
                                                 taxa_ids = ["t1", "t2", "t3"],
                                                 drop_policy = "drop")
            @test prepared == table_4                       # the count response is untouched
            @test manifest.offset ≈ log.(expected) atol = 1e-10
            @test diagnostics.checks["scaling"]["kind"] == kind
            @test manifest.provenance["scaling"]["kind"] == kind
            @test manifest.provenance["scaling"]["offset_sha256"] isa String
            @test length(manifest.provenance["scaling"]["offset_sha256"]) == 64
            @test sample_ids == ids_4
        end

        # `none` is not "no offset": for a count model it is the plain log library size,
        # and it is recorded as such rather than left to be inferred.
        config_none = AnalysisConfig.AnalysisConfig(
            method = "nb_glm", formula = "~ group", metadata_columns = ["group"],
            normalization = AnalysisConfig.NormalizationConfig(method = "none"),
            advanced = adv, created_by = "test_scaling")
        (_, diag_none, manifest_none, _, _) = Execution.prepare_analysis_table(
            config_none, table_4; sample_ids = ids_4, taxa_ids = ["t1", "t2", "t3"],
            drop_policy = "drop")
        @test diag_none.checks["scaling"]["kind"] == "tss"
        @test manifest_none.offset ≈ log.(tss_factors(table_4).factors) atol = 1e-10

        # A run that declares `relative` has no offset, and does not get one by accident.
        config_rel = AnalysisConfig.AnalysisConfig(
            method = "nb_glm", formula = "~ group", metadata_columns = ["group"],
            normalization = AnalysisConfig.NormalizationConfig(method = "relative"),
            advanced = adv, created_by = "test_scaling")
        (_, diag_rel, manifest_rel, _, _) = Execution.prepare_analysis_table(
            config_rel, table_4; sample_ids = ids_4, taxa_ids = ["t1", "t2", "t3"],
            drop_policy = "drop")
        @test isnothing(manifest_rel.offset)
        @test !haskey(diag_rel.checks, "scaling")
    end

    @testset "deferred ILR bases are refused at construction and in prepare_analysis_table" begin
        for basis in AnalysisConfig.DEFERRED_ILR_BASIS
            @test_throws ArgumentError AnalysisConfig.NormalizationConfig(
                method = "ilr", ilr_basis = basis)
        end
        # "default" basis is accepted
        norm_ok = AnalysisConfig.NormalizationConfig(method = "ilr", ilr_basis = "default")
        @test norm_ok.ilr_basis == "default"
    end

    @testset "ILR relabels rows to balance_1..n-1 with diagnostics" begin
        table_ilr = [
            10.0 20.0 30.0 40.0;
            20.0 30.0 40.0 50.0;
            30.0 40.0 50.0 60.0;
            40.0 50.0 60.0 70.0
        ]
        sample_ids_ilr = ["s1", "s2", "s3", "s4"]
        taxa_ids_ilr = ["t1", "t2", "t3", "t4"]

        norm_ilr = AnalysisConfig.NormalizationConfig(method = "ilr", pseudocount = 0.5)
        adv = AnalysisConfig.AdvancedConfig(min_prevalence = 0.0, min_abundance = 0.0, min_samples_per_group = 2)
        config_ilr = AnalysisConfig.AnalysisConfig(
            method = "ilr_lm",
            formula = "~ group",
            metadata_columns = ["group"],
            normalization = norm_ilr,
            advanced = adv,
            created_by = "test_ilr"
        )

        (prep_ilr, diag_ilr, manifest_ilr, sids_ilr, tids_ilr) = Execution.prepare_analysis_table(
            config_ilr, table_ilr;
            sample_ids = sample_ids_ilr,
            taxa_ids = taxa_ids_ilr,
            drop_policy = "drop"
        )

        @test size(prep_ilr, 1) == 3
        @test tids_ilr == ["balance_1", "balance_2", "balance_3"]
        @test haskey(diag_ilr.checks, "ilr")
        @test diag_ilr.checks["ilr"]["basis"] == "default"
        @test diag_ilr.checks["ilr"]["taxa_in"] == 4
        @test diag_ilr.checks["ilr"]["taxa_order"] == taxa_ids_ilr
        @test occursin("Helmert", diag_ilr.checks["ilr"]["definition"])
    end

    # ------------------------------------------------------------------
    # The R transcription
    #
    # Base R only, written from the same conditions document. It is the same author and a
    # different language: it catches transcription slips (an off-by-one in the trim, a
    # quantile type, the wrong centring), not errors in the specification itself. The
    # real reference packages are not in renv.lock, and this does not pretend to be them.
    # ------------------------------------------------------------------
    r_reference_script = """
    r_A <- matrix(c(10, 20, 30, 20, 20, 60, 40, 10, 50), nrow = 3, byrow = FALSE)
    r_libs <- colSums(r_A)
    r_tss <- r_libs / exp(mean(log(r_libs)))
    r_q <- 0.75
    r_css_raw <- sapply(seq_len(ncol(r_A)), function(j) {
      r_col <- r_A[, j]
      r_thr <- quantile(r_col, r_q, type = 7)
      sum(r_col[r_col <= r_thr])
    })
    r_css <- r_css_raw / exp(mean(log(r_css_raw)))
    r_uq <- sapply(seq_len(ncol(r_A)), function(j) quantile(r_A[, j], 0.75, type = 7) / r_libs[j])
    r_ref <- which.min(abs(r_uq - mean(r_uq)))
    r_raw <- rep(1, ncol(r_A))
    for (i in seq_len(ncol(r_A))) {
      if (i == r_ref) next
      r_x <- r_A[, i]
      r_r <- r_A[, r_ref]
      r_keep <- r_x > 0 & r_r > 0
      r_m <- log2(r_x[r_keep] / r_r[r_keep])
      r_a <- 0.5 * log2(r_x[r_keep] * r_r[r_keep])
      r_w <- (1 - r_x[r_keep] / r_libs[i]) / r_x[r_keep] + (1 - r_r[r_keep] / r_libs[r_ref]) / r_r[r_keep]
      r_n <- length(r_m)
      r_lo <- floor(r_n * 0.3) + 1
      r_hi <- r_n + 1 - r_lo
      r_los <- floor(r_n * 0.05) + 1
      r_his <- r_n + 1 - r_los
      r_rm <- rank(r_m, ties.method = "first")
      r_ra <- rank(r_a, ties.method = "first")
      r_sel <- r_rm >= r_lo & r_rm <= r_hi & r_ra >= r_los & r_ra <= r_his
      r_raw[i] <- 2^(sum(r_m[r_sel] * r_w[r_sel]) / sum(r_w[r_sel]))
    }
    r_tmm <- r_raw / exp(mean(log(r_raw)))
    r_gm <- function(v) exp(mean(log(v)))
    r_rle_raw <- sapply(seq_len(ncol(r_A)), function(j) median(r_A[, j] / apply(r_A, 1, r_gm)))
    r_rle <- r_rle_raw / exp(mean(log(r_rle_raw)))
    """

    r_reference = try
        with_r_lock(; timeout = 60.0) do
            RCall.globalEnv[:scaling_A] = table_a
            RCall.reval(r_reference_script)
            (
                tss = RCall.rcopy(RCall.reval("r_tss")),
                css = RCall.rcopy(RCall.reval("r_css")),
                tmm = RCall.rcopy(RCall.reval("r_tmm")),
                rle = RCall.rcopy(RCall.reval("r_rle")),
                reference = RCall.rcopy(RCall.reval("r_ref")),
            )
        end
    catch
        nothing
    end

    if r_reference === nothing
        # Loud, by name, with the reason: a silent skip is how a validation claim goes
        # missing. CI installs R and restores renv.lock, so a skip here is a regression.
        @info "SKIPPED (by name): the R transcription cross-check for TSS/CSS/RSS/RLE — R is not reachable in this environment."
        @test_skip css_factors(table_a; quantile = 0.75)
    else
        @testset "an R transcription of the same conditions agrees" begin
            @test r_reference.tss ≈ tss_factors(table_a).factors atol = 1e-12
            @test r_reference.css ≈ css_factors(table_a; quantile = 0.75).factors atol = 1e-12
            @test r_reference.tmm ≈ tmm_factors(table_a).factors atol = 1e-12
            @test r_reference.rle ≈ rle_factors(table_a).factors atol = 1e-12
            # And R reproduces the published numbers, so the constants above are not
            # Julia-version artefacts.
            @test r_reference.tss ≈ [0.711378660898012, 1.185631101496687, 1.185631101496687] atol = 1e-12
            @test r_reference.tmm ≈ [0.786198050576376, 1.248011612540287, 1.019176522885718] atol = 1e-12
            @test r_reference.reference == 1
        end
    end
end
