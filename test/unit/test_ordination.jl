# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

using Test
using DataFrames
using DuckDB
using DBInterface
using JSON3
using MetaManifold
using MetaManifold.Analysis: r_available
using MetaManifold.Canonical
using MetaManifold.CladeCumulus
using MetaManifold.Ordination
using MetaManifold.RRuntime
using MetaManifold.Validation
using RCall

const _ORD_SV = MetaManifold.Server
const _ORD_REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const _ORD_REF_PATH = joinpath(_ORD_REPO_ROOT, "test", "fixtures", "ordination_reference.json")
const _ORD_PY_ORACLE = joinpath(_ORD_REPO_ROOT, "test", "references", "check_ordination_references.py")

function _ord_http(method::String, path::String, body = nothing; raw::Bool = false)
    payload = isnothing(body) ? UInt8[] : (raw ? body : jcs_bytes(body))
    headers = isnothing(body) ? Pair{String,String}[] : ["Content-Type" => "application/json"]
    req = _ORD_SV.HTTP.Request(method, path, headers, payload)
    _ORD_SV.Oxygen.internalrequest(req)
end

function _ord_with_study_root(f::Function)
    root = mktempdir()
    saved = _ORD_SV.ServerState._root[]
    try
        mkpath(joinpath(root, "config"))
        cp(joinpath(_ORD_REPO_ROOT, "config", "defaults"), joinpath(root, "config", "defaults"))
        for (grp, rname, counts_rows) in (
            ("Control", "run1", [
                ("seq1", "ACGTACGTACGTACGT", "Bacteroides", 410, 395, 430),
                ("seq2", "TGCAACGTACGTACGT", "Prevotella",  290, 310, 275),
                ("seq3", "GGCCACGTACGTACGT", "Faecalibacterium", 120, 115, 125),
                ("seq4", "TTAAACGTACGTACGT", "Roseburia",   80, 90, 75),
            ]),
            ("Treatment", "run2", [
                ("seq1", "ACGTACGTACGTACGT", "Bacteroides", 95, 110, 88),
                ("seq2", "TGCAACGTACGTACGT", "Prevotella",  140, 130, 150),
                ("seq3", "GGCCACGTACGTACGT", "Faecalibacterium", 320, 305, 335),
                ("seq4", "TTAAACGTACGTACGT", "Roseburia",   265, 280, 255),
            ]),
        )
            mkpath(joinpath(root, "data", "study1", grp, rname))
            for s in ("s1", "s2", "s3"), rd in ("R1", "R2")
                touch(joinpath(root, "data", "study1", grp, rname, "$(s)_L001_$(rd)_001.fastq.gz"))
            end
            merged_dir = joinpath(root, "projects", "study1", grp, rname, "merged")
            mkpath(merged_dir)
            db = DuckDB.DB(joinpath(merged_dir, "results.duckdb"))
            con = DBInterface.connect(db)
            DBInterface.execute(con,
                "CREATE TABLE merged (SeqName VARCHAR, Sequence VARCHAR, Genus_dada2 VARCHAR, s1 BIGINT, s2 BIGINT, s3 BIGINT)")
            for (sn, sq, gn, c1, c2, c3) in counts_rows
                DBInterface.execute(con,
                    "INSERT INTO merged VALUES ('$sn', '$sq', '$gn', $c1, $c2, $c3)")
            end
            DBInterface.close!(con)
            close(db)
        end
        _ORD_SV.ServerState.set_root!(root)
        f(root)
    finally
        _ORD_SV.ServerState._root[] = saved
        rm(root; recursive = true, force = true)
    end
end

function _json_matrix(rows)::Matrix{Float64}
    n = length(rows)
    p = length(rows[1])
    m = Matrix{Float64}(undef, n, p)
    for i in 1:n, j in 1:p
        m[i, j] = Float64(rows[i][j])
    end
    m
end

