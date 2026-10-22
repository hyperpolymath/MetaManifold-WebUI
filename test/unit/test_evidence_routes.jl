# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Route-level tests for Evidence Mode.
#
# A fixture results database is built in a temp root and the route helpers are
# called directly, the way test_composition.jl calls `_composition_summary`.
# This is where the SQL is exercised: the fibre profile, the member list, both
# echo kinds and both residual nulls.
#
# The fixture (one row per ASV, reads in three samples):
#
#   ASV1  Lactobacillus / Lactobacillus  Firmicutes   10  20  30
#   ASV2  Lactobacillus / Lactobacillus  Firmicutes    5   0  10
#   ASV3  Lactobacillus / Bacillus       Firmicutes    1   2   3
#   ASV4  Bacillus      / Bacillus       Firmicutes   20  10   0
#   ASV5  ''            / NULL           Firmicutes    0  40   5
#   ASV6  Bacteroides   / Bacteroides    Bacteroidota  7   7   7
#
# Plain ranks are VSEARCH's whenever `Pident` is present, which it is here.

using HTTP, JSON3, DuckDB, DataFrames, DBInterface

const _evidence_saved_root = MetaManifold.Server.ServerState._root[]
const EvidenceServer = MetaManifold.Server

function with_evidence_fixture(f::Function)
    tmp = mktempdir()
    try
        EvidenceServer.ServerState.set_root!(tmp)

        merge_dir = joinpath(tmp, "projects", "studyE", "runE", "merged")
        mkpath(merge_dir)

        mkpath(joinpath(tmp, "config"))
        write(joinpath(tmp, "config", "composition.yml"), """
        filters:
          lacto:
            filters:
              - { column: Genus, pattern: Lactobacillus, action: keep }
        sets:
          lacto_set:
            label: Lactobacilli
            description: Fixture set for the Evidence Mode route tests
            categories:
              - { name: Lactobacillus, filter: lacto }
        """)

        db = DuckDB.DB(joinpath(merge_dir, "results.duckdb"))
        con = DBInterface.connect(db)
        try
            DBInterface.execute(con, """
                CREATE TABLE merged (
                    "SeqName"      VARCHAR,
                    "Genus"        VARCHAR,
                    "Genus_dada2"  VARCHAR,
                    "Family"       VARCHAR,
                    "Family_dada2" VARCHAR,
                    "Pident"       DOUBLE,
                    "s1"           BIGINT,
                    "s2"           BIGINT,
                    "s3"           BIGINT
                )
            """)
            DBInterface.execute(con, """
                INSERT INTO merged VALUES
                    ('ASV1','Lactobacillus','Lactobacillus','Firmicutes','Firmicutes',99.0,10,20,30),
                    ('ASV2','Lactobacillus','Lactobacillus','Firmicutes','Firmicutes',98.0, 5, 0,10),
                    ('ASV3','Lactobacillus','Bacillus',     'Firmicutes','Firmicutes',97.0, 1, 2, 3),
                    ('ASV4','Bacillus',     'Bacillus',     'Firmicutes','Bacillota', 96.0,20,10, 0),
                    ('ASV5','',              NULL,          'Firmicutes',NULL,        95.0, 0,40, 5),
                    ('ASV6','Bacteroides',  'Bacteroides',  'Bacteroidota','Bacteroidota',94.0,7,7,7)
            """)
        finally
            DBInterface.close!(con); close(db)
        end

        f(tmp)
    finally
        rm(tmp; recursive=true, force=true)
    end
end

