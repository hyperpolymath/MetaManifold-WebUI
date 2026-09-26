# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Milestone 3 — AnalysisConfig.jl immutable struct exactly matching user's answers
# Tests for validators, manifest creation, DANGER banner logging with epsilon/zero_policy

@testset "AnalysisConfig Milestone 3 — immutable struct, validators, DANGER banner, DOI bundles" begin

    using OrderedCollections

    @testset "NormalizationConfig with epsilon and zero_policy" begin
        # Valid with epsilon and zero_policy
        nc = AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5, epsilon=1e-6, zero_policy="pseudocount")
        @test nc.method == "clr"
        @test nc.epsilon == 1e-6
        @test nc.zero_policy == AnalysisConfig.PSEUDOCOUNT

        # Epsilon validation — must be in (0,1)
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5, epsilon=0.0)
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5, epsilon=1.0)
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5, epsilon=-0.1)
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5, epsilon=2.0)

        # Zero policy validation
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5, zero_policy="invalid")
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5, zero_policy="refuse") # refuse invalid for CLR/ILR even with token

        # Valid zero policies
        nc_mult = AnalysisConfig.NormalizationConfig(method="size_factors", zero_policy="multiplicative_replacement", multiplicative_replacement_delta=0.65)
        @test nc_mult.zero_policy == AnalysisConfig.MULTIPLICATIVE_REPLACEMENT
        @test nc_mult.multiplicative_replacement_delta == 0.65

        # Delta validation
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="size_factors", zero_policy="multiplicative_replacement", multiplicative_replacement_delta=0.0)
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="size_factors", zero_policy="multiplicative_replacement", multiplicative_replacement_delta=1.0)

        # TSS/CSS/RSS alias with warning — should not throw, but warn
        nc_tss = AnalysisConfig.NormalizationConfig(method="TSS", pseudocount=0.5)
        @test nc_tss.method == "tss" # lowercased
        @test nc_tss.tss_css_rss_note === nothing # no note, but warns

        nc_tss_note = AnalysisConfig.NormalizationConfig(method="TSS", tss_css_rss_note="deferred, see issue 01")
        @test nc_tss_note.tss_css_rss_note == "deferred, see issue 01"
    end

    @testset "AdvancedConfig with pseudocount/epsilon/zero_policy heavy validation" begin
        # Valid
        adv = AnalysisConfig.AdvancedConfig()
        @test adv.pseudocount == 0.5
        @test adv.epsilon == 1e-6
        @test adv.zero_policy == AnalysisConfig.PSEUDOCOUNT

        # Pseudocount validation
        @test_throws ArgumentError AnalysisConfig.AdvancedConfig(pseudocount=0.0)
        @test_throws ArgumentError AnalysisConfig.AdvancedConfig(pseudocount=-0.1)

        # Epsilon validation
        @test_throws ArgumentError AnalysisConfig.AdvancedConfig(epsilon=0.0)
        @test_throws ArgumentError AnalysisConfig.AdvancedConfig(epsilon=1.0)
        @test_throws ArgumentError AnalysisConfig.AdvancedConfig(epsilon=-1e-6)
        @test_throws ArgumentError AnalysisConfig.AdvancedConfig(epsilon=2.0)

        # Zero policy validation
        @test_throws ArgumentError AnalysisConfig.AdvancedConfig(zero_policy="invalid")
        adv_refuse = AnalysisConfig.AdvancedConfig(zero_policy="refuse", acknowledgment_token=AnalysisConfig.DANGER_ACK_TOKEN)
        @test adv_refuse.zero_policy == AnalysisConfig.REFUSE

        # Zero handling refuse requires token
        @test_throws ArgumentError AnalysisConfig.AdvancedConfig(zero_handling="refuse")
        adv_refuse2 = AnalysisConfig.AdvancedConfig(zero_handling="refuse", acknowledgment_token=AnalysisConfig.DANGER_ACK_TOKEN)
        @test adv_refuse2.zero_handling == "refuse"

        # Backwards compatibility alias AdvancedOverrides
        ao = AnalysisConfig.AdvancedOverrides(pseudocount=0.5, epsilon=1e-6)
        @test ao.pseudocount == 0.5
        @test ao isa AnalysisConfig.AdvancedConfig
    end

    @testset "AnalysisConfig immutable struct with new fields" begin
        norm = AnalysisConfig.NormalizationConfig(method="size_factors", epsilon=1e-6, zero_policy="pseudocount")
        adv = AnalysisConfig.AdvancedConfig(pseudocount=0.5, epsilon=1e-6, zero_policy="pseudocount")

        cfg = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group", "batch"],
            normalization=norm,
            correction=AnalysisConfig.CorrectionConfig(),
            advanced=adv,
            created_by="test_user_m3"
        )

        @test cfg.method == AnalysisConfig.NB_GLM
        @test cfg.normalization.epsilon == 1e-6
        @test cfg.normalization.zero_policy == AnalysisConfig.PSEUDOCOUNT
        @test cfg.advanced.epsilon == 1e-6
        @test cfg.advanced.pseudocount == 0.5
        @test cfg.dangerous == false
        @test cfg.schema_version == AnalysisConfig.SCHEMA_VERSION

        # Backwards compatibility alias AnalysisConfigStruct
        cfg_struct = AnalysisConfig.AnalysisConfigStruct(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
        )
        @test cfg_struct isa AnalysisConfig.AnalysisConfig
    end

    @testset "Validators refuse meaningless inputs — heavy validation" begin
        norm = AnalysisConfig.NormalizationConfig(method="size_factors")

        # Empty formula
        @test_throws ArgumentError AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="",
            metadata_columns=["group"],
            normalization=norm,
        )

        # Formula without ~
        @test_throws ArgumentError AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="group",
            metadata_columns=["group"],
            normalization=norm,
        )

        # Formula just ~
        @test_throws ArgumentError AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~",
            metadata_columns=["group"],
            normalization=norm,
        )

        # Forbidden chars
        @test_throws ArgumentError AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group; rm -rf",
            metadata_columns=["group"],
            normalization=norm,
        )

        # Empty metadata_columns
        @test_throws ArgumentError AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=String[],
            normalization=norm,
        )

        # Duplicate metadata_columns
        @test_throws ArgumentError AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group", "group"],
            normalization=norm,
        )

        # Invalid metadata column pattern
        @test_throws ArgumentError AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group; rm"],
            normalization=norm,
        )

        # Incompatible normalization
        @test_throws ArgumentError AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5),
        )

        # LOGISTIC requires outcome_column
        @test_throws ArgumentError AnalysisConfig.AnalysisConfig(
            method="logistic",
            formula="disease ~ group",
            metadata_columns=["group"],
            normalization=AnalysisConfig.NormalizationConfig(method="presence_absence"),
        )
    end

    @testset "DANGER banner logging — scary for paper writers" begin
        norm = AnalysisConfig.NormalizationConfig(method="size_factors")

        # Safe config — no banner
        safe_cfg = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
        )
        @test !AnalysisConfig.is_dangerous(safe_cfg)
        @test isnothing(AnalysisConfig.danger_banner(safe_cfg))
        # log_danger_banner should log info, not error
        @test isnothing(AnalysisConfig.log_danger_banner(safe_cfg))

        # Dangerous — BH disabled
        dangerous_corr = AnalysisConfig.CorrectionConfig(method="none", allow_no_correction=true, acknowledgment_token=AnalysisConfig.DANGER_ACK_TOKEN)
        dangerous_cfg = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            correction=dangerous_corr,
        )
        @test AnalysisConfig.is_dangerous(dangerous_cfg)
        banner = AnalysisConfig.danger_banner(dangerous_cfg)
        @test !isnothing(banner)
        @test occursin("DANGER", banner)
        @test occursin("BH", banner)
        @test occursin(dangerous_cfg.id, banner)
        @test occursin(dangerous_cfg.hash, banner)

        # log_danger_banner should log error and warn, return banner
        logged_banner = AnalysisConfig.log_danger_banner(dangerous_cfg)
        @test !isnothing(logged_banner)
        @test occursin("DANGER", logged_banner)

        # Dangerous — zero_handling refuse
        adv_refuse = AnalysisConfig.AdvancedConfig(zero_handling="refuse", acknowledgment_token=AnalysisConfig.DANGER_ACK_TOKEN)
        dangerous_cfg2 = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            advanced=adv_refuse,
        )
        @test AnalysisConfig.is_dangerous(dangerous_cfg2)
        banner2 = AnalysisConfig.danger_banner(dangerous_cfg2)
        @test occursin("refuse", lowercase(banner2))

        # Dangerous — min_samples_per_group <3
        adv_low_n = AnalysisConfig.AdvancedConfig(min_samples_per_group=2)
        dangerous_cfg3 = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            advanced=adv_low_n,
        )
        @test AnalysisConfig.is_dangerous(dangerous_cfg3)
        banner3 = AnalysisConfig.danger_banner(dangerous_cfg3)
        @test occursin("min_samples_per_group", banner3)
    end

    @testset "JSON manifest with new fields epsilon/zero_policy" begin
        norm = AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5, epsilon=1e-6, zero_policy="pseudocount")
        cfg = AnalysisConfig.AnalysisConfig(
            method="clr_lm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            created_by="tester_m3"
        )

        json_str = AnalysisConfig.to_json(cfg)
        @test occursin("clr_lm", json_str)
        @test occursin(cfg.id, json_str)
        @test occursin("epsilon", json_str)
        @test occursin("zero_policy", json_str)
        @test occursin("pseudocount", json_str)

        cfg_restored = AnalysisConfig.from_json(json_str)
        @test cfg_restored.method == cfg.method
        @test cfg_restored.formula == cfg.formula
        @test cfg_restored.normalization.epsilon == cfg.normalization.epsilon
        @test cfg_restored.normalization.zero_policy == cfg.normalization.zero_policy
        @test cfg_restored.normalization.pseudocount == cfg.normalization.pseudocount
    end

    @testset "Nickel and DEED serialization with new fields" begin
        norm = AnalysisConfig.NormalizationConfig(method="size_factors", epsilon=1e-6, zero_policy="pseudocount")
        cfg = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            created_by="tester_m3"
        )

        nickel_str = AnalysisConfig.to_nickel(cfg)
        @test occursin("nb_glm", nickel_str)
        @test occursin(cfg.id, nickel_str)
        @test occursin("epsilon", nickel_str)
        @test occursin("PseudocountContract", nickel_str)
        @test occursin("CorrectionContract", nickel_str)

        nickel_errors = AnalysisConfig.validate_nickel(nickel_str)
        @test isempty(nickel_errors)

        deed_str = AnalysisConfig.to_deed(cfg)
        @test occursin("repo-deed", deed_str)
        @test occursin(":schema-version", deed_str)
        @test occursin(cfg.id, deed_str)
        @test occursin("epsilon", deed_str)
        @test occursin("zero-policy", deed_str)
        @test occursin("#t", deed_str) || occursin("#f", deed_str) # booleans #t/#f

        deed_errors = AnalysisConfig.validate_deed(deed_str)
        @test isempty(deed_errors)
    end

    @testset "DOI-ready JSON manifest bundles with DataCite" begin
        norm = AnalysisConfig.NormalizationConfig(method="size_factors", epsilon=1e-6, zero_policy="pseudocount")
        cfg = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            created_by="test_user_m3"
        )

        result = AnalysisConfig.AnalysisResult(
            config_id=cfg.id,
            config_hash=cfg.hash,
            method=cfg.method,
            results=OrderedDict{String,Any}("taxon1" => OrderedDict("p" => 0.01, "log2FoldChange" => 2.0))
        )

        mktempdir() do tmpdir
            bundle_path = AnalysisConfig.create_doi_bundle(cfg, result; output_dir=joinpath(tmpdir, "bundle_m3"), authors=["Test User M3"], title="Test Bundle M3")
            @test isdir(bundle_path)
            @test isfile(joinpath(bundle_path, "analysis_config.json"))
            @test isfile(joinpath(bundle_path, "analysis_config.ncl"))
            @test isfile(joinpath(bundle_path, "analysis_config_chora.deed"))
            @test isfile(joinpath(bundle_path, "datacite.json"))
            @test isfile(joinpath(bundle_path, "provenance.json"))
            @test isfile(joinpath(bundle_path, "content_hash.txt"))

            # Check datacite contains method and epsilon/zero_policy via config
            datacite_content = read(joinpath(bundle_path, "datacite.json"), String)
            @test occursin("nb_glm", datacite_content)
            @test occursin(cfg.id, datacite_content)

            # Check content_hash matches config hash
            hash_content = strip(read(joinpath(bundle_path, "content_hash.txt"), String))
            @test hash_content == cfg.hash

            # Safe bundle should not have DANGER_BANNER.txt
            @test !isfile(joinpath(bundle_path, "DANGER_BANNER.txt"))
        end

        # Dangerous bundle should have DANGER_BANNER.txt
        dangerous_corr = AnalysisConfig.CorrectionConfig(method="none", allow_no_correction=true, acknowledgment_token=AnalysisConfig.DANGER_ACK_TOKEN)
        dangerous_cfg = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            correction=dangerous_corr,
            created_by="test_user_m3"
        )

        mktempdir() do tmpdir
            bundle_path = AnalysisConfig.create_doi_bundle(dangerous_cfg; output_dir=joinpath(tmpdir, "bundle_danger"), authors=["Test User"], title="Danger Bundle")
            @test isfile(joinpath(bundle_path, "DANGER_BANNER.txt"))
            banner_content = read(joinpath(bundle_path, "DANGER_BANNER.txt"), String)
            @test occursin("DANGER", banner_content)
        end
    end

    @testset "Context-sensitive help for new fields" begin
        help_eps = AnalysisConfig.context_help("advanced.epsilon")
        @test occursin("epsilon", lowercase(help_eps))

        help_zero = AnalysisConfig.context_help("advanced.zero_policy")
        @test occursin("zero", lowercase(help_zero))

        help_pseudo = AnalysisConfig.context_help("advanced.pseudocount")
        @test occursin("pseudocount", lowercase(help_pseudo))

        help_norm_eps = AnalysisConfig.context_help("normalization.epsilon")
        @test occursin("epsilon", lowercase(help_norm_eps))
    end

    @testset "TSS/CSS/RSS deferred — alias with warning" begin
        # Should not throw, but warn and be aliased to relative
        norm_tss = AnalysisConfig.NormalizationConfig(method="TSS")
        @test norm_tss.method == "tss"

        # For NB_GLM, TSS is allowed (deferred alias)
        cfg_tss = AnalysisConfig.AnalysisConfig(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm_tss,
        )
        @test cfg_tss.normalization.method == "tss"
        # Validation should pass (TSS allowed for NB_GLM)
        errors = AnalysisConfig.validate_config(cfg_tss, ["group"]; strict=false)
        @test isempty(errors)
    end

    @testset "issue #21: zero-replacement and dispersion configuration surface" begin
        # delta is validated at the door, exactly as the operator validates it: (0,1) strict.
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(
            method="none", zero_policy="multiplicative_replacement",
            multiplicative_replacement_delta=0.0)
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(
            method="none", zero_policy="multiplicative_replacement",
            multiplicative_replacement_delta=1.0)
        ok = AnalysisConfig.NormalizationConfig(
            method="none", zero_policy="multiplicative_replacement",
            multiplicative_replacement_delta=0.65)
        @test ok.multiplicative_replacement_delta == 0.65

        # alpha > 0: a non-positive Dirichlet concentration is an improper prior.
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(
            method="none", zero_policy="bayesian_multiplicative",
            bayesian_multiplicative_alpha=0.0)
        alpha_ok = AnalysisConfig.NormalizationConfig(
            method="none", zero_policy="bayesian_multiplicative",
            bayesian_multiplicative_alpha=1.5)
        @test alpha_ok.bayesian_multiplicative_alpha == 1.5

        # The advanced overrides carry the same parameters and are echoed into the
        # configuration's canonical JSON, so a run cannot use a delta nobody can see.
        adv = AnalysisConfig.AdvancedConfig(
            min_prevalence=0.0, min_abundance=0.0, min_samples_per_group=2,
            zero_replacement_method="multiplicative_replacement",
            multiplicative_delta=0.5, bayesian_alpha=2.0,
            glmgampoi_abundance_trend=false)
        cfg = AnalysisConfig.AnalysisConfig(
            method="nb_glm", formula="~ group", metadata_columns=["group"],
            normalization=ok, advanced=adv, created_by="test_issue21")
        json = AnalysisConfig.to_json(cfg)
        @test occursin("multiplicative_delta", json)
        @test occursin("glmgampoi_abundance_trend", json)

        # glmGamPoi is a real option now, and the spline trend is not: asking for the spline
        # is refused at the operator, not silently downgraded.
        @test "glmGamPoi" in AnalysisConfig.VALID_DISPERSION_METHODS
        # (The trend being *true* is refused by the dispersion operator rather than by the
        # configuration constructor: the config records the request, and the operator refuses
        # it by name. test/unit/test_dispersion.jl asserts that refusal.)
    end
end
