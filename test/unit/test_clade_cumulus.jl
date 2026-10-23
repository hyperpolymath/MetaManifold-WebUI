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
const _CLADE_SV = MetaManifold.Server

"""Depth-first lookup of a clade node by `id` in a decoded clade-tree payload."""
function _cc_find(node, id::AbstractString)
    String(node.id) == id && return node
    for ch in node.children
        hit = _cc_find(ch, id)
        hit === nothing || return hit
    end
    nothing
end

"""Depth-first lookup by `id` in a `clade_node_to_dict` payload (an `OrderedDict`)."""
function _cc_find_dict(node, id::AbstractString)
    String(node["id"]) == id && return node
    for ch in node["children"]
        hit = _cc_find_dict(ch, id)
        hit === nothing || return hit
    end
    nothing
end

"""Every clade node below `root`, in depth-first order."""
function _cc_nodes(root)
    out = Any[root]
    i = 1
    while i <= length(out)
        append!(out, out[i].children)
        i += 1
    end
    out
end

"""The first non-root clade holding exactly one child, or `nothing`."""
function _cc_single_child_parent(root)
    for u in _cc_nodes(root)
        (u !== root && length(u.children) == 1) && return u
    end
    nothing
end

"""The internal clade that directly contains the tip labelled `tipname`."""
function _cc_parent_of_tip(root, tipname::AbstractString)
    for u in _cc_nodes(root)
        for ch in u.children
            (isempty(ch.children) && startswith(String(ch.name), tipname)) && return u
        end
    end
    nothing
end

_cc_req(method::String, path::String, body::String = "") =
    _CLADE_SV.Oxygen.internalrequest(
        _CLADE_SV.HTTP.Request(method, path, ["Host" => "127.0.0.1:8080", "Content-Type" => "application/json"], body);
        middleware = _CLADE_SV._MIDDLEWARE,
    )

