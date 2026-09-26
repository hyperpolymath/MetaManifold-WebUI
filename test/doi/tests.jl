# SPDX-License-Identifier: MPL-2.0
module DOIContractTests
using Test, HTTP, JSON3, Dates, SHA, MD5, Sockets, Logging
const Target = isdefined(Main, :MetaManifold) ? Main.MetaManifold : Main.DOIIsolated
const S = Target.DOIStorage
const B = Target.DOIBundles
const Z = Target.Zenodo
const P = Target.DOIPublications
const W = Target.DOIWeb
include("fixtures.jl")

@testset "DOI metadata and bundle contracts" begin
    input = metadata_fixture()
    valid = B.validate_metadata(input)
    @test valid["creators"][1]["orcid"] == "0000-0002-1825-0097"
    @test valid["license"] == "CC-BY-4.0"
    for field in ("title", "description", "creators", "license")
        bad = deepcopy(input); delete!(bad, field)
        @test_throws S.PublicationError B.validate_metadata(bad)
    end
    for (field, value) in (("title", "   "), ("title", repeat("x", 251)), ("description", 42),
                           ("creators", []), ("creators", [Dict("name" => "Anonymous")]),
                           ("creators", [Dict("name" => "Example", "orcid" => "0000-0002-1825-0098")]),
                           ("license", "some-license"), ("publication_date", "2099-12-01"),
                           ("publication_date", "2026-02-30"), ("publication_date", "2026-1-1"),
                           ("github_release_url", "https://github.com/x/y/releases/latest"),
                           ("github_release_url", "https://github.com/x/y/releases/tag/../main"),
                           ("github_release_url", "https://github.com/x/y/releases/tag/v1?access_token=secret"),
                           ("github_release_url", "https://github.com/x/y/releases/tag/%2e%2e"),
                           ("github_project_url", "https://evil.example/users/x/projects/1"),
                           ("github_project_url", "javascript:alert(1)"))
        bad = merge(deepcopy(input), Dict(field => value))
        @test_throws S.PublicationError B.validate_metadata(bad)
    end
    for secret_field in ("access_token", "token", "base_url", "doi", "access_right")
        @test_throws S.PublicationError B.validate_metadata(merge(input, Dict(secret_field => "forbidden")))
    end
    mktempdir() do tmp
        bundle = bundle_fixture(tmp)
        @test B.verify_checksums(bundle)
        binding = B.snapshot(bundle)
        @test binding["kind"] == "configuration"
        @test isnothing(binding["result_id"])
        write(joinpath(bundle, "analysis_config.ncl"), "tampered")
        @test_throws S.PublicationError B.snapshot(bundle)
    end
    for extra in ("secret.env", "unexpected.txt")
        mktempdir() do tmp
            bundle = bundle_fixture(tmp)
            write(joinpath(bundle, extra), "must never upload")
            @test_throws S.PublicationError B.snapshot(bundle)
        end
    end
    mktempdir() do tmp
        bundle = bundle_fixture(tmp)
        rm(joinpath(bundle, "provenance.json"))
        symlink(joinpath(bundle, "datacite.json"), joinpath(bundle, "provenance.json"))
        @test_throws S.PublicationError B.snapshot(bundle)
    end
    mktempdir() do tmp
        bundle = bundle_fixture(tmp; dangerous=true)
        rm(joinpath(bundle, "DANGER_BANNER.txt"))
        B.write_checksums!(bundle)
        @test_throws S.PublicationError B.snapshot(bundle)
    end
    for modification in (:mock, :empty, :mismatch, :wrong_method, :not_run)
        mktempdir() do tmp
            bundle = bundle_fixture(tmp; result=true, mock=modification == :mock)
            path = joinpath(bundle, "analysis_result.json")
            result = S.read_json(path)
            modification == :empty && (result["results"] = Dict())
            modification == :mismatch && (result["config_hash"] = repeat("c", 64))
            modification == :wrong_method && (result["method"] = "logistic")
            modification == :not_run && (result["provenance"]["estimation"] = Dict("status" => "not_run"))
            write(path, JSON3.write(result)); B.write_checksums!(bundle)
            fake = FakeZenodo()
            @test_throws S.PublicationError P.prepare!(joinpath(tmp, "state"), bundle, metadata_fixture(), client(fake))
            @test isempty(fake.calls)
        end
    end
