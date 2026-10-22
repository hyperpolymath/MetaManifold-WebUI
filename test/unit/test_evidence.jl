# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Unit tests for the Evidence module: the claim schema's rules, the record's
# round trip, and the residual arithmetic. The SQL lives in the route file and
# needs a results database, so it is exercised by the server integration test.
using MetaManifold.Evidence
using MetaManifold.Evidence: ResidualRow
using YAML

const EVIDENCE_TMP = mktempdir()

function sample_claim(; kwargs...)
    claim = Dict{String,Any}(
        "text"   => "Lactobacillus holds more than half the caecal reads",
        "status" => "draft",
        "scope"  => Dict{String,Any}(
            "table"  => "merged",
            "tag"    => "rank",
            "value"  => "Genus",
            "source" => "VSEARCH",
            "values" => Any["Lactobacillus"],
        ),
        "warrant" => Any[],
        "caveats" => Any[],
    )
    for (k, v) in kwargs
        claim[string(k)] = v
    end
    Evidence.normalise_claim(claim; id = "genus-lactobacillus")
end

@testset "Evidence Mode" begin

    @testset "slugify" begin
        @test slugify("Lactobacillus is enriched!") == "lactobacillus-is-enriched"
        @test slugify("  %%  ") == ""
        @test length(slugify(repeat("a", 200))) <= 48
        @test slugify("already-safe") == "already-safe"
    end

    @testset "claim normalisation" begin
        claim = Evidence.normalise_claim(Dict{String,Any}(
            "text" => "A claim",
            "scope" => Dict{String,Any}("tag" => "rank", "value" => "Genus",
                                        "values" => Any["Lactobacillus"])))
        @test claim["id"] == ""
        @test claim["status"] == "draft"
        @test claim["scope"]["table"] == "merged"
        @test claim["scope"]["source"] === nothing
        @test claim["warrant"] == Any[]
        @test !isempty(Evidence.claim_errors(claim))  # no id yet

        named = Evidence.normalise_claim(Dict{String,Any}("text" => "A claim",
            "scope" => Dict{String,Any}("tag" => "rank", "value" => "Genus",
                                        "values" => Any["Lactobacillus"]));
            id = "a-claim")
        @test isempty(Evidence.claim_errors(named))
    end

    @testset "claim validation" begin
        @test isempty(claim_errors(sample_claim()))

        bad_text = sample_claim(text = "  ")
        @test any(occursin("needs text", e) for e in claim_errors(bad_text))

        no_values = sample_claim(scope = Dict{String,Any}(
            "tag" => "rank", "value" => "Genus", "values" => Any[]))
        @test any(occursin("at least one value", e) for e in claim_errors(no_values))

        no_values["scope"]["tag"] = "category"
        no_values["scope"]["value"] = "trophic"
        @test any(occursin("at least one value", e) for e in claim_errors(no_values))

        bad_set = sample_claim(scope = Dict{String,Any}(
            "tag" => "category", "value" => "not a name", "values" => Any["x"]))
        @test any(occursin("not a category set name", e) for e in claim_errors(bad_set))

        bad_rank = sample_claim(scope = Dict{String,Any}(
            "tag" => "rank", "value" => "Genus; DROP", "values" => Any["x"]))
        @test any(occursin("not a rank name", e) for e in claim_errors(bad_rank))

        bad_source = sample_claim(scope = Dict{String,Any}(
            "tag" => "rank", "value" => "Genus", "source" => "BLAST",
            "values" => Any["x"]))
        @test any(occursin("scope.source", e) for e in claim_errors(bad_source))

        bad_status = sample_claim(status = "true")
        @test any(occursin("status", e) for e in claim_errors(bad_status))

        # The anti-cherry-pick rule: a definition alone cannot support a claim,
        # and an empty warrant list certainly cannot.
        unsupported = sample_claim(status = "supported")
        @test any(occursin("needs at least one warrant", e) for e in claim_errors(unsupported))

        defined_only = sample_claim(status = "supported", warrant = Any[
            Dict{String,Any}("kind" => "definition", "text" => "Bloom means high reads")])
        @test any(occursin("needs at least one warrant", e) for e in claim_errors(defined_only))

        measured = sample_claim(status = "supported", warrant = Any[
            Dict{String,Any}("kind" => "measurement", "text" => "54% of caecal reads",
                             "ref" => "fibre:Genus/Lactobacillus")])
        @test isempty(claim_errors(measured))

        bad_warrant = sample_claim(warrant = Any[Dict{String,Any}("kind" => "vibes",
                                                                  "text" => "feelings")])
        @test any(occursin("kind 'vibes'", e) for e in claim_errors(bad_warrant))

        empty_warrant = sample_claim(warrant = Any[Dict{String,Any}("kind" => "citation",
                                                                    "text" => "")])
        @test any(occursin("needs text", e) for e in claim_errors(empty_warrant))
    end

    @testset "document validation" begin
        doc = Evidence.blank_document("study_a", "run_a")
        @test isempty(Evidence.document_errors(doc))

        bad_version = Evidence.blank_document("study_a", "run_a")
        bad_version["schema_version"] = 99
        @test any(occursin("schema_version", e) for e in Evidence.document_errors(bad_version))

        bad_name = Evidence.blank_document("../etc", "run_a")
        @test any(occursin("study", e) for e in Evidence.document_errors(bad_name))

        duped = Evidence.blank_document("study_a", "run_a")
        claim = sample_claim()
        duped["claims"] = Any[claim, claim]
        @test any(occursin("duplicate", e) for e in Evidence.document_errors(duped))
    end

    @testset "identifier collisions" begin
        doc = Evidence.blank_document("study_a", "run_a")
        @test Evidence.next_claim_id(doc, "Same claim") == "same-claim"
        @test Evidence.next_claim_id(doc, "Genus Lactobacillus") == "genus-lactobacillus"
        doc = Evidence.upsert_claim(doc, sample_claim())
        @test Evidence.next_claim_id(doc, "Genus Lactobacillus") == "genus-lactobacillus-2"
        @test Evidence.next_claim_id(Evidence.blank_document("s", "r"), "%%") == "claim"
    end

    @testset "record round trip" begin
        path = joinpath(EVIDENCE_TMP, "study_a", "run_a", "evidence", "claims.yml")
        doc = Evidence.blank_document("study_a", "run_a")
        doc = Evidence.upsert_claim(doc, sample_claim())
        Evidence.save_document(path, doc)
        @test isfile(path)

        loaded = Evidence.load_document(path; study = "study_a", run = "run_a")
        @test length(loaded["claims"]) == 1
        @test loaded["claims"][1]["text"] == "Lactobacillus holds more than half the caecal reads"
        @test loaded["claims"][1]["scope"]["values"] == ["Lactobacillus"]
        @test loaded["schema_version"] == Evidence.SCHEMA_VERSION
        @test loaded["updated"] isa AbstractString

        # A second save must be able to append a claim of a different shape; YAML
        # narrows homogeneous sequences and the vector must stay open.
        second = Evidence.normalise_claim(Dict{String,Any}(
            "text"   => "A claim with no warrant",
            "status" => "contested",
            "scope"  => Dict{String,Any}("tag" => "category", "value" => "trophic",
                                         "values" => Any["copiotroph"]),
            "caveats" => Any["One site only"]);
            id = "a-claim-with-no-warrant")
        doc = Evidence.upsert_claim(loaded, second)
        Evidence.save_document(path, doc)
        reloaded = Evidence.load_document(path; study = "study_a", run = "run_a")
        @test length(reloaded["claims"]) == 2
        @test reloaded["claims"][2]["caveats"] == ["One site only"]

        # Editing an existing claim replaces it in place.
        edited = copy(reloaded["claims"][1])
        edited["status"] = "contested"
        doc = Evidence.upsert_claim(reloaded, edited)
        @test length(doc["claims"]) == 2
        @test Evidence.find_claim(doc, edited["id"])["status"] == "contested"

        doc, removed = Evidence.remove_claim(doc, "a-claim-with-no-warrant")
        @test removed
        @test length(doc["claims"]) == 1
        @test isnothing(Evidence.find_claim(doc, "a-claim-with-no-warrant"))
        _, removed_again = Evidence.remove_claim(doc, "a-claim-with-no-warrant")
        @test !removed_again

        yaml = Evidence.render_claims_yaml(doc)
        @test occursin("schema_version", yaml)
        @test occursin("Lactobacillus", yaml)

        @test YAML.load(Evidence.render_claims_yaml(Evidence.blank_document("study_a", "run_a")))["study"] == "study_a"
    end

    @testset "empty record is not written" begin
        missing = joinpath(EVIDENCE_TMP, "nowhere", "claims.yml")
        doc = Evidence.load_document(missing; study = "study_a", run = "run_a")
        @test isempty(doc["claims"])
        @test doc["updated"] === nothing
        @test !isfile(missing)
    end

    @testset "residuals under a proportional null" begin
        samples  = ["a", "b", "c", "d"]
        observed = [10.0, 20.0, 0.0, 70.0]
        totals   = [100.0, 200.0, 100.0, 100.0]
        fibre_total = 100.0
        grand_total = 500.0
        rows = Evidence.residual_rows(samples, observed, totals, fibre_total, grand_total)

        # The fibre holds 20% of the library, so each sample's expectation is 20%.
        expected = Dict(r.sample => r.expected for r in rows)
        @test expected["a"] ≈ 20.0
        @test expected["b"] ≈ 40.0
        @test expected["c"] ≈ 20.0
        @test expected["d"] ≈ 20.0

        by_sample = Dict(r.sample => r for r in rows)
        @test by_sample["a"].residual < 0          # under-represented
        @test by_sample["b"].residual < 0
        @test by_sample["d"].residual > 0          # over-represented
        @test by_sample["a"].residual ≈ (10 - 20) / sqrt(20)
        @test by_sample["d"].log2_ratio > 0
        @test by_sample["c"].log2_ratio < 0

        # Largest absolute residual first, ties broken by sample name.
        @test rows[1].sample == "d"
        @test abs(rows[end].residual) <= abs(rows[1].residual)

        summary = Evidence.residual_summary(rows)
        @test summary.df == 3
        @test summary.n_samples == 4
        @test summary.n_usable == 4
        @test summary.chi2 ≈ sum(r.residual^2 for r in rows)
        # a, b and c each sit more than two standardised units below their
        # expectation; only d is above it.
        @test summary.n_deficit == 3
        @test summary.n_excess == 1
        @test summary.max_abs_residual ≈ abs(by_sample["d"].residual)
    end

    @testset "residuals under a claim share" begin
        samples  = ["a", "b"]
        observed = [30.0, 30.0]
        totals   = [100.0, 100.0]
        rows = Evidence.residual_rows(samples, observed, totals, 60.0, 200.0; share = 0.5)
        @test all(r -> r.expected ≈ 50.0, rows)
        @test all(r -> r.residual < 0, rows)
        @test Evidence.share_of(60, 200) ≈ 0.3
    end

    @testset "zero expectation is finite" begin
        @test Evidence.pearson_residual(5, 0) == 0.0
        rows = Evidence.residual_rows(["a"], [0.0], [0.0], 0.0, 0.0)
        @test all(isfinite, (rows[1].residual, rows[1].log2_ratio))
        summary = Evidence.residual_summary(rows)
        @test summary.n_usable == 0
        @test summary.df == 0
        @test summary.chi2 == 0.0
    end

    @testset "echo verdict thresholds" begin
        @test Evidence.echo_verdict(0, 0, 0) == "empty"
        @test Evidence.echo_verdict(100, 0, 0) == "concordant"
        @test Evidence.echo_verdict(95, 5, 0) == "minor divergence"
        @test Evidence.echo_verdict(60, 30, 10) == "partial agreement"
        @test Evidence.echo_verdict(10, 90, 0) == "discordant"
        @test Evidence.echo_verdict(50, 40, 10) == "partial agreement"
    end

    @testset "claim projection" begin
        projection = Evidence.claim_projection(sample_claim())
        @test projection.table == "merged"
        @test projection.tag == "rank"
        @test projection.value == "Genus"
        @test projection.source == "VSEARCH"
        @test projection.values == ["Lactobacillus"]
        @test Evidence.claim_projection(Dict{String,Any}("text" => "x")) === nothing
    end
end