@testset "CladeCumulus & Phylogenetic Integration" begin
    @testset "Indexed study-tree API: parsing, clade roll-up, Faith PD, and UniFrac" begin
        # `((A:1.0,B:2.0)0.9:3.0,C:4.0);` parses in pre-order:
        # 1 = root, 2 = (A,B), 3 = A, 4 = B, 5 = C.
        tree = CC.parse_phylogenetic_tree("((A:1.0,B:2.0)0.9:3.0,C:4.0);")
        @test tree isa CC.PhylogeneticTree
        @test tree.root == 1
        @test length(tree.nodes) == 5
        @test sort(collect(keys(tree.tips))) == ["A", "B", "C"]
        @test tree.nodes[tree.tips["A"]].parent == 2
        @test tree.nodes[tree.tips["A"]].length == 1.0
        @test tree.nodes[tree.tips["C"]].length == 4.0
        @test tree.nodes[2].name == "0.9"
        @test tree.nodes[2].length == 3.0
        @test tree.nodes[tree.root].length === nothing
        @test all(i -> all(c -> tree.nodes[c].parent == i, tree.nodes[i].children),
                  eachindex(tree.nodes))

        # Labels and branch lengths come out of the byte buffer as real Strings:
        # an ordinary unquoted label, a multi-byte label, a quoted label with a
        # space, and a trailing bracket comment must all survive the round trip.
        odd = CC.parse_phylogenetic_tree("('ASV one':0.5[note],Σ_tip:0.5)root:0.0;\n")
        @test haskey(odd.tips, "ASV one")
        @test haskey(odd.tips, "Σ_tip")
        @test odd.nodes[odd.tips["Σ_tip"]].length == 0.5
        @test odd.nodes[odd.root].name == "root"

        iqtree = CC.parse_phylogenetic_tree("(A:0.1,(B:0.2,C:0.3)0.95:0.4);\n")
        @test sort(collect(keys(iqtree.tips))) == ["A", "B", "C"]
        @test iqtree.nodes[iqtree.root].length === nothing

        @test_throws ArgumentError CC.parse_phylogenetic_tree("(A:1.0,A:1.0);")
        @test_throws ArgumentError CC.parse_phylogenetic_tree("(A:1.0,B:1.0)")
        @test_throws ArgumentError CC.parse_phylogenetic_tree("(A:-1.0,B:1.0);")
        @test_throws ArgumentError CC.parse_phylogenetic_tree("(A:1.0,B:1.0);;")

        # Content-addressed ASV tip names ignore case, whitespace and gaps.
        @test CC.asv_tip_name("ACGT") == CC.asv_tip_name(" acg-t. ")
        @test startswith(CC.asv_tip_name("ACGT"), "ASV_")
        @test ncodeunits(CC.asv_tip_name("ACGT")) == 24
        @test_throws ArgumentError CC.asv_tip_name(" --- ")

        tips = ["A", "B", "C"]
        samples = ["s1", "s2"]
        counts = [1.0 0.0 1.0;
                  0.0 2.0 0.0]
        cumulative = CC.clade_counts(tree, counts, tips)
        @test size(cumulative) == (5, 2)
        @test cumulative[tree.tips["A"], :] == [1.0, 0.0]
        @test cumulative[tree.tips["B"], :] == [0.0, 2.0]
        @test cumulative[tree.tips["C"], :] == [1.0, 0.0]
        @test cumulative[2, :] == [1.0, 2.0]
        @test cumulative[tree.root, :] == [2.0, 2.0]
        @test_throws ArgumentError CC.clade_counts(tree, counts, ["A", "A", "C"])
        @test_throws ArgumentError CC.clade_counts(tree, counts, ["A", "B", "Z"])
        @test_throws DimensionMismatch CC.clade_counts(tree, counts, ["A", "B"])

        # edges: A 1.0, B 2.0, (A,B) 3.0, C 4.0 -> PD([s1]) = 8.0, PD([s2]) = 5.0
        @test CC.faith_pd(tree, counts, tips) ≈ [8.0, 5.0]
        @test CC.faith_pd(tree, cumulative) ≈ [8.0, 5.0]
        negative = copy(cumulative)
        negative[tree.tips["A"], 1] = -1.0
        not_a_number = copy(cumulative)
        not_a_number[tree.tips["B"], 2] = NaN
        @test_throws ArgumentError CC.faith_pd(tree, negative)
        @test_throws ArgumentError CC.faith_pd(tree, not_a_number)
        @test_throws ArgumentError CC.unifrac(tree, negative)
        @test_throws DimensionMismatch CC.faith_pd(tree, zeros(4, 2))

        # UniFrac: branches active in exactly one sample are A (1.0) and C (4.0)
        # for s1 and B (2.0) for s2, over the 10.0 union of all four edges;
        # the abundance-weighted variant is 6.0 / 9.0.
        unweighted = CC.unifrac(tree, counts, tips)
        weighted = CC.unifrac(tree, counts, tips; weighted = true)
        @test unweighted[1, 2] ≈ 0.7
        @test unweighted[2, 1] ≈ 0.7
        @test unweighted[1, 1] == 0.0
        @test weighted[1, 2] ≈ 6.0 / 9.0
        @test CC.unifrac(tree, cumulative) ≈ unweighted
        @test CC.unifrac(tree, cumulative; weighted = true) ≈ weighted

        result = CC.analyse_phylogeny(tree, counts, tips, samples)
        @test result.samples == samples
        @test result.sample_reads ≈ [2.0, 2.0]
        @test length(result.nodes) == 5
        @test result.nodes[1].id == "n1"
        @test result.nodes[1].parent_id === nothing
        @test result.nodes[1].branch_length === nothing
        @test result.nodes[1].tip_count == 3
        @test result.nodes[1].cumulative_count ≈ 4.0
        @test result.nodes[1].cumulative_frequency ≈ 1.0
        @test result.nodes[2].parent_id == "n1"
        @test result.nodes[2].label == "0.9"
        @test result.nodes[2].tip_count == 2
        @test result.nodes[tree.tips["A"]].is_tip
        @test !result.nodes[2].is_tip
        @test result.faith_pd ≈ [8.0, 5.0]
        @test result.unweighted_unifrac ≈ unweighted
        @test result.weighted_unifrac ≈ weighted
        @test result.total_branch_length ≈ 10.0
        @test_throws DimensionMismatch CC.analyse_phylogeny(tree, counts, tips, ["only"])
        @test_throws ArgumentError CC.analyse_phylogeny(tree, counts, tips, ["s1", "s1"])

        # The route writes this straight to JSON, so the payload must serialise.
        payload = Dict{String,Any}(string(k) => v for (k, v) in pairs(result))
        for key in ("unweighted_unifrac", "weighted_unifrac")
            payload[key] = [collect(row) for row in eachrow(payload[key])]
        end
        decoded = JSON3.read(JSON3.write(payload))
        @test decoded.nodes[1].id == "n1"
        @test decoded.nodes[1].parent_id === nothing
        @test decoded.faith_pd[2] ≈ 5.0
        @test decoded.unweighted_unifrac[1][2] ≈ 0.7

        # IQ-TREE infers an unrooted tree for a reversible model, so the root of
        # a `reference.treefile` is only whichever node was serialized first.
        # `analyse_phylogeny` must therefore root the way the legacy metrics do
        # (midpoint), or Faith's PD depends on that arbitrary choice.
        unrooted_text = "(A:1.0,B:2.0,C:3.0);"
        unrooted = CC.parse_phylogenetic_tree(unrooted_text)
        @test length(unrooted.nodes[unrooted.root].children) == 3
        rooted = CC.ensure_rooted(unrooted)
        @test length(rooted.nodes[rooted.root].children) == 2
        @test sort(collect(keys(rooted.tips))) == ["A", "B", "C"]
        @test CC.ensure_rooted(rooted) === rooted

        tips3 = ["A", "B", "C"]
        one_tip = [1.0 0.0 0.0]
        counts3 = [1.0 0.0 0.0;
                   0.0 2.0 3.0]
        # The midpoint falls inside the root-C edge, so a lone A tip now has to
        # reach it: 1.0 (A) + 0.5 (half of the B-root-C path remainder) = 1.5.
        @test CC._faith_pd_indexed(unrooted, CC.clade_counts(unrooted, one_tip, tips3))[1] ≈ 1.0
        @test CC.faith_pd(unrooted, one_tip, tips3)[1] ≈ 1.5
        @test CC.faith_pd(unrooted, one_tip, tips3)[1] ≈
              CC.faith_pd([1.0, 0.0, 0.0], tips3, unrooted_text)

        # Rooted and unrooted serializations must agree on every payload metric:
        # PD through the shared rooting convention, UniFrac through invariance.
        unrooted_result = CC.analyse_phylogeny(unrooted, counts3, tips3, samples)
        rooted_result = CC.analyse_phylogeny(rooted, counts3, tips3, samples)
        @test unrooted_result.faith_pd ≈ rooted_result.faith_pd
        @test unrooted_result.unweighted_unifrac ≈ rooted_result.unweighted_unifrac
        @test unrooted_result.weighted_unifrac ≈ rooted_result.weighted_unifrac
        @test unrooted_result.total_branch_length ≈ rooted_result.total_branch_length
        @test unrooted_result.total_branch_length ≈ 6.0
    end


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

        # An explicit per-sample total keeps mass that is not on the tree off
        # it, instead of renormalising it onto the tips that are. Without this
        # the weighted metric divides by the placed-only sum, so a sample whose
        # placements carry a fraction of its reads is scaled straight back up
        # to a full community and the down-weighting achieves nothing.
        #
        # Against an all-zero partner every `pb` is 0, so the raw distance is
        # exactly `sum(branch_length * pa)` and is linear in `1 / total_a`:
        # declaring twice the library size must halve it.
        f_zero = zeros(Int, length(ft_taxa))
        d_placed_only = CC.weighted_unifrac(fa, f_zero, ft_taxa, ft_nwk; normalized = false)
        d_true_total = CC.weighted_unifrac(fa, f_zero, ft_taxa, ft_nwk;
                                           normalized = false, total_a = 2 * sum(fa))
        @test d_placed_only > 0.0
        @test d_true_total ≈ d_placed_only / 2 atol = 1e-12
        # Declaring the mass already on the tree is the default, to the bit.
        @test CC.weighted_unifrac(fa, fb, ft_taxa, ft_nwk; normalized = false,
                                  total_a = sum(fa), total_b = sum(fb)) ≈
              CC.weighted_unifrac(fa, fb, ft_taxa, ft_nwk; normalized = false)
        # A total below what the tree already carries would push a relative
        # abundance above one, so it is rejected rather than clamped.
        @test_throws ArgumentError CC.weighted_unifrac(fa, fb, ft_taxa, ft_nwk; total_a = 1.0)
        @test_throws ArgumentError CC.weighted_unifrac(fa, fb, ft_taxa, ft_nwk; total_b = -1.0)
        @test_throws ArgumentError CC.unifrac_matrix(
            hcat(Float64.(fa), Float64.(fb)), ft_taxa, ["A", "B"], ft_nwk;
            metric = :weighted, totals = [1.0])

        # The per-branch breakdown uses the same denominators, so the table
        # still explains the distance it sits next to.
        contribs_default = CC.branch_unifrac_contributions(fa, f_zero, ft_taxa, ft_nwk)
        contribs_total = CC.branch_unifrac_contributions(fa, f_zero, ft_taxa, ft_nwk;
                                                         total_a = 2 * sum(fa))
        @test sum(Float64(c["contribution"]) for c in contribs_total) ≈
              sum(Float64(c["contribution"]) for c in contribs_default) / 2 atol = 1e-12

        # Quoted labels, NHX support, negative branch clamping, non-finite branch rejection,
        # and midpoint split-support symmetry across both root children.
        warns = String[]
        qtree = CC.parse_newick("[&R] (('Taxon ''alpha''':0.2,ASV_b:-0.05)[&&NHX:B=92]:0.1,ASV_c:0.3);", warnings = warns)
        @test !isempty(warns)
        @test qtree.children[1].support ≈ 0.92 atol = 1e-12
        @test qtree.children[1].children[1].name == "Taxon 'alpha'"
        @test qtree.children[1].children[2].branch_length == 0.0
        @test_throws ArgumentError CC.parse_newick("(ASV_1:NaN,ASV_2:0.1);")
        @test_throws ArgumentError CC.parse_newick("(ASV_1:Inf,ASV_2:0.1);")
        mp_sym, did_mp = CC.midpoint_root(CC.parse_newick("(ASV_1:0.1,ASV_2:0.1,(ASV_3:0.1,ASV_4:0.1)0.55:2.0);"))
        @test did_mp
        @test mp_sym.children[1].support ≈ 0.55 atol = 1e-12
        @test mp_sym.children[2].support ≈ 0.55 atol = 1e-12
    end

    @testset "Strict raw jplace evidence reader, edge projection, and independent LWR threshold" begin
        raw_jplace = JSON3.write(OrderedDict(
            "version" => 3,
            "tree" => "((Ref_1:0.1{0},Ref_2:0.2{1})95:0.3{2},Ref_3:0.4{3}){4};",
            "fields" => ["edge_num", "likelihood", "like_weight_ratio", "distal_length", "pendant_length"],
            "placements" => [
                OrderedDict("n" => ["Q_split"], "p" => [[0, -100.0, 0.60, 0.01, 0.02], [1, -100.4, 0.40, 0.01, 0.03]]),
                OrderedDict("nm" => [["Q_borderline", 1]], "p" => [[3, -98.0, 0.85, 0.05, 0.02], [2, -101.0, 0.15, 0.05, 0.02]]),
                OrderedDict("n" => ["Q_strong"], "p" => [[3, -97.0, 0.98, 0.02, 0.01]]),
                OrderedDict("n" => ["Q_bad_sum"], "p" => [[0, -100.0, 0.40, 0.01, 0.01]]),
            ],
        ))
        jp = CC.parse_jplace(raw_jplace)
        @test length(jp.queries) == 4
        @test jp.queries[1].status === :valid
        @test jp.queries[1].max_lwr ≈ 0.60 atol = 1e-12
        @test jp.queries[2].status === :valid
        @test jp.queries[2].max_lwr ≈ 0.85 atol = 1e-12
        @test jp.queries[3].status === :valid
        @test jp.queries[3].max_lwr ≈ 0.98 atol = 1e-12
        @test jp.queries[4].status === :undecided
        @test startswith(jp.queries[4].reason, "single_candidate_below_min_lwr")

        # Two acceptance rules, not one blanket tolerance. A single-candidate
        # record is the tool naming one site and leaving the rest of the mass
        # unplaced, so it is judged on its own share; a multi-candidate record
        # partitions the mass, whose shortfall may be the placement tool's
        # own truncation but whose excess never is.
        _lwr_doc(ps) = JSON3.write(OrderedDict(
            "version" => 3,
            "tree" => "((Ref_1:0.1{0},Ref_2:0.2{1})95:0.3{2},Ref_3:0.4{3}){4};",
            "fields" => ["edge_num", "likelihood", "like_weight_ratio", "distal_length", "pendant_length"],
            "placements" => ps,
        ))
        _single_at(w) = CC.parse_jplace(_lwr_doc([
            OrderedDict("n" => ["Q"], "p" => [[0, -100.0, w, 0.01, 0.02]]),
        ])).queries[1]
        _partition(a, b) = CC.parse_jplace(_lwr_doc([
            OrderedDict("n" => ["Q"], "p" => [[0, -100.0, a, 0.01, 0.02], [1, -100.4, b, 0.01, 0.03]]),
        ])).queries[1]

        @test _single_at(0.60).status === :valid
        @test _single_at(0.60).max_lwr ≈ 0.60 atol = 1e-12
        @test _single_at(CC.PLACEMENT_SINGLE_MIN_LWR).status === :valid
        @test _single_at(0.49).status === :undecided
        @test startswith(_single_at(0.49).reason, "single_candidate_below_min_lwr")

        @test _partition(0.70, 0.30).status === :valid
        @test _partition(0.80, 0.16).status === :valid       # 0.96: a truncated candidate list
        @test _partition(0.80, 0.24).status === :undecided   # 1.04: overweight evidence
        @test _partition(0.60, 0.60).status === :undecided

        # Placed query read counts project onto the reference tree edges without losing reads,
        # and `lwr_threshold = 0.95` marks `Q_borderline` (LWR = 0.85) as `present_in_some`
        # even when `support_threshold = 0.80`.
        jdf = DataFrame(
            SeqName = ["Q_split", "Q_borderline", "Q_strong"],
            Domain  = ["Bacteria", "Bacteria", "Bacteria"],
            Genus   = ["GenA", "GenB", "GenC"],
            Sample1 = [50, 30, 20],
            Sample2 = [10, 40, 50],
        )
        cc_jp = CC.build_clade_tree(
            jdf;
            mode = :combined,
            jplace_json = raw_jplace,
            support_threshold = 0.80,
            lwr_threshold = 0.95,
        )
        @test cc_jp.root.cumulative_count ≈ 200.0 atol = 1e-9

        # Cross-classifier disagreement + single-counted taxonomic residual invariant
        merged_tax_df = DataFrame(
            SeqName     = ["ASV_disagree", "ASV_partial"],
            Domain      = ["Bacteria", "Bacteria"],
            Domain_dada2= ["Bacteria", "Bacteria"],
            Domain_boot = [100, 100],
            Genus       = ["VsearchGenus", missing],
            Genus_dada2 = ["Dada2OtherGenus", missing],
            Genus_boot  = [99, missing],
            S1          = [60, 40],
        )
        cc_tax = CC.build_clade_tree(
            merged_tax_df;
            mode = :taxonomic,
            support_threshold = 0.80,
            lwr_threshold = 0.95,
        )
        @test cc_tax.root.cumulative_count ≈ 100.0 atol = 1e-9
        @test cc_tax.root.residual_count <= cc_tax.root.cumulative_count
        disagree_leaf = CC._find_clade(cc_tax.root, "asv:ASV_disagree")
        @test disagree_leaf !== nothing
        @test disagree_leaf.epistemic_status === :present_in_some

        # Taxonomic mode requires at least one taxonomic rank column
        no_rank_df = DataFrame(SeqName = ["ASV_1", "ASV_2"], S1 = [10, 20])
        @test_throws ArgumentError CC.build_clade_tree(no_rank_df; mode = :taxonomic)

        # Partial Newick tree preserves omitted table reads under an explicit sans_fibre clade
        partial_df = DataFrame(
            SeqName = ["ASV_1", "ASV_2", "ASV_missing"],
            Domain  = ["Bacteria", "Bacteria", "Bacteria"],
            S1      = [30, 20, 50],
        )
        cc_partial = CC.build_clade_tree(partial_df; mode = :combined, newick = "(ASV_1:0.1,ASV_2:0.2)Root;")
        @test cc_partial.subsampled
        @test cc_partial.retained_asvs == 2
        @test cc_partial.retained_fraction ≈ 0.5 atol = 1e-12
        @test cc_partial.root.cumulative_count ≈ 100.0 atol = 1e-9
        omitted_node = CC._find_clade(cc_partial.root, "unplaced:omitted")
        @test omitted_node !== nothing
        @test omitted_node.epistemic_status === :sans_fibre
        @test omitted_node.colour == "#c62828"
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
            write(mock_ft, raw"""#!/usr/bin/env bash
if [ "$1" = "-help" ]; then
  echo "FastTree 2.2.0 Double precision, OpenMP (2 threads):" >&2
  exit 0
fi
OUT=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-out" ]; then
    OUT="$2"
    shift 2
  else
    shift 1
  fi
done
echo "(MMTIP_000001:0.05,(MMTIP_000002:0.03,MMTIP_000003:0.04)0.910:0.12,MMTIP_000004:0.08);" > "$OUT"
""")
            chmod(mock_ft, 0o755)
            # `Phylogeny` imports `tool_bin` from `Tools` but does not bind the
            # module itself, so the registry is reached through `MetaManifold`.
            old_ft = get(MetaManifold.Tools._tools, "fasttree", nothing)
            MetaManifold.Tools._tools["fasttree"] = mock_ft
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
                    delete!(MetaManifold.Tools._tools, "fasttree")
                else
                    MetaManifold.Tools._tools["fasttree"] = old_ft
                end
            end
        end
    end

    @testset "Nested-clade drag-and-drop counts each active branch once" begin
        df = DataFrame(
            SeqName = ["ASV_1", "ASV_2", "ASV_3", "ASV_4", "ASV_5", "ASV_6"],
            S1 = [10, 20, 30, 40, 50, 0],
        )
        tree = CC.build_clade_tree(df; mode = :phylogenetic, newick =
            "((ASV_1:0.10,ASV_2:0.20,ASV_6:9.0)0.96:0.30,(ASV_3:0.40,ASV_4:0.50,ASV_5:0.70)0.97:0.60)Root:8.0;")
        source, target = tree.root.children
        verdict = CC.validate_drag_drop(tree, source.id, target.id)
        @test verdict["allowed"]
        proposed = verdict["proposed_root"]
        target_after = only(proposed["children"])
        source_after = last(target_after["children"])

        # 0.10 + 0.20 + 0.30 + 0.40 + 0.50 + 0.70 + 0.60 = 2.80.
        # The inactive tip's 9.0 and the root's 8.0 contribute nothing.
        @test proposed["subtree_pd"] ≈ 2.80 atol = 1e-12
        @test target_after["subtree_pd"] ≈ 2.80 atol = 1e-12
        @test source_after["subtree_pd"] ≈ 0.60 atol = 1e-12
        @test [ch["subtree_pd"] for ch in source_after["children"]] ≈ [0.10, 0.20, 0.0] atol = 1e-12
        @test proposed["cumulative_count"] == tree.root.cumulative_count == 150.0
        @test tree.root.subtree_pd ≈ 2.80 atol = 1e-12
        @test length(tree.root.children) == 2
    end

    @testset "Leaf subtree PD is identical before and after a move" begin
        # Codex P2 on PR #228: validating a drag-and-drop must not change the
        # reported PD of a leaf whose topology did not change. `build_node` and
        # `_reaggregate_after_move` share the `clade_faith_pd` convention - an
        # active non-root node contributes its own incoming branch - so an
        # untouched tip keeps its edge in both trees.
        df = DataFrame(
            SeqName = ["ASV_1", "ASV_2", "ASV_3", "ASV_4"],
            S1 = [10, 20, 30, 0],
        )
        tree = CC.build_clade_tree(df; mode = :phylogenetic, newick =
            "((ASV_1:0.10,ASV_2:0.20)0.96:0.30,(ASV_3:0.40,ASV_4:9.0)0.97:0.60)Root:8.0;")

        # Node-local PD: own branch when active and non-root, plus the
        # children's subtree PD.
        for u in _cc_nodes(tree.root)
            own = (u !== tree.root && u.cumulative_count > 0.0) ? max(0.0, u.branch_length) : 0.0
            @test u.subtree_pd ≈ own + sum((ch.subtree_pd for ch in u.children); init = 0.0) atol = 1e-12
        end

        tips = Dict(String(u.name) => u for u in _cc_nodes(tree.root) if isempty(u.children))
        @test tips["ASV_1"].subtree_pd ≈ 0.10 atol = 1e-12
        @test tips["ASV_2"].subtree_pd ≈ 0.20 atol = 1e-12
        @test tips["ASV_3"].subtree_pd ≈ 0.40 atol = 1e-12
        @test tips["ASV_4"].subtree_pd == 0.0   # no reads, so no edge in the PD sum
        # 0.10 + 0.20 + 0.30 + 0.40 + 0.60; the inactive tip's 9.0 and the
        # root's 8.0 contribute nothing.
        @test tree.root.subtree_pd ≈ 1.60 atol = 1e-12

        source, target = tree.root.children
        verdict = CC.validate_drag_drop(tree, String(source.id), String(target.id))
        @test verdict["allowed"]
        proposed = verdict["proposed_root"]
        for name in ("ASV_1", "ASV_2")
            before = Float64(tips[name].subtree_pd)
            after = _cc_find_dict(proposed, String(tips[name].id))
            @test after !== nothing
            if after !== nothing
                @test Float64(after["subtree_pd"]) ≈ before atol = 1e-12
            end
        end
    end

    @testset "Dual-hierarchy CladeCumulus, polyphyly detection, drag-and-drop, and HTTP routes" begin
        tmp = mktempdir()
        old_root = _CLADE_SV.ServerState._root[]
        _CLADE_SV.ServerState.set_root!(tmp)
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
            DuckDB.unregister_data_frame(con, "src_df")
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

            # Moving into a terminal sequence tip is rejected even if high support!
            r_leaf = _cc_req("POST", "/api/v1/studies/StudyCC/runs/run1/clade-cumulus/validate-move", JSON3.write(Dict(
                "table" => "merged",
                "mode" => "combined",
                "treeSource" => "study_tree",
                "treeFile" => "amplicon.nwk",
                "supportThreshold" => 0.85,
                "sourceId" => "ASV_3",
                "targetId" => "ASV_1",
            )))
            @test r_leaf.status == 200
            @test JSON3.read(String(r_leaf.body)).allowed == false

            # Moving ASV_4 (SplitGenus) into high-support clade (containing ASV_1 SplitGenus)
            # succeeds, recomputes target subtree_pd upward, AND saves configuration-keyed sidecars!
            before_target_pd = Float64(high_clade.subtree_pd)
            r_allow = _cc_req("POST", "/api/v1/studies/StudyCC/runs/run1/clade-cumulus/validate-move", JSON3.write(Dict(
                "table" => "merged",
                "mode" => "combined",
                "treeSource" => "study_tree",
                "treeFile" => "amplicon.nwk",
                "supportThreshold" => 0.85,
                "sourceId" => "ASV_4",
                "targetId" => high_clade.id,
                "saveProposal" => true,
            )))
            @test r_allow.status == 200
            v_allow = JSON3.read(String(r_allow.body))
            @test v_allow.allowed == true
            @test v_allow.proposal_file !== nothing
            @test isfile(joinpath(trees_dir, ".clade_cumulus", String(v_allow.proposal_file)))
            @test v_allow.proposed_root.cumulative_count ≈ 110.0 atol = 1e-9
            # Subtree PD includes each active edge exactly once, including the
            # target's own incoming edge (main's node-local PD convention).
            function proposed_node(u, id)
                u.id == id && return u
                for child in u.children
                    found = proposed_node(child, id)
                    found !== nothing && return found
                end
                nothing
            end
            proposed_target = proposed_node(v_allow.proposed_root, high_clade.id)
            @test proposed_target !== nothing
            if proposed_target !== nothing
                expected_pd = max(0.0, Float64(proposed_target.branch_length)) +
                              sum((Float64(ch.subtree_pd) for ch in proposed_target.children
                                   if ch.cumulative_count > 0); init=0.0)
                @test Float64(proposed_target.subtree_pd) ≈ expected_pd atol = 1e-10
                @test Float64(proposed_target.subtree_pd) != before_target_pd
            end

            # Re-saving under a different threshold writes a distinct immutable sidecar file
            r_allow2 = _cc_req("POST", "/api/v1/studies/StudyCC/runs/run1/clade-cumulus/validate-move", JSON3.write(Dict(
                "table" => "merged",
                "mode" => "combined",
                "treeSource" => "study_tree",
                "treeFile" => "amplicon.nwk",
                "supportThreshold" => 0.90,
                "sourceId" => "ASV_4",
                "targetId" => high_clade.id,
                "saveProposal" => true,
            )))
            v_allow2 = JSON3.read(String(r_allow2.body))
            @test v_allow2.allowed == true
            @test String(v_allow2.proposal_file) != String(v_allow.proposal_file)

            # 5. A `.jplace` study tree: the diversity block weights each tip by
            # the raw like-weight ratio, so mass the placement file left on no
            # edge is reported rather than renormalised onto the edge that was
            # kept. ASV_1 is placed once at LWR 0.60 and ASV_2 once at LWR 1.00;
            # ASV_3 and ASV_4 are not placed at all.
            #
            # SampleA holds 40 + 10 + 0 + 5 = 55 reads, of which the tree
            # carries 40 x 0.6 + 10 = 34, so 21 are unplaced: 16 of ASV_1's
            # like-weight shortfall plus ASV_4's 5 unmapped reads.
            # SampleB holds 0 + 20 + 25 + 10 = 55 and the tree carries 20, so
            # 35 are unplaced (ASV_3's 25 and ASV_4's 10, ASV_1 having none
            # here).
            write(joinpath(trees_dir, "placed.jplace"), JSON3.write(OrderedDict(
                "version" => 3,
                "tree" => "((Ref_1:0.10{0},Ref_2:0.20{1})0.96:0.30{2},Ref_3:0.40{3}){4};",
                "fields" => ["edge_num", "likelihood", "like_weight_ratio", "distal_length", "pendant_length"],
                "placements" => [
                    OrderedDict("n" => ["ASV_1"], "p" => [[0, -100.0, 0.60, 0.05, 0.02]]),
                    OrderedDict("n" => ["ASV_2"], "p" => [[1, -99.0, 1.00, 0.05, 0.02]]),
                ],
            )))
            r_jp = _cc_req("POST", "/api/v1/studies/StudyCC/runs/run1/clade-cumulus", JSON3.write(Dict(
                "table" => "merged",
                "mode" => "combined",
                "treeSource" => "study_tree",
                "treeFile" => "placed.jplace",
                "supportThreshold" => 0.85,
                "lwrThreshold" => 0.95,
            )))
            @test r_jp.status == 200
            jp_body = JSON3.read(String(r_jp.body))
            @test jp_body.diversity !== nothing
            @test jp_body.diversity.mapped_tips == 2
            @test jp_body.diversity.unplaced_reads.SampleA ≈ 21.0 atol = 1e-9
            @test jp_body.diversity.unplaced_reads.SampleB ≈ 35.0 atol = 1e-9
            # Raw weighted UniFrac against the 55-read library sizes (the
            # `totals` denominators that keep unplaced mass off the tree): the
            # grafted tree contributes 0.02 (ASV_1's pendant), 0.05 (the rest
            # of Ref_1's branch), 0.02 (ASV_2's pendant), 0.15 (the rest of
            # Ref_2's branch) and 0.30 (the clade joining them), so
            #   (0.02*24 + 0.05*24 + 0.02*10 + 0.15*10 + 0.30*(34-20)) / 55
            #   = 7.58 / 55 = 0.1378181...
            @test jp_body.diversity.weighted_unifrac[1][2] ≈ 7.58 / 55 atol = 1e-9
            # The clade tree is a count view of the table and still conserves
            # every observed read; only the abundance-weighted diversity matrix
            # discounts the unplaced mass.
            @test jp_body.root.cumulative_count ≈ 110.0 atol = 1e-9

            # Canonical DuckDB database is strictly untouched byte-for-byte!
            @test bytes2hex(open(sha256, db_path)) == before_db_sha

            # 6. POST combined mode against a study `.jplace` artifact
            jplace_payload = JSON3.write(OrderedDict(
                "version" => 3,
                "tree" => "((ASV_1:0.05{0},ASV_2:0.05{1})0.96:0.20{2},ASV_3:0.08{3}){4};",
                "fields" => ["edge_num", "likelihood", "like_weight_ratio", "distal_length", "pendant_length"],
                "placements" => [
                    OrderedDict("n" => ["ASV_4"], "p" => [[3, -10.0, 0.99, 0.02, 0.03]]),
                ],
            ))
            write(joinpath(trees_dir, "placed.jplace"), jplace_payload)
            r_jp = _cc_req("POST", "/api/v1/studies/StudyCC/runs/run1/clade-cumulus", JSON3.write(Dict(
                "table" => "merged",
                "mode" => "combined",
                "treeSource" => "study_tree",
                "treeFile" => "placed.jplace",
            )))
            @test r_jp.status == 200
            jp_body = JSON3.read(String(r_jp.body))
            @test jp_body.diversity !== nothing
            @test jp_body.diversity.unplaced_reads.SampleA ≈ 0.05 atol = 1e-9
            @test jp_body.diversity.unplaced_reads.SampleB ≈ 0.10 atol = 1e-9

            # Path traversal attempts are rejected with 400!
            @test _cc_req("GET", "/api/v1/studies/..%2Fetc/runs/run1/clade-cumulus/sources").status == 400
            @test _cc_req("POST", "/api/v1/studies/StudyCC/runs/run1/clade-cumulus", JSON3.write(Dict(
                "treeSource" => "study_tree",
                "treeFile" => "../secret.nwk",
            ))).status == 400
        finally
            _CLADE_SV.ServerState._root[] = old_root
            rm(tmp; recursive = true, force = true)
        end
    end

    @testset "A move that empties a clade clears its activity and PD" begin
        # `_reaggregate_after_move` detaches the moving clade from its old
        # parent. When that parent's only child was the one that moved, the
        # parent is left with no children but still carries the
        # `cumulative_count` (and the `residual_count` behind its uncertainty
        # cloud) of the subtree that has just left. Read as a leaf, that stale
        # count would keep the emptied clade active and give it a nonzero
        # `subtree_pd` and frequency for reads it no longer holds.
        # Two domains, two ASVs each, so the proposed root's taxon purity
        # distinguishes "four real tips" (0.5) from "four tips plus the
        # emptied wrapper counted as a fifth Bacteria tip" (0.6).
        df = DataFrame(
            SeqName = ["ASV_1", "ASV_2", "ASV_3", "ASV_4"],
            Domain  = ["Bacteria", "Bacteria", "Archaea", "Archaea"],
            SampleA = [10.0, 20.0, 30.0, 40.0],
        )
        # `wrapper` has exactly one child (the ASV_1/ASV_2 clade); the other
        # side of the root is a two-tip clade we can move that child into.
        nwk = "(((ASV_1:0.10,ASV_2:0.20)0.96:0.30)0.94:0.05,(ASV_3:0.15,ASV_4:0.25)0.90:0.40)Root;"
        cc_move = CC.build_clade_tree(
            df; mode = :combined, newick = nwk, support_threshold = 0.5, lwr_threshold = 0.95,
        )

        wrapper = _cc_single_child_parent(cc_move.root)
        @test wrapper !== nothing
        only_child = wrapper === nothing ? nothing : wrapper.children[1]
        @test only_child !== nothing

        # The target is the clade directly holding ASV_3: internal, well
        # supported, and in the other half of the tree from the moving clade.
        target = _cc_parent_of_tip(cc_move.root, "ASV_3")
        @test target !== nothing

        if wrapper !== nothing && only_child !== nothing && target !== nothing
            before_total = Float64(cc_move.root.cumulative_count)
            vacated_reads = Float64(wrapper.cumulative_count)
            vacated_residual = Float64(wrapper.residual_count)
            moved_reads = Float64(only_child.cumulative_count)
            moved_residual = Float64(only_child.residual_count)
            @test vacated_reads > 0.0
            @test vacated_residual > 0.0   # so clearing it is observable
            @test moved_reads > 0.0

            verdict = CC.validate_drag_drop(cc_move, String(only_child.id), String(target.id))
            @test verdict["allowed"] == true
            proposed_root = verdict["proposed_root"]

            vacated = _cc_find_dict(proposed_root, String(wrapper.id))
            @test vacated !== nothing
            if vacated !== nothing
                @test Float64(vacated["cumulative_count"]) == 0.0
                @test Float64(vacated["cumulative_frequency"]) == 0.0
                @test Float64(vacated["subtree_pd"]) == 0.0
                # The residual uncertainty belonged to the reads that left, so
                # it leaves with them instead of lingering on an empty clade.
                @test Float64(vacated["residual_count"]) == 0.0
                @test isempty(vacated["children"])
            end

            # The reads are relocated, not lost, and the clade that moved keeps
            # every one of them.
            relocated = _cc_find_dict(proposed_root, String(only_child.id))
            @test relocated !== nothing
            if relocated !== nothing
                @test Float64(relocated["cumulative_count"]) == moved_reads
                @test Float64(relocated["residual_count"]) == moved_residual
            end
            @test Float64(proposed_root["cumulative_count"]) ≈ before_total atol = 1e-9
            # The emptied wrapper is childless but is not a tip: it must not
            # add its departed subtree's taxon to the tip counts behind
            # purity/monophyly. Four real tips, two per domain, give 0.5;
            # counting the wrapper as a fifth Bacteria tip would give 0.6.
            @test Float64(proposed_root["taxon_purity"]) ≈ 0.5 atol = 1e-9
        end
    end


end