end

@testset "Zenodo client safety and bounded retries" begin
    @test Z.origin(Z.Client(FAKE_TOKEN)) == "https://sandbox.zenodo.org"
    @test_throws ArgumentError Z.Client(FAKE_TOKEN; environment="https://evil.example")
    @test_throws ArgumentError Z.Client("header\ninjection")
    @test_throws ArgumentError Z.environment_client(Dict("ZENODO_TOKEN" => FAKE_TOKEN))
    @test_throws ArgumentError Z.environment_client(Dict("METAMANIFOLD_ZENODO_ENABLED" => "true", "ZENODO_TOKEN" => FAKE_TOKEN))
    @test Z.environment_client(Dict("METAMANIFOLD_ZENODO_ENABLED" => "true", "ZENODO_SANDBOX_TOKEN" => FAKE_TOKEN)).environment == "sandbox"
    @test !occursin(FAKE_TOKEN, sprint(show, Z.Client(FAKE_TOKEN)))
    @test !occursin(FAKE_TOKEN, sprint(show, Z.Client(FAKE_TOKEN).token))
    @test Z.checked_id(123) == "123"
    for id in (true, 0, -1, "1/../2", "1?access_token=x", 1.2, nothing)
        @test_throws Z.RemoteError Z.checked_id(id)
    end
    @test_throws Z.RemoteError Z.checked_doi(Z.Client(FAKE_TOKEN), "10.5281/zenodo.123")
    @test Z.retry_after_seconds("5") == 5
    @test Z.retry_after_seconds("nonsense") === nothing
    @test Z.retry_after_seconds("Wed, 21 Oct 2015 07:28:00 GMT", DateTime(2015, 10, 21, 7, 27, 30)) == 30
    for status in (401, 403, 400, 404, 409, 415, 422, 302)
        calls = Ref(0)
        c = Z.Client(FAKE_TOKEN; transport=(args...) -> (calls[] += 1; fake_response(Dict("message" => FAKE_TOKEN); status)), sleeper=_ -> error("must not sleep"))
        err = captured_error(() -> Z.get_deposition(c, 101))
        @test err isa Z.RemoteError
        @test err.status == status
        @test !occursin(FAKE_TOKEN, sprint(showerror, err))
        @test calls[] == 1
    end
    for status in (429, 503)
        calls = Ref(0); waits = Int[]
        c = Z.Client(FAKE_TOKEN; transport=(args...) -> begin
            calls[] += 1
            calls[] < 3 ? fake_response(Dict(); status, headers=["Retry-After" => "2"]) : fake_response(Dict("id" => 101))
        end, sleeper=x -> push!(waits, x))
        @test Z.get_deposition(c, 101)["id"] == 101
        @test calls[] == 3
        @test waits == [2, 2]
    end
    calls = Ref(0)
    c = Z.Client(FAKE_TOKEN; transport=(args...) -> (calls[] += 1; fake_response(Dict(); status=429, headers=["Retry-After" => "3600"])), sleeper=_ -> error("must not retry early"))
    err = captured_error(() -> Z.create_deposition(c, Dict()))
    @test err.retry_after == 3600
    @test calls[] == 1
    calls[] = 0
    c = Z.Client(FAKE_TOKEN; transport=(args...) -> (calls[] += 1; fake_response(Dict(); status=429)), sleeper=_ -> nothing)
    @test_throws Z.RemoteError Z.create_deposition(c, Dict())
    @test calls[] == 4
    for operation in (c -> Z.create_deposition(c, Dict()), c -> Z.publish_deposition(c, 101))
        for fault in (:server_error, :disconnect, :malformed)
            calls[] = 0
            c = Z.Client(FAKE_TOKEN; transport=(args...) -> begin
                calls[] += 1
                fault == :disconnect && error("Authorization: Bearer $FAKE_TOKEN")
                fault == :malformed && return HTTP.Response(201; body="not JSON " * FAKE_TOKEN)
                fake_response(Dict("message" => FAKE_TOKEN); status=503)
            end, sleeper=_ -> error("must not retry ambiguous POST"))
            err = captured_error(() -> operation(c))
            @test err isa Z.RemoteError
            @test !occursin(FAKE_TOKEN, sprint(showerror, err))
            @test calls[] == 1
            # A status mismatch (201 on publish) is itself an unusable POST
            # response; recovery must not automatically replay it.
        end
    end
    mktempdir() do tmp
        path = joinpath(tmp, "test.zip"); write(path, "test payload")
        for bucket in ("http://sandbox.zenodo.org/api/files/11111111-1111-4111-8111-111111111111",
                       "https://evil.example/api/files/11111111-1111-4111-8111-111111111111",
                       "https://sandbox.zenodo.org.evil.example/api/files/11111111-1111-4111-8111-111111111111",
                       "https://zenodo.org/api/files/11111111-1111-4111-8111-111111111111",
                       "https://sandbox.zenodo.org/api/files/11111111-1111-4111-8111-111111111111?x=1",
                       "https://sandbox.zenodo.org/api/files/../deposit/depositions",
                       "https://user:pass@sandbox.zenodo.org/api/files/11111111-1111-4111-8111-111111111111")
            c = Z.Client(FAKE_TOKEN; transport=(args...) -> error("must not send credentials"))
            @test_throws Z.RemoteError Z.upload_file(c, Dict("links" => Dict("bucket" => bucket)), path, "test.zip")
        end
        bodies = String[]
        c = Z.Client(FAKE_TOKEN; transport=(method, url, headers, body) -> begin
            push!(bodies, String(read(body)))
            length(bodies) == 1 && error("disconnect")
            fake_response(Dict("ok" => true); status=201)
        end, sleeper=_ -> nothing)
        Z.upload_file(c, Dict("links" => Dict("bucket" => "https://sandbox.zenodo.org/api/files/11111111-1111-4111-8111-111111111111")), path, "test.zip")
        @test bodies == ["test payload", "test payload"]
    end
