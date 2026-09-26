# SPDX-License-Identifier: AGPL-3.0-only
#
# Evidence for issue #20 — ILR bases: phylogenetic (PhILR), sequential binary partition
# (SBP) and balance dendrogram — held to the conditions published before the
# implementation in docs/statistics/method-conditions/ilr-bases.md:
#
#   * one test per machine-checked theorem (proofs/agda, plan in
#     docs/formal/verification-plan.md §5), each description starting with the theorem's
#     name: the proofs hold in exact arithmetic; these check the floating-point code
#     against them;
#   * reference agreement with the committed fixtures in test/fixtures/ilr/, which
#     test/fixtures/ilr/ilr_reference.jl -- an independent, Base-only Julia port of philr,
#     compositions::ilr / gsi.merge2signary and robCompositions::variation, with a generic
#     Lance-Williams clustering rather than hclust.f's nearest-neighbour list -- recomputes
#     from the committed inputs on every run. It is NOT R: philr, compositions and
#     robCompositions are not in renv.lock and are not added. The R cross-check at the end
#     runs only where those packages are installed and says so when it is skipped;
#   * hand-computed tie cases for R's hclust.f tie-breaking;
#   * a negative control for every refusal in the conditions document, asserting that it
#     fires and names what it refused;
#   * the integration path, from AnalysisConfig through prepare_analysis_table to the
#     balances, the checks and the provenance;
#   * performance at 100, 1 000 and 10 000 taxa, including the allocation bound that
#     shows no dense basis is built.

# The independent reference is a module, so it is loaded here at file scope, not inside a
# testset. It never calls MetaManifold.ILRBasis.
include(joinpath(@__DIR__, "..", "fixtures", "ilr", "ilr_reference.jl"))

