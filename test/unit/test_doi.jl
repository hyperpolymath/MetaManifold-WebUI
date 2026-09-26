# SPDX-License-Identifier: MPL-2.0
# The same contracts also run inside the full scientific application environment.
using MetaManifold: DOIStorage, DOIBundles, Zenodo, DOIPublications, DOIWeb, AnalysisStore
include(joinpath(@__DIR__, "..", "doi", "tests.jl"))

@testset "Analysis persistence and actual DOI bundles" begin
    using OrderedCollections
    mktempdir() do tmp
        cfg = AnalysisConfig.AnalysisConfigStruct(method="nb_glm", formula="~ group",
            metadata_columns=["group"], created_by="Example, Ada")
        original = AnalysisConfig.to_json(cfg)
        store = joinpath(tmp, "analysis")
        AnalysisStore.save_config!(store, cfg)
        reloaded = AnalysisStore.configs(store)[cfg.id]
        @test reloaded.hash == cfg.hash
        @test AnalysisConfig.to_json(reloaded) == original
        @test AnalysisStore.save_config!(store, cfg) == cfg.id
        result = AnalysisConfig.AnalysisResult(config_id=cfg.id, config_hash=cfg.hash, method=cfg.method,
            results=OrderedDict{String,Any}("z_fixture" => Dict("status" => "fixture"), "a_fixture" => Dict("status" => "fixture")))
        AnalysisStore.save_result!(store, result)
        @test AnalysisStore.results(store)[result.id].hash == result.hash
        bundle = AnalysisConfig.create_doi_bundle(reloaded, result; output_dir=joinpath(tmp, "bundle"))
        @test DOIBundles.verify_checksums(bundle)
        @test DOIBundles.snapshot(bundle)["result_id"] == result.id
        @test_throws ArgumentError AnalysisConfig.create_doi_bundle(cfg; output_dir=bundle)
        wrong = AnalysisConfig.AnalysisResult(config_id=cfg.id, config_hash=repeat("a", 64), method=cfg.method)
        @test_throws ArgumentError AnalysisConfig.create_doi_bundle(cfg, wrong; output_dir=joinpath(tmp, "wrong"))
        # Persistence reads do not trust hashes supplied in stored JSON.
        path = joinpath(store, "configs", cfg.id * ".json")
        data = JSON3.read(read(path, String), Dict{String,Any})
        data["formula"] = "~ group + batch"
        DOIStorage.atomic_json(path, data)
        @test_throws DOIStorage.PublicationError AnalysisStore.configs(store)
    end
end
