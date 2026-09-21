# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""
Benchmark for epistemic parsing pathways

Measures (future epistemic layer, currently mocked with categories + avec_fibre):
- avec_fibre column parsing and boolean coercion
- Epistemic colour coding logic
- Cloud sizing by residual count
- present_in_every_admissible_world validation
- Warrant / Candidate / Holds logic (finite model)
- Category materialisation (contamination model)
"""

using Random
using JSON3
using Statistics

# Mock epistemic types (mirrors src/core/epistemic.jl future implementation)
@enum EpistemicStatus present_in_every=1 present_in_some=2 absent=3 unknown=4 sans_fibre=5

struct MockCandidate
    observation::Int
    residual::Int
    witness::Int
end

struct MockCase
    candidates::Vector{MockCandidate}
end

function present_in_every_admissible_world(case_::MockCase, query::Function)
    # Returns true if query holds for every candidate
    all(c -> query(c.witness), case_.candidates)
end

function epistemic_colour(status::EpistemicStatus)
    if status == present_in_every
        return "#2e7d32"  # green
    elseif status == present_in_some
        return "#f9a825"  # yellow
    elseif status == absent
        return "#9e9e9e"  # grey
    elseif status == sans_fibre
        return "#c62828"  # red
    else
        return "#9e9e9e"
    end
end

function cloud_size(residual_count::Int)
    return log(1 + residual_count) * 10 + 5
end

function avec_fibre_parse(value::Union{Bool, String, Int, Missing})
    if ismissing(value)
        return false
    elseif value isa Bool
        return value
    elseif value isa String
        return lowercase(value) in ("true", "t", "1", "avec_fibre", "avec")
    elseif value isa Int
        return value != 0
    else
        return false
    end
end

function bench_avec_fibre_parsing(n::Int=10000)
    values = rand([true, false, "true", "false", "avec_fibre", "sans_fibre", 1, 0, missing], n)
    @elapsed for v in values
        avec_fibre_parse(v)
    end
end

function bench_epistemic_colour(n::Int=10000)
    statuses = rand([present_in_every, present_in_some, absent, unknown, sans_fibre], n)
    @elapsed for s in statuses
        epistemic_colour(s)
    end
end

function bench_cloud_size(n::Int=10000)
    residuals = rand(0:1000, n)
    @elapsed for r in residuals
        cloud_size(r)
    end
end

function bench_present_in_every(n_cases::Int=100, n_candidates::Int=50)
    cases = [MockCase([MockCandidate(rand(-6:6), rand(-3:3), rand(-6:6)) for _ in 1:n_candidates]) for _ in 1:n_cases]
    @elapsed for case_ in cases
        present_in_every_admissible_world(case_, w -> w != 0)
    end
end

function bench_warrant_logic(n::Int=10000)
    # Mock Warrant: evidence set, no Evidence->A
    @elapsed for _ in 1:n
        evidence = rand(Bool, 10)
        # Warrant holds if any evidence true (simplified)
        any(evidence)
    end
end

function run_benchmarks(; reps=5)
    println("=== Epistemic Parsing Benchmark ===")
    results = Dict{String, Vector{Float64}}()

    for name in ["avec_fibre_parse", "epistemic_colour", "cloud_size", "present_in_every", "warrant_logic"]
        results[name] = Float64[]
    end

    for _ in 1:reps
        push!(results["avec_fibre_parse"], bench_avec_fibre_parsing())
        push!(results["epistemic_colour"], bench_epistemic_colour())
        push!(results["cloud_size"], bench_cloud_size())
        push!(results["present_in_every"], bench_present_in_every())
        push!(results["warrant_logic"], bench_warrant_logic())
    end

    for (name, times) in results
        med = median(times)
        println("$name: median $(round(med*1000, digits=2)) ms over $reps reps")
    end

    baseline_path = joinpath(@__DIR__, "baseline.json")
    if isfile(baseline_path)
        baseline = JSON3.read(read(baseline_path, String))
        println("\nBaseline comparison (informational):")
        for (name, times) in results
            med = median(times)
            if haskey(baseline, name)
                base_med = baseline[name]
                delta = (med - base_med) / base_med * 100
                status = delta > 10 ? "NOTE" : "ok"
                println("$status $name: $(round(delta, digits=1))% vs baseline $(round(base_med*1000, digits=2)) ms")
                if delta > 10
                    # Informational — absolute ns vs a committed baseline measures the host, not the change (see the benchmark step comment in .github/workflows/ci.yml). Never gates in CI.
                    @warn "Delta >10% vs baseline for $name (informational)" delta
                end
            end
        end
    else
        println("\nNo baseline.json — saving current as baseline")
        baseline = Dict(name => median(times) for (name, times) in results)
        open(baseline_path, "w") do io
            JSON3.write(io, baseline)
        end
    end

    return results
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_benchmarks()
end
