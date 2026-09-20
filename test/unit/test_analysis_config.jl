# SPDX-License-Identifier: AGPL-3.0-only
# CI invokes this file as `using Test; using MetaManifold; include(...)`, which does
# not bring submodules into scope. `:` form binds the module, not the same-named struct.
using MetaManifold: AnalysisConfig

@testset "AnalysisConfig — safe, explicit, versioned layer" begin

    using OrderedCollections

    @testset "NormalizationConfig validation" begin
        # Valid
        nc = AnalysisConfig.NormalizationConfig(method="none")
        @test nc.method == "none"

        nc_clr = AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5)
        @test nc_clr.method == "clr"

        # Refuse pseudocount <=0 for CLR
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.0)
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="clr", pseudocount=-0.1)

        # Refuse ilr_basis for non-ILR
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5, ilr_basis="default")
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="none", ilr_basis="default")

        # Valid ILR
        nc_ilr = AnalysisConfig.NormalizationConfig(method="ilr", pseudocount=0.5, ilr_basis="default")
        @test nc_ilr.ilr_basis == "default"

        # Invalid ILR basis
        @test_throws ArgumentError AnalysisConfig.NormalizationConfig(method="ilr", pseudocount=0.5, ilr_basis="invalid_basis")
    end

    @testset "CorrectionConfig — BH mandatory" begin
        cc = AnalysisConfig.CorrectionConfig()
        @test cc.method == "BH"
        @test cc.alpha == 0.05
        @test cc.allow_no_correction == false

        # Non-BH without acknowledgment should throw
        @test_throws ArgumentError AnalysisConfig.CorrectionConfig(method="none")
        @test_throws ArgumentError AnalysisConfig.CorrectionConfig(method="bonferroni")

        # With acknowledgment token, allow
        cc_danger = AnalysisConfig.CorrectionConfig(method="none", allow_no_correction=true, acknowledgment_token=AnalysisConfig.DANGER_ACK_TOKEN)
        @test cc_danger.allow_no_correction == true

        # Wrong token should throw
        @test_throws ArgumentError AnalysisConfig.CorrectionConfig(method="none", allow_no_correction=true, acknowledgment_token="wrong")

        # Alpha validation
        @test_throws ArgumentError AnalysisConfig.CorrectionConfig(alpha=0.0)
        @test_throws ArgumentError AnalysisConfig.CorrectionConfig(alpha=1.0)
        @test_throws ArgumentError AnalysisConfig.CorrectionConfig(alpha=-0.1)
    end

    @testset "AdvancedOverrides validation" begin
        ao = AnalysisConfig.AdvancedOverrides()
        @test ao.min_prevalence == 0.1

        @test_throws ArgumentError AnalysisConfig.AdvancedOverrides(min_prevalence=-0.1)
        @test_throws ArgumentError AnalysisConfig.AdvancedOverrides(min_prevalence=1.5)
        @test_throws ArgumentError AnalysisConfig.AdvancedOverrides(min_abundance=-1.0)
        @test_throws ArgumentError AnalysisConfig.AdvancedOverrides(max_features=0)
        @test_throws ArgumentError AnalysisConfig.AdvancedOverrides(max_features=200000)
        @test_throws ArgumentError AnalysisConfig.AdvancedOverrides(min_samples_per_group=1)

        # zero_handling=refuse requires token
        @test_throws ArgumentError AnalysisConfig.AdvancedOverrides(zero_handling="refuse")
        ao_refuse = AnalysisConfig.AdvancedOverrides(zero_handling="refuse", acknowledgment_token=AnalysisConfig.DANGER_ACK_TOKEN)
        @test ao_refuse.zero_handling == "refuse"
    end

    @testset "AnalysisConfigStruct creation and immutability" begin
        norm = AnalysisConfig.NormalizationConfig(method="size_factors")
        corr = AnalysisConfig.CorrectionConfig()
        adv = AnalysisConfig.AdvancedOverrides()

        cfg = AnalysisConfig.AnalysisConfigStruct(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group", "batch"],
            normalization=norm,
            correction=corr,
            advanced=adv,
            created_by="test_user"
        )

        @test cfg.method == AnalysisConfig.NB_GLM
        @test cfg.formula == "~ group"
        @test cfg.schema_version == AnalysisConfig.SCHEMA_VERSION
        @test length(cfg.hash) == 64  # SHA256 hex
        @test cfg.created_by == "test_user"

        # Hash should be deterministic for same content (except id and timestamp)
        # Different ids should give different hashes? Actually hash includes id, so different
        cfg2 = AnalysisConfig.AnalysisConfigStruct(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group", "batch"],
            normalization=norm,
            correction=corr,
            advanced=adv,
            created_by="test_user",
            id=cfg.id,
            created_at=cfg.created_at,
        )
        @test cfg.hash == cfg2.hash

        # Test method parsing
        @test_throws ArgumentError AnalysisConfig.AnalysisConfigStruct(
            method="invalid_method",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
        )

        # Test empty formula refusal
        @test_throws ArgumentError AnalysisConfig.AnalysisConfigStruct(
            method="nb_glm",
            formula="",
            metadata_columns=["group"],
            normalization=norm,
        )

        # Test formula without ~
        @test_throws ArgumentError AnalysisConfig.AnalysisConfigStruct(
            method="nb_glm",
            formula="group",
            metadata_columns=["group"],
            normalization=norm,
        )

        # Test empty metadata_columns
        @test_throws ArgumentError AnalysisConfig.AnalysisConfigStruct(
            method="nb_glm",
            formula="~ group",
            metadata_columns=String[],
            normalization=norm,
        )

        # Test LOGISTIC requires outcome_column
        @test_throws ArgumentError AnalysisConfig.AnalysisConfigStruct(
            method="logistic",
            formula="disease ~ group",
            metadata_columns=["group"],
            normalization=AnalysisConfig.NormalizationConfig(method="presence_absence"),
        )

        # Valid logistic
        cfg_log = AnalysisConfig.AnalysisConfigStruct(
            method="logistic",
            formula="disease ~ group",
            outcome_column="disease",
            metadata_columns=["group", "disease"],
            normalization=AnalysisConfig.NormalizationConfig(method="presence_absence"),
        )
        @test cfg_log.method == AnalysisConfig.LOGISTIC
        @test cfg_log.outcome_column == "disease"

        # Test incompatible normalization
        @test_throws ArgumentError AnalysisConfig.AnalysisConfigStruct(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5),
        )

        @test_throws ArgumentError AnalysisConfig.AnalysisConfigStruct(
            method="clr_lm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=AnalysisConfig.NormalizationConfig(method="none"),
        )
    end

    @testset "validate_config with available metadata" begin
        norm = AnalysisConfig.NormalizationConfig(method="size_factors")
        cfg = AnalysisConfig.AnalysisConfigStruct(
            method="nb_glm",
            formula="~ group + batch",
            metadata_columns=["group", "batch"],
            normalization=norm,
        )

        # Valid with available columns
        errors = AnalysisConfig.validate_config(cfg, ["group", "batch", "age"]; strict=false)
        @test isempty(errors)

        # Missing column in available
        errors2 = AnalysisConfig.validate_config(cfg, ["group"]; strict=false)
        @test !isempty(errors2)
        @test any(occursin("batch", e) for e in errors2)

        # Formula references non-listed column
        cfg_bad = AnalysisConfig.AnalysisConfigStruct(
            method="nb_glm",
            formula="~ group + age",
            metadata_columns=["group"],
            normalization=norm,
        )
        errors3 = AnalysisConfig.validate_config(cfg_bad, ["group", "age", "batch"]; strict=false)
        @test !isempty(errors3)
        @test any(occursin("age", e) for e in errors3)
    end

    @testset "DANGER banner logic" begin
        norm = AnalysisConfig.NormalizationConfig(method="size_factors")

        safe_cfg = AnalysisConfig.AnalysisConfigStruct(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
        )
        @test !AnalysisConfig.is_dangerous(safe_cfg)
        @test isnothing(AnalysisConfig.danger_banner(safe_cfg))

        dangerous_corr = AnalysisConfig.CorrectionConfig(method="none", allow_no_correction=true, acknowledgment_token=AnalysisConfig.DANGER_ACK_TOKEN)
        dangerous_cfg = AnalysisConfig.AnalysisConfigStruct(
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
    end

    @testset "Serialization JSON roundtrip" begin
        norm = AnalysisConfig.NormalizationConfig(method="clr", pseudocount=0.5)
        cfg = AnalysisConfig.AnalysisConfigStruct(
            method="clr_lm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            created_by="tester"
        )

        json_str = AnalysisConfig.to_json(cfg)
        @test occursin("clr_lm", json_str)
        @test occursin(cfg.id, json_str)

        cfg_restored = AnalysisConfig.from_json(json_str)
        @test cfg_restored.method == cfg.method
        @test cfg_restored.formula == cfg.formula
        @test cfg_restored.normalization.method == cfg.normalization.method
    end

    @testset "Serialization Nickel and DEED" begin
        norm = AnalysisConfig.NormalizationConfig(method="size_factors")
        cfg = AnalysisConfig.AnalysisConfigStruct(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
        )

        nickel = AnalysisConfig.to_nickel(cfg)
        @test occursin("nb_glm", nickel)
        @test occursin(cfg.id, nickel)
        @test occursin("BH", nickel)

        deed = AnalysisConfig.to_deed(cfg)
        @test occursin("repo-deed", deed)
        @test occursin(":schema-version", deed)
        @test occursin(cfg.id, deed)
        @test occursin("nb_glm", deed)
    end

    @testset "Context-sensitive help" begin
        help_method = AnalysisConfig.context_help("method")
        @test occursin("nb_glm", help_method)
        @test occursin("clr_lm", help_method)

        help_formula = AnalysisConfig.context_help("formula")
        @test occursin("~", help_formula)

        help_bh = AnalysisConfig.context_help("correction.method")
        @test occursin("BH", help_bh)
    end

    @testset "DOI bundle creation" begin
        norm = AnalysisConfig.NormalizationConfig(method="size_factors")
        cfg = AnalysisConfig.AnalysisConfigStruct(
            method="nb_glm",
            formula="~ group",
            metadata_columns=["group"],
            normalization=norm,
            created_by="test_user"
        )

        result = AnalysisConfig.AnalysisResult(
            config_id=cfg.id,
            config_hash=cfg.hash,
            method=cfg.method,
            results=OrderedDict{String,Any}("taxon1" => OrderedDict("p" => 0.01, "log2FoldChange" => 2.0))
        )

        mktempdir() do tmpdir
            bundle_path = AnalysisConfig.create_doi_bundle(cfg, result, joinpath(tmpdir, "bundle"); authors=["Test User"], title="Test Bundle")
            @test isdir(bundle_path)
            @test isfile(joinpath(bundle_path, "analysis_config.json"))
            @test isfile(joinpath(bundle_path, "analysis_config.ncl"))
            @test isfile(joinpath(bundle_path, "analysis_config_chora.deed"))
            @test isfile(joinpath(bundle_path, "datacite.json"))
            @test isfile(joinpath(bundle_path, "provenance.json"))
            @test isfile(joinpath(bundle_path, "analysis_result.json"))
            @test isfile(joinpath(bundle_path, "README.md"))

            # Check datacite contains method
            datacite_content = read(joinpath(bundle_path, "datacite.json"), String)
            @test occursin("nb_glm", datacite_content)
        end
    end

    @testset "present_in_every_admissible_world" begin
        # Sans fibre -> false
        @test !AnalysisConfig.present_in_every_admissible_world([1.0, 2.0, 3.0], Dict{String,Any}("avec_fibre" => false))

        # Avec fibre and all >= threshold -> true
        @test AnalysisConfig.present_in_every_admissible_world([1.0, 2.0, 3.0], Dict{String,Any}("avec_fibre" => true, "epistemic_status" => "unknown"); threshold=1.0)

        # One below threshold -> false
        @test !AnalysisConfig.present_in_every_admissible_world([0.0, 2.0, 3.0], Dict{String,Any}("avec_fibre" => true); threshold=1.0)

        # Explicit status present_in_every -> true even if counts low? Actually should trust status
        @test AnalysisConfig.present_in_every_admissible_world([0.0], Dict{String,Any}("avec_fibre" => true, "epistemic_status" => "present_in_every_admissible_world"))

        # Explicit absent -> false
        @test !AnalysisConfig.present_in_every_admissible_world([10.0], Dict{String,Any}("avec_fibre" => true, "epistemic_status" => "absent_in_every_admissible_world"))
    end
end

@testset "Epistemic module" begin
    @testset "EchoFiber avec_fibre" begin
        fiber_with = Epistemic.EchoFiber{String,String}("observed", ["w1", "w2"])
        @test Epistemic.avec_fibre(fiber_with)
        @test !Epistemic.sans_fibre(fiber_with)

        fiber_empty = Epistemic.EchoFiber{String,String}("observed", String[])
        @test !Epistemic.avec_fibre(fiber_empty)
        @test Epistemic.sans_fibre(fiber_empty)
    end

    @testset "Warrant without soundness" begin
        w = Epistemic.Warrant{String}("count>=1", [1, 2, 3], "taxon present")
        @test w.claim == "taxon present"
        # Having warrant does NOT give claim directly — need SoundWarrant
        sw = Epistemic.SoundWarrant{String}(w, token -> token > 0 ? "taxon present" : "absent")
        @test sw(1) == "taxon present"
    end

    @testset "Candidate and present_in_every" begin
        # Simplified world: (u,n) where u=true abundance, n=noise, observe=u+n
        # For presence, we check u !=0

        # Two candidates: (0,2) and (2,0) both observe 2
        c1 = Epistemic.Candidate{Tuple{Int,Int},Int}((0,2), true, true)
        c2 = Epistemic.Candidate{Tuple{Int,Int},Int}((2,0), true, true)
        case_unbounded = Epistemic.Case{Tuple{Int,Int},Int}(c1, [c1, c2])

        present_fn = (world) -> world[1] != 0  # u !=0

        @test !Epistemic.present_in_every_admissible_world(case_unbounded, present_fn) # (0,2) has u=0, so not present in every

        # Bounded: n<=1, candidates (1,1) and (2,0) both have u!=0
        c3 = Epistemic.Candidate{Tuple{Int,Int},Int}((1,1), true, true)
        c4 = Epistemic.Candidate{Tuple{Int,Int},Int}((2,0), true, true)
        case_bounded = Epistemic.Case{Tuple{Int,Int},Int}(c3, [c3, c4])

        @test Epistemic.present_in_every_admissible_world(case_bounded, present_fn) # both have u!=0
    end

    @testset "Epistemic colour coding" begin
        @test Epistemic.epistemic_colour("present_in_every_admissible_world") == "#2e7d32"
        @test Epistemic.epistemic_colour("present_in_some_admissible_world") == "#f9a825"
        @test Epistemic.epistemic_colour("absent_in_every_admissible_world") == "#9e9e9e"
        @test Epistemic.epistemic_colour("unknown") == "#c62828"
    end

    @testset "Cloud sizing" begin
        s1 = Epistemic.cloud_size_by_residual(0)
        s2 = Epistemic.cloud_size_by_residual(10)
        s3 = Epistemic.cloud_size_by_residual(100)
        @test s1 < s2 < s3
        @test s1 >= 5.0
    end
end

@testset "CladeCumulus" begin
    @testset "CladeNode creation" begin
        node = CladeCumulus.CladeNode(id="test", label="Test", rank="Genus", count=10.0)
        @test node.id == "test"
        @test node.count == 10.0
        @test node.epistemic_status == "unknown"
    end

    @testset "Build clade tree and cumulative frequencies" begin
        rows = [
            Dict{String,Any}("Domain" => "Bacteria", "Phylum" => "Firmicutes", "Genus" => "Lactobacillus", "total" => 100.0, "avec_fibre" => true, "epistemic_status" => "present_in_every_admissible_world", "residual_count" => 2),
            Dict{String,Any}("Domain" => "Bacteria", "Phylum" => "Firmicutes", "Genus" => "Streptococcus", "total" => 50.0, "avec_fibre" => true, "epistemic_status" => "present_in_some_admissible_world", "residual_count" => 5),
            Dict{String,Any}("Domain" => "Bacteria", "Phylum" => "Bacteroidetes", "Genus" => "Bacteroides", "total" => 200.0, "avec_fibre" => false, "epistemic_status" => "unknown", "residual_count" => 0),
        ]

        tree = CladeCumulus.build_clade_tree(rows)
        @test haskey(tree.nodes, "root")
        @test tree.total_count >= 350.0

        freqs = CladeCumulus.cumulative_frequencies(tree)
        @test !isempty(freqs)

        # Root should have cumulative_frequency 1.0
        root_node = tree.nodes[tree.root_id]
        @test root_node.cumulative_frequency ≈ 1.0 atol=0.01
    end

    @testset "Drag-and-drop validation with present_in_every_admissible_world" begin
        rows = [
            Dict{String,Any}("Domain" => "Bacteria", "Genus" => "Lactobacillus", "total" => 100.0, "avec_fibre" => true, "epistemic_status" => "present_in_every_admissible_world", "residual_count" => 1),
            Dict{String,Any}("Domain" => "Bacteria", "Genus" => "Bacteroides", "total" => 200.0, "avec_fibre" => false, "epistemic_status" => "unknown", "residual_count" => 0),
        ]
        tree = CladeCumulus.build_clade_tree(rows)

        # Find nodes
        lacto_id = nothing
        bact_id = nothing
        for (id, node) in tree.nodes
            if node.label == "Lactobacillus"
                lacto_id = id
            elseif node.label == "Bacteroides"
                bact_id = id
            end
        end
        @test !isnothing(lacto_id)
        @test !isnothing(bact_id)

        # Valid: Lactobacillus has avec_fibre and present_in_every
        (valid, msg) = CladeCumulus.validate_drag_drop(tree, lacto_id, tree.root_id, Dict{String,Any}())
        @test valid
        @test occursin("present_in_every", msg)

        # Invalid: Bacteroides sans fibre
        (valid2, msg2) = CladeCumulus.validate_drag_drop(tree, bact_id, tree.root_id, Dict{String,Any}())
        @test !valid2
        @test occursin("sans fibre", msg2)

        # Invalid: drop onto descendant (cycle)
        # Create a child under lacto and try to drop lacto onto child
        child_id = lacto_id * "|child"
        # We need to add child manually for test
        nodes = copy(tree.nodes)
        nodes[child_id] = CladeCumulus.CladeNode(id=child_id, label="Child", parent_id=lacto_id, count=10.0, avec_fibre=true, epistemic_status="present_in_every_admissible_world")
        # Update parent's children
        old_parent = nodes[lacto_id]
        nodes[lacto_id] = CladeCumulus.CladeNode(id=old_parent.id, label=old_parent.label, rank=old_parent.rank, parent_id=old_parent.parent_id, children_ids=vcat(old_parent.children_ids, [child_id]), count=old_parent.count, cumulative_count=old_parent.cumulative_count, residual_count=old_parent.residual_count, avec_fibre=old_parent.avec_fibre, epistemic_status=old_parent.epistemic_status)
        tree2 = CladeCumulus.CladeTree(nodes, tree.root_id)

        (valid3, msg3) = CladeCumulus.validate_drag_drop(tree2, lacto_id, child_id, Dict{String,Any}())
        @test !valid3
        @test occursin("cycle", lowercase(msg3))
    end

    @testset "Epistemic colour and cloud size" begin
        node_every = CladeCumulus.CladeNode(id="every", label="Every", count=10.0, avec_fibre=true, epistemic_status="present_in_every_admissible_world", residual_count=2)
        node_some = CladeCumulus.CladeNode(id="some", label="Some", count=10.0, avec_fibre=true, epistemic_status="present_in_some_admissible_world", residual_count=5)

        @test CladeCumulus.epistemic_colour_for_node(node_every) == "#2e7d32"
        @test CladeCumulus.epistemic_colour_for_node(node_some) == "#f9a825"

        @test CladeCumulus.cloud_size_for_node(node_some) > CladeCumulus.cloud_size_for_node(node_every)
    end
end
