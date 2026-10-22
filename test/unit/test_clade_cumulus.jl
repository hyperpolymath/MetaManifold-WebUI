# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

using MetaManifold
using DataFrames
using DuckDB
using DBInterface
using JSON3
using OrderedCollections
using SHA
using Test

const EP = MetaManifold.Epistemic
const CC = MetaManifold.CladeCumulus
const DM = MetaManifold.DiversityMetrics
const PH = MetaManifold.Phylogeny
const SV = MetaManifold.Server

_cc_req(method::String, path::String, body::String = "") =
    SV.Oxygen.internalrequest(
        SV.HTTP.Request(method, path, ["Host" => "127.0.0.1:8080", "Content-Type" => "application/json"], body);
        middleware = SV._MIDDLEWARE,
    )

@testset "CladeCumulus & Phylogenetic Integration" begin

    @testset "Epistemic world admissibility, colours, cloud sizing, and receipts" begin
        empty_case = EP.Case("empty", EP.WorldCandidate[])
        @test !EP.present_in_every_admissible_world(empty_case, "clade_1")
        @test !EP.present_in_some_admissible_world(empty_case, "clade_1")
        @test !EP.absent_in_every_admissible_world(empty_case, "clade_1")
        @test EP.epistemic_status(empty_case, "clade_1") === :sans_fibre

        w1 = EP.WorldCandidate("strict"; present_ids = Set(["c_all"]))
        w2 = EP.WorldCandidate("permissive"; present_ids = Set(["c_all", "c_some"]))
        c = EP.Case("two_worlds", [w1, w2]; unanchored_ids = Set(["c_unplaced"]), threshold = 0.85)

        @test EP.present_in_every_admissible_world(c, "c_all")
        @test EP.present_in_some_admissible_world(c, "c_all")
        @test !EP.absent_in_every_admissible_world(c, "c_all")
        @test EP.epistemic_status(c, "c_all") === :present_in_every
        @test EP.epistemic_colour(:present_in_every) == "#2e7d32"

        @test !EP.present_in_every_admissible_world(c, "c_some")
        @test EP.present_in_some_admissible_world(c, "c_some")
        @test EP.epistemic_status(c, "c_some") === :present_in_some
        @test EP.epistemic_colour(:present_in_some) == "#f9a825"

        @test EP.absent_in_every_admissible_world(c, "c_none")
        @test EP.epistemic_status(c, "c_none") === :absent
        @test EP.epistemic_colour(:absent) == "#9e9e9e"

        @test EP.epistemic_status(c, "c_unplaced") === :sans_fibre
        @test EP.epistemic_colour(:sans_fibre) == "#c62828"

        @test EP.cloud_size_by_residual(0) ≈ 5.0 atol = 1e-12
        @test EP.cloud_size_by_residual(ℯ - 1.0) ≈ 15.0 atol = 1e-12
        @test_throws ArgumentError EP.cloud_size_by_residual(-0.5)
        @test_throws ArgumentError EP.cloud_size_by_residual(NaN)

        rec = EP.create_receipt(;
            study = "S1",
            run = "R1",
            source_digests = OrderedDict("table" => "abc123"),
            parameters = OrderedDict("mode" => "combined", "max_asvs" => 500),
            warnings = ["short amplicon caveat"],
        )
        @test EP.verify_receipt(rec)
        tampered = EP.receipt_dict(rec)
        tampered["study"] = "S2"
        @test !EP.verify_receipt(tampered)
    end

    @testset "Newick parser, midpoint rooting, and scikit-bio golden reference parity" begin
        rooted_nwk = "((ASV_1:0.10,ASV_2:0.20)Clade_A:0.30,(ASV_3:0.15,(ASV_4:0.05,ASV_5:0.25)Clade_B2:0.10)Clade_B:0.40)Root;"
        taxa = ["ASV_1", "ASV_2", "ASV_3", "ASV_4", "ASV_5"]
        s1 = [10, 20, 0, 0, 0]
        s2 = [0, 0, 15, 5, 10]
        s3 = [10, 0, 10, 0, 20]
        s4 = [5, 5, 5, 5, 5]

        # Exact Faith's PD parity against scikit-bio 0.7.4
        @test CC.faith_pd(s1, taxa, rooted_nwk) ≈ 0.60 atol = 1e-12
        @test CC.faith_pd(s2, taxa, rooted_nwk) ≈ 0.95 atol = 1e-12
        @test CC.faith_pd(s3, taxa, rooted_nwk) ≈ 1.30 atol = 1e-12
        @test CC.faith_pd(s4, taxa, rooted_nwk) ≈ 1.55 atol = 1e-12

        # Exact Unweighted & Weighted UniFrac parity against scikit-bio 0.7.4
        @test CC.unweighted_unifrac(s1, s2, taxa, rooted_nwk) ≈ 1.0 atol = 1e-12
        @test CC.unweighted_unifrac(s1, s3, taxa, rooted_nwk) ≈ (11 / 15) atol = 1e-12
        @test CC.unweighted_unifrac(s1, s4, taxa, rooted_nwk) ≈ 0.612903225806 atol = 1e-11
        @test CC.weighted_unifrac(s1, s2, taxa, rooted_nwk; normalized = false) ≈ (13 / 12) atol = 1e-12
        @test CC.weighted_unifrac(s1, s2, taxa, rooted_nwk; normalized = true) ≈ 1.0 atol = 1e-12
        @test CC.weighted_unifrac(s1, s3, taxa, rooted_nwk; normalized = false) ≈ 0.879166666667 atol = 1e-11
        @test CC.weighted_unifrac(s1, s3, taxa, rooted_nwk; normalized = true) ≈ 0.814671814672 atol = 1e-11

        # Shared export identity in DiversityMetrics
        @test DM.faith_pd === CC.faith_pd
        @test DM.unweighted_unifrac === CC.unweighted_unifrac
        @test DM.weighted_unifrac === CC.weighted_unifrac

        # Real FastTree 2.2.0 unrooted 6-tip output midpoint-rooted parity against scikit-bio 0.7.4
        ft_nwk = "(ASV_1:0.027130892,(ASV_5:0.027116348,(ASV_4:0.000000006,ASV_6:0.091864434)0.685:0.000000006)1.000:3.444768322,(ASV_3:0.027134678,ASV_2:0.000000006)0.071:0.000000006);"
        ft_taxa = ["ASV_1", "ASV_2", "ASV_3", "ASV_4", "ASV_5", "ASV_6"]
        fa = [10, 20, 0, 0, 0, 0]
        fb = [0, 5, 15, 30, 0, 10]
        @test CC.faith_pd(fa, ft_taxa, ft_nwk) ≈ 1.7818799429999999 atol = 1e-11
        @test CC.faith_pd(fb, ft_taxa, ft_nwk) ≈ 3.563767458 atol = 1e-11
        @test CC.unweighted_unifrac(fa, fb, ft_taxa, ft_nwk) ≈ 0.5113342456491424 atol = 1e-11
        @test CC.weighted_unifrac(fa, fb, ft_taxa, ft_nwk; normalized = false) ≈ 2.3276502663333334 atol = 1e-11
        @test CC.weighted_unifrac(fa, fb, ft_taxa, ft_nwk; normalized = true) ≈ 0.6655215451489284 atol = 1e-11

        # Quoted labels, NHX support, and negative branch clamping
        warns = String[]
        qtree = CC.parse_newick("[&R] (('Taxon ''alpha''':0.2,ASV_b:-0.05)[&&NHX:B=92]:0.1,ASV_c:0.3);", warnings = warns)
        @test !isempty(warns)
        @test qtree.children[1].support ≈ 0.92 atol = 1e-12
        @test qtree.children[1].children[1].name == "Taxon 'alpha'"
        @test qtree.children[1].children[2].branch_length == 0.0
    end

    @testset "Strict raw jplace evidence reader" begin
        raw_jplace = JSON3.write(OrderedDict(
            "version" => 3,
            "tree" => "((ASV_1:0.1{0},ASV_2:0.2{1})95:0.3{2},ASV_3:0.4{3}){4};",
            "fields" => ["edge_num", "likelihood", "like_weight_ratio", "distal_length", "pendant_length"],
            "placements" => [
                OrderedDict("n" => ["Q_split"], "p" => [[0, -100.0, 0.60, 0.01, 0.02], [1, -100.4, 0.40, 0.01, 0.03]]),
                OrderedDict("nm" => [["Q_strong", 2]], "p" => [[3, -98.0, 0.98, 0.01, 0.01], [2, -104.0, 0.02, 0.01, 0.01]]),
                OrderedDict("n" => ["Q_bad_sum"], "p" => [[0, -100.0, 0.40, 0.01, 0.01]]),
            ],
        ))
        jp = CC.parse_jplace(raw_jplace)
        @test length(jp.queries) == 3
        @test jp.queries[1].status === :valid
        @test jp.queries[1].max_lwr ≈ 0.60 atol = 1e-12
        @test jp.queries[2].status === :valid
        @test jp.queries[2].max_lwr ≈ 0.98 atol = 1e-12
        @test jp.queries[3].status === :undecided
        @test startswith(jp.queries[3].reason, "weight_sum_out_of_tolerance")
    end

    @testset "Amplicon phylogeny builder, subsampling guard, and FastTree CLI provenance" begin
        # 20 synthetic ASVs with vsearch-style semicolon headers; subsampled cleanly to max_asvs = 6.
        seqs = [
            "ASV_$(i);size=$(100 - i)" =>
            (i <= 10 ? "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT" : "TGCATGCATGCATGCATGCATGCATGCATGCATGCATGCA")
            for i in 1:20
        ]
        abund = Dict("ASV_$(i);size=$(100 - i)" => Float64(100 - i) for i in 1:20)
        res = PH.build_amplicon_phylogeny(seqs; abundances = abund, method = :nj, max_asvs = 6, seed = 7, n_boot = 20)
        @test res.subsampled
        @test res.total_input_asvs == 20
        @test res.retained_asvs == 6
        @test res.excluded_asvs == 14
        @test any(w -> occursin("Short amplicon sequences", w), res.warnings)
        @test any(w -> occursin("exceeded max_asvs", w), res.warnings)
        parsed = CC.parse_newick(res.newick)
        tips = CC._collect_tree_tips!(Set{String}(), parsed)
        @test length(tips) == 6
        @test "ASV_1;size=99" in tips

        # Verify FastTree invocation path + SHA256 binary provenance via controlled mock executable.
        mktempdir() do tmp
            mock_ft = joinpath(tmp, "FastTree")
            write(mock_ft, """#!/usr/bin/env bash
if [ "\$1" = "-help" ]; then
  echo "FastTree 2.2.0 Double precision, OpenMP (2 threads):" >&2
  exit 0
fi
OUT=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "-out" ]; then
    OUT="\$2"
    shift 2
  else
    shift 1
  fi
done
echo "(MMTIP_000001:0.05,(MMTIP_000002:0.03,MMTIP_000003:0.04)0.910:0.12,MMTIP_000004:0.08);" > "\$OUT"
""")
            chmod(mock_ft, 0o755)
            old_ft = get(PH.Tools._tools, "fasttree", nothing)
            PH.Tools._tools["fasttree"] = mock_ft
            try
                s4 = [
                    "ASV_1" => "ACGTACGTACGTACGTACGT",
                    "ASV_2" => "ACGTACGTACGTACGTACGA",
                    "ASV_3" => "ACGTACGTACGTACGTTCGA",
                    "ASV_4" => "TGCATGCATGCATGCATGCA",
                ]
                ft_res = PH.build_amplicon_phylogeny(s4; method = :fasttree, seed = 11)
                @test ft_res.method == "fasttree"
                @test any(r -> r["name"] == "FastTree" && r["version"] == "2.2.0" &&
                               r["sha256"] == bytes2hex(open(sha256, mock_ft)), ft_res.tool_records)
            finally
                if old_ft === nothing
                    delete!(PH.Tools._tools, "fasttree")
                else
                    PH.Tools._tools["fasttree"] = old_ft
                end
            end
        end
    end

    @testset "Dual-hierarchy CladeCumulus, polyphyly detection, drag-and-drop, and HTTP routes" begin
        tmp = mktempdir()
        old_root = SV.ServerState._root[]
        SV.ServerState.set_root!(tmp)
        try
            data_dir = joinpath(tmp, "data", "StudyCC", "run1")
            mkpath(data_dir)
            touch(joinpath(data_dir, "S1_R1.fastq.gz"))
            merge_dir = joinpath(tmp, "projects", "StudyCC", "run1", "merged")
            trees_dir = joinpath(tmp, "projects", "StudyCC", "trees")
            mkpath(merge_dir)
            mkpath(trees_dir)

            study_nwk = "((ASV_1:0.10,ASV_2:0.20)0.96:0.30,(ASV_3:0.15,ASV_4:0.25)0.55:0.40)Root;"
            write(joinpath(trees_dir, "amplicon.nwk"), study_nwk)

            # Note: Genus 'SplitGenus' appears on ASV_1 (Clade 1) AND ASV_4 (Clade 2) -> non-monophyletic!
            df = DataFrame(
                SeqName = ["ASV_1", "ASV_2", "ASV_3", "ASV_4"],
                Domain  = ["Bacteria", "Bacteria", "Bacteria", "Bacteria"],
                Genus   = ["SplitGenus", "MonoGenus", "OtherGenus", "SplitGenus"],
                Sequence = [
                    "ACGTACGTACGTACGTACGTACGT",
                    "ACGTACGTACGTACGTACGTACGA",
                    "TGCATGCATGCATGCATGCATGCA",
                    "TGCATGCATGCATGCATGCATGCT",
                ],
                SampleA = [40, 10, 0, 5],
                SampleB = [0, 20, 25, 10],
            )
            db_path = joinpath(merge_dir, "results.duckdb")
            db = DuckDB.DB(db_path)
            con = DBInterface.connect(db)
            DuckDB.register_data_frame(con, df, "src_df")
            DBInterface.execute(con, "CREATE TABLE merged AS SELECT * FROM src_df")
            DBInterface.close!(con)
            close(db)
            before_db_sha = bytes2hex(open(sha256, db_path))

            # 1. GET sources route
            r_src = _cc_req("GET", "/api/v1/studies/StudyCC/runs/run1/clade-cumulus/sources")
            @test r_src.status == 200
            src_json = JSON3.read(String(r_src.body))
            @test any(t -> t.table == "merged" && t.has_sequence == true, src_json.tables)
            @test any(t -> t.file == "amplicon.nwk", src_json.trees)

            # 2. POST combined mode against study_tree
            r_comb = _cc_req("POST", "/api/v1/studies/StudyCC/runs/run1/clade-cumulus", JSON3.write(Dict(
                "table" => "merged",
                "mode" => "combined",
                "treeSource" => "study_tree",
                "treeFile" => "amplicon.nwk",
                "supportThreshold" => 0.85,
                "lwrThreshold" => 0.95,
            )))
            @test r_comb.status == 200
            comb = JSON3.read(String(r_comb.body))
            @test comb.root.cumulative_count ≈ 110.0 atol = 1e-9
            @test all(ch -> ch.cumulative_count <= comb.root.cumulative_count, comb.root.children)
            @test any(dt -> dt.taxon == "SplitGenus" && dt.monophyletic == false, comb.concordance.dispersed_taxa)
            @test EP.verify_receipt(JSON3.read(JSON3.write(comb.receipt), Dict{String,Any}))
            @test comb.diversity !== nothing
            @test length(comb.diversity.samples) == 2

            # High-support clade (0.96 >= 0.85) is `present_in_every`; low-support clade (0.55 < 0.85) is `present_in_some`!
            high_clade = comb.root.children[1]
            low_clade = comb.root.children[2]
            @test high_clade.epistemic_status == "present_in_every"
            @test high_clade.colour == "#2e7d32"
            @test low_clade.epistemic_status == "present_in_some"
            @test low_clade.colour == "#f9a825"

            # 3. Validate drag-and-drop: moving ASV_3 into low-support clade fails warrant check!
            r_deny = _cc_req("POST", "/api/v1/studies/StudyCC/runs/run1/clade-cumulus/validate-move", JSON3.write(Dict(
                "table" => "merged",
                "mode" => "combined",
                "treeSource" => "study_tree",
                "treeFile" => "amplicon.nwk",
                "supportThreshold" => 0.85,
                "sourceId" => "ASV_1",
                "targetId" => low_clade.id,
            )))
            @test r_deny.status == 200
            v_deny = JSON3.read(String(r_deny.body))
            @test v_deny.allowed == false
            @test v_deny.target_colour == "#f9a825"

            # Moving ASV_3 into high-support clade succeeds AND saves non-destructive proposal sidecar!
            r_allow = _cc_req("POST", "/api/v1/studies/StudyCC/runs/run1/clade-cumulus/validate-move", JSON3.write(Dict(
                "table" => "merged",
                "mode" => "combined",
                "treeSource" => "study_tree",
                "treeFile" => "amplicon.nwk",
                "supportThreshold" => 0.85,
                "sourceId" => "ASV_3",
                "targetId" => high_clade.id,
                "saveProposal" => true,
            )))
            @test r_allow.status == 200
            v_allow = JSON3.read(String(r_allow.body))
            @test v_allow.allowed == true
            @test v_allow.proposal_file !== nothing
            @test isfile(joinpath(trees_dir, ".clade_cumulus", String(v_allow.proposal_file)))
            @test v_allow.proposed_root.cumulative_count ≈ 110.0 atol = 1e-9

            # Canonical DuckDB database is strictly untouched byte-for-byte!
            @test bytes2hex(open(sha256, db_path)) == before_db_sha

            # Path traversal attempts are rejected with 400!
            @test _cc_req("GET", "/api/v1/studies/..%2Fetc/runs/run1/clade-cumulus/sources").status == 400
            @test _cc_req("POST", "/api/v1/studies/StudyCC/runs/run1/clade-cumulus", JSON3.write(Dict(
                "treeSource" => "study_tree",
                "treeFile" => "../secret.nwk",
            ))).status == 400
        finally
            SV.ServerState._root[] = old_root
            rm(tmp; recursive = true, force = true)
        end
    end

end
