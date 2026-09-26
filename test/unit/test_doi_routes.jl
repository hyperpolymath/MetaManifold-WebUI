# SPDX-License-Identifier: MPL-2.0
using HTTP, Oxygen
using MetaManifold: DOIStorage, AnalysisStore, DOIBundles, DOIPublications

if !isdefined(Main, :Server)
    include(joinpath(@__DIR__, "..", "..", "src", "server", "server.jl"))
end

@testset "DOI HTTP boundary and persistence" begin
    server = Main.Server
    oldroot = server.ServerState._root[]
    factory = server._DOI_CLIENT_FACTORY[]
    fake = Main.DOIContractTests.FakeZenodo()
    server._DOI_CLIENT_FACTORY[] = () -> Main.DOIContractTests.client(fake)
    headers = ["Host" => "localhost:8080", "Origin" => "http://localhost:8080",
               "Content-Type" => "application/json", "X-DOI-CSRF" => server._DOI_CSRF]
    call(method, path, body=nothing; hs=headers) = Oxygen.internalrequest(HTTP.Request(method, path, hs,
        isnothing(body) ? "" : JSON3.write(body)); catch_errors=false)
    decode(response) = JSON3.read(String(response.body), Dict{String,Any})
    try
        mktempdir() do tmp
            mkpath(joinpath(tmp, "data", "example"))
            server.ServerState.set_root!(tmp)
            base = "/api/v1/studies/example"
            @test call("GET", "/api/v1/studies/nope/doi-ui").status == 404
            response = call("GET", base * "/doi-ui")
            @test response.status == 200
            @test occursin("text/html", HTTP.header(response, "Content-Type"))
            @test occursin("script-src 'self'", HTTP.header(response, "Content-Security-Policy"))
            @test HTTP.header(response, "Cache-Control") == "no-store"
            @test call("GET", "/api/v1/doi/assets/publication.js").status == 200
            @test call("GET", "/api/v1/doi/assets/secrets.env").status == 404
            @test decode(call("GET", "/api/v1/doi/capabilities"))["enabled"]
            @test call("POST", base * "/doi-publications", Dict(); hs=["Content-Type" => "application/json"]).status == 403
            foreign = [h for h in headers if first(h) != "Origin"]
            push!(foreign, "Origin" => "https://attacker.example")
            @test call("POST", base * "/doi-publications", Dict(); hs=foreign).status == 403
            badtype = [h for h in headers if first(h) != "Content-Type"]
            push!(badtype, "Content-Type" => "text/plain")
            @test call("POST", base * "/doi-publications", Dict(); hs=badtype).status == 415
            @test call("POST", base * "/doi-publications", Dict("token" => "never-send-this")).status == 400
            @test isempty(fake.calls)
            # The existing creation API now writes a durable config, and keeps
            # fields which were previously silently dropped by the route parser.
            created = call("POST", base * "/analysis-config", Dict("method" => "nb_glm", "formula" => "~ group", "metadata_columns" => ["group"],
                "created_by" => "Example, Ada", "normalization" => Dict("method" => "size_factors", "epsilon" => 0.00001),
                "advanced" => Dict("pseudocount" => 0.7, "epsilon" => 0.00002)))
            @test created.status == 200
            cfg = decode(created)["config"]
            @test cfg["normalization"]["epsilon"] == 0.00001
            @test cfg["advanced"]["pseudocount"] == 0.7
            @test isfile(joinpath(tmp, "projects", "example", ".analysis", "configs", cfg["id"] * ".json"))
            @test only(decode(call("GET", base * "/analysis-config"))["configs"])["hash"] == cfg["hash"]
            @test isempty(decode(call("GET", base * "/analysis-config/" * cfg["id"] * "/results"))["results"])
            request = Dict{String,Any}("config_id" => cfg["id"], "result_id" => nothing,
                "metadata" => Main.DOIContractTests.metadata_fixture(), "acknowledge_upload" => true)
            missing = copy(request); delete!(missing, "result_id")
            @test call("POST", base * "/doi-publications", missing).status == 422
            @test call("POST", base * "/doi-publications", merge(request, Dict("acknowledge_upload" => false))).status == 422
            @test isempty(fake.calls)
            # Legacy mock endpoint is clearly marked, persists as such, and cannot
            # be elevated to a public scientific result by the publication API.
            mock_response = call("POST", base * "/analysis-config/" * cfg["id"] * "/run", Dict())
            @test mock_response.status == 200
            result_id = decode(mock_response)["result"]["id"]
            listed = only(decode(call("GET", base * "/analysis-config/" * cfg["id"] * "/results"))["results"])
            @test !listed["publishable"]
            @test call("POST", base * "/doi-publications", merge(request, Dict("result_id" => result_id))).status == 422
            @test isempty(fake.calls)
            prepared_response = call("POST", base * "/doi-publications", request)
            @test prepared_response.status == 200
            prepared = decode(prepared_response)
            @test prepared["state"] == "ready"
            @test prepared["binding"]["result_id"] === nothing # never silently includes mock/latest result
            publication = base * "/doi-publications/" * prepared["id"]
            @test call("POST", publication * "/publish", Dict()).status == 422
            @test Main.DOIContractTests.count_calls(fake, "POST", "/actions/publish") == 0
            @test call("GET", publication * "/download/bundle").status == 200
            @test call("GET", publication * "/download/receipt").status == 409
            @test call("GET", publication * "/download/state.json").status == 404
            # Study-level destruction and generic file serving cannot erase or
            # leak the private journal; the explicit downloads remain available.
            @test call("DELETE", base).status == 409
            @test call("POST", base * "/rename", Dict("name" => "other")).status == 409
            @test call("DELETE", base * "/analysis-config/" * cfg["id"]).status == 409
            middleware = server._file_middleware(_ -> HTTP.Response(200))
            @test middleware(HTTP.Request("GET", "/files/example/runs/.doi/" * prepared["id"] * "/state.json")).status == 403
            @test middleware(HTTP.Request("GET", "/files/example/runs/%2Eanalysis/configs/" * cfg["id"] * ".json")).status == 403
            # Preview/same-origin proxy requests work without wildcard CORS.
            preview_headers = ["Host" => "8080-test.e2b.app", "Origin" => "https://8080-test.e2b.app"]
            cors = server._cors_middleware(_ -> HTTP.Response(200))
            @test cors(HTTP.Request("GET", "/api/v1/doi/capabilities", preview_headers)).status == 200
            @test cors(HTTP.Request("GET", "/api/v1/doi/capabilities", foreign)).status == 403
            published_response = call("POST", publication * "/publish", Dict("confirmation" => prepared["confirmation_phrase"],
                "bundle_sha256" => prepared["bundle_sha256"], "acknowledge_public" => true))
            @test published_response.status == 200
            @test decode(published_response)["state"] == "published"
            @test call("GET", publication * "/download/receipt").status == 200
            @test call("GET", publication * "/download/citation").status == 200
            # Restarts/disabled credentials do not remove access to existing receipts.
            server._DOI_CLIENT_FACTORY[] = () -> throw(ArgumentError("disabled"))
            @test !decode(call("GET", "/api/v1/doi/capabilities"))["enabled"]
            @test call("GET", publication).status == 200
            @test call("GET", publication * "/download/receipt").status == 200
            @test call("POST", publication * "/refresh", Dict()).status == 503
        end
    finally
        server.ServerState._root[] = oldroot
        server._DOI_CLIENT_FACTORY[] = factory
    end
end
