@testset "DOI / Zenodo publication" begin

    using MetaManifold.DOI
    using MetaManifold.DOI: DOIConfig, Deposition, PublicationReceipt,
        load_doi_config, publication_enabled, redact,
        journal_append, journal_state

    const SANDBOX = "https://sandbox.zenodo.org"
    const PROD    = "https://zenodo.org"

    @testset "disabled by default" begin
        cfg = load_doi_config()
        @test !cfg.enabled
        @test !publication_enabled(cfg)
        @test cfg.origin == SANDBOX
    end

    @testset "constructor validates the fixed origins" begin
        @test DOIConfig(origin=SANDBOX).sandbox == true
        @test DOIConfig(origin=PROD).sandbox == false
        # Any other host is refused and falls back to sandbox.
        @test DOIConfig(origin="https://evil.example.com").origin == SANDBOX
        @test DOIConfig(origin="http://localhost:1").origin == SANDBOX
    end

    @testset "redaction scrubs bearer tokens" begin
        msg = "POST /api/deposit/depositions Authorization: Bearer sk-secret-token"
        red = redact(msg)
        @test occursin("[redacted]", red)
        @test !occursin("sk-secret-token", red)
        # Unrelated text passes through untouched.
        @test redact("zenodo request") == "zenodo request"
    end

    @testset "publish requires an enabled config" begin
        cfg = load_doi_config()
        @test_throws ErrorException DOI.create_deposition(cfg, "study", "run")
        @test_throws ErrorException DOI.publish_deposition(
            Deposition(1, "10.5281/zenodo.0", false, "", Dict{String,Any}[]); confirm=true)
    end

    @testset "receipt checksum covers attestation content" begin
        receipt = PublicationReceipt(
            1, "study", "run", PROD, 42, "10.5281/zenodo.123456", true,
            [Dict{String,Any}("name" => "f.svg", "sha256" => "aa", "size" => 1)],
            "2026-01-01T00:00:00Z", nothing, "")
        d = MetaManifold.DOI._receipt_dict(receipt)
        checksum = MetaManifold.DOI._receipt_checksum(d)
        @test !isempty(checksum)
        # Changing any attested field changes the checksum.
        d2 = copy(d); d2["doi"] = "10.5281/zenodo.tampered"
        @test MetaManifold.DOI._receipt_checksum(d2) != checksum
    end

    @testset "journal append and read" begin
        dir = mktempdir()
        cfg = DOIConfig(enabled=false, storage_dir=dir)
        DOI.journal_append(cfg, Dict{String,Any}("phase" => "created", "study" => "s", "run" => "r"))
        DOI.journal_append(cfg, Dict{String,Any}("phase" => "published", "study" => "s", "run" => "r"))
        state = journal_state(cfg)
        @test length(state) == 2
        @test state[1]["phase"] == "created"
        @test state[2]["phase"] == "published"
        # Empty journal when absent.
        empty_cfg = DOIConfig(enabled=false, storage_dir=joinpath(dir, "missing"))
        @test isempty(journal_state(empty_cfg))
    end

    @testset "multipart upload form" begin
        body, ctype = DOI._multipart_form("figure.svg", UInt8[1, 2, 3])
        @test occursin("multipart/form-data; boundary=", ctype)
        s = String(body)
        @test occursin("name=\"file\"", s)
        @test occursin("filename=\"figure.svg\"", s)
        @test occursin("application/octet-stream", s)
    end

end
