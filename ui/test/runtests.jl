using Test, JSON3
include(joinpath(@__DIR__, "..", "src", "Contracts.jl"))
include(joinpath(@__DIR__, "..", "src", "BackendClient.jl"))
using .Contracts, .BackendClient

summary = JSON3.read("""{"name":"study A","run_count":1,"group_count":0,"active_job_count":2}""")
@testset "Typed study boundary" begin
    s = decode_summary(summary)
    @test s isa StudySummary
    @test s.name == "study A"
    @test s.active_job_count == 2
    @test isempty(decode_studies(JSON3.read("[]")))
    @test decode_studies([summary])[1].run_count == 1
    @test_throws ContractError decode_studies(summary)
    @test_throws ContractError decode_summary(JSON3.read("null"))
    @test_throws ContractError decode_summary(Dict("name"=>"x"))
    for invalid in (-1, true, 1.5, "1", nothing)
        d = Dict{String,Any}(String(k)=>v for (k,v) in pairs(summary))
        d["run_count"] = invalid
        @test_throws ContractError decode_summary(d)
    end
    d = Dict{String,Any}(String(k)=>v for (k,v) in pairs(summary))
    d["runs"] = ["run_1"]; d["groups"] = String[]
    @test decode_study(d).runs == ["run_1"]
    d["runs"] = []
    @test_throws ContractError decode_study(d)
    d["runs"] = [false]
    @test_throws ContractError decode_study(d)
end
@testset "Backend URL boundary" begin
    @test Backend("http://127.0.0.1:8080/").origin == "http://127.0.0.1:8080"
    for url in ("file:///etc/passwd", "http://host/path", "http://user:pass@host", "http://host?x=1", "http://host#x")
        @test_throws ArgumentError Backend(url)
    end
    @test_throws ArgumentError Backend("http://localhost"; timeout=0)
    @test_throws ArgumentError Backend("http://localhost"; timeout=NaN)
    @test study_path("study A") == "/api/v1/studies/study%20A"
    for name in ("", "..", ".", "a/b", "a\\b", "a\n")
        @test_throws ArgumentError study_path(name)
    end
end

# Optional integration checks against the disposable fixture server, never real studies.
if get(ENV, "UI_TEST_API", "") != ""
    b = Backend(ENV["UI_TEST_API"])
    @testset "HTTP adapter with fixture server" begin
        @test length(list_studies(b)) == 2
        @test get_study(b, "fixture_coastal").runs == ["run_A", "run_B"]
        @test_throws BackendError get_study(b, "missing")
        @test_throws ContractError get_study(b, "malformed")
        @test_throws BackendError get_study(b, "invalid_json")
        @test_throws BackendError get_study(b, "redirect")
        @test_throws BackendError list_studies(Backend("http://127.0.0.1:1"; timeout=0.5))
    end
end