end

@testset "Durable two-phase DOI publication" begin
    for environment in ("sandbox", "production")
        prepared_fixture(; result=true, dangerous=true, environment) do tmp, root, source, fake, c, prepared
            @test prepared["state"] == "ready"
            @test prepared["doi"] === nothing
            @test prepared["doi_url"] === nothing
            @test prepared["test_record"] == (environment == "sandbox")
            @test startswith(prepared["reserved_doi"], environment == "sandbox" ? "10.5072/" : "10.5281/")
            @test count_calls(fake, "POST", "/deposit/depositions") == 1
            @test count_calls(fake, "POST", "/actions/publish") == 0
            @test bytes2hex(sha256(fake.uploaded)) == prepared["bundle_sha256"]
            @test length(fake.uploaded) == prepared["bundle_size"]
            directory = P.publication_path(root, prepared["id"])
            payload = joinpath(directory, "payload")
            @test B.verify_checksums(payload)
            @test read(joinpath(payload, "analysis_config.json")) == read(joinpath(source, "analysis_config.json"))
            @test read(joinpath(payload, "analysis_result.json")) == read(joinpath(source, "analysis_result.json"))
            @test read(joinpath(payload, "provenance.json")) == read(joinpath(source, "provenance.json"))
            @test isfile(joinpath(payload, "DANGER_BANNER.txt"))
            @test isfile(joinpath(payload, "publication.ncl"))
            @test isfile(joinpath(payload, "publication_chora.deed"))
            @test occursin(":schema-version", read(joinpath(payload, "publication_chora.deed"), String))
            @test S.read_json(joinpath(payload, "publication.json"))["state"] == "reserved"
            @test S.read_json(joinpath(payload, "datacite.json"))["identifiers"][1]["identifier"] == prepared["reserved_doi"]
            @test occursin(prepared["reserved_doi"], read(joinpath(payload, "CITATION.cff"), String))
            archive = P.download_path(root, prepared["id"], "bundle")[1]
            entries = split(strip(read(`unzip -Z1 $archive`, String)), '\n')
            @test Set(entries) == Set(readdir(payload))
            @test all(name -> !occursin('/', name), entries) # no leaked /tmp/ prefixes
            @test success(`unzip -tq $archive`)
            @test stat(joinpath(directory, "state.json")).mode & 0o777 == 0o600
            @test_throws S.PublicationError P.receipt(root, prepared["id"])
            @test_throws S.PublicationError P.download_path(root, prepared["id"], "citation")
            before = length(fake.calls)
            # New client object simulates reloading the service after restart;
            # no process-local store participates in the idempotency decision.
            repeated = P.prepare!(root, source, metadata_fixture(), client(fake))
            @test repeated["id"] == prepared["id"]
            @test length(fake.calls) == before
            @test P.status(root, prepared["id"])["bundle_sha256"] == prepared["bundle_sha256"]
            @test length(P.publications(root)) == 1
            @test_throws S.PublicationError P.prepare!(root, source, merge(metadata_fixture(), Dict("title" => "Different")), c)
            @test_throws S.PublicationError P.resume!(root, prepared["id"], Z.Client(FAKE_TOKEN; environment=environment == "sandbox" ? "production" : "sandbox"))
            for kwargs in ((confirmation="wrong", bundle_sha256=prepared["bundle_sha256"], acknowledge_public=true),
                           (confirmation=prepared["confirmation_phrase"], bundle_sha256="wrong", acknowledge_public=true),
                           (confirmation=prepared["confirmation_phrase"], bundle_sha256=prepared["bundle_sha256"], acknowledge_public=false))
                @test_throws S.PublicationError P.publish!(root, prepared["id"], c; kwargs...)
            end
            @test count_calls(fake, "POST", "/actions/publish") == 0
            published = publish_fixture(root, prepared, c)
            @test published["state"] == "published"
            @test published["doi"] == prepared["reserved_doi"]
            @test published["doi_url"] == "https://doi.org/" * published["doi"]
            @test published["record_url"] == Z.origin(c) * "/records/101"
            @test count_calls(fake, "POST", "/actions/publish") == 1
            @test P.receipt(root, prepared["id"])["bundle_sha256"] == prepared["bundle_sha256"]
            @test P.receipt(root, prepared["id"])["binding"]["result_id"] == RESULT_ID
            receipt_before = read(P.download_path(root, prepared["id"], "receipt")[1])
            before = length(fake.calls)
            @test publish_fixture(root, prepared, client(fake))["doi"] == published["doi"]
            @test length(fake.calls) == before
            @test read(P.download_path(root, prepared["id"], "receipt")[1]) == receipt_before
            @test S.file_sha256(archive) == prepared["bundle_sha256"] # no self-referential rewrite
            if haskey(ENV, "DOI_CONTRACT_ARTIFACTS")
                output = ENV["DOI_CONTRACT_ARTIFACTS"]
                mkpath(output)
                S.atomic_json(joinpath(output, "prepared-" * environment * ".json"), prepared)
                S.atomic_json(joinpath(output, "published-" * environment * ".json"), P.receipt(root, prepared["id"]))
                for (source, suffix) in (("publication.json", ".json"), ("publication.ncl", ".ncl"), ("publication_chora.deed", ".deed"), ("CITATION.cff", ".cff"))
                    cp(joinpath(payload, source), joinpath(output, "attestation-" * environment * suffix); force=true)
                end
                write(joinpath(output, "publication.html"), W.render_page("example", "fixture-csrf", "sandbox", true; selected_config=CONFIG_ID))
                write(joinpath(output, "publication-production.html"), W.render_page("example", "fixture-csrf", "production", true; selected_config=CONFIG_ID))
                write(joinpath(output, "publication-disabled.html"), W.render_page("example", "fixture-csrf", "sandbox", false; selected_config=CONFIG_ID))
            end
            for (dir, _, files) in walkdir(root), file in files
                endswith(file, ".zip") && continue
                @test !occursin(FAKE_TOKEN, read(joinpath(dir, file), String))
            end
        end
    end
    prepared_fixture() do _, root, _, fake, c, prepared
        @test prepared["binding"]["kind"] == "configuration"
        @test occursin("Configuration only", fake.deposit["metadata"]["description"])
        @test P.refresh!(root, prepared["id"], c)["state"] == "ready"
        @test count_calls(fake, "POST", "/actions/publish") == 0
    end
