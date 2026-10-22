#!/usr/bin/env julia
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Runtime and memory of the two multinomial models at 100, 1000 and 10000 taxa.
#
# Issue #17 asks for a benchmark at three sizes and a warning above 5 minutes.
# `CompositionalModels.MAX_TAXA` refuses a fit with more than 1000
# non-reference taxa, because the observed information is a dense
# ((K-1) q) x ((K-1) q) matrix: at 1000 taxa and two covariates that is 32 MB
# of doubles and a Cholesky factorisation of a 1998 x 1998 matrix. The 10000-taxon
# row therefore measures the refusal, not a fit, and says so: the point of the
# row is that the answer comes back immediately, with a reason, instead of the
# request hanging in a factorisation.
#
# The data are synthetic but shaped like a real table: log-normal abundances
# over taxa, a 2-fold effect on every third taxon, 20000 reads per sample, and
# log-normal multiplicative noise between samples, which is the extra-Poisson
# variation a Dirichlet-multinomial would also produce.
#
# Usage:
#   julia --project=. bench/compositional_scaling/scaling.jl
#   julia --project=. bench/compositional_scaling/scaling.jl 100 1000     # sizes
#   julia --project=. bench/compositional_scaling/scaling.jl --samples 60 # per group
#
# Writes results/scaling.csv and prints a table. The process exits non-zero if a
# fit that should be possible exceeds five minutes, so CI can gate on it.

using Dates
using Printf
using Random
using MetaManifold

const CM = MetaManifold.CompositionalModels

const BENCH_DIR      = @__DIR__
const RESULTS_DIR    = joinpath(BENCH_DIR, "results")
const BUDGET_SECONDS = 300.0        # the issue's warning threshold
const READS_PER_SAMPLE = 20_000

"""
    _synthetic(K, n_per_group, rng) -> (counts, design)

Counts of `2 * n_per_group` samples over `K` taxa. Abundances are log-normal,
the second group carries a 2-fold effect on every third taxon, and a log-normal
per-count multiplier adds the between-sample variation that makes these data
overdispersed, so the Dirichlet-multinomial has a concentration to estimate
rather than collapsing to the multinomial. Row totals vary around
`READS_PER_SAMPLE`, which is what the model conditions on.
"""
function _synthetic(K::Int, n_per_group::Int, rng::AbstractRNG)
    n = 2 * n_per_group
    design = zeros(Float64, n, 2)
    design[:, 1] .= 1.0
    design[:, 2] .= (vcat(fill(0, n_per_group), fill(1, n_per_group)) .== 1)
    effect = [j % 3 == 0 ? log(2.0) : 0.0 for j in 1:K]
    base = randn(rng, K) .* 1.5
    counts = Matrix{Int}(undef, n, K)
    for i in 1:n
        eta = base .+ effect .* design[i, 2]
        p = exp.(eta .- maximum(eta))
        p ./= sum(p)
        for j in 1:K
            counts[i, j] = round(Int, READS_PER_SAMPLE * p[j] * exp(0.35 * randn(rng)))
        end
    end
    counts, design
end

"""
    _timed(f) -> (seconds, bytes, result, error)

Run `f()`, returning its wall-clock time, the bytes it allocated, and either its
result or the exception it threw. Allocation is Julia's own counter, so it
excludes the R runtime and any child process.
"""
function _timed(f::Function)
    out = Ref{Any}(nothing)
    err = Ref{Any}(nothing)
    GC.gc()
    started = time_ns()
    bytes = @allocated begin
        try
            out[] = f()
        catch e
            err[] = e
        end
    end
    (seconds=(time_ns() - started) / 1e9, bytes=bytes, result=out[], error=err[])
end

# One fit of each model on a table small enough to be instant, so the first
# measured fit is not paying for compilation of the Newton loop.
function _warmup(rng::AbstractRNG)
    counts, design = _synthetic(8, 4, rng)
    CM.fit_multinomial(counts, design; reference=1)
    CM.fit_dirichlet_multinomial(counts, design; reference=1, max_iter=50)
    nothing
end

const _CSV_HEADER = "taxa,method,status,seconds,allocated_bytes,converged,iterations," *
                    "concentration,alternations,loglik,note"

_csv_escape(s::AbstractString) = replace(String(s), ',' => ';', '\n' => ' ', '\r' => ' ')

function main(args::Vector{String})
    sizes = [100, 1000, 10_000]
    n_per_group = 30
    positional = String[]
    i = 1
    while i <= length(args)
        if args[i] == "--samples"
            i += 1
            n_per_group = parse(Int, args[i])
        else
            push!(positional, args[i])
        end
        i += 1
    end
    isempty(positional) || (sizes = parse.(Int, positional))

    rng = MersenneTwister(20261022)
    mkpath(RESULTS_DIR)
    _warmup(rng)

    over_budget = false
    csv = open(joinpath(RESULTS_DIR, "scaling.csv"), "w")
    println(csv, _CSV_HEADER)
    @printf("%-6s %-22s %-12s %10s %10s %6s %6s\n",
            "taxa", "method", "status", "seconds", "MB", "iter", "alt")

    for K in sizes
        counts, design = _synthetic(K, n_per_group, rng)
        for method in ("multinomial", "dirichlet_multinomial")
            run = _timed() do
                method == "multinomial" ?
                    CM.fit_multinomial(counts, design; reference=1) :
                    CM.fit_dirichlet_multinomial(counts, design; reference=1)
            end
            megabytes = run.bytes / 1e6
            if run.error isa CM.RuntimeRefusal
                status, note = "over_budget", _csv_escape(sprint(showerror, run.error))
                over_budget = true
            elseif run.error isa CM.CompositionalRefusal
                # The taxon cap: an immediate, documented refusal.
                status, note = "refused", _csv_escape(sprint(showerror, run.error))
            elseif !isnothing(run.error)
                status, note = "failed", _csv_escape(sprint(showerror, run.error))
                over_budget |= run.seconds > BUDGET_SECONDS
            else
                fit = run.result
                status = fit.converged ? "ok" : "not_converged"
                @printf("%-6d %-22s %-12s %10.3f %10.1f %6d %6d\n",
                        K, method, status, run.seconds, megabytes,
                        fit.iterations, fit.alternations)
                println(csv, "$K,$method,$status,$(round(run.seconds; digits=3))," *
                             "$(run.bytes),$(fit.converged),$(fit.iterations)," *
                             "$(isfinite(fit.concentration) ? round(fit.concentration; digits=6) : "Inf")," *
                             "$(fit.alternations),$(round(fit.loglik; digits=6)),")
                over_budget |= run.seconds > BUDGET_SECONDS
            end
            if status == "refused" || status == "over_budget" || status == "failed"
                @printf("%-6d %-22s %-12s %10.3f %10.1f %6s %6s\n",
                        K, method, status, run.seconds, megabytes, "-", "-")
                println(csv, "$K,$method,$status,$(round(run.seconds; digits=3))," *
                             "$(run.bytes),false,0,,,$note")
            end
        end
    end
    close(csv)

    println("\nWrote ", joinpath(RESULTS_DIR, "scaling.csv"))
    println("Machine: ", Sys.CPU_NAME, " (", Sys.CPU_THREADS, " threads), Julia ", VERSION,
            ", ", Dates.format(now(), "yyyy-mm-dd HH:MM"))
    if over_budget
        @warn "a fit that should be possible exceeded the 5-minute budget" budget=BUDGET_SECONDS
        return 1
    end
    0
end

exit(main(ARGS))
