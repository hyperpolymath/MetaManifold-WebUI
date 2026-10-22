# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

using MetaManifold
using JSON3, DuckDB, DBInterface, SHA, LinearAlgebra

const _CC = MetaManifold.CladeCumulus
const _CCS = MetaManifold.Server

_cc_request(method, path, body="") =
    _CCS.Oxygen.internalrequest(_CCS.HTTP.Request(method, path,
        ["Content-Type" => "application/json"], body))
_cc_json(response) = JSON3.read(String(response.body))

@testset "CladeCumulus" begin
    @testset "Newick parsing is strict and keeps labels and lengths" begin
        tree = _CC.parse_newick("[&R] ((A:1,B:1)90:1,C:2);")
        @test length(tree.nodes) == 5
        @test length(tree.tips) == 3
        @test tree.nodes[2].name == "90"
        @test tree.nodes[2].children == [3, 4]
        @test tree.nodes[3].parent == 2
        @test tree.nodes[5].length == 2.0

        # Support values are internal labels, not taxa, and may legitimately repeat.
        supported = _CC.parse_newick("((A:1,B:1)95:1,(C:1,D:1)95:1)100;")
        @test length(supported.tips) == 4
        @test supported.nodes[2].name == supported.nodes[5].name == "95"

        quoted = _CC.parse_newick("('A ''one''':1e-3,\"λ two\":2.0,plain:3);")
        @test Set(keys(quoted.tips)) == Set(["A 'one'", "λ two", "plain"])
        @test quoted.nodes[2].length ≈ 0.001

        @test_throws ArgumentError _CC.parse_newick("((A:1,A:1):1,C:1);")
        @test_throws ArgumentError _CC.parse_newick("((A:1,B:1):1,C:-1);")
        @test_throws ArgumentError _CC.parse_newick("((A:1,B:1):1,C:NaN);")
        @test_throws ArgumentError _CC.parse_newick("((A:1,B:1):1,C:1)")
        @test_throws ArgumentError _CC.parse_newick("((A:1,B:1):1,C:1); trailing")
        @test_throws ArgumentError _CC.parse_newick("((A:1,B:1):1,C:1)[unclosed;")
        @test_throws ArgumentError _CC.parse_newick("((A:1,B:1):1,C:oops);")

        @test _CC.asv_tip_name("ac-gt\n") == _CC.asv_tip_name("ACGT")
        @test _CC.asv_tip_name("ACGT") != _CC.asv_tip_name("ACGA")
        @test startswith(_CC.asv_tip_name("ACGT"), "ASV_")
    end

    @testset "cumulative counts, Faith PD and UniFrac match a hand-worked tree" begin
        # ((A:1,B:1):1,C:2);
        # A and B share one unit of internal branch; C has no shared branch.
        tree = _CC.parse_newick("((A:1,B:1):1,C:2);")
        counts = [1.0 0 0;       # A
                  0.0 1 0;       # B
                  0.0 0 1;       # C
                  1.0 1 0]       # A + B
        tips = ["A", "B", "C"]
        cumulative = _CC.clade_counts(tree, counts, tips)
        root, ab, a, b, c = 1, 2, 3, 4, 5
        @test cumulative[root, :] == [1, 1, 1, 2]
        @test cumulative[ab, :] == [1, 1, 0, 2]
        @test cumulative[a, :] == [1, 0, 0, 1]
        @test cumulative[b, :] == [0, 1, 0, 1]
        @test cumulative[c, :] == [0, 0, 1, 0]

        @test _CC.faith_pd(tree, cumulative) == [2, 2, 2, 3]
        @test _CC.faith_pd(tree, counts, tips) == [2, 2, 2, 3]
        unweighted = _CC.unifrac(tree, cumulative)
        @test unweighted[1, 2] ≈ 2 / 3
        @test unweighted[1, 3] == 1
        @test unweighted[1, 4] ≈ 1 / 3
        @test unweighted == transpose(unweighted)
        @test diag(unweighted) == zeros(4)

        weighted = _CC.unifrac(tree, cumulative; weighted=true)
        @test weighted[1, 2] == 0.5
        @test weighted[1, 3] == 1
        @test weighted[1, 4] == 0.25
        @test all(x -> 0 <= x <= 1, weighted)
        # Relative-abundance weighted UniFrac does not depend on sequencing depth.
        @test _CC.unifrac(tree, counts .* [1, 10, 100, 1000], tips; weighted=true) ≈ weighted

        analysed = _CC.analyse_phylogeny(tree, counts, tips, ["A", "B", "C", "AB"])
        @test analysed.sample_reads == [1, 1, 1, 2]
        @test analysed.nodes[root].cumulative_frequency == 1
        @test analysed.nodes[ab].cumulative_frequency ≈ 4 / 5
        @test analysed.nodes[c].cumulative_frequency ≈ 1 / 5
        @test analysed.nodes[ab].tip_count == 2
        @test analysed.total_branch_length == 5

        # A root's optional length is not a branch and must not inflate metrics.
        rooted = _CC.parse_newick("((A:1,B:1):1,C:2):99;")
        @test _CC.faith_pd(rooted, counts, tips) == [2, 2, 2, 3]
        @test _CC.unifrac(rooted, counts, tips) == unweighted
    end

    @testset "metric guards never discard unmatched counts or missing lengths" begin
        tree = _CC.parse_newick("((A:1,B:1):1,C:2);")
        @test_throws ArgumentError _CC.clade_counts(tree, [1.0 0], ["A", "not-in-tree"])
        @test_throws ArgumentError _CC.clade_counts(tree, [1.0 -1 0], ["A", "B", "C"])
        @test_throws ArgumentError _CC.clade_counts(tree, [1.0 0 0], ["A", "A", "C"])
        @test_throws DimensionMismatch _CC.clade_counts(tree, [1.0 0], ["A", "B", "C"])

        no_lengths = _CC.parse_newick("((A,B),C);")
        @test_throws ArgumentError _CC.faith_pd(no_lengths, [1.0 0 0], ["A", "B", "C"])
        @test_throws ArgumentError _CC.unifrac(no_lengths, [1.0 0 0], ["A", "B", "C"])

        # Empty samples have explicit pairwise semantics in the pure API.
        empty_counts = [0.0 0 0; 1 0 0; 0 0 0]
        cumulative = _CC.clade_counts(tree, empty_counts, ["A", "B", "C"])
        @test _CC.faith_pd(tree, cumulative) == [0, 2, 0]
        @test _CC.unifrac(tree, cumulative; weighted=true)[1, 2] == 1
        @test _CC.unifrac(tree, cumulative; weighted=true)[1, 3] == 0

        # With no positive-length branches there is no unique branch length.
        # Different sequencing depths alone must not manufacture a distance.
        zero_tree = _CC.parse_newick("((A:0,B:0):0,C:0);")
        zero_counts = [0.0 0 0; 1 0 0; 2 0 0]
        for weighted in (false, true)
            distances = _CC.unifrac(zero_tree, zero_counts, ["A", "B", "C"]; weighted)
            @test distances[1, 2] == 1
            @test distances[1, 3] == 1
            @test distances[2, 3] == 0
        end
    end

    @testset "study source persistence and routes" begin
        tmp = mktempdir()
        old_root = _CCS.ServerState._root[]
        _CCS.ServerState.set_root!(tmp)
        mkpath(joinpath(tmp, "config", "defaults"))
        cp(joinpath(@__DIR__, "..", "..", "config", "defaults", "pipeline.yml"),
           joinpath(tmp, "config", "defaults", "pipeline.yml"))
        mkpath(joinpath(tmp, "data", "StudyCC", "run1"))
        touch(joinpath(tmp, "data", "StudyCC", "run1", "s1_R1.fastq.gz"))
        merged = joinpath(tmp, "projects", "StudyCC", "run1", "merged")
        mkpath(merged)
        db = DBInterface.connect(DuckDB.DB, joinpath(merged, "results.duckdb"))
        DBInterface.execute(db, """CREATE TABLE merged AS SELECT * FROM (VALUES
            ('a1', 'AAAAAAAA', 10, 0),
            ('a2', 'CCCCCCCC',  8, 1),
            ('a3', 'GGGGGGGG',  0, 7),
            ('a4', 'TTTTTTTT',  2, 2),
            ('a5', 'ACACACAC',  1, 0)) t(SeqName, Sequence, Caecum_1, Colon_1)""")
        DBInterface.close!(db)

        id = "abcdef12"
        body = JSON3.read(JSON3.write(Dict(
            "name" => "Test ASV tree",
            "runs" => [Dict("run" => "run1")],
            "table" => "merged", "min_reads" => 2, "max_asvs" => 4,
            "normalisation" => "none", "depth" => 0)))
        try
            @test_throws ArgumentError _CCS._cc_integer(3, 500, "max_asvs", 4, 2000)
            @test_throws ArgumentError _CCS._cc_integer(4.5, 500, "max_asvs", 4, 2000)
            @test_throws ArgumentError _CCS._cc_min_reads(0)

            _CCS._cc_prepare!("StudyCC", id, body)
            source = _CCS._read_doc(_CCS._clad_doc_path("StudyCC", id))
            @test source["asv_count"] == 4
            @test source["sample_count"] == 2
            @test source["source"]["available_asvs"] == 4  # a5 is below min_reads
            @test length(source["counts_sha256"]) == 64

            counts, tips, samples, _ = _CCS._cc_read_counts("StudyCC", id)
            @test size(counts) == (2, 4)
            @test samples == ["run1 / Caecum_1", "run1 / Colon_1"]
            @test tips == _CC.asv_tip_name.(["AAAAAAAA", "CCCCCCCC", "GGGGGGGG", "TTTTTTTT"])
            @test counts[:, 1] == [10, 0]
            @test counts[:, 4] == [2, 2]

            files = _CCS._clad_files("StudyCC", id)
            newick = "(($(tips[1]):1,$(tips[2]):1):1,($(tips[3]):1,$(tips[4]):1):1);"
            mkpath(dirname(files["reference.treefile"]))
            write(files["reference.treefile"], newick)
            result = _CCS._cc_compute("StudyCC", id)
            @test result["tree_sha256"] == bytes2hex(sha256(newick))
            @test result["counts_sha256"] == source["counts_sha256"]
            @test length(result["nodes"]) == 7
            @test length(result["faith_pd"]) == 2
            @test size(result["weighted_unifrac"]) == (2,)
            @test length(result["weighted_unifrac"][1]) == 2
            @test result["nodes"][1].cumulative_count == sum(counts)

            write(files["reference.treefile"], replace(newick, ");" => ",EXTRA:1);"))
            @test_throws ErrorException _CCS._cc_compute("StudyCC", id)
            write(files["reference.treefile"], newick)

            _CCS._write_atomic(_CCS._clad_results_path("StudyCC", id), JSON3.write(result))
            _CCS._write_atomic(joinpath(_CCS._clad_dir("StudyCC", id), "status.json"),
                               JSON3.write(Dict("state" => "done")))
            source["published"] = _CCS._cc_publish("StudyCC", id, "Test ASV tree")
            _CCS._write_doc(_CCS._clad_doc_path("StudyCC", id), source)

            base = "/api/v1/studies/StudyCC/cladistics"
            listing = _cc_json(_cc_request("GET", base))
            @test length(listing) == 1
            @test listing[1].built && listing[1].state == "done"
            detail = _cc_json(_cc_request("GET", "$base/$id"))
            @test detail.result.tree_sha256 == result["tree_sha256"]
            @test detail.summary.asv_count == 4
            @test _cc_request("GET", "/api/v1/studies/Missing/cladistics").status == 404
            @test _cc_request("GET", "$base/nothex12").status == 400
            @test _cc_request("GET", "$base/$id/log/tree").status == 404

            bad = JSON3.write(Dict("runs" => [Dict("run" => "run1")], "max_asvs" => 3))
            @test _cc_request("POST", base, bad).status == 400
            @test _cc_request("DELETE", "$base/$id").status == 200
            @test !isdir(_CCS._clad_dir("StudyCC", id))
            @test !isfile(joinpath(tmp, "projects", "StudyCC", "trees", source["published"]))
            @test isempty(_cc_json(_cc_request("GET", base)))
        finally
            _CCS.ServerState.set_root!(old_root)
            rm(tmp; recursive=true, force=true)
        end
    end
end