@testset "Evidence Mode routes" begin

    @testset "record path" begin
        tmp = mktempdir()
        try
            EvidenceServer.ServerState.set_root!(tmp)
            expected = joinpath(tmp, "projects", "s", "r", "evidence", "claims.yml")
            @test EvidenceServer._evidence_path("s", "r") == expected
        finally
            rm(tmp; recursive=true, force=true)
        end
    end

    with_evidence_fixture() do _tmp
        body(text) = JSON3.read(text)
        rank_body = body("""{"table":"merged","tag":"rank","value":"Genus","values":["Lactobacillus"]}""")

        @testset "fibre of a rank projection" begin
            result = EvidenceServer._evidence_fibre("studyE", "runE", rank_body)
            @test result isa NamedTuple
            @test result.table == "merged"
            @test result.tag == "rank"
            @test result.value == "Genus"
            @test result.source == "VSEARCH"
            @test result.column == "Genus"

            @test result.fibre.rows == 3
            @test result.fibre.reads == 81.0
            @test result.totals.rows == 6
            @test result.totals.reads == 177.0
            @test result.fibre.read_share ≈ 81 / 177 atol = 1e-5
            @test result.fibre.row_share ≈ 0.5

            observed = Dict(p.sample => p.observed for p in result.fibre.samples)
            totals   = Dict(p.sample => p.total for p in result.fibre.samples)
            @test observed == Dict("s1" => 16.0, "s2" => 22.0, "s3" => 43.0)
            @test totals   == Dict("s1" => 43.0, "s2" => 79.0, "s3" => 55.0)
            percents = Dict(p.sample => p.percent for p in result.fibre.samples)
            @test percents["s1"] ≈ 100 * 16 / 43 atol = 1e-3
        end

        @testset "fibre members are capped and counted" begin
            result = EvidenceServer._evidence_fibre("studyE", "runE", rank_body)
            @test result.member_count == 3
            @test result.members_truncated == false
            @test [m.member for m in result.members] == ["ASV1", "ASV2", "ASV3"]
            @test [m.reads for m in result.members] == [60, 15, 6]
        end

        @testset "echoes: the other classifier and the parent rank" begin
            result = EvidenceServer._evidence_fibre("studyE", "runE", rank_body)
            @test length(result.echoes) == 2

            source = only(filter(e -> e.kind == "source", result.echoes))
            @test source.label == "DADA2"
            @test source.projection.value == "Genus"
            @test source.agree_rows == 2       # ASV1, ASV2
            @test source.conflict_rows == 1    # ASV3 is Bacillus under DADA2
            @test source.missing_rows == 0
            @test source.agree_reads == 75.0
            @test source.conflict_reads ≈ 6.0
            @test source.agree_fraction ≈ 2 / 3 atol = 1e-4
            @test source.verdict == "partial agreement"

            rank = only(filter(e -> e.kind == "rank", result.echoes))
            @test rank.projection.value == "Family"
            @test rank.projection.values == ["Firmicutes"]
            @test rank.echo_rows == 5
            @test rank.echo_reads == 156.0
            @test rank.inside_rows == 3
            @test rank.contained_in_echo == true
            @test rank.verdict == "contained"
            @test isempty(rank.note)
        end

        @testset "Unclassified is a reachable fibre" begin
            unclassified = body("""{"tag":"rank","value":"Genus","values":["Unclassified"]}""")
            result = EvidenceServer._evidence_fibre("studyE", "runE", unclassified)
            @test result isa NamedTuple
            @test result.fibre.rows == 1        # ASV5's blank Genus
            @test result.fibre.reads == 45.0
            @test result.members[1].member == "ASV5"
        end

        @testset "a category projection backfills and reads its column" begin
            category = body("""{"tag":"category","value":"lacto_set","values":["Lactobacillus"]}""")
            result = EvidenceServer._evidence_fibre("studyE", "runE", category)
            @test result isa NamedTuple
            @test result.tag == "category"
            @test result.column == "Category__lacto_set"
            @test result.fibre.rows == 3
            @test result.fibre.reads == 81.0
        end

        @testset "invalid projections are refused" begin
            empty_values = body("""{"tag":"rank","value":"Genus","values":[]}""")
            err = EvidenceServer._evidence_fibre("studyE", "runE", empty_values)
            @test err isa HTTP.Response
            @test err.status == 400
            @test JSON3.read(String(err.body))["error"] == "missing_values"

            bad_rank = body("""{"tag":"rank","value":"Nope","values":["x"]}""")
            err = EvidenceServer._evidence_fibre("studyE", "runE", bad_rank)
            @test err.status == 400
            @test JSON3.read(String(err.body))["error"] == "bad_rank"

            bad_tag = body("""{"tag":"colour","value":"Genus","values":["x"]}""")
            err = EvidenceServer._evidence_fibre("studyE", "runE", bad_tag)
            @test JSON3.read(String(err.body))["error"] == "bad_tag"

            bad_table = body("""{"table":"x;drop","tag":"rank","value":"Genus","values":["x"]}""")
            err = EvidenceServer._evidence_fibre("studyE", "runE", bad_table)
            @test JSON3.read(String(err.body))["error"] == "invalid_table"

            absent_set = body("""{"tag":"category","value":"absent_set","values":["x"]}""")
            err = EvidenceServer._evidence_fibre("studyE", "runE", absent_set)
            @test err.status == 404
            @test JSON3.read(String(err.body))["error"] == "category_set_not_found"

            too_long = body("""{"tag":"rank","value":"Genus","values":["$(repeat("x", 201))"]}""")
            err = EvidenceServer._evidence_fibre("studyE", "runE", too_long)
            @test JSON3.read(String(err.body))["error"] == "value_too_long"
        end

        @testset "context survey names every projection's column" begin
            dir = EvidenceServer._require_duckdb("studyE", "runE")
            @test !isnothing(dir)
            survey = with_results_db(dir) do con
                EvidenceServer._evidence_survey(con)
            end
            @test survey.merged_table == "merged"
            @test "merged" in [t.id for t in survey.tables]
            @test survey.sources == ["VSEARCH", "DADA2"]

            vsearch = only(filter(r -> r.source == "VSEARCH", survey.ranks))
            dada2   = only(filter(r -> r.source == "DADA2", survey.ranks))
            @test vsearch.names == ["Family", "Genus"]
            @test vsearch.columns == ["Family", "Genus"]
            @test dada2.columns == ["Family_dada2", "Genus_dada2"]
        end

        @testset "no attestation is reported as absent, not as clean" begin
            provenance = EvidenceServer._evidence_provenance("studyE", "runE")
            @test provenance.present == false
            @test provenance.file == "attestation.yml"
        end

        @testset "residuals under the proportional null" begin
            result = EvidenceServer._evidence_residuals("studyE", "runE", rank_body)
            @test result isa NamedTuple
            @test result.null.kind == "proportional"
            @test result.null.share === nothing
            @test result.grand.rows == 6
            @test result.grand.reads == 177.0

            expected = Dict(r.sample => r.expected for r in result.samples)
            @test expected["s1"] ≈ 81 * 43 / 177 atol = 1e-3
            @test expected["s2"] ≈ 81 * 79 / 177 atol = 1e-3
            @test expected["s3"] ≈ 81 * 55 / 177 atol = 1e-3

            # Worst departure first: s3 is enriched, s2 depleted.
            @test result.samples[1].sample == "s3"
            @test result.samples[1].residual ≈ 3.5541 atol = 1e-3
            @test result.samples[2].sample == "s2"
            @test result.samples[2].residual ≈ -2.3538 atol = 1e-3
            @test result.samples[3].sample == "s1"

            @test result.summary.df == 2
            @test result.summary.n_samples == 3
            @test result.summary.n_excess == 1
            @test result.summary.n_deficit == 1
            @test result.summary.chi2 ≈ 18.8593 atol = 1e-2
            @test result.summary.max_abs_residual ≈ 3.5541 atol = 1e-3
        end

        @testset "residuals under a claim share" begin
            claim_share = body("""{"tag":"rank","value":"Genus","values":["Lactobacillus"],
                                    "null":"claim_share","share":0.5}""")
            result = EvidenceServer._evidence_residuals("studyE", "runE", claim_share)
            @test result isa NamedTuple
            @test result.null.share == 0.5
            expected = Dict(r.sample => r.expected for r in result.samples)
            @test expected["s1"] ≈ 21.5
            @test expected["s2"] ≈ 39.5
            @test expected["s3"] ≈ 27.5
            @test occursin("stated share", result.null.note)
        end

        @testset "residual nulls are validated" begin
            bad_null = body("""{"tag":"rank","value":"Genus","values":["Lactobacillus"],
                                 "null":"whatever"}""")
            err = EvidenceServer._evidence_residuals("studyE", "runE", bad_null)
            @test err isa HTTP.Response && err.status == 400
            @test JSON3.read(String(err.body))["error"] == "bad_null"

            no_share = body("""{"tag":"rank","value":"Genus","values":["Lactobacillus"],
                                 "null":"claim_share"}""")
            @test JSON3.read(String(EvidenceServer._evidence_residuals("studyE", "runE", no_share).body))["error"] == "missing_share"

            bad_share = body("""{"tag":"rank","value":"Genus","values":["Lactobacillus"],
                                  "null":"claim_share","share":0}""")
            @test JSON3.read(String(EvidenceServer._evidence_residuals("studyE", "runE", bad_share).body))["error"] == "bad_share"
        end

        @testset "a saved record is read back from the run's evidence directory" begin
            document = MetaManifold.Evidence.blank_document("studyE", "runE")
            claim = MetaManifold.Evidence.normalise_claim(Dict{String,Any}(
                "text"  => "Lactobacillus holds 46 % of reads",
                "scope" => Dict{String,Any}("tag" => "rank", "value" => "Genus",
                                            "source" => "VSEARCH",
                                            "values" => Any["Lactobacillus"]),
                "warrant" => Any[Dict{String,Any}("kind" => "measurement",
                                                  "text" => "fibre profile")]);
                id = "lactobacillus-holds-46")
            document = MetaManifold.Evidence.upsert_claim(document, claim)
            MetaManifold.Evidence.save_document(
                EvidenceServer._evidence_path("studyE", "runE"), document)

            loaded = EvidenceServer._load_evidence("studyE", "runE")
            @test length(loaded["claims"]) == 1
            @test loaded["claims"][1]["scope"]["values"] == ["Lactobacillus"]
            @test !isempty(MetaManifold.Evidence.render_claims_yaml(loaded))
        end
    end

    # Testsets above point the server at temporary roots.
    EvidenceServer.ServerState._root[] = _evidence_saved_root
end