end

@testset "Lost responses, recovery and integrity failures" begin
    # Crash after creation is sent, before a deposition ID can be journalled.
    mktempdir() do tmp
        source = bundle_fixture(tmp); root = joinpath(tmp, "state")
        fake = FakeZenodo(); normal = transport(fake)
        faulty = Z.Client(FAKE_TOKEN; transport=(method, url, headers, body) -> begin
            response = normal(method, url, headers, body)
            method == "POST" && error("lost response with $FAKE_TOKEN")
            response
        end)
        @test_throws Z.RemoteError P.prepare!(root, source, metadata_fixture(), faulty)
        state = only(P.publications(root))
        @test state["state"] == "creation_uncertain"
        @test state["deposition_id"] === nothing
        @test_throws S.PublicationError P.prepare!(root, source, metadata_fixture(), client(fake))
        @test count_calls(fake, "POST", "/deposit/depositions") == 1
        notes = fake.deposit["metadata"]["notes"]
        fake.deposit["metadata"]["notes"] = "Unrelated draft"
        @test_throws S.PublicationError P.recover_creation!(root, state["id"], 101, client(fake))
        @test P.status(root, state["id"])["deposition_id"] === nothing
        fake.deposit["metadata"]["notes"] = notes
        recovered = P.recover_creation!(root, state["id"], 101, client(fake))
        @test recovered["state"] == "ready"
        @test count_calls(fake, "POST", "/deposit/depositions") == 1
    end
    # Definite rejection is retryable; an invalid response to a successful POST isn't.
    for (status, body, expected) in ((401, "{}", "preparing"), (429, "{}", "preparing"), (201, "not-json", "creation_uncertain"), (201, "{}", "creation_uncertain"))
        mktempdir() do tmp
            source = bundle_fixture(tmp); root = joinpath(tmp, "state")
            c = Z.Client(FAKE_TOKEN; transport=(args...) -> HTTP.Response(status; body), attempts=1)
            @test !isnothing(captured_error(() -> P.prepare!(root, source, metadata_fixture(), c)))
            @test only(P.publications(root))["state"] == expected
        end
    end
    prepared_fixture() do _, root, _, fake, c, prepared
        fake.publish_done = false
        submitted = publish_fixture(root, prepared, c)
        @test submitted["state"] == "publishing"
        @test submitted["doi"] === nothing
        @test_throws S.PublicationError publish_fixture(root, prepared, c)
        @test count_calls(fake, "POST", "/actions/publish") == 1
        mark_published!(fake)
        @test P.refresh!(root, prepared["id"], client(fake))["state"] == "published"
        @test count_calls(fake, "POST", "/actions/publish") == 1
    end
    prepared_fixture() do _, root, _, fake, _, prepared
        normal = transport(fake)
        faulty = Z.Client(FAKE_TOKEN; transport=(method, url, headers, body) -> begin
            response = normal(method, url, headers, body)
            method == "POST" && error("lost response with $FAKE_TOKEN")
            response
        end)
        @test_throws Z.RemoteError publish_fixture(root, prepared, faulty)
        @test P.status(root, prepared["id"])["state"] == "publication_uncertain"
        @test_throws S.PublicationError publish_fixture(root, prepared, client(fake))
        @test P.refresh!(root, prepared["id"], client(fake))["state"] == "published"
        @test count_calls(fake, "POST", "/actions/publish") == 1
    end
    for modification in (:metadata, :extra_file, :checksum, :size, :local_bytes, :doi)
        prepared_fixture() do _, root, _, fake, c, prepared
            modification == :metadata && (fake.deposit["metadata"]["title"] = "Edited outside application")
            modification == :extra_file && push!(fake.deposit["files"], Dict("name" => "secret.txt"))
            modification == :checksum && (fake.deposit["files"][1]["checksum"] = repeat("0", 32))
            modification == :size && (fake.deposit["files"][1]["filesize"] = "1")
            modification == :doi && (fake.deposit["metadata"]["prereserve_doi"]["doi"] = "10.5072/zenodo.999")
            if modification == :local_bytes
                open(P.download_path(root, prepared["id"], "bundle")[1], "a") do io; write(io, "changed"); end
            end
            @test_throws S.PublicationError publish_fixture(root, prepared, c)
            @test count_calls(fake, "POST", "/actions/publish") == 0
        end
    end
    prepared_fixture() do _, root, _, fake, c, prepared
        publish_fixture(root, prepared, c)
        receipt_path = P.download_path(root, prepared["id"], "receipt")[1]
        original = read(receipt_path, String)
        write(receipt_path, original * " ")
        @test_throws S.PublicationError P.receipt(root, prepared["id"])
        write(receipt_path, original)
        citation_path = P.download_path(root, prepared["id"], "citation")[1]
        write(citation_path, "doi: 10.5281/zenodo.999")
        @test_throws S.PublicationError P.download_path(root, prepared["id"], "citation")
        @test count_calls(fake, "POST", "/actions/publish") == 1
    end
    # PUT failure can be resumed with the original bytes and the same deposition.
    mktempdir() do tmp
        source = bundle_fixture(tmp); root = joinpath(tmp, "state")
        fake = FakeZenodo(); normal = transport(fake)
        faulty = Z.Client(FAKE_TOKEN; attempts=1, transport=(method, url, headers, body) -> begin
            method == "PUT" && return fake_response(Dict(); status=503)
            normal(method, url, headers, body)
        end)
        @test_throws Z.RemoteError P.prepare!(root, source, metadata_fixture(), faulty)
        draft = only(P.publications(root))
        @test draft["state"] == "draft"
        @test draft["bundle_sha256"] !== nothing
        ready = P.resume!(root, draft["id"], client(fake))
        @test ready["bundle_sha256"] == draft["bundle_sha256"]
        @test count_calls(fake, "POST", "/deposit/depositions") == 1
    end
