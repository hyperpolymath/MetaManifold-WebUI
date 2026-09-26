# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Evidence for issue #21's dispersion work: the pure-Julia port of glmGamPoi's dispersion
# pipeline, and the reason it is a port rather than an alias for a different estimator
# (docs/statistics/method-conditions/dispersion-glmGamPoi.md).
#
# The numbers come from test/fixtures/issue21/golden.json, whose `generator` block says
# exactly how far they can be trusted: they are a pinned transcription of the published
# method and of const-ae/glmGamPoi's source, not a live call into the R package. Where R and
# glmGamPoi are installed (CI installs them) the module is compared against the package
# itself, and that is the strongest evidence in this file. Where they are not, the test says
# so instead of passing quietly.

using Test
using JSON3
using MetaManifold.Dispersion

const DISPERSION_GOLDEN = JSON3.read(read(joinpath(@__DIR__, "..", "fixtures", "issue21",
                                                   "golden.json"), String)).dispersion

disp_matrix(rows) = begin
    M = Matrix{Float64}(undef, length(rows), length(rows[1]))
    for i in 1:length(rows), j in 1:length(rows[1])
        M[i, j] = Float64(rows[i][j])
    end
    M
end

disp_vector(vals) = Float64[Float64(v) for v in vals]

@testset "dispersion (issue #21)" begin

    @testset "the fixture's shape is the shape the module takes" begin
        @test size(disp_matrix(DISPERSION_GOLDEN.counts)) ==
              size(disp_matrix(DISPERSION_GOLDEN.means))
        @test size(disp_matrix(DISPERSION_GOLDEN.design), 1) ==
              size(disp_matrix(DISPERSION_GOLDEN.counts), 2)
    end

    @testset "estimate_dispersions reproduces the reference pipeline" begin
        counts = disp_matrix(DISPERSION_GOLDEN.counts)
        means = disp_matrix(DISPERSION_GOLDEN.means)
        design = disp_matrix(DISPERSION_GOLDEN.design)
        outcome = estimate_dispersions(counts, means; design = design)
        @test outcome.overdispersion ≈ disp_vector(DISPERSION_GOLDEN.dispersion_trend) rtol = 1e-6
        @test outcome.raw_mle ≈ disp_vector(DISPERSION_GOLDEN.raw_mle) atol = 1e-8
        @test outcome.gene_means ≈ disp_vector(DISPERSION_GOLDEN.gene_means) rtol = 1e-9
        @test outcome.df ≈ Float64(DISPERSION_GOLDEN.residual_df)
        @test outcome.ql_dispersion ≈ disp_vector(DISPERSION_GOLDEN.ql_disp_estimate) rtol = 1e-6
        @test outcome.trend ≈ outcome.overdispersion rtol = 1e-9
    end

    @testset "theta is 1/alpha, and the fit's theta is the one recorded" begin
        counts = disp_matrix(DISPERSION_GOLDEN.counts)
        means = disp_matrix(DISPERSION_GOLDEN.means)
        design = disp_matrix(DISPERSION_GOLDEN.design)
        outcome = estimate_dispersions(counts, means; design = design)
        @test outcome.theta ≈ disp_vector(DISPERSION_GOLDEN.theta_used_by_the_fit) rtol = 1e-6
        for i in eachindex(outcome.overdispersion)
            @test outcome.theta[i] ≈ 1.0 / outcome.overdispersion[i] rtol = 1e-12
        end
        # alpha = 0 is the Poisson boundary, and it is spelled Inf rather than 0 or NaN:
        # MASS::negative.binomial(theta) takes theta, and theta -> Inf is a Poisson fit.
        # Shrinkage lifts the raw zeros of features 1, 3 and 5 to the trend, so the boundary is
        # exercised on the unshrunk path, where the fixture's raw MLE really is 0.
        unshrunk = estimate_dispersions(counts, means; design = design, shrinkage = false)
        @test all(==(0.0), unshrunk.overdispersion[[1, 3, 5]])
        @test all(isinf, unshrunk.theta[[1, 3, 5]])
    end

    @testset "shrinkage moves the estimate toward the prior, never past it" begin
        counts = disp_matrix(DISPERSION_GOLDEN.counts)
        means = disp_matrix(DISPERSION_GOLDEN.means)
        design = disp_matrix(DISPERSION_GOLDEN.design)
        outcome = estimate_dispersions(counts, means; design = design)
        ql = outcome.ql_dispersion
        prior = outcome.ql_trend
        shrunk = outcome.diagnostics["ql_disp_shrunken"]
        for i in eachindex(shrunk)
            lo = min(ql[i], prior[i])
            hi = max(ql[i], prior[i])
            @test lo - 1e-12 <= shrunk[i] <= hi + 1e-12
        end
        @test Float64(outcome.ql_df0) ≈ Float64(DISPERSION_GOLDEN.ql_df0) rtol = 1e-4
        @test count(isfinite, [Float64(v) for v in shrunk]) == length(shrunk)
    end

    @testset "overdispersion_mle: the reference's early returns" begin
        # All-zero counts: the reference returns 0 without iterating.
        r = overdispersion_mle(zeros(6), fill(1.0, 6))
        @test r.estimate == 0.0
        @test r.iterations == 0
        @test occursin("0", r.message)
        # A feature whose mean is essentially zero at every sample: alpha -> 0 (Poisson end).
        r2 = overdispersion_mle([0.0, 1.0, 0.0, 0.0], fill(1e-6, 4))
        @test r2.estimate >= 0.0
        @test isfinite(r2.estimate)
        # A wildly overdispersed feature stays finite and non-negative.
        r3 = overdispersion_mle([0.0, 100.0, 0.0, 100.0], fill(50.0, 4))
        @test r3.estimate > 0.0
        @test isfinite(r3.estimate)
    end

    @testset "overdispersion_mle: Cox-Reid changes the answer, and is the default" begin
        counts = disp_matrix(DISPERSION_GOLDEN.counts)
        means = disp_matrix(DISPERSION_GOLDEN.means)
        design = disp_matrix(DISPERSION_GOLDEN.design)
        y = counts[4, :]
        mu = means[4, :]
        with_cr = overdispersion_mle(y, mu; design = design, do_cox_reid_adjustment = true)
        without_cr = overdispersion_mle(y, mu; design = design, do_cox_reid_adjustment = false)
        @test with_cr.estimate != without_cr.estimate
        @test with_cr.estimate ≈ Float64(DISPERSION_GOLDEN.raw_mle[4]) rtol = 1e-6
    end

    @testset "overdispersion_mle: refusals" begin
        @test_throws ArgumentError overdispersion_mle([1.0, 2.0], [1.0])
        @test_throws ArgumentError overdispersion_mle([1.0, -1.0], [1.0, 1.0])
        @test_throws ArgumentError overdispersion_mle([1.0, 2.0], [1.0, NaN])
        @test_throws ArgumentError overdispersion_mle([1.0, 2.0], [1.0, 1.0]; design = [1.0 2.0 3.0])
    end

    @testset "loc_median_fit is the reference's weighted median, not a running mean" begin
        # A single outlier must not drag the trend at its own location: the weighted median
        # is robust where a mean is not, and that robustness is the reason glmGamPoi uses it.
        x = collect(1.0:20.0)
        y = fill(0.1, 20)
        y[10] = 100.0
        trend = loc_median_fit(x, y)
        @test length(trend) == 20
        @test maximum(abs.(trend .- 0.1)) < 0.01
        # Endpoints are filled rather than dropped: every feature gets a trend value.
        @test all(isfinite, trend)
        # A constant input gives a constant trend.
        @test all(≈(0.5), loc_median_fit(x, fill(0.5, 20)))
    end

    @testset "variance_prior: the degenerate Poisson case and the fitted case" begin
        # s2 == 1 everywhere is the reference's Poisson case: the prior is degenerate, df0 is
        # Inf, and the posterior is the sample value exactly.
        pr = variance_prior(fill(1.0, 10), fill(9.0, 10))
        @test pr.df0 == Inf
        @test all(==(1.0), pr.var_post)
        cols = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
        pr2 = variance_prior(cols, fill(9.0, 10))
        @test isfinite(pr2.df0)
        @test pr2.df0 > 0
        @test all(>(0.0), pr2.variance0)
        # The posterior is a weighted average of prior and sample: bounded by the two.
        for i in eachindex(cols)
            lo = min(pr2.variance0[i], cols[i])
            hi = max(pr2.variance0[i], cols[i])
            @test lo - 1e-9 <= pr2.var_post[i] <= hi + 1e-9
        end
    end

    @testset "the spline abundance trend is refused by name, not aliased" begin
        counts = disp_matrix(DISPERSION_GOLDEN.counts)
        means = disp_matrix(DISPERSION_GOLDEN.means)
        err = try
            estimate_dispersions(counts, means; abundance_trend = true)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("not ported", sprint(showerror, err))
        @test occursin("abundance_trend", sprint(showerror, err))
    end

    @testset "a table at or above the spline threshold is refused unless the deviation is asked for" begin
        n_features = SPLINE_TREND_MIN_FEATURES
        # Deterministic, so a failure is reproducible: a ramp with a gentle wave.
        counts = [Float64(1 + (i % 7) + (j % 3)) for i in 1:n_features, j in 1:6]
        means = counts ./ 2.0
        err = try
            estimate_dispersions(counts, means)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(string(SPLINE_TREND_MIN_FEATURES), sprint(showerror, err))
        # The explicit non-trended form is the reference's own behaviour for a numeric
        # argument, and asking for it is how a big table is still analysed.
        design = [1.0 0.0; 1.0 0.0; 1.0 0.0; 1.0 1.0; 1.0 1.0; 1.0 1.0]
        outcome = estimate_dispersions(counts, means; design = design,
                                       abundance_trend = false)
        @test length(outcome.overdispersion) == n_features
        @test occursin("non-trended", outcome.diagnostics["abundance_trend"])
    end

    @testset "shrinkage can be turned off, and says what that costs" begin
        counts = disp_matrix(DISPERSION_GOLDEN.counts)
        means = disp_matrix(DISPERSION_GOLDEN.means)
        outcome = estimate_dispersions(counts, means; shrinkage = false)
        @test outcome.trend === nothing
        @test any(occursin("noisiest", n) for n in outcome.notes)
        @test outcome.overdispersion ≈ disp_vector(DISPERSION_GOLDEN.raw_mle) atol = 1e-8
    end

    @testset "provenance names the reference and the port's boundary" begin
        counts = disp_matrix(DISPERSION_GOLDEN.counts)
        means = disp_matrix(DISPERSION_GOLDEN.means)
        outcome = estimate_dispersions(counts, means)
        @test occursin("glmGamPoi", string(outcome.provenance))
        @test occursin("Ahlmann-Eltze", string(outcome.provenance))
        @test occursin("spline", lowercase(string(outcome.provenance)))
    end

    @testset "the R reference, where R and glmGamPoi are installed" begin
        rscript = Sys.which("Rscript")
        if isnothing(rscript)
            @testset "Rscript absent — the glmGamPoi comparison did NOT run" begin
                @test true
                @info "dispersion: Rscript is not on PATH; the glmGamPoi parity test was skipped, which is not evidence of parity"
            end
        else
            scripts = """
            suppressMessages(requireNamespace("glmGamPoi", quietly = TRUE))
            """
            has_pkg = success(pipeline(`$rscript -e $scripts`, stdout = devnull, stderr = devnull))
            if !has_pkg
                @testset "glmGamPoi absent — the parity comparison did NOT run" begin
                    @test true
                    @info "dispersion: glmGamPoi is not installed; the parity test was skipped"
                end
            else
                counts = disp_matrix(DISPERSION_GOLDEN.counts)
                design = disp_matrix(DISPERSION_GOLDEN.design)
                dir = mktempdir()
                open(joinpath(dir, "counts.csv"), "w") do io
                    for i in 1:size(counts, 1)
                        println(io, join(counts[i, :], ","))
                    end
                end
                open(joinpath(dir, "design.csv"), "w") do io
                    for i in 1:size(design, 1)
                        println(io, join(design[i, :], ","))
                    end
                end
                script = """
                library(glmGamPoi)
                X <- t(as.matrix(read.csv(file.path("$dir", "counts.csv"), header = FALSE)))
                D <- as.matrix(read.csv(file.path("$dir", "design.csv"), header = FALSE))
                sf <- estimate_size_factors(X)
                fit <- glm_gp(X, design = D, size_factors = sf, overdispersion = 0,
                              do_cox_reid_adjustment = TRUE, verbose = FALSE)
                write.table(fit$overdispersions, stdout(), sep = ",", row.names = FALSE,
                            col.names = FALSE)
                """
                r_out = read(`$rscript -e $script`, String)
                reference = disp_vector([Float64(parse(Float64, l)) for l in
                                       split(strip(r_out), "\n") if !isempty(strip(l))])
                ours = estimate_dispersions(counts, disp_matrix(DISPERSION_GOLDEN.means);
                                            design = design)
                # The reference's `overdispersions` are the trend values the fit uses.
                @test length(reference) == length(ours.overdispersion)
                @test maximum(abs.(ours.overdispersion .- reference) ./ max.(reference, 1e-12)) < 1e-6
            end
        end
    end
end