@testset "ILR bases — phylogenetic, SBP, balance dendrogram (issue #20)" begin

    ILR = MetaManifold.ILRBasis
    FIX = joinpath(@__DIR__, "..", "fixtures", "ilr")

    # rows x cols matrix from a fixture CSV (first column: row ids; header: corner + col ids)
    function read_matrix(path)
        lines = [String(strip(l)) for l in readlines(path) if !isempty(strip(l))]
        cols = map(String, split(lines[1], ',')[2:end])
        rows = String[]
        M = zeros(Float64, length(lines) - 1, length(cols))
        for (r, l) in enumerate(lines[2:end])
            f = split(l, ',')
            push!(rows, String(f[1]))
            for c in eachindex(cols)
                M[r, c] = parse(Float64, f[c + 1])
            end
        end
        return rows, cols, M
    end

    function refusal(f)
        try
            f()
        catch e
            return sprint(showerror, e)
        end
        return "NO REFUSAL"
    end

    # Deterministic positive table without Random: taxa x samples.
    synth(D, n; k=0) = [1.5 + mod(i * 7919 + j * 104729 + k * 31337, 997) + 0.25 * mod(i * j, 7) for i in 1:D, j in 1:n]

    # SBP basis matrix V (D x (D-1)) and masses from a balance tree and part weights, the
    # dense formula `buildilrBasep` uses: +c/r on the numerator, -c/s on the denominator.
    function dense_basis(bt, p)
        W = ILR.sbp_matrix(bt)
        D = size(W, 1)
        V = zeros(Float64, D, D - 1)
        for n in 1:(D - 1)
            r = sum(p[i] for i in 1:D if W[i, n] == 1)
            s = sum(p[i] for i in 1:D if W[i, n] == -1)
            c = sqrt(r * s / (r + s))
            for i in 1:D
                W[i, n] == 1 && (V[i, n] = c / r)
                W[i, n] == -1 && (V[i, n] = -c / s)
            end
        end
        return V
    end

    ids8, s8, X8 = read_matrix(joinpath(FIX, "philr_d8", "counts.csv"))
    tree8 = read(joinpath(FIX, "philr_d8", "tree.nwk"), String)
    ids25, s25, X25 = read_matrix(joinpath(FIX, "philr_d25", "counts.csv"))
    tree25 = read(joinpath(FIX, "philr_d25", "tree.nwk"), String)
    bt8, _ = ILR.phylo_balance_tree(tree8, ids8)
    bt25, _ = ILR.phylo_balance_tree(tree25, ids25)

    # ==================================================================================
    # One test per theorem (verification-plan §5)
    # ==================================================================================

    @testset "internal-count: D taxa give D-1 balances with unique ids" begin
        for (bt, D) in ((bt8, 8), (bt25, 25))
            @test length(bt.balance_ids) == D - 1
            @test allunique(bt.balance_ids)
            @test count(==(0), bt.tip) == D - 1
            @test sort(bt.balance_row[bt.tip .== 0]) == collect(1:(D - 1))
        end
        @test length(ILR.comb_tree(["a", "b"]).balance_ids) == 1
    end

    @testset "code: tree -> SBP -> tree is the identity and every column has a + and a - part" begin
        for bt in (bt8, bt25)
            W = ILR.sbp_matrix(bt)
            D = length(bt.taxa)
            @test size(W) == (D, D - 1)
            @test all(any(==(1), W[:, n]) && any(==(-1), W[:, n]) for n in 1:(D - 1))
            bt2 = ILR.sbp_balance_tree(bt.taxa, bt.balance_ids, W, bt.taxa)
            @test bt2.left == bt.left && bt2.right == bt.right && bt2.tip == bt.tip
            @test bt2.balance_row == bt.balance_row && bt2.balance_ids == bt.balance_ids
        end
    end

    @testset "contrast-from-code: clade sums equal the SBP matrix formula" begin
        for p in (ones(25), ILR.part_weights(X25, "gm_counts"), ILR.part_weights(X25, "enorm"))
            V = dense_basis(bt25, p)
            B = ILR.tree_balances(bt25, X25, p, ones(24))
            Y = log.(X25) .- log.(p)
            B2 = [sum(V[i, n] * p[i] * Y[i, j] for i in 1:25) for n in 1:24, j in 1:size(X25, 2)]
            @test maximum(abs.(B .- B2)) < 1e-12
        end
    end

    @testset "contrast-sum-zero: balances of a constant composition are zero" begin
        const_x = fill(42.0, 25, 3)
        @test maximum(abs.(ILR.tree_balances(bt25, const_x, ones(25), ones(24)))) < 1e-12
        # In the p-weighted geometry the "constant" composition is x proportional to p.
        p = ILR.part_weights(X25, "anorm_x_gm_counts")
        prop_p = hcat(p .* 3.0, p .* 0.01)
        @test maximum(abs.(ILR.tree_balances(bt25, prop_p, p, ones(24)))) < 1e-12
    end

    @testset "basis-orthogonal: basis columns are orthonormal under part weights" begin
        for p in (ones(25), ILR.part_weights(X25, "gm_counts"), ILR.part_weights(X25, "anorm"))
            V = dense_basis(bt25, p)
            G = [sum(p[i] * V[i, a] * V[i, b] for i in 1:25) for a in 1:24, b in 1:24]
            @test maximum(abs.(G .- [a == b ? 1.0 : 0.0 for a in 1:24, b in 1:24])) < 1e-12
            # contrast-sum-zero, column form: every column is p-centred.
            @test maximum(abs(sum(p[i] * V[i, n] for i in 1:25)) for n in 1:24) < 1e-12
        end
    end

    @testset "contrast-norm: recorded coefficient equals sqrt(rs/(r+s))" begin
        dir = mktempdir()
        tp = joinpath(dir, "t.nwk")
        write(tp, tree25)
        out = ILR.ilr_transform(X25, ids25; basis = "phylogenetic", tree_path = tp, part_weights_kind = "gm_counts")
        for rec in out.checks["balances"]
            r, s = rec["r"], rec["s"]
            @test abs(rec["coefficient"] - sqrt(r * s / (r + s))) < 1e-12
            # the unnormalised contrast's squared norm is r*s*(r+s) under uniform weights;
            # under weights it is s^2 r + r^2 s — the same expression.
            @test abs((s^2 * r + r^2 * s) - r * s * (r + s)) < 1e-9 * max(1.0, r * s * (r + s))
        end
        @test sum(rec["r"] + rec["s"] for rec in out.checks["balances"] if rec["id"] == out.balance_ids[1]) ≈ sum(ILR.part_weights(X25, "gm_counts"))
    end

    @testset "balance-injective: balances are an isometry of centred log vectors" begin
        for p in (ones(25), ILR.part_weights(X25, "enorm_x_gm_counts"))
            B = ILR.tree_balances(bt25, X25, p, ones(24))
            n = size(X25, 2)
            worst = 0.0
            for a in 1:n, b in (a + 1):n
                d = log.(X25[:, a]) .- log.(X25[:, b])
                dbar = sum(p .* d) / sum(p)
                aitchison = sum(p .* (d .- dbar) .^ 2)
                worst = max(worst, abs(sum((B[:, a] .- B[:, b]) .^ 2) - aitchison))
                # distinct compositions (not proportional) give distinct balances
                @test sum((B[:, a] .- B[:, b]) .^ 2) > 1e-6
            end
            @test worst < 1e-9
        end
    end

    @testset "balance-scale-invariant: scaling a sample leaves balances unchanged" begin
        p = ILR.part_weights(X25, "gm_counts")
        B = ILR.tree_balances(bt25, X25, p, ones(24))
        for λ in (1e-3, 7.0, 1e5)
            Bλ = ILR.tree_balances(bt25, λ .* X25, p, ones(24))
            @test maximum(abs.(Bλ .- B) ./ max.(1.0, abs.(B))) < 1e-12
        end
        # counts and proportions give the same balances
        P = X25 ./ sum(X25, dims = 1)
        @test maximum(abs.(ILR.tree_balances(bt25, P, p, ones(24)) .- B)) < 1e-11
    end

    @testset "balance-perturb: perturbation adds balance vectors" begin
        Y = synth(25, size(X25, 2); k = 3)
        Bx = ILR.tree_balances(bt25, X25, ones(25), ones(24))
        By = ILR.tree_balances(bt25, Y, ones(25), ones(24))
        Bxy = ILR.tree_balances(bt25, X25 .* Y, ones(25), ones(24))
        @test maximum(abs.(Bxy .- (Bx .+ By))) < 1e-12
    end

    @testset "comb-is-helmert: comb tree reproduces the Helmert default" begin
        taxa = ["t$i" for i in 1:12]
        counts = synth(12, 6)
        cfg = AnalysisConfig.AnalysisConfig(
            method = "ilr_lm", formula = "~ group", metadata_columns = ["group"],
            normalization = AnalysisConfig.NormalizationConfig(method = "ilr", pseudocount = 0.5),
            advanced = AnalysisConfig.AdvancedConfig(min_prevalence = 0.0, min_abundance = 0.0),
            created_by = "test_ilr_basis")
        (prepared, _, _, _, rows) = Execution.prepare_analysis_table(
            cfg, counts; sample_ids = ["s$j" for j in 1:6], taxa_ids = taxa, drop_policy = "drop")
        comb = ILR.comb_tree(taxa)
        B = ILR.tree_balances(comb, counts .+ 0.5, ones(12), ones(11))
        @test rows == comb.balance_ids
        @test maximum(abs.(B .- prepared)) < 1e-12
    end

    @testset "kernel-needs-hypothesis: signed weights lose injectivity, so non-positive weights are refused" begin
        # The counterexample, in numbers: two parts with weights p = (1, -1), so r = 1 and
        # s = -1. y = (1, 1) is p-centred (1*1 + (-1)*1 = 0) and non-zero, yet it is
        # p-orthogonal to the balance's contrast c = (s, -r) = (-1, -1):
        # 1*(-1)*1 + (-1)*(-1)*1 = 0. The balance cannot see y, so the map is not injective
        # without positive weights (the hypothesis the Agda Kernel module carries).
        p = (1, -1); y = (1, 1)
        @test p[1] * y[1] + p[2] * y[2] == 0
        r, s = p[1], p[2]
        contrast = (s, -r)
        @test p[1] * contrast[1] * y[1] + p[2] * contrast[2] * y[2] == 0
        @test y != (0, 0)
        # So a weight that is zero (anorm of a taxon constant across samples) is refused.
        Xc = copy(X25); Xc[3, :] .= 10.0
        msg = refusal(() -> ILR.part_weights(Xc, "anorm"))
        @test occursin("finite and positive", msg)
        @test occursin("refused", msg)
    end

    # ==================================================================================
    # Reference agreement (committed fixtures, recomputed by test/fixtures/ilr/ilr_reference.jl)
    # ==================================================================================

    @testset "the independent Julia reference reproduces every committed expectation (1e-10)" begin
        # Three-way agreement: the committed files, the reference recomputing them from the
        # committed inputs (here), and the engine (the testsets below). A change to any one
        # of the three that the other two do not share fails.
        @test ILRReference.philr_known_answers()
        expectations = ILRReference.reference_expectations(FIX)
        @test length(expectations) == 9 + 1 + 1 + 2 * 3
        for e in expectations
            rows, cols, M = read_matrix(joinpath(FIX, e.file))
            @test rows == e.rows
            @test cols == e.cols
            @test size(M) == size(e.values)
            @test maximum(abs.(M .- e.values) ./ max.(1.0, abs.(e.values))) < 1e-10
        end
    end

    @testset "PhILR agrees with the philr reference on three datasets (1e-10)" begin
        n_compared = 0
        for d in ("philr_d8", "philr_d25", "philr_d60_pruned")
            taxa, _, X = read_matrix(joinpath(FIX, d, "counts.csv"))
            bt, info = ILR.phylo_balance_tree(read(joinpath(FIX, d, "tree.nwk"), String), taxa)
            for f in sort(readdir(joinpath(FIX, d)))
                startswith(f, "expected_") || continue
                part, ilrw = split(f[10:(end - 4)], "__")
                eids, _, E = read_matrix(joinpath(FIX, d, f))
                p = ILR.part_weights(X, String(part))
                bw, _ = ILR.balance_weights(bt, String(ilrw))
                B = ILR.tree_balances(bt, X, p, bw)
                @test bt.balance_ids == eids
                @test maximum(abs.(B .- E) ./ max.(1.0, abs.(E))) < 1e-10
                n_compared += 1
            end
            d == "philr_d60_pruned" && @test info["pruned_tips_count"] == 15
            d == "philr_d60_pruned" && @test startswith(info["balance_id_rule"], "n1")
            d == "philr_d8" && @test startswith(info["balance_id_rule"], "internal node labels")
        end
        @test n_compared == 9
    end

    @testset "SBP agrees with compositions::ilr semantics, SBP rows in any order (1e-10)" begin
        taxa, _, X = read_matrix(joinpath(FIX, "sbp_d12", "counts.csv"))
        (st, ids, W) = ILR.parse_sbp(read(joinpath(FIX, "sbp_d12", "sbp.csv"), String))
        @test st != taxa                     # the fixture permutes the SBP rows on purpose
        bt = ILR.sbp_balance_tree(st, ids, W, taxa)
        eids, _, E = read_matrix(joinpath(FIX, "sbp_d12", "expected.csv"))
        @test bt.balance_ids == ids == eids  # the SBP's column order and names are kept
        @test maximum(abs.(ILR.tree_balances(bt, X, ones(12), ones(11)) .- E)) < 1e-10
        # round trip: the reconstructed tree's SBP is the input, rows re-ordered to the table
        W2 = ILR.sbp_matrix(bt)
        @test all(W2[findfirst(==(t), taxa), :] == W[i, :] for (i, t) in enumerate(st))
    end

    @testset "balance dendrogram: variation matrix, R hclust merges and balances (generic reference, tie-free)" begin
        taxa, _, X = read_matrix(joinpath(FIX, "dendrogram_d30", "counts.csv"))
        D = length(taxa)
        _, _, T = read_matrix(joinpath(FIX, "dendrogram_d30", "variation.csv"))
        tau = ILR.variation_condensed(X)
        @test maximum(abs(tau[k] - T[i, j]) for (k, (i, j)) in enumerate(((i, j) for i in 1:(D - 1) for j in (i + 1):D))) < 1e-12
        for m in ("ward", "complete", "average")
            _, _, R = read_matrix(joinpath(FIX, "dendrogram_d30", "merge_$m.csv"))
            merge, height = ILR.hclust_r(tau, D, m)
            @test merge == round.(Int, R[:, 1:2])
            @test maximum(abs.(height .- R[:, 3])) < 1e-12
            bt = ILR.dendrogram_balance_tree(merge, taxa)
            eids, _, E = read_matrix(joinpath(FIX, "dendrogram_d30", "expected_$m.csv"))
            @test bt.balance_ids == eids
            @test maximum(abs.(ILR.tree_balances(bt, X, ones(D), ones(D - 1)) .- E)) < 1e-10
        end
    end

    @testset "hclust tie-breaking follows R's hclust.f (hand-computed)" begin
        # All six distances equal: the first pair in scan order merges first, then the
        # cluster absorbs the next singleton — R gives merge [-1 -2; -3 1; -4 2].
        for m in ("ward", "complete", "average")
            merge, height = ILR.hclust_r(ones(6), 4, m)
            @test merge == [-1 -2; -3 1; -4 2]
            @test height ≈ [1.0, 1.0, 1.0] atol = 1e-15
        end
        # Two tied pairs (d12 = d34 = 1, all else 2): (1,2) first, then (3,4), then both
        # clusters, smaller step first. Ward.D2 top height = sqrt(((1+2)5 + (1+2)5 - 2)/4)
        # = sqrt(7), from the squared-distance update (5 = ((1+1)4 + (1+1)4 - 1)/3).
        d = [1.0, 2.0, 2.0, 2.0, 2.0, 1.0]
        for m in ("ward", "complete", "average")
            merge, height = ILR.hclust_r(d, 4, m)
            @test merge == [-1 -2; -3 -4; 1 2]
            @test height[1:2] ≈ [1.0, 1.0] atol = 1e-15
            @test height[3] ≈ (m == "ward" ? sqrt(7.0) : 2.0) atol = 1e-14
        end
        # gsi.merge2signary reading: second cluster = numerator (left child).
        bt = ILR.dendrogram_balance_tree([-1 -2; -3 -4; 1 2], ["a", "b", "c", "d"])
        @test bt.balance_ids == ["m3", "m2", "m1"]
        @test ILR.sbp_matrix(bt) == Int8[-1 0 -1; -1 0 1; 1 -1 0; 1 1 0]
    end

    # ==================================================================================
    # Negative controls: every refusal fires and names what it refused
    # ==================================================================================

    @testset "phylogenetic refusals" begin
        abc = ["A", "B", "C"]
        m = refusal(() -> ILR.phylo_balance_tree("(A:1,B:1,C:1);", abc))
        @test occursin("unrooted", m) && occursin("trifurcation", m)
        # checked before pruning: pruning D would otherwise invent a root
        m = refusal(() -> ILR.phylo_balance_tree("((A,B),C,D);", abc))
        @test occursin("unrooted", m)
        m = refusal(() -> ILR.phylo_balance_tree("(((A,B,C),D),E);", ["A", "B", "C", "D"]))
        @test occursin("polytomy", m) && occursin("'A'", m)
        # a polytomy with only two retained branches is an ordinary split once pruned
        bt, info = ILR.phylo_balance_tree("(((A,B,X),C),Y);", abc)
        @test length(bt.balance_ids) == 2 && info["pruned_tips_count"] == 2
        m = refusal(() -> ILR.phylo_balance_tree("((A,A),B);", ["A", "B"]))
        @test occursin("duplicate tip labels", m) && occursin("'A'", m)
        m = refusal(() -> ILR.phylo_balance_tree("((A,B),C);", ["A", "B", "C", "Zed"]))
        @test occursin("not tips", m) && occursin("'Zed'", m)
        @test occursin("no terminating ';'", refusal(() -> ILR.parse_newick("((A,B),C)")))
        @test occursin("not closed", refusal(() -> ILR.parse_newick("((A,B),C;")))
        @test occursin("unbalanced ')'", refusal(() -> ILR.parse_newick("(A,B));")))
        @test occursin("not a finite number", refusal(() -> ILR.parse_newick("(A:x,B);")))
        @test occursin("second label", refusal(() -> ILR.parse_newick("(Homo sapiens,B);")))
        # quoted labels, comments and exact matching
        bt, _ = ILR.phylo_balance_tree("('Homo sapiens':1,(B:1[&c],'it''s':1):1);", ["Homo sapiens", "B", "it's"])
        @test sort(bt.taxa) == sort(["Homo sapiens", "B", "it's"])
        @test occursin("not tips", refusal(() -> ILR.phylo_balance_tree("((a,B),C);", ["A", "B", "C"])))
        # labels: unique non-numeric -> used; numeric support values -> n1..
        bt, _ = ILR.phylo_balance_tree("((A,B)x,C)root;", abc)
        @test bt.balance_ids == ["root", "x"]
        bt, _ = ILR.phylo_balance_tree("((A,B)95,C)100;", abc)
        @test bt.balance_ids == ["n1", "n2"]
    end

    @testset "balance-weight refusals and philr's zero-length tip rule" begin
        bt, _ = ILR.phylo_balance_tree("((A,B),C);", ["A", "B", "C"])
        @test occursin("branch length", refusal(() -> ILR.balance_weights(bt, "blw")))
        bt, _ = ILR.phylo_balance_tree("((A:0,B:2):1,C:3);", ["A", "B", "C"])
        w, info = ILR.balance_weights(bt, "blw")
        @test info["zero_length_tip_edges_replaced"] == 1 && info["min_nonzero_edge_length"] == 1.0
        @test w == [1.0 + 3.0, 1.0 + 2.0]     # root: edges 1 and 3; inner: A 0 -> 1, B 2
        bt, _ = ILR.phylo_balance_tree("((A:-1,B:2):1,C:3);", ["A", "B", "C"])
        @test occursin("non-negative", refusal(() -> ILR.balance_weights(bt, "blw_sqrt")))
        m = refusal(() -> ILR.ilr_transform(synth(3, 4), ["A", "B", "C"]; basis = "balance_dendrogram",
                                            dendrogram_method = "ward", balance_weights_kind = "blw"))
        @test occursin("only the phylogenetic basis", m)
    end

    @testset "SBP refusals (Egozcue & Pawlowsky-Glahn 2005)" begin
        t4 = ["a", "b", "c", "d"]
        sbp(rows) = ILR.parse_sbp("taxon,b1,b2,b3\n" * join(rows, "\n") * "\n")
        ok = ["a,1,1,0", "b,1,-1,0", "c,-1,0,1", "d,-1,0,-1"]
        (st, ids, W) = sbp(ok)
        @test ILR.sbp_balance_tree(st, ids, W, t4).balance_ids == ["b1", "b2", "b3"]
        # spellings
        (_, _, W2) = ILR.parse_sbp("taxon,b1\nx,+1\ny,-1.0\n")
        @test W2 == reshape(Int8[1, -1], 2, 1)
        @test occursin("'2'", refusal(() -> sbp(["a,2,1,0", "b,1,-1,0", "c,-1,0,1", "d,-1,0,-1"])))
        @test occursin("''", refusal(() -> sbp(["a,,1,0", "b,1,-1,0", "c,-1,0,1", "d,-1,0,-1"])))
        m = refusal(() -> ILR.sbp_balance_tree(["a", "b", "c", "d"], ["b1", "b2"], Int8[1 1; 1 -1; -1 0; -1 0], t4))
        @test occursin("exactly 3 balance columns", m)
        (st, ids, W) = sbp(["a,1,1,0", "b,1,1,0", "c,-1,0,1", "d,-1,0,-1"])
        @test occursin("no -1 entry", refusal(() -> ILR.sbp_balance_tree(st, ids, W, t4)))
        # b3 splits {b, c}, which no earlier partition produced
        (st, ids, W) = sbp(["a,1,1,0", "b,1,-1,1", "c,-1,0,-1", "d,-1,0,0"])
        m = refusal(() -> ILR.sbp_balance_tree(st, ids, W, t4))
        @test occursin("not a sequential binary partition", m)
        @test occursin("'b3'", m) && occursin("{c, d}", m)
        # no column involves every taxon
        (st, ids, W) = sbp(["a,1,1,0", "b,-1,-1,0", "c,0,1,1", "d,0,0,-1"])
        @test occursin("no column involves every taxon", refusal(() -> ILR.sbp_balance_tree(st, ids, W, t4)))
        (st, ids, W) = sbp(["a,1,1,1", "b,1,-1,-1", "c,-1,0,0", "d,-1,0,0"])
        @test occursin("involve the same taxa", refusal(() -> ILR.sbp_balance_tree(st, ids, W, t4)))
        # taxa must be exactly the retained taxa
        (st, ids, W) = sbp(ok)
        m = refusal(() -> ILR.sbp_balance_tree(st, ids, W, ["a", "b", "c", "d", "e"]))
        @test occursin("not rows of the SBP", m) && occursin("'e'", m)
        m = refusal(() -> ILR.sbp_balance_tree(st, ids, W, ["a", "b", "c"]; removed_by_filtering = ["d"]))
        @test occursin("removed by prevalence/abundance filtering", m) && occursin("'d'", m)
        m = refusal(() -> ILR.sbp_balance_tree(st, ids, W, ["a", "b", "c"]))
        @test occursin("not in the count table", m)
        @test occursin("more than once", refusal(() -> ILR.sbp_balance_tree(["a", "a", "c", "d"], ids, W, t4)))
        @test occursin("repeated balance ids", refusal(() -> ILR.sbp_balance_tree(st, ["b1", "b1", "b3"], W, t4)))
    end

    @testset "dendrogram refusals and the memory guard" begin
        @test occursin("at least 2 samples", refusal(() -> ILR.variation_condensed(synth(4, 1))))
        m = refusal(() -> ILR.ilr_transform(synth(4, 3), ["a", "b", "c", "d"]; basis = "balance_dendrogram", dendrogram_method = "single"))
        @test occursin("ward, complete, average", m)
        # 23 171 taxa need a > 2 GiB condensed variation matrix: refused before allocating it.
        D = 23_171
        m = refusal(() -> ILR.ilr_transform(ones(D, 2), ["t$i" for i in 1:D]; basis = "balance_dendrogram", dendrogram_method = "ward"))
        @test occursin("GiB", m) && occursin("limit", m)
    end

    @testset "engine refusals" begin
        X = synth(4, 3); X[2, 2] = 0.0
        m = refusal(() -> ILR.ilr_transform(X, ["a", "b", "c", "d"]; basis = "balance_dendrogram", dendrogram_method = "ward"))
        @test occursin("strictly positive", m) && occursin("'b'", m)
        @test occursin("not one of", refusal(() -> ILR.ilr_transform(synth(3, 3), ["a", "b", "c"]; basis = "default")))
        @test occursin("does not exist", refusal(() -> ILR.ilr_transform(synth(3, 3), ["a", "b", "c"]; basis = "phylogenetic", tree_path = "/nonexistent/tree.nwk")))
        @test occursin("is required", refusal(() -> ILR.ilr_transform(synth(3, 3), ["a", "b", "c"]; basis = "sequential_binary_partition")))
    end

    # ==================================================================================
    # Configuration contract
    # ==================================================================================

    function ilr_config(; basis = nothing, norm = "ilr", method = "ilr_lm", kw...)
        AnalysisConfig.AnalysisConfig(
            method = method, formula = "~ group", metadata_columns = ["group"],
            normalization = AnalysisConfig.NormalizationConfig(method = norm, pseudocount = 0.5, ilr_basis = basis),
            advanced = AnalysisConfig.AdvancedConfig(; min_prevalence = 0.0, min_abundance = 0.0, kw...),
            created_by = "test_ilr_basis")
    end
    digest(s) = bytes2hex(sha256(s))

    @testset "configuration: each basis requires its input and forbids the others'" begin
        # the configuration's copies of the enums agree with the engine's
        @test (collect(AnalysisConfig.VALID_ILR_PART_WEIGHTS) == ILR.VALID_PART_WEIGHTS &&
            collect(AnalysisConfig.VALID_ILR_BALANCE_WEIGHTS) == ILR.VALID_BALANCE_WEIGHTS &&
            collect(AnalysisConfig.VALID_ILR_DENDROGRAM_METHODS) == ILR.VALID_DENDROGRAM_METHODS &&
            AnalysisConfig.ILR_SBP_ATTEMPT_DANGER_THRESHOLD == ILR.SBP_ATTEMPT_DANGER_THRESHOLD)
        @test occursin("requires advanced.ilr_phylo_tree_path", refusal(() -> ilr_config(basis = "phylogenetic")))
        @test occursin("requires advanced.ilr_sbp_matrix_path", refusal(() -> ilr_config(basis = "sequential_binary_partition")))
        @test occursin("requires advanced.ilr_balance_dendrogram_method", refusal(() -> ilr_config(basis = "balance_dendrogram")))
        @test occursin("silently ignored", refusal(() -> ilr_config(basis = "default", ilr_phylo_tree_path = "t.nwk")))
        @test occursin("silently ignored", refusal(() -> ilr_config(basis = "phylogenetic", ilr_phylo_tree_path = "t.nwk", ilr_sbp_matrix_path = "s.csv")))
        @test occursin("only meaningful for the ILR transform", refusal(() -> ilr_config(norm = "clr", method = "clr_lm", ilr_balance_dendrogram_method = "ward")))
        @test occursin("default Helmert basis is unweighted", refusal(() -> ilr_config(ilr_part_weights = "gm_counts")))
        @test occursin("only ilr_basis = 'phylogenetic'", refusal(() -> ilr_config(basis = "balance_dendrogram", ilr_balance_dendrogram_method = "ward", ilr_balance_weights = "blw")))
        @test occursin("only used by ilr_basis = 'sequential_binary_partition'", refusal(() -> ilr_config(basis = "balance_dendrogram", ilr_balance_dendrogram_method = "ward", ilr_sbp_history = [digest("x")])))
        @test occursin("SHA-256", refusal(() -> AnalysisConfig.AdvancedConfig(ilr_sbp_history = ["not-a-digest"])))
        @test occursin("ward, complete, average", refusal(() -> AnalysisConfig.AdvancedConfig(ilr_balance_dendrogram_method = "single")))
        @test occursin("not allowed in a path", refusal(() -> AnalysisConfig.AdvancedConfig(ilr_phylo_tree_path = "trees/[v2].nwk")))
        @test occursin("is empty", refusal(() -> AnalysisConfig.AdvancedConfig(ilr_sbp_matrix_path = "  ")))
        c = ilr_config(basis = "balance_dendrogram", ilr_balance_dendrogram_method = "Ward", ilr_part_weights = "GM_COUNTS")
        @test c.advanced.ilr_balance_dendrogram_method == "ward" && c.advanced.ilr_part_weights == "gm_counts"
        @test !AnalysisConfig.is_dangerous(c)
    end

    @testset "configuration: hash, JSON, Nickel, DEED and help carry the ILR inputs" begin
        plain = ilr_config()
        tree = ilr_config(basis = "phylogenetic", ilr_phylo_tree_path = "data/tree.nwk", ilr_balance_weights = "blw")
        # without ILR inputs the canonical form is the pre-#20 one (no "ilr" block)
        @test !occursin("\"ilr\"", AnalysisConfig.canonical_json(plain))
        @test occursin("\"ilr\"", AnalysisConfig.canonical_json(tree))
        a = ilr_config(basis = "balance_dendrogram", ilr_balance_dendrogram_method = "ward")
        b = AnalysisConfig.AnalysisConfig(
            id = a.id, created_at = a.created_at, method = "ilr_lm", formula = "~ group", metadata_columns = ["group"],
            normalization = AnalysisConfig.NormalizationConfig(method = "ilr", pseudocount = 0.5, ilr_basis = "balance_dendrogram"),
            advanced = AnalysisConfig.AdvancedConfig(min_prevalence = 0.0, min_abundance = 0.0, ilr_balance_dendrogram_method = "average"),
            created_by = "test_ilr_basis")
        @test a.hash != b.hash                   # the clustering method is part of the identity
        back = AnalysisConfig.from_json(AnalysisConfig.to_json(tree))
        @test back.advanced.ilr_phylo_tree_path == "data/tree.nwk"
        @test back.advanced.ilr_balance_weights == "blw"
        @test back.hash == tree.hash
        # JSON written before issue #20 has no ILR keys: the defaults apply
        old = JSON3.read(AnalysisConfig.to_json(plain), Dict{String,Any})
        ilr_keys = ("ilr_phylo_tree_path", "ilr_sbp_matrix_path", "ilr_balance_dendrogram_method",
                    "ilr_part_weights", "ilr_balance_weights", "ilr_sbp_history")
        old["advanced"] = Dict{String,Any}(string(k) => v for (k, v) in pairs(old["advanced"]) if !(string(k) in ilr_keys))
        @test !occursin("ilr_part_weights", JSON3.write(old))
        legacy = AnalysisConfig.from_json(JSON3.write(old))
        @test legacy.advanced.ilr_part_weights == "uniform" && isempty(legacy.advanced.ilr_sbp_history)
        nk = AnalysisConfig.to_nickel(tree)
        @test occursin("IlrBasisInputsContract", nk) && occursin("ilr_phylo_tree_path = \"data/tree.nwk\"", nk)
        dd = AnalysisConfig.to_deed(tree)
        @test occursin(":ilr-phylo-tree-path \"data/tree.nwk\"", dd) && occursin(":ilr-balance-weights \"blw\"", dd)
        @test isempty(AnalysisConfig.validate_deed(dd))
        for f in ("normalization.ilr_basis", "advanced.ilr_phylo_tree_path", "advanced.ilr_sbp_matrix_path",
                  "advanced.ilr_balance_dendrogram_method", "advanced.ilr_part_weights",
                  "advanced.ilr_balance_weights", "advanced.ilr_sbp_history")
            h = AnalysisConfig.context_help(f)
            @test !occursin("NOT IMPLEMENTED", h) && length(h) > 200
        end
        @test occursin("Silverman", AnalysisConfig.context_help("normalization.ilr_basis"))
        @test occursin("Egozcue", AnalysisConfig.context_help("normalization.ilr_basis"))
        @test occursin("Pawlowsky-Glahn", AnalysisConfig.context_help("normalization.ilr_basis"))
    end

    @testset "configuration: more than 3 SBPs already recorded is DANGER before the run" begin
        hs = [digest("sbp$i") for i in 1:4]
        c = ilr_config(basis = "sequential_binary_partition", ilr_sbp_matrix_path = "s.csv", ilr_sbp_history = hs)
        @test AnalysisConfig.is_dangerous(c)
        @test occursin("SBP p-hacking guard", something(AnalysisConfig.danger_banner(c), ""))
        c3 = ilr_config(basis = "sequential_binary_partition", ilr_sbp_matrix_path = "s.csv", ilr_sbp_history = hs[1:3])
        @test !AnalysisConfig.is_dangerous(c3)     # the run decides, once it knows the current SBP
        # BH stays mandatory: the ILR bases do not touch the correction contract
        @test c3.correction.method == "BH" && !c3.correction.allow_no_correction
    end

    # ==================================================================================
    # Integration: AnalysisConfig -> prepare_analysis_table -> balances, checks, provenance
    # ==================================================================================

    @testset "integration: phylogenetic basis end to end, with tree hash and pruning recorded" begin
        taxa, samples, X = read_matrix(joinpath(FIX, "philr_d60_pruned", "counts.csv"))
        tp = joinpath(FIX, "philr_d60_pruned", "tree.nwk")
        cfg = ilr_config(basis = "phylogenetic", ilr_phylo_tree_path = tp, ilr_part_weights = "gm_counts")
        (prepared, diag, manifest, _, rows) = Execution.prepare_analysis_table(
            cfg, X; sample_ids = samples, taxa_ids = taxa, drop_policy = "drop")
        ref = ILR.ilr_transform(X .+ 0.5, taxa; basis = "phylogenetic", tree_path = tp, part_weights_kind = "gm_counts")
        @test rows == ref.balance_ids == ["n$i" for i in 1:59]
        @test maximum(abs.(prepared .- ref.balances)) < 1e-12
        @test diag.checks["ilr"]["basis"] == "phylogenetic"
        @test diag.checks["ilr"]["basis_details"]["pruned_tips_count"] == 15
        @test any(occursin("15 tree tips", w) for w in diag.warnings)
        prov = manifest.provenance["ilr"]
        @test prov["tree_sha256"] == bytes2hex(sha256(read(tp)))
        @test prov["part_weights"] == "gm_counts" && prov["balance_weights"] == "uniform"
        @test isnothing(prov["sbp_sha256"]) && isnothing(prov["dendrogram_method"])
    end

    @testset "integration: SBP p-hacking guard counts the current SBP" begin
        taxa, samples, X = read_matrix(joinpath(FIX, "sbp_d12", "counts.csv"))
        sp = joinpath(FIX, "sbp_d12", "sbp.csv")
        own = bytes2hex(sha256(read(sp)))
        others = [digest("earlier$i") for i in 1:3]
        # own digest + 2 others = 3 distinct SBPs: disclosed, not DANGER
        cfg = ilr_config(basis = "sequential_binary_partition", ilr_sbp_matrix_path = sp, ilr_sbp_history = [own, others[1], others[2]])
        (_, diag, manifest, _, rows) = Execution.prepare_analysis_table(cfg, X; sample_ids = samples, taxa_ids = taxa, drop_policy = "drop")
        @test rows == ["b$i" for i in 1:11]
        @test manifest.provenance["ilr"]["sbp_attempts"] == 3
        @test manifest.provenance["ilr"]["sbp_sha256"] == own
        @test !diag.is_dangerous
        # 3 others + the current one = 4 > 3: DANGER, with its own banner
        cfg4 = ilr_config(basis = "sequential_binary_partition", ilr_sbp_matrix_path = sp, ilr_sbp_history = others)
        (_, diag4, manifest4, _, _) = Execution.prepare_analysis_table(cfg4, X; sample_ids = samples, taxa_ids = taxa, drop_policy = "drop")
        @test manifest4.provenance["ilr"]["sbp_attempts"] == 4
        @test diag4.is_dangerous
        @test occursin("DANGER — ILR BASIS SELECTION", something(diag4.banner, ""))
        @test any(occursin("SBP p-hacking guard", w) for w in diag4.warnings)
    end

    @testset "integration: an SBP taxon removed by filtering is refused and named" begin
        taxa, samples, X = read_matrix(joinpath(FIX, "sbp_d12", "counts.csv"))
        X2 = copy(X); X2[5, 2:end] .= 0.0          # T5 present in 1 of 10 samples
        cfg = AnalysisConfig.AnalysisConfig(
            method = "ilr_lm", formula = "~ group", metadata_columns = ["group"],
            normalization = AnalysisConfig.NormalizationConfig(method = "ilr", pseudocount = 0.5, ilr_basis = "sequential_binary_partition"),
            advanced = AnalysisConfig.AdvancedConfig(min_prevalence = 0.5, ilr_sbp_matrix_path = joinpath(FIX, "sbp_d12", "sbp.csv")),
            created_by = "test_ilr_basis")
        m = refusal(() -> Execution.prepare_analysis_table(cfg, X2; sample_ids = samples, taxa_ids = taxa, drop_policy = "drop"))
        @test occursin("removed by prevalence/abundance filtering", m) && occursin("'T5'", m)
    end

    @testset "integration: balance dendrogram records its method and data-derived status" begin
        taxa, samples, X = read_matrix(joinpath(FIX, "dendrogram_d30", "counts.csv"))
        cfg = ilr_config(basis = "balance_dendrogram", ilr_balance_dendrogram_method = "average")
        (prepared, diag, manifest, _, rows) = Execution.prepare_analysis_table(cfg, X; sample_ids = samples, taxa_ids = taxa, drop_policy = "drop")
        @test all(startswith(r, "m") for r in rows) && length(rows) == 29
        @test diag.checks["ilr"]["basis_details"]["method"] == "average"
        @test diag.checks["ilr"]["uses_data_twice"] === true
        @test manifest.provenance["ilr"]["dendrogram_method"] == "average"
        @test size(prepared) == (29, length(samples))
    end

    @testset "integration: the default basis is untouched and records itself as such" begin
        taxa = ["t$i" for i in 1:6]
        cfg = ilr_config()
        (prepared, diag, manifest, _, rows) = Execution.prepare_analysis_table(cfg, synth(6, 4); sample_ids = ["s$j" for j in 1:4], taxa_ids = taxa, drop_policy = "drop")
        @test rows == ["balance_$i" for i in 1:5]
        @test manifest.provenance["ilr"]["basis"] == "default"
        @test startswith(diag.checks["ilr"]["definition"], "Helmert")
        # the loop's own formula, written out, for one cell
        x = synth(6, 4)[:, 2] .+ 0.5
        @test prepared[3, 2] == sqrt(3 / 4) * (sum(log.(x[1:3])) / 3 - log(x[4])) ||
              abs(prepared[3, 2] - sqrt(3 / 4) * (sum(log.(x[1:3])) / 3 - log(x[4]))) < 1e-14
    end

    # ==================================================================================
    # Performance: 100 / 1 000 / 10 000 taxa, and no dense basis
    # ==================================================================================

    # Balanced Newick over t1..tD, built without recursion depth issues (depth log2 D).
    function balanced_newick(lo, hi)
        lo == hi && return "t$lo:0.1"
        mid = (lo + hi) ÷ 2
        return "(" * balanced_newick(lo, mid) * "," * balanced_newick(mid + 1, hi) * "):0.05"
    end

    @testset "performance: 100 and 1000 taxa, all three bases" begin
        for D in (100, 1000)
            taxa = ["t$i" for i in 1:D]
            X = synth(D, 30)
            dir = mktempdir()
            tp = joinpath(dir, "tree.nwk"); write(tp, balanced_newick(1, D) * ";")
            t = @elapsed out = ILR.ilr_transform(X, taxa; basis = "phylogenetic", tree_path = tp, balance_weights_kind = "mean_descendants")
            @test size(out.balances) == (D - 1, 30)
            @test t < 60
            sp = joinpath(dir, "sbp.csv")
            W = ILR.sbp_matrix(ILR.phylo_balance_tree(balanced_newick(1, D) * ";", taxa)[1])
            open(sp, "w") do io
                println(io, "taxon,", join(["b$k" for k in 1:(D - 1)], ","))
                for i in 1:D
                    println(io, taxa[i], ",", join(W[i, :], ","))
                end
            end
            t = @elapsed out = ILR.ilr_transform(X, taxa; basis = "sequential_binary_partition", sbp_path = sp)
            @test size(out.balances) == (D - 1, 30) && t < 60
            t = @elapsed out = ILR.ilr_transform(X, taxa; basis = "balance_dendrogram", dendrogram_method = "ward")
            @test size(out.balances) == (D - 1, 30) && t < 120
        end
    end

    @testset "performance: 10 000 taxa balances allocate O(D·n), not a dense basis" begin
        D = 10_000
        taxa = ["t$i" for i in 1:D]
        X = synth(D, 5)
        bt, _ = ILR.phylo_balance_tree(balanced_newick(1, D) * ";", taxa)
        ILR.tree_balances(bt, X, ones(D), ones(D - 1))           # compile
        bytes = @allocated ILR.tree_balances(bt, X, ones(D), ones(D - 1))
        # A dense D x (D-1) basis is 8e8 bytes; the output itself is 8·(D-1)·5 = 4e5.
        @test bytes < 20_000_000
        comb = ILR.comb_tree(taxa)
        @test length(comb.balance_ids) == D - 1                   # iterative: no stack overflow
        # A comb is the SBP reconstruction's worst case: its column supports total D^2/2
        # indices. They are hash-keyed and confirmed exactly, never stored, and the round trip
        # must still be the identity.
        ctaxa = taxa[1:2000]
        cb = ILR.comb_tree(ctaxa)
        Wc = ILR.sbp_matrix(cb)
        rt = ILR.sbp_balance_tree(ctaxa, cb.balance_ids, Wc, ctaxa)
        @test rt.balance_ids == cb.balance_ids
        @test ILR.sbp_matrix(rt) == Wc
    end

    # ==================================================================================
    # R cross-check, only where the R packages are installed
    # ==================================================================================

    @testset "R cross-check (philr / compositions), skipped visibly when absent" begin
        # RCall is loaded by the scaling tests; reached through Main so that nothing here
        # depends on a macro resolving at expansion time.
        RC = isdefined(Main, :RCall) ? getfield(Main, :RCall) : nothing
        have = RC !== nothing && try
            RC.rcopy(RC.reval("all(sapply(c('philr', 'ape', 'compositions'), requireNamespace, quietly = TRUE))")) === true
        catch
            false
        end
        if !have
            @info "ILR R cross-check skipped: philr/ape/compositions are not installed (not in renv.lock). Agreement is established against the Julia reference test/fixtures/ilr/ilr_reference.jl instead."
            @test_skip false
        else
            taxa, samples, X = read_matrix(joinpath(FIX, "philr_d25", "counts.csv"))
            tp = joinpath(FIX, "philr_d25", "tree.nwk")
            RC.reval("suppressMessages(library(philr))")
            RC.globalEnv[:X] = X
            RC.globalEnv[:taxa] = taxa
            RC.globalEnv[:samples] = samples
            RC.globalEnv[:tp] = tp
            Rres = RC.rcopy(RC.reval("""
                x <- t(X); colnames(x) <- taxa; rownames(x) <- samples
                tr <- ape::read.tree(tp)
                unname(as.matrix(philr(x, tr, part.weights = 'anorm', ilr.weights = 'blw', return.all = FALSE)))
            """))
            bt, _ = ILR.phylo_balance_tree(read(tp, String), taxa)
            bw, _ = ILR.balance_weights(bt, "blw")
            B = ILR.tree_balances(bt, X, ILR.part_weights(X, "anorm"), bw)
            @test maximum(abs.(permutedims(Rres) .- B)) < 1e-6
        end
    end
end