end

@testset "Bounded downloads through the real HTTP writer" begin
    mktempdir() do tmp
        path = joinpath(tmp, "archive.zip")
        content = repeat("0123456789abcdef", 200_003) # multiple 1 MiB chunks and a final partial chunk
        write(path, content)
        socket = Sockets.listen(ip"127.0.0.1", 0)
        port = last(Sockets.getsockname(socket))
        server = HTTP.serve!(_ -> HTTP.Response(200, ["Content-Type" => "application/zip", "Content-Length" => string(filesize(path))]; body=S.FileBody(path)), socket; verbose=false)
        try
            response = HTTP.get("http://127.0.0.1:$port/"; retry=false, readtimeout=10)
            @test response.status == 200
            @test HTTP.header(response, "Content-Length") == string(sizeof(content))
            @test String(response.body) == content
            logs = IOBuffer()
            with_logger(SimpleLogger(logs, Logging.Debug)) do
                # The real HTTP transport must suppress even opt-in wire logging.
                Z._http("GET", "http://127.0.0.1:$port/", ["Authorization" => "Bearer " * FAKE_TOKEN], "")
            end
            @test !occursin(FAKE_TOKEN, String(take!(logs)))
        finally
            HTTP.forceclose(server)
        end
    end
end

@testset "Private atomic storage and Julia UI" begin
    mktempdir() do tmp
        root = joinpath(tmp, "private")
        S.atomic_json(joinpath(root, "state.json"), Dict("value" => 1))
        @test S.read_json(joinpath(root, "state.json"))["value"] == 1
        S.atomic_json(joinpath(root, "state.json"), Dict("value" => 2))
        @test S.read_json(joinpath(root, "state.json"))["value"] == 2
        stream = IOBuffer()
        bytes = write(stream, S.FileBody(joinpath(root, "state.json")))
        @test bytes == filesize(joinpath(root, "state.json"))
        @test String(take!(stream)) == read(joinpath(root, "state.json"), String)
        @test readdir(root) == ["state.json"]
        S.with_publication_lock(root) do
            err = captured_error(() -> S.with_publication_lock(() -> nothing, root))
            @test err isa S.PublicationError
            @test err.code == "publication_busy"
        end
        @test S.with_publication_lock(() -> true, root)
        @test_throws S.PublicationError P.publication_path(root, "../../secrets")
        @test_throws S.PublicationError P.publication_path(root, repeat("a", 63))
        symlink(joinpath(root, "state.json"), joinpath(root, "unsafe.json"))
        @test_throws S.PublicationError S.atomic_json(joinpath(root, "unsafe.json"), Dict())
    end
    html = W.render_page("<script>attack</script>", "csrf", "sandbox", false; selected_config="</script><script>attack</script>")
    @test !occursin("<script>attack", html)
    @test occursin("&lt;script&gt;attack", html)
    @test occursin("\\u003c/script\\u003e", html)
    @test occursin("SANDBOX", html)
    @test occursin("DANGER", html)
    @test occursin("<dialog", html)
    @test occursin("Evidence Mode", html)
    @test occursin("No saved config?", html)
    @test !occursin("ZENODO_TOKEN", html)
end

end # module DOIContractTests
