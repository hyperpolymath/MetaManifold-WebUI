# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# The /statistics page is the issue's UI-to-backend workflow evidence. It is
# Julia-rendered, has no client-side script, and must show provenance,
# accessibility affordances and honest failure states.
using Test
using MetaManifold
using MetaManifold.Canonical

const _UI_SV = MetaManifold.Server

_ui_text(response) = response.body isa AbstractString ? String(response.body) :
                     String(copy(response.body))

function _ui_get()
    req = _UI_SV.HTTP.Request("GET", "/statistics", String[], "")
    _UI_SV.Oxygen.internalrequest(req)
end

function _ui_post(form::AbstractString)
    req = _UI_SV.HTTP.Request("POST", "/statistics",
        ["Content-Type" => "application/x-www-form-urlencoded"], form)
    _UI_SV.Oxygen.internalrequest(req)
end

function _ui_form(overrides::AbstractDict=Dict{String,String}())
    fields = Dict{String,String}(
        "mode" => "exact_counts",
        "sample_labels" => "A, B",
        "feature_labels" => "taxon1, taxon2",
        "counts" => "1, 2\n3, 4",
        "round_digits" => "6",
    )
    merge(fields, Dict{String,String}(overrides))
end

_ui_body(fields) = join(["$(k)=$v" for (k, v) in fields], "&")

function _ui_with_root(f::Function)
    root = mktempdir()
    old = _UI_SV.ServerState._root[]
    try
        _UI_SV.ServerState.set_root!(root)
        mkpath(joinpath(root, "projects"))
        f(root)
    finally
        _UI_SV.ServerState._root[] = old
        rm(root; recursive=true, force=true)
    end
end

@testset "Statistics page is Julia-rendered and script-free" begin
    _ui_with_root() do _
        response = _ui_get()
        @test response.status == 200
        headers = Dict(String(k) => String(v) for (k, v) in response.headers)
        @test startswith(headers["Content-Type"], "text/html")
        @test headers["Cache-Control"] == "no-store"
        @test headers["X-Content-Type-Options"] == "nosniff"
        @test occursin("default-src 'none'", headers["Content-Security-Policy"])
        @test occursin("frame-ancestors 'none'", headers["Content-Security-Policy"])
        @test !occursin("script-src", headers["Content-Security-Policy"])

        html = _ui_text(response)
        @test startswith(html, "<!doctype html>")
        @test occursin("<html lang=\"en\">", html)
        @test occursin("Skip to main content", html)
        @test occursin("<main id=\"main\">", html)
        @test occursin("<form method=\"post\" action=\"/statistics\">", html)
        @test !occursin("<script", lowercase(html))
        @test !occursin("javascript:", lowercase(html))
        @test !occursin("onclick", lowercase(html))
        # The catalogue is displayed with its approval record and fingerprint.
        @test occursin("metamanifold.statistics-method-catalogue.v1", html)
        @test occursin("exact-descriptive-summaries", html)
        @test occursin("#issuecomment-5775420481", html)
        # Accessibility: every control is labelled and described.
        for id in ("mode", "precision_bits", "max_denominator_bits", "round_digits",
                   "time_limit_seconds", "sample_labels", "feature_labels", "counts",
                   "groups")
            @test occursin("for=\"$id\"", html)
            @test occursin("id=\"$id\"", html)
        end
        @test occursin("aria-describedby=\"counts-help\"", html)
        @test occursin("What this does not claim", html)
        @test occursin("no hypothesis test", html)
        @test occursin("Higher precision is not exactness", html)

        # The page must remain behind the documented route, not the SPA fallback.
        server_source = read(joinpath(dirname(dirname(@__DIR__)), "src", "server",
                                      "server.jl"), String)
        @test occursin("include(joinpath(@__DIR__, \"routes\", \"statistics_ui.jl\"))",
                       server_source)
        @test occursin("(uri == \"/statistics\"", server_source)
    end
end

@testset "Successful exact form shows totals, provenance and no persistence" begin
    _ui_with_root() do root
        response = _ui_post(_ui_body(_ui_form()))
        @test response.status == 200
        html = _ui_text(response)
        @test occursin("Status: success", html)
        @test occursin("<th scope=\"row\">A</th>", html)
        @test occursin("<th scope=\"row\">B</th>", html)
        @test occursin("Exact counts and proportions for A", html)
        @test occursin("<code>1/4</code>", html)
        @test occursin("<code>3/4</code>", html)
        @test occursin("<code>1/3</code>", html)
        @test occursin("<code>2/3</code>", html)
        @test occursin("Input fingerprint", html)
        @test occursin("Numeric policy fingerprint", html)
        @test occursin("Not persisted (persist was unchecked)", html)
        @test occursin("exact_counts", html)
        @test !occursin("<script", lowercase(html))
        # A fingerprint is a canonical SHA-256, not a display truncation.
        m = match(r"<dt>Input fingerprint</dt><dd><code>([0-9a-f]{64})</code>", html)
        @test !isnothing(m)
        @test !ispath(joinpath(root, "projects", "_derived", "direct"))
    end
end

@testset "Persisted form publishes an immutable derived record" begin
    _ui_with_root() do root
        fields = merge(_ui_form(), Dict{String,String}(
            "persist" => "on", "groups" => "g1, g2"))
        response = _ui_post(_ui_body(fields))
        @test response.status == 200
        html = _ui_text(response)
        @test occursin("Derived analysis ID", html)
        m = match(r"Derived analysis ID</dt><dd><code>([0-9a-f]{64})</code>", html)
        @test !isnothing(m)
        id = m.captures[1]
        @test isfile(joinpath(root, "projects", "_derived", "direct", "$id.json"))
        @test occursin("Group summaries", html)
        @test occursin("<th scope=\"row\">g1</th>", html)

        # Repeating the same form is idempotent: the same immutable record.
        repeated = _ui_text(_ui_post(_ui_body(fields)))
        @test occursin(id, repeated)
        directory = joinpath(root, "projects", "_derived", "direct")
        @test count(f -> endswith(f, ".json"), readdir(directory)) == 1
    end
