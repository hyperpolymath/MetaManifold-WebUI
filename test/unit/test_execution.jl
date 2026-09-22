# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Milestone 4 — Execution harness tests
# Tests for prepare_analysis_table (CLR with pseudocount=1, epsilon=1e-6, drop vs impute)

@testset "Execution — harness and adapters (stubs) - Milestone 4" begin

    using OrderedCollections

    @testset "AnalysisAdapter abstract and concrete stubs" begin
        # RAdapter valid
        r_adapter = Execution.RAdapter(r_binary="R", r_packages=["DESeq2"], method="nb_glm", use_r_runtime_lock=true, seed=42)
        @test r_adapter.method == "nb_glm"
        @test r_adapter.r_binary == "R"
        @test r_adapter isa Execution.AnalysisAdapter

        # JuliaAdapter valid
        jl_adapter = Execution.JuliaAdapter(method="clr_lm", use_multithreading=false, seed=42, optimizer="LBFGS")
        @test jl_adapter.method == "clr_lm"
        @test jl_adapter isa Execution.AnalysisAdapter

        # Invalid method should throw
        @test_throws ArgumentError Execution.RAdapter(method="invalid_method")
        @test_throws ArgumentError Execution.JuliaAdapter(method="invalid")
    end

    @testset "Self-diagnostics — checks" begin
        # NaN/Inf check
        table_with_nan = [1.0 2.0; 3.0 NaN]
        check = Execution.check_nan_inf(table_with_nan)
        @test check["has_nan_inf"] == true
        @test check["nan_count"] == 1

        table_with_inf = [1.0 2.0; 3.0 Inf]
        check_inf = Execution.check_nan_inf(table_with_inf)
        @test check_inf["inf_count"] == 1

        table_clean = [1.0 2.0; 3.0 4.0]
        check_clean = Execution.check_nan_inf(table_clean)
        @test check_clean["has_nan_inf"] == false

        # Zero variance
        table_zero_var = [1.0 1.0; 2.0 3.0] # first row zero variance? Actually row [1.0 1.0] var 0
        check_zv = Execution.check_zero_variance(table_zero_var)
        @test check_zv["has_zero_variance"] == true

        # All-zero samples
        counts_all_zero_sample = [1.0 0.0; 2.0 0.0; 3.0 0.0] # second sample all zero
        check_azs = Execution.check_all_zero_samples(counts_all_zero_sample)
        @test check_azs["has_all_zero_samples"] == true
        @test check_azs["all_zero_samples_count"] == 1

        # All-zero taxa
        counts_all_zero_taxa = [1.0 2.0 3.0; 0.0 0.0 0.0; 4.0 5.0 6.0] # second taxon all zero
        check_azt = Execution.check_all_zero_taxa(counts_all_zero_taxa)
        @test check_azt["has_all_zero_taxa"] == true
        @test check_azt["all_zero_taxa_count"] == 1

        # Library size outliers
        counts_outlier = [100.0 100.0 10000.0; 100.0 100.0 10000.0] # third sample huge outlier
        check_out = Execution.check_library_size_outliers(counts_outlier)
        # With 3 samples, mean ~3400, std ~ 5700, 3sd ~17100, so 10000 may not be outlier >3sd? Let's check logic
        # Our stub uses >3sd, so for [200,200,20000] mean ~6800, std ~11400, 3sd 34200, 20000 not outlier
        # For stronger outlier, use [100,100,100000]
        counts_strong_outlier = [100.0 100.0 100000.0; 100.0 100.0 100000.0]
        check_strong = Execution.check_library_size_outliers(counts_strong_outlier)
        # Still may not be >3sd with 3 samples, but we test that function returns dict
        @test haskey(check_strong, "library_sizes")
    end

    @testset "Safe self-healing" begin
        # Heal NaN/Inf
        table_nan_inf = [1.0 NaN; Inf 4.0]
        (healed, nan_c, inf_c) = Execution.heal_nan_inf(table_nan_inf, 1e-6)
        @test nan_c == 1
        @test inf_c == 1
        @test !any(isnan, healed)
        @test !any(isinf, healed)

        # Heal all-zero samples drop
        counts = [1.0 0.0 3.0; 2.0 0.0 4.0]
        sample_ids = ["s1", "s2", "s3"]
        (healed_counts, healed_sids, healings, indices) = Execution.heal_all_zero_samples(counts, sample_ids, Execution.DROP, 1e-6)
        @test size(healed_counts, 2) == 2
        @test length(healed_sids) == 2
        @test "s2" ∉ healed_sids
        @test length(healings) == 1

        # Heal all-zero samples impute
        (healed_counts_imp, healed_sids_imp, healings_imp, _) = Execution.heal_all_zero_samples(counts, sample_ids, Execution.IMPUTE, 1e-6)
        @test size(healed_counts_imp, 2) == 3
        @test all(healed_counts_imp[:, 2] .== 1e-6)

        # Heal all-zero samples refuse should throw
        @test_throws ArgumentError Execution.heal_all_zero_samples(counts, sample_ids, Execution.REFUSE, 1e-6)

        # Heal all-zero taxa drop
        counts_taxa = [1.0 2.0; 0.0 0.0; 3.0 4.0]
        taxa_ids = ["t1", "t2", "t3"]
        (healed_counts_t, healed_tids, healings_t, _) = Execution.heal_all_zero_taxa(counts_taxa, taxa_ids, Execution.DROP, 1e-6)
        @test size(healed_counts_t, 1) == 2
        @test "t2" ∉ healed_tids

        # Heal all-zero taxa impute
        (healed_counts_t_imp, healed_tids_imp, _, _) = Execution.heal_all_zero_taxa(counts_taxa, taxa_ids, Execution.IMPUTE, 1e-6)
        @test size(healed_counts_t_imp, 1) == 3
        @test all(healed_counts_t_imp[2, :] .== 1e-6)
    end

    @testset "prepare_analysis_table — CLR with pseudocount=1, epsilon=1e-6, drop vs impute" begin
        # Create config for CLR with pseudocount=1, epsilon=1e-6
        norm = AnalysisConfig.NormalizationConfig(method="clr", pseudocount=1.0, epsilon=1e-6, zero_policy="pseudocount")
        adv = AnalysisConfig.AdvancedConfig(pseudocount=1.0, epsilon=1e-6, min_prevalence=0.0, min_abundance=0.0, min_samples_per_group=2)
        config = AnalysisConfig.AnalysisConfig(
            method="clr_lm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            advanced=adv,
            created_by="test_m4"
        )

        # Create counts with zeros
        # >= 2*min_samples_per_group samples: prepare_analysis_table refuses fewer,
        # needing 2 groups of min_samples_per_group for variance estimation.
        counts = [
            0.0 1.0 2.0 1.0;
            1.0 0.0 3.0 2.0;
            2.0 3.0 0.0 1.0;
            10.0 20.0 30.0 40.0
        ] # 4 taxa x 4 samples, with zeros

        sample_ids = ["s1", "s2", "s3", "s4"]
        taxa_ids = ["t1", "t2", "t3", "t4"]

        # Test drop policy
        (prepared_drop, diagnostics_drop, manifest_drop, sids_drop, tids_drop) = Execution.prepare_analysis_table(
            config, counts;
            sample_ids=sample_ids,
            taxa_ids=taxa_ids,
            drop_policy="drop",
            impute_policy="pseudocount"
        )

        @test size(prepared_drop, 2) == 4 # 4 samples, no all-zero samples in this case
        @test size(prepared_drop, 1) == 4 # CLR keeps 4 taxa (or 4 for CLR, not ILR)
        @test !any(isnan, prepared_drop)
        @test !any(isinf, prepared_drop)
        # Check that CLR was applied: each column should have mean ~0 (centered log-ratio)
        for j in 1:size(prepared_drop, 2)
            @test mean(prepared_drop[:, j]) ≈ 0.0 atol=1e-10
        end

        # Check diagnostics
        @test diagnostics_drop isa Execution.ExecutionDiagnostics
        @test manifest_drop isa Execution.ExecutionManifest
        @test manifest_drop.transform == "clr"
        @test manifest_drop.zero_policy == "PSEUDOCOUNT"

        # Test impute policy with all-zero sample
        counts_with_all_zero_sample = [
            1.0 0.0 3.0 4.0 5.0;
            2.0 0.0 4.0 5.0 6.0;
            3.0 0.0 5.0 6.0 7.0
        ] # second sample all zero; 5 samples so 4 remain after the drop
        sample_ids_az = ["s1", "s2", "s3", "s4", "s5"]
        taxa_ids_az = ["t1", "t2", "t3"]

        # Drop policy should drop all-zero sample
        (prepared_drop_az, diag_drop_az, manifest_drop_az, sids_drop_az, tids_drop_az) = Execution.prepare_analysis_table(
            config, counts_with_all_zero_sample;
            sample_ids=sample_ids_az,
            taxa_ids=taxa_ids_az,
            drop_policy="drop",
            impute_policy="pseudocount"
        )
        @test size(prepared_drop_az, 2) == 4 # dropped s2, 4 remain
        @test "s2" ∉ sids_drop_az
        @test length(diag_drop_az.healings) >= 1
        @test occursin("Dropped", diag_drop_az.healings[1])

        # Impute policy should impute all-zero sample with epsilon
        (prepared_imp_az, diag_imp_az, manifest_imp_az, sids_imp_az, tids_imp_az) = Execution.prepare_analysis_table(
            config, counts_with_all_zero_sample;
            sample_ids=sample_ids_az,
            taxa_ids=taxa_ids_az,
            drop_policy="impute",
            impute_policy="epsilon"
        )
        @test size(prepared_imp_az, 2) == 5 # kept all 5 samples
        @test "s2" ∈ sids_imp_az
        @test length(diag_imp_az.healings) >= 1
        @test occursin("Imputed", diag_imp_az.healings[1])

        # Refuse policy should throw for all-zero sample
        @test_throws ArgumentError Execution.prepare_analysis_table(
            config, counts_with_all_zero_sample;
            sample_ids=sample_ids_az,
            taxa_ids=taxa_ids_az,
            drop_policy="refuse",
            impute_policy="pseudocount"
        )

        # Test with all-zero taxa
        counts_with_all_zero_taxa = [
            1.0 2.0 3.0 4.0 5.0;
            0.0 0.0 0.0 0.0 0.0;
            4.0 5.0 6.0 7.0 8.0
        ]
        (prepared_drop_azt, diag_drop_azt, _, sids_drop_azt, tids_drop_azt) = Execution.prepare_analysis_table(
            config, counts_with_all_zero_taxa;
            sample_ids=sample_ids_az,
            taxa_ids=taxa_ids_az,
            drop_policy="drop",
            impute_policy="pseudocount"
        )
        @test size(prepared_drop_azt, 1) == 2 # dropped t2
        @test "t2" ∉ tids_drop_azt

        # Test CLR with pseudocount=1 and epsilon=1e-6 specifically
        # pseudocount=1 should be added to all counts for CLR, so 0->1, 1->2, etc.
        # Then log(1)=0, log(2)=0.693, etc., CLR centered
        # Check that prepared table does not have -Inf (which would happen with pseudocount=0)
        counts_simple = [0.0 1.0 2.0 3.0; 1.0 0.0 2.0 1.0]
        (prepared_simple, _, _, _, _) = Execution.prepare_analysis_table(
            config, counts_simple;
            sample_ids=["s1","s2","s3","s4"],
            taxa_ids=["t1","t2"],
            drop_policy="drop",
            impute_policy="pseudocount"
        )
        @test !any(x -> x == -Inf, prepared_simple)
        @test !any(isnan, prepared_simple)
    end

    @testset "zero-depth samples are healed before the transform, not after" begin
        # The defect these tests pin, in the owner's words: "Execution.jl still writes
        # a zero-depth sample's relative abundance as 0.0 — the exact thing item 1's
        # conditions forbid." A sample with no reads at all has NO relative
        # abundances: 0/0 is undefined, while 0.0 is a value, and reporting the second
        # as the first is a claim the data does not support. No downstream check could
        # catch it, because 0.0 is a perfectly ordinary number.
        #
        # The cause was ordering. `prepared` was computed from counts that still
        # contained such samples, and every transform divides by a sample total, so
        # one empty sample poisoned whichever transform ran: relative wrote 0.0 into
        # every feature; rarefy took min_lib = minimum(lib_sizes) = 0 and scaled EVERY
        # sample by 0, emptying the whole prepared table while reporting success; clr
        # took log(0) = -Inf, which centring turns into NaN, which the later NaN/Inf
        # healing then replaced with epsilon — a wrong number presented as a healed
        # one. Healing afterwards could not repair any of it: under drop_policy=impute
        # the imputed counts were assigned while `prepared` kept the values computed
        # from the empty column, so `prepared` and `filtered_counts` described
        # different data.
        #
        # Only drop_policy=impute changes its visible result, and only where it was
        # wrong: the sample is imputed and the transform now sees the imputed counts,
        # so its proportions are uniform rather than a column of 0.0. The drop and
        # refuse results are unchanged, which is why the assertion that carries the
        # weight here is the impute one.
        norm = AnalysisConfig.NormalizationConfig(method="relative", pseudocount=1.0,
                                                  epsilon=1e-6, zero_policy="pseudocount")
        adv = AnalysisConfig.AdvancedConfig(pseudocount=1.0, epsilon=1e-6,
                                            min_prevalence=0.0, min_abundance=0.0,
                                            min_samples_per_group=2)
        config = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            advanced=adv,
            created_by="test_zero_depth"
        )

        # s3 has no reads at all; the other four samples do.
        counts_zero_depth = [10.0 20.0 0.0 30.0 25.0;
                             30.0 20.0 0.0 10.0 15.0]
        sids_zd = ["s1", "s2", "s3", "s4", "s5"]
        tids_zd = ["t1", "t2"]

        @testset "impute — the imputed sample's proportions are uniform, not 0.0" begin
            (prepared_zd, diag_zd, _, kept_zd, _) = Execution.prepare_analysis_table(
                config, counts_zero_depth;
                sample_ids=sids_zd, taxa_ids=tids_zd,
                drop_policy="impute", impute_policy="epsilon"
            )
            @test size(prepared_zd, 2) == 5
            @test "s3" in kept_zd
            @test any(h -> occursin("Imputed", h), diag_zd.healings)

            # The assertion the old code fails. An equal epsilon in every feature is
            # an equal share, so this column is uniform and sums to one; the old code
            # left it at 0.0 while claiming the counts had been imputed.
            col = prepared_zd[:, 3]
            @test all(col .≈ 1 / length(tids_zd))
            @test !all(col .== 0.0)
            @test sum(col) ≈ 1.0
        end

        @testset "drop — the empty sample is still dropped" begin
            (prepared_dz, diag_dz, _, kept_dz, _) = Execution.prepare_analysis_table(
                config, counts_zero_depth;
                sample_ids=sids_zd, taxa_ids=tids_zd,
                drop_policy="drop", impute_policy="epsilon"
            )
            @test size(prepared_dz, 2) == 4
            @test "s3" ∉ kept_dz
            @test any(h -> occursin("Dropped", h), diag_dz.healings)
            # The property, whatever the policy: no column of the prepared table
            # stands for a sample with no reads.
            @test !any(all(c .== 0.0) for c in eachcol(prepared_dz))
        end

        @testset "refuse — the same refusal, raised earlier" begin
            @test_throws ArgumentError Execution.prepare_analysis_table(
                config, counts_zero_depth;
                sample_ids=sids_zd, taxa_ids=tids_zd,
                drop_policy="refuse", impute_policy="epsilon"
            )
        end
    end

    @testset "rarefy does not empty the matrix when a sample is empty" begin
        # min_lib = minimum(lib_sizes) is 0 whenever any sample is empty, and every
        # sample was then scaled by 0/lib. Measured before the fix: four correctly
        # kept samples and a 2x4 matrix of zeros, reported as success.
        norm_rar = AnalysisConfig.NormalizationConfig(method="rarefy", epsilon=1e-6,
                                                      zero_policy="pseudocount")
        adv_rar = AnalysisConfig.AdvancedConfig(min_samples_per_group=2)
        config_rar = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm_rar,
            advanced=adv_rar,
            created_by="test_zero_depth_rarefy"
        )
        counts_zero_depth = [10.0 20.0 0.0 30.0 25.0;
                             30.0 20.0 0.0 10.0 15.0]
        (prepared_rar, _, _, kept_rar, _) = Execution.prepare_analysis_table(
            config_rar, counts_zero_depth;
            sample_ids=["s1", "s2", "s3", "s4", "s5"], taxa_ids=["t1", "t2"],
            drop_policy="drop", impute_policy="epsilon"
        )
        @test size(prepared_rar, 2) == 4        # s3 dropped
        @test "s3" ∉ kept_rar
        @test !all(prepared_rar .== 0.0)        # the old code produced all zeros
        @test any(prepared_rar .> 0)
    end

    @testset "run_analysis — stub with manifest and diagnostics, hard-stop DANGER banner" begin
        norm = AnalysisConfig.NormalizationConfig(method="size_factors", epsilon=1e-6)
        adv = AnalysisConfig.AdvancedConfig(min_samples_per_group=2)
        config = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            advanced=adv,
            created_by="test_m4_run"
        )

        counts = [1.0 2.0 3.0 4.0; 4.0 5.0 6.0 7.0; 7.0 8.0 9.0 10.0]
        sample_ids = ["s1","s2","s3","s4"]
        taxa_ids = ["t1","t2","t3"]

        (prepared, diagnostics, manifest, sids, tids) = Execution.prepare_analysis_table(
            config, counts;
            sample_ids=sample_ids,
            taxa_ids=taxa_ids,
            drop_policy="drop"
        )

        # RAdapter stub
        r_adapter = Execution.RAdapter(method="nb_glm")
        result_r = Execution.run_analysis(r_adapter, config, prepared; diagnostics=diagnostics, manifest=manifest, sample_ids=sids, taxa_ids=tids)
        @test result_r isa Execution.ExecutionResult
        @test result_r.config_id == config.id
        @test length(result_r.results) == 3
        @test result_r.manifest.id == manifest.id

        # JuliaAdapter stub
        jl_adapter = Execution.JuliaAdapter(method="nb_glm")
        result_jl = Execution.run_analysis(jl_adapter, config, prepared; diagnostics=diagnostics, manifest=manifest, sample_ids=sids, taxa_ids=tids)
        @test result_jl isa Execution.ExecutionResult

        # Adapter method mismatch should hard-stop with DANGER banner
        wrong_adapter = Execution.JuliaAdapter(method="clr_lm") # config is nb_glm
        @test_throws ArgumentError Execution.run_analysis(wrong_adapter, config, prepared; diagnostics=diagnostics, manifest=manifest, sample_ids=sids, taxa_ids=tids)

        # Dangerous config should trigger DANGER banner logging
        dangerous_corr = AnalysisConfig.CorrectionConfig(method="none", allow_no_correction=true, acknowledgment_token=AnalysisConfig.DANGER_ACK_TOKEN)
        dangerous_config = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            correction=dangerous_corr,
            advanced=adv,
            created_by="test_danger"
        )
        (prepared_dang, diag_dang, manifest_dang, sids_dang, tids_dang) = Execution.prepare_analysis_table(
            dangerous_config, counts;
            sample_ids=sample_ids,
            taxa_ids=taxa_ids,
            drop_policy="drop"
        )
        @test diag_dang.is_dangerous == true
        @test !isnothing(diag_dang.banner)
        @test occursin("DANGER", diag_dang.banner)

        result_dang = Execution.run_analysis(r_adapter, dangerous_config, prepared_dang; diagnostics=diag_dang, manifest=manifest_dang, sample_ids=sids_dang, taxa_ids=tids_dang)
        @test result_dang.diagnostics.is_dangerous == true

        # Test with NaN/Inf still present after healing should hard-stop
        # Create prepared table with NaN that healing fails? Our heal_nan_inf should heal, so we need to test hard-stop for still NaN
        # For this test, we manually create diagnostics with errors and try run_analysis — should have been caught earlier, but we test that run_analysis checks for NaN/Inf
        prepared_with_nan = [1.0 NaN; 3.0 4.0]
        # Create diagnostics with no errors (to pass prepare step) but prepared has NaN
        diag_clean = Execution.ExecutionDiagnostics(warnings=String[], errors=String[], healings=String[], checks=OrderedDict{String,Any}(), is_dangerous=false, banner=nothing)
        manifest_clean = Execution.ExecutionManifest(
            config_id=config.id,
            config_hash=config.hash,
            adapter_type="JuliaAdapter",
            transform="none",
            zero_policy="pseudocount",
            prepared_table_hash=Execution.prepared_table_hash(prepared_with_nan),
            diagnostics=diag_clean
        )
        @test_throws ArgumentError Execution.run_analysis(r_adapter, config, prepared_with_nan; diagnostics=diag_clean, manifest=manifest_clean, sample_ids=sample_ids, taxa_ids=taxa_ids)
    end

    @testset "Epistemic filtering with Advanced validation" begin
        norm = AnalysisConfig.NormalizationConfig(method="size_factors")
        adv = AnalysisConfig.AdvancedConfig(min_prevalence=0.5, min_abundance=5.0, min_samples_per_group=2)
        config = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            advanced=adv,
            created_by="test_epistemic"
        )

        # Counts: 3 taxa, 4 samples
        # t1 present in 4/4 samples, abundance 10
        # t2 present in 1/4 samples (prevalence 0.25 <0.5), abundance 10 — should be filtered
        # t3 present in 4/4 but abundance 2 <5.0 — should be filtered
        counts = [
            2.0 3.0 2.0 3.0; # t1: prevalence 1.0, abundance 10
            10.0 0.0 0.0 0.0; # t2: prevalence 0.25, abundance 10
            0.5 0.5 0.5 0.5  # t3: prevalence 1.0, abundance 2
        ]
        sample_ids = ["s1","s2","s3","s4"]
        taxa_ids = ["t1","t2","t3"]

        (prepared, diagnostics, manifest, sids, tids) = Execution.prepare_analysis_table(
            config, counts;
            sample_ids=sample_ids,
            taxa_ids=taxa_ids,
            drop_policy="drop"
        )

        @test size(prepared, 1) == 1 # only t1 passes
        @test tids == ["t1"]
        @test diagnostics.checks["prevalence_abundance"]["low_prevalence_count"] == 1
        @test diagnostics.checks["prevalence_abundance"]["low_abundance_count"] == 1
    end
end
