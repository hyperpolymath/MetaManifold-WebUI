# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Evidence for docs/pilots/kyaml-pilot.md, which is the authority for what is claimed here.
#
# What these tests establish is behaviour, not taste: comments survive conversion with their
# association, conversion is idempotent, YAML -> KYAML -> YAML returns the canonical block
# form, a refused file is refused rather than half-rewritten, the repository's own YAML is
# inside the tool's subset, and — the one the policy insists on — a deliberately dropped
# comment makes the gate go red. A check that has never failed is not a check
# (standards :: 3-practice/YAML-POLICY.adoc §2.2).

const KYAML_TOOL_PATH = normpath(joinpath(@__DIR__, "..", "..", "scripts", "kyaml", "KYAML.jl"))
const KYAML_REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

include(KYAML_TOOL_PATH)

using .KYAML: parse_document, render_kyaml, render_yaml, check, git_yaml_paths, KyamlError

function kyaml_exempt_prefixes()::Vector{String}
    drift = joinpath(KYAML_REPO_ROOT, "config", "kyaml", "drift.txt")
    isfile(drift) || return String[]
    prefixes = String[]
    for line in eachline(drift)
        t = strip(line)
        (isempty(t) || startswith(t, "#")) && continue
        push!(prefixes, t)
    end
    return prefixes
end

@testset "KYAML switch" begin

    @testset "comments keep their association" begin
        src = """
        # leading comment
        name: "CI"  # trailing comment
        jobs:
          # comment about test
          test:
            runs-on: ubuntu-24.04
        """
        doc = parse_document("t.yml", src)
        out = render_kyaml(doc)
        @test occursin("# leading comment", out)
        @test occursin("# trailing comment", out)
        @test occursin("# comment about test", out)
        nameline = [l for l in split(out, "\n") if occursin("name:", l)]
        @test length(nameline) == 1
        @test occursin("\"CI\"", nameline[1])
        @test occursin("# trailing comment", nameline[1])
        lines = split(out, "\n")
        comment_at = findfirst(l -> occursin("# comment about test", l), lines)
        @test comment_at !== nothing
        @test occursin("test:", lines[comment_at + 1])
    end

    @testset "a comment above the document root survives" begin
        # Every YAML file in this repository starts with an SPDX comment above the document.
        # Dropping it would be a silent licence-header deletion, which is the worst possible
        # thing for a formatter to do quietly.
        src = "# SPDX-License-Identifier: MPL-2.0\n---\nname: \"x\"\n"
        out = render_kyaml(parse_document("t.kyaml", src))
        @test occursin("SPDX-License-Identifier", out)
        again = render_kyaml(parse_document("t.kyaml", out))
        @test out == again
    end

    @testset "conversion is idempotent" begin
        src = "# c\nname: \"x\"\nitems:\n  - one\n  - two\n"
        once = render_kyaml(parse_document("t.yml", src))
        twice = render_kyaml(parse_document("t.kyaml", once))
        @test once == twice
    end

    @testset "YAML -> KYAML -> YAML keeps the document" begin
        src = "name: \"CI\"\njobs:\n  test:\n    runs-on: ubuntu-24.04\n"
        canonical = render_yaml(parse_document("t.yml", src))
        ky = render_kyaml(parse_document("t.yml", src))
        back = render_yaml(parse_document("t.kyaml", ky))
        @test back == canonical
    end

    @testset "block scalars survive as escaped strings and come back as block scalars" begin
        src = "run: |\n  echo one\n  echo two\n"
        ky = render_kyaml(parse_document("b.yml", src))
        @test occursin("run: \"echo one\\n\\", ky)
        back = render_yaml(parse_document("b.kyaml", ky))
        @test occursin("run: |", back)
        @test occursin("echo one", back)
        @test render_yaml(parse_document("b.kyaml", ky)) == render_yaml(parse_document("b.yml", src))
    end

    @testset "the decisions KYAML forces are taken and reported" begin
        src = "flag: no\ncount: 15\nlabel: \"15\"\nempty: ~\n"
        stats = KYAML.Stats()
        out = render_kyaml(parse_document("s.yml", src); stats = stats)
        @test occursin("flag: \"no\"", out)      # the Norway fix: a bare `no` is not a boolean
        @test occursin("count: 15,", out)        # a canonical integer stays bare
        @test occursin("label: \"15\",", out)    # a quoted number stays a string
        @test occursin("empty: null,", out)      # `~` is spelled one way
        @test stats.scalars_quoted >= 2
        @test stats.nulls_canonicalised >= 1
    end

    @testset "schema-ambiguous keys are quoted" begin
        out = render_kyaml(parse_document("k.yml", "on:\n  push:\n    branches: [\"main\"]\n"))
        @test occursin("\"on\": {", out)
        @test occursin("push: {", out)
    end

    @testset "refusals are refusals, not guesses" begin
        @test_throws KyamlError parse_document("a.yml", "a: &anchor 1\n")
        @test_throws KyamlError parse_document("a.yml", "a: *alias\n")
        @test_throws KyamlError parse_document("a.yml", "a: !!str 1\n")
        @test_throws KyamlError parse_document("a.yml", "a:\n\tb: 1\n")
        @test_throws KyamlError parse_document("a.yml", "a: 1\na: 2\n")
        @test_throws KyamlError parse_document("a.yml", "---\na: 1\n---\nb: 2\n")
    end

    @testset "a dropped comment makes the gate go red" begin
        src = "# keep me\nname: \"x\"  # and me\n"
        out = render_kyaml(parse_document("m.yml", src))
        mktempdir() do dir
            path = joinpath(dir, "m.yml")
            write(path, out)
            @test check(path)
            mutant = join([l for l in split(out, "\n") if !occursin("# keep me", l)], "\n") * "\n"
            write(path, mutant)
            @test !check(path)
        end
    end

    @testset "the repository's own YAML is inside the subset" begin
        exempt = kyaml_exempt_prefixes()
        failures = String[]
        for rel in git_yaml_paths(KYAML_REPO_ROOT)
            any(prefix -> startswith(rel, prefix), exempt) && continue
            path = joinpath(KYAML_REPO_ROOT, rel)
            isfile(path) || continue
            try
                doc = parse_document(path, read(path, String))
                render_kyaml(doc)
                render_yaml(doc)
            catch err
                err isa KyamlError || rethrow()
                push!(failures, rel * " -> " * sprint(showerror, err))
            end
        end
        if !isempty(failures)
            println("KYAML cannot handle these files yet:")
            for f in failures
                println("  ", f)
            end
        end
        @test isempty(failures)
    end
end