end

@testset "The run path is callable without the HTTP handler" begin
    # The handler turns any exception into a 500 page, which hides the cause
    # behind "No result is claimed". Calling the run path directly means a
    # failure reaches the test as the exception it is.
    _ui_with_root() do _
        params = Dict{String,String}(
            "mode" => "high_precision", "precision_bits" => "128",
            "sample_labels" => "A, B", "feature_labels" => "t1, t2",
            "counts" => "1, 0\n1, 0", "round_digits" => "6")
        outcome = _UI_SV._ui_run(params)
        @test outcome.result["status"] == "partial"
        @test outcome.result["samples"][1]["shannon"]["precision_bits"] == 128
        @test isnothing(outcome.result["samples"][2]["shannon"])
    end
end

@testset "High-precision form labels approximations as approximate" begin
    _ui_with_root() do _
        fields = merge(_ui_form(), Dict{String,String}(
            "mode" => "high_precision", "precision_bits" => "128",
            "counts" => "1, 0\n1, 0"))
        html = _ui_text(_ui_post(_ui_body(fields)))
        @test occursin("approximate", html)
        @test occursin("128-bit", html)
        # A zero-total sample is undefined, never silently zero.
        @test occursin("undefined (zero total)", html)
        @test occursin("Status: partial", html)
    end
end

@testset "Zero totals are undefined and stated as such" begin
    _ui_with_root() do _
        fields = merge(_ui_form(), Dict{String,String}(
            "counts" => "0, 1\n0, 1"))
        html = _ui_text(_ui_post(_ui_body(fields)))
        @test occursin("Status: partial", html)
        @test occursin("undefined (zero total)", html)
        @test occursin("has zero reads: relative abundances are undefined, not zero", html)
    end
end

@testset "Failure states return the documented status and no result" begin
    _ui_with_root() do _
        cases = [
            (merge(_ui_form(), Dict{String,String}("counts" => "1.5, 2\n3, 4")), 422),
            (merge(_ui_form(), Dict{String,String}("counts" => "1e3, 2\n3, 4")), 422),
            (merge(_ui_form(), Dict{String,String}("counts" => "-1, 2\n3, 4")), 422),
            (merge(_ui_form(), Dict{String,String}("counts" => "1\n3, 4")), 400),
            (merge(_ui_form(), Dict{String,String}("sample_labels" => "A")), 400),
            (merge(_ui_form(), Dict{String,String}("sample_labels" => "A, A")), 400),
            (merge(_ui_form(), Dict{String,String}("mode" => "ordinary")), 400),
            (merge(_ui_form(), Dict{String,String}("precision_bits" => "53")), 400),
            (merge(_ui_form(), Dict{String,String}("round_digits" => "-1")), 400),
            (merge(_ui_form(), Dict{String,String}("time_limit_seconds" => "0")), 400),
            (merge(_ui_form(), Dict{String,String}("time_limit_seconds" => "soon")), 400),
            (merge(_ui_form(), Dict{String,String}("groups" => "g1")), 400),
        ]
        for (fields, status) in cases
            response = _ui_post(_ui_body(fields))
            @test response.status == status
            @test response.status != 500
            html = _ui_text(response)
            @test occursin("did not produce a result", html)
            @test !occursin("id=\"results-heading\"", html)
            @test !occursin("id=\"analysis_id\"", html)
        end

        # High precision with groups is refused rather than silently ignored.
        grouped = merge(_ui_form(), Dict{String,String}(
            "mode" => "high_precision", "groups" => "g1, g2"))
        @test _ui_post(_ui_body(grouped)).status == 400

        # A repeated field is ambiguous and refused.
        duplicated = _ui_body(_ui_form()) * "&mode=high_precision"
        @test _ui_post(duplicated).status == 400
        # An invalid percent escape is a client error, not a crash. Whether the
        # URI decoder rejects it or passes it through as a literal, the request
        # must fail as a 4xx and never as a 500.
        @test _ui_post("mode=exact_counts&counts=%zz").status in (400, 422)
    end
end

@testset "Form values are escaped on echo" begin
    _ui_with_root() do _
        payload = "<script>alert('x')</script>"
        form = "mode=exact_counts&sample_labels=" *
               "%3Cscript%3Ealert(%27x%27)%3C%2Fscript%3E&feature_labels=f" *
               "&counts=" * payload
        response = _ui_post(form)
        html = _ui_text(response)
        @test response.status != 500
        @test !occursin("<script>alert", lowercase(html))
        @test occursin("&lt;script&gt;", html)
        # Single quotes in an echoed attribute value are escaped too.
        @test occursin("&#39;", html)
    end
end

@testset "Large matrices are summarised without an unbounded page" begin
    _ui_with_root() do _
        samples = join(["s$i" for i in 1:142], ",")
        features = join(["f$i" for i in 1:141], ",")
        rows = join((("0," ^ 141) * "0" for _ in 1:141), "\n")
        fields = merge(_ui_form(), Dict{String,String}(
            "sample_labels" => samples, "feature_labels" => features,
            "counts" => rows))
        response = _ui_post(_ui_body(fields))
        @test response.status == 200
        html = _ui_text(response)
        @test occursin("per-cell table is omitted", html)
        @test occursin("display cap is 20000", html)
        @test occursin("remain authoritative", html)
        @test length(html) < 2_000_000
    end
end