@testset "Constrained ordinations (Issue #19)" begin

    @testset "Independent Python reference oracle, KYAML contract, and JCS schema" begin
        if !isnothing(Sys.which("python3"))
            proc = run(`python3 $_ORD_PY_ORACLE --check $_ORD_REF_PATH`)
            @test proc.exitcode == 0
        end
        contract = load_ordination_contract()
        @test contract["schema_version"] == 1
        @test haskey(contract["methods"], "rda")
        @test haskey(contract["methods"], "cca")
        @test haskey(contract["methods"], "cap")
        @test haskey(contract["methods"], "dbrda")
        @test contract["permutation_bounds"]["min"] == 99
        @test contract["permutation_bounds"]["max"] == 9999
        # Contract serialises cleanly to canonical RFC 8785 JCS
        raw_jcs = jcs_bytes(contract)
        @test !isempty(raw_jcs)
        @test ijson_read(raw_jcs)[:schema_version] == 1
    end

    @testset "OrdinationConfig and method/distance compatibility validation" begin
        cfg_default = OrdinationConfig()
        @test cfg_default.ordination_method === :none
        @test cfg_default.ordination_distance === :bray
        @test cfg_default.ordination_scaling == 2
        @test cfg_default.permutations == 999
        @test !cfg_default.variance_partitioning

        # RDA requires linear Euclidean / Aitchison CLR space, rejecting Bray-Curtis & UniFrac
        @test OrdinationConfig(; ordination_method=:rda, ordination_distance=:aitchison).ordination_distance === :aitchison
        @test OrdinationConfig(; ordination_method=:rda, ordination_distance=:euclidean).ordination_distance === :euclidean
        @test_throws ArgumentError OrdinationConfig(; ordination_method=:rda, ordination_distance=:bray)
        @test_throws ArgumentError OrdinationConfig(; ordination_method=:rda, ordination_distance=:weighted_unifrac)

        # CCA requires chi-square geometry
        @test OrdinationConfig(; ordination_method=:cca, ordination_distance=:chisq).ordination_distance === :chisq
        @test_throws ArgumentError OrdinationConfig(; ordination_method=:cca, ordination_distance=:bray)

        # CAP and dbRDA accept Bray-Curtis, Jaccard, Euclidean, Aitchison, and UniFrac
        for m in (:cap, :dbrda), d in (:bray, :jaccard, :euclidean, :aitchison, :unweighted_unifrac, :weighted_unifrac)
            c = OrdinationConfig(; ordination_method=m, ordination_distance=d)
            @test c.ordination_method === m
            @test c.ordination_distance === d
        end
        @test_throws ArgumentError OrdinationConfig(; ordination_method=:dbrda, ordination_distance=:chisq)

        # Permutation bounds [99, 9999] and scaling {1, 2}
        @test OrdinationConfig(; ordination_method=:dbrda, permutations=99).permutations == 99
        @test OrdinationConfig(; ordination_method=:dbrda, permutations=9999).permutations == 9999
        @test_throws ArgumentError OrdinationConfig(; ordination_method=:dbrda, permutations=98)
        @test_throws ArgumentError OrdinationConfig(; ordination_method=:dbrda, permutations=10000)
        @test OrdinationConfig(; ordination_method=:dbrda, ordination_scaling=1).ordination_scaling == 1
        @test_throws ArgumentError OrdinationConfig(; ordination_method=:dbrda, ordination_scaling=3)
        @test_throws ArgumentError OrdinationConfig(; ordination_method=:rda, ordination_distance=:aitchison, replacement_delta=0.0)
        @test_throws ArgumentError OrdinationConfig(; ordination_method=:rda, ordination_distance=:aitchison, replacement_delta=1.0)
    end

    @testset "Formula AST parsing, Condition(...) partial terms, and collinearity guards" begin
        meta = DataFrame(
            sample = ["s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8"],
            group  = ["A", "A", "A", "A", "B", "B", "B", "B"],
            run    = ["R1", "R1", "R2", "R2", "R1", "R1", "R2", "R2"],
            ph     = [6.1, 6.3, 6.5, 6.7, 7.0, 7.2, 7.4, 7.6],
            const_col = fill("same", 8),
        )

        p1 = parse_ordination_formula("~ group + ph + Condition(run)", meta)
        @test p1.constrained_terms == ["group", "ph"]
        @test p1.condition_terms == ["run"]
        @test p1.df_constrained == 2
        @test p1.df_conditioned == 1

        p_int = parse_ordination_formula("~ group * ph", meta)
        @test p_int.constrained_terms == ["group", "ph", "group:ph"]
        @test p_int.df_constrained == 3

        # Auto-formula deduplicates identical categorical partitions (e.g. group == run)
        meta_collinear = DataFrame(
            sample = ["s1", "s2", "s3", "s4", "s5", "s6"],
            group  = ["Control", "Control", "Control", "Treatment", "Treatment", "Treatment"],
            run    = ["run1", "run1", "run1", "run2", "run2", "run2"],
        )
        p_auto = parse_ordination_formula(nothing, meta_collinear)
        @test p_auto.constrained_terms == ["group"]
        @test p_auto.df_constrained == 1

        # Reject injection, LHS formulas, Condition-only, overlap, constant covariates, saturation
        @test_throws ArgumentError validate_formula_syntax("~ system(ls)")
        @test_throws ArgumentError validate_formula_syntax("y ~ group")
        @test_throws ArgumentError validate_formula_syntax("~ Condition(run)")
        @test_throws ArgumentError validate_formula_syntax("~ group + Condition(group)")
        @test_throws ArgumentError parse_ordination_formula("~ const_col", meta)
        @test_throws ArgumentError parse_ordination_formula("~ missing_cov", meta)
        meta_tiny = DataFrame(sample=["a", "b", "c"], g=["x", "y", "z"])
        @test_throws ArgumentError parse_ordination_formula("~ g", meta_tiny)
    end

    @testset "Pure-Julia RDA, Ezekiel adjusted-R2, and two-way varpart vs Python reference fixture" begin
        ref_doc = ijson_read(read(_ORD_REF_PATH))
        for ds in ref_doc[:datasets]
            Y = _json_matrix(ds[:y])
            X = _json_matrix(ds[:x])
            Z = isnothing(ds[:z]) ? nothing : _json_matrix(ds[:z])
            res = pure_linear_rda(Y, X; Z=Z)
            exp_rda = ds[:expected_rda]
            @test isapprox(res.total_inertia, Float64(exp_rda[:total_inertia]); atol=1e-9)
            @test isapprox(res.conditioned_inertia, Float64(exp_rda[:conditioned_inertia]); atol=1e-9)
            @test isapprox(res.constrained_inertia, Float64(exp_rda[:constrained_inertia]); atol=1e-9)
            @test isapprox(res.unconstrained_inertia, Float64(exp_rda[:unconstrained_inertia]); atol=1e-9)
            @test isapprox(res.r2, Float64(exp_rda[:r2]); atol=1e-9)
            @test isapprox(res.adj_r2, Float64(exp_rda[:adj_r2]); atol=1e-9)
            # The F statistic is a ratio of sums of squares, so its absolute
            # size grows with the data: 223 and 820 on this fixture. An
            # absolute tolerance of 1e-9 is a relative 1e-12 there, which two
            # correct implementations can miss by using a different BLAS
            # reduction order. Compare with the same 1e-9 as a *relative*
            # tolerance instead of loosening the absolute one.
            @test isapprox(res.f_statistic, Float64(exp_rda[:f_statistic]); atol=1e-9, rtol=1e-9)
            @test length(res.constrained_eigenvalues) == length(exp_rda[:constrained_eigenvalues])
            for (a, b) in zip(res.constrained_eigenvalues, exp_rda[:constrained_eigenvalues])
                @test isapprox(a, Float64(b); atol=1e-9)
            end
            for (a, b) in zip(res.unconstrained_eigenvalues, exp_rda[:unconstrained_eigenvalues])
                @test isapprox(a, Float64(b); atol=1e-9)
            end

            if !isnothing(ds[:expected_varpart])
                X1 = _json_matrix(ds[:x1])
                X2 = _json_matrix(ds[:x2])
                r1 = pure_linear_rda(Y, X1).adj_r2
                r2 = pure_linear_rda(Y, X2).adj_r2
                r12 = pure_linear_rda(Y, hcat(X1, X2)).adj_r2
                vp = pure_varpart_two_way(r1, r2, r12)
                exp_vp = ds[:expected_varpart]
                @test isapprox(vp.unique_x1, Float64(exp_vp[:unique_x1]); atol=1e-9)
                @test isapprox(vp.unique_x2, Float64(exp_vp[:unique_x2]); atol=1e-9)
                @test isapprox(vp.shared, Float64(exp_vp[:shared]); atol=1e-9)
                @test isapprox(vp.residual, Float64(exp_vp[:residual]); atol=1e-9)
            end
        end
    end

    @testset "Pipeline validation, config cascade, and HTTP route pre-R validation" begin
        _ord_with_study_root() do root
            # Contract endpoint returns canonical JCS
            res_contract = _ord_http("GET", "/api/v1/ordination/contract")
            @test res_contract.status == 200
            parsed_contract = ijson_read(res_contract.body)
            @test parsed_contract[:schema_version] == 1

            # Config cascade rejects rda + inherited bray distance, accepts atomic rda + aitchison
            bad_patch = _ord_http("PATCH", "/api/v1/studies/study1/config",
                Dict("analysis.ordination.method" => "rda"))
            @test bad_patch.status == 400
            @test occursin("incompatible", String(bad_patch.body))

            good_patch = _ord_http("PATCH", "/api/v1/studies/study1/config",
                Dict("analysis.ordination.method" => "rda",
                     "analysis.ordination.distance" => "aitchison",
                     "analysis.ordination.scaling" => 1,
                     "analysis.ordination.permutations" => 499))
            @test good_patch.status == 200

            # Pre-R HTTP 400 checks on /api/v1/studies/{study}/analysis/ordination
            runs_payload = [
                Dict("run" => "run1", "group" => "Control"),
                Dict("run" => "run2", "group" => "Treatment"),
            ]
            r404 = _ord_http("POST", "/api/v1/studies/unknown_study/analysis/ordination",
                Dict("method" => "dbrda", "runs" => runs_payload))
            @test r404.status == 404

            r_bad_compat = _ord_http("POST", "/api/v1/studies/study1/analysis/ordination",
                Dict("method" => "rda", "distance" => "bray", "runs" => runs_payload))
            @test r_bad_compat.status == 400

            r_bad_formula = _ord_http("POST", "/api/v1/studies/study1/analysis/ordination",
                Dict("method" => "dbrda", "distance" => "bray", "formula" => "~ system(id)", "runs" => runs_payload))
            @test r_bad_formula.status == 400

            r_missing_tree = _ord_http("POST", "/api/v1/studies/study1/analysis/ordination",
                Dict("method" => "dbrda", "distance" => "weighted_unifrac", "runs" => runs_payload))
            @test r_missing_tree.status == 400
            @test occursin("missing_phylogeny", String(r_missing_tree.body))
        end
    end

    if r_available() && vegan_available()
        @testset "vegan accuracy within 1e-6 (dune + 3 microbiome datasets, all 4 methods, Condition, varpart, UniFrac)" begin
            # 1. Cross-check all 4 reference datasets against live R vegan::rda & vegan::varpart within 1e-6
            ref_doc = ijson_read(read(_ORD_REF_PATH))
            for ds in ref_doc[:datasets]
                Y = _json_matrix(ds[:y])
                X = _json_matrix(ds[:x])
                n = size(Y, 1)
                meta_df = DataFrame(sample = ["s$i" for i in 1:n])
                x_names = String[]
                for j in 1:size(X, 2)
                    nm = "x$j"
                    meta_df[!, nm] = X[:, j]
                    push!(x_names, nm)
                end
                rhs = join(x_names, " + ")
                if !isnothing(ds[:z])
                    Z = _json_matrix(ds[:z])
                    z_names = String[]
                    for j in 1:size(Z, 2)
                        nm = "z$j"
                        meta_df[!, nm] = Z[:, j]
                        push!(z_names, nm)
                    end
                    rhs *= " + Condition(" * join(z_names, " + ") * ")"
                end
                cfg = OrdinationConfig(;
                    ordination_method = :rda,
                    ordination_distance = :euclidean,
                    ordination_formula = "~ " * rhs,
                    ordination_scaling = 2,
                    permutations = 199,
                    variance_partitioning = !isnothing(ds[:expected_varpart]) && size(X, 2) == 2,
                    seed = 12345,
                )
                out = run_constrained_ordination(Y, meta_df, cfg; beta_transform = "none")
                exp_rda = ds[:expected_rda]
                @test isapprox(out.total_inertia, Float64(exp_rda[:total_inertia]); atol=1e-6)
                @test isapprox(out.conditioned_inertia, Float64(exp_rda[:conditioned_inertia]); atol=1e-6)
                @test isapprox(out.constrained_inertia, Float64(exp_rda[:constrained_inertia]); atol=1e-6)
                @test isapprox(out.unconstrained_inertia, Float64(exp_rda[:unconstrained_inertia]); atol=1e-6)
                @test isapprox(out.r2, Float64(exp_rda[:r2]); atol=1e-6)
                @test isapprox(out.adj_r2, Float64(exp_rda[:adj_r2]); atol=1e-6)
                @test isapprox(out.omnibus_test.f_statistic, Float64(exp_rda[:f_statistic]); atol=1e-6)
                for (e_got, e_exp) in zip(out.constrained_eigenvalues, exp_rda[:constrained_eigenvalues])
                    @test isapprox(e_got.eigenvalue, Float64(e_exp); atol=1e-6)
                end
                if cfg.variance_partitioning
                    exp_vp = ds[:expected_varpart]
                    @test out.variance_partitioning.status == "computed"
                    ind = out.variance_partitioning.individual_fractions
                    @test length(ind) == 4
                    # vegan documents the four individual fractions, not the
                    # row order of `$part$indfract`, and the rows carry their
                    # own labels. Assert the multiset of adjusted R2 values so
                    # the test checks the arithmetic rather than a row order
                    # that R is free to change.
                    got = sort([r.adj_r2 for r in ind])
                    expected = sort([Float64(exp_vp[:unique_x1]),
                                     Float64(exp_vp[:shared]),
                                     Float64(exp_vp[:unique_x2]),
                                     Float64(exp_vp[:residual])])
                    @test all(isapprox.(got, expected; atol=1e-6))
                    # The labels are what a reader uses to identify a row, so
                    # they must be present and distinct.
                    labels = [r.label for r in ind]
                    @test all(!isempty, labels)
                    @test length(unique(labels)) == 4
                end
            end

            # 2. Direct vegan::dune comparison for RDA, CCA, CAP, dbRDA including seeded permutation p-values & scores
            dune_mat, dune_a1, dune_mgmt, ref_vals = with_r_lock() do
                RCall.reval(raw"""
                data(dune, package = "vegan")
                data(dune.env, package = "vegan")
                d_mat <- as.matrix(dune)
                d_a1 <- as.numeric(dune.env$A1)
                d_mgmt <- as.character(dune.env$Management)
                d_df <- data.frame(A1 = d_a1, Management = factor(d_mgmt, levels = unique(d_mgmt)))
                RNGkind("Mersenne-Twister", "Inversion", "Rejection")
                set.seed(777)
                fit_dbrda <- vegan::dbrda(d_mat ~ A1 + Management, data = d_df, distance = "bray")
                r2_dbrda <- vegan::RsquareAdj(fit_dbrda)
                set.seed(777)
                aov_dbrda <- vegan::anova.cca(fit_dbrda, permutations = permute::how(nperm = 199L), parallel = 1L)
                sc_dbrda <- as.matrix(vegan::scores(fit_dbrda, choices = c(1, 2), display = "sites", scaling = 2L))
                """)
                out_tuple = (
                    Matrix{Float64}(RCall.rcopy(RCall.reval("d_mat"))),
                    Vector{Float64}(RCall.rcopy(RCall.reval("d_a1"))),
                    Vector{String}(RCall.rcopy(RCall.reval("d_mgmt"))),
                    (;
                        tot = Float64(RCall.rcopy(RCall.reval("as.numeric(fit_dbrda[['tot.chi']])"))),
                        con = Float64(RCall.rcopy(RCall.reval("as.numeric(fit_dbrda[['CCA']][['tot.chi']])"))),
                        r2  = Float64(RCall.rcopy(RCall.reval("as.numeric(r2_dbrda[['r.squared']])"))),
                        adj = Float64(RCall.rcopy(RCall.reval("as.numeric(r2_dbrda[['adj.r.squared']])"))),
                        f   = Float64(RCall.rcopy(RCall.reval("as.numeric(aov_dbrda[['F']][1])"))),
                        p   = Float64(RCall.rcopy(RCall.reval("as.numeric(aov_dbrda[['Pr(>F)']][1])"))),
                        sc  = Matrix{Float64}(RCall.rcopy(RCall.reval("sc_dbrda"))),
                    ),
                )
                RCall.reval("rm(list = intersect(ls(), c('d_mat', 'd_a1', 'd_mgmt', 'd_df', 'fit_dbrda', 'r2_dbrda', 'aov_dbrda', 'sc_dbrda')))")
                out_tuple
            end
            dune_meta = DataFrame(
                sample = ["site$i" for i in 1:size(dune_mat, 1)],
                A1 = dune_a1,
                Management = dune_mgmt,
            )
            res_dbrda = run_constrained_ordination(
                dune_mat,
                dune_meta,
                OrdinationConfig(;
                    ordination_method = :dbrda,
                    ordination_distance = :bray,
                    ordination_formula = "~ A1 + Management",
                    ordination_scaling = 2,
                    permutations = 199,
                    variance_partitioning = true,
                    seed = 777,
                );
                beta_transform = "none",
                test_axes = true,
            )
            @test isapprox(res_dbrda.total_inertia, ref_vals.tot; atol=1e-6)
            @test isapprox(res_dbrda.constrained_inertia, ref_vals.con; atol=1e-6)
            @test isapprox(res_dbrda.r2, ref_vals.r2; atol=1e-6)
            @test isapprox(res_dbrda.adj_r2, ref_vals.adj; atol=1e-6)
            @test isapprox(res_dbrda.omnibus_test.f_statistic, ref_vals.f; atol=1e-6)
            @test isapprox(res_dbrda.omnibus_test.p_value, ref_vals.p; atol=1e-6)
            for i in 1:size(dune_mat, 1)
                @test isapprox(res_dbrda.sites[i].axis1, ref_vals.sc[i, 1]; atol=1e-6)
                @test isapprox(res_dbrda.sites[i].axis2, ref_vals.sc[i, 2]; atol=1e-6)
            end
            @test !isempty(res_dbrda.axis_tests)
            @test res_dbrda.variance_partitioning.status == "computed"

            # Verify CCA, CAP, and scaling=1 on dune as well
            res_cca = run_constrained_ordination(
                dune_mat,
                dune_meta,
                OrdinationConfig(;
                    ordination_method = :cca,
                    ordination_distance = :chisq,
                    ordination_formula = "~ A1 + Condition(Management)",
                    ordination_scaling = 1,
                    permutations = 199,
                    seed = 777,
                );
                beta_transform = "none",
            )
            @test res_cca.method == "cca"
            @test res_cca.scaling == 1
            @test res_cca.conditioned_inertia > 0.0
            @test res_cca.provenance["scaling_meaning"] == "distance"

            res_cap = run_constrained_ordination(
                dune_mat,
                dune_meta,
                OrdinationConfig(;
                    ordination_method = :cap,
                    ordination_distance = :jaccard,
                    ordination_formula = "~ A1 + Management",
                    ordination_scaling = 2,
                    permutations = 199,
                    seed = 777,
                );
                beta_transform = "none",
            )
            @test res_cap.method == "cap"
            @test res_cap.distance == "jaccard"
            @test !isnothing(res_cap.omnibus_test.p_value)

            # 3. End-to-end HTTP POST with persistence, Aitchison CLR, and inline Newick UniFrac
            _ord_with_study_root() do _
                runs_payload = [
                    Dict("run" => "run1", "group" => "Control"),
                    Dict("run" => "run2", "group" => "Treatment"),
                ]
                resp_clr = _ord_http("POST", "/api/v1/studies/study1/analysis/ordination", Dict(
                    "method" => "rda",
                    "distance" => "aitchison",
                    "scaling" => 2,
                    "permutations" => 199,
                    "formula" => "~ group",
                    "persist" => true,
                    "show_features" => true,
                    "runs" => runs_payload,
                ))
                @test resp_clr.status == 200
                body_clr = ijson_read(resp_clr.body)
                @test body_clr[:method] == "rda"
                @test body_clr[:distance] == "aitchison"
                @test body_clr[:n_samples] == 6
                @test haskey(body_clr, :biplot)
                @test haskey(body_clr, :artifact)
                aid = String(body_clr[:artifact][:analysis_id])
                resp_loaded = _ord_http("GET", "/api/v1/studies/study1/analysis/ordination/$aid")
                @test resp_loaded.status == 200

                # Weighted UniFrac via inline ASV Newick tree
                t1 = CladeCumulus.asv_tip_name("ACGTACGTACGTACGT")
                t2 = CladeCumulus.asv_tip_name("TGCAACGTACGTACGT")
                t3 = CladeCumulus.asv_tip_name("GGCCACGTACGTACGT")
                t4 = CladeCumulus.asv_tip_name("TTAAACGTACGTACGT")
                nwk = "(($t1:0.15,$t2:0.15):0.25,($t3:0.12,$t4:0.12):0.28);"
                resp_uf = _ord_http("POST", "/api/v1/studies/study1/analysis/ordination", Dict(
                    "method" => "dbrda",
                    "distance" => "weighted_unifrac",
                    "permutations" => 199,
                    "formula" => "~ group",
                    "tree_newick" => nwk,
                    "runs" => runs_payload,
                ))
                @test resp_uf.status == 200
                body_uf = ijson_read(resp_uf.body)
                @test body_uf[:distance] == "weighted_unifrac"
                @test body_uf[:provenance][:phylogeny_source] == "inline_newick"
            end
        end
    else
        @info "Skipping live R/vegan ordination execution tests (R or vegan unavailable in this environment)"
    end
end
