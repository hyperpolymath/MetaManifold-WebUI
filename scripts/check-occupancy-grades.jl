# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Validate empirical records only; never supply missing windows from a model.
# Exit 0: comparisons passed; 1: malformed evidence/disagreement; 2: incomplete evidence.
# Reuse the package binding when included by its registered unit tests.
if !isdefined(@__MODULE__, :MemoryProbe)
    include(joinpath(@__DIR__, "..", "src", "core", "memory_probe.jl"))
end
using .MemoryProbe
using YAML

function check_records(orders; io=stdout)
    failures = 0
    incomplete = 0
    for name in sort(collect(keys(orders)))
        rec = orders[name]
        tasks = rec["tasks"]
        if isempty(tasks) || any(t -> !haskey(t, "first_sample") || !haskey(t, "last_sample"), tasks)
            println(io, "INDETERMINATE: $name: no recorded task sample windows; rerun required")
            incomplete += 1
            continue
        end
        valid = all(tasks) do t
            first, last, samples = t["first_sample"], t["last_sample"], t["samples"]
            all(x -> x isa Integer && !(x isa Bool), (first, last, samples)) &&
                ((first == last == samples == 0) ||
                 (first > 0 && last >= first && samples >= 0 &&
                  samples <= last - first + 1 && last <= rec["samples"]))
        end
        if !valid
            println(io, "FAIL: $name: inconsistent or unclosed recorded sample window")
            failures += 1
            continue
        end
        if any(t -> t["samples"] == 0, tasks)
            println(io, "INDETERMINATE: $name: a child was not sampled; no empirical bound established")
            incomplete += 1
            continue
        end
        predicted = MemoryProbe.predicted_peak_rss_kib(rec)
        cost = MemoryProbe.cost_bound_rss_kib(rec)
        reclaimed = MemoryProbe.reclaimed_kib(rec)
        grade = MemoryProbe.stage_grade(rec)
        if rec["child_peak_rss_kib"] > predicted || predicted > cost || reclaimed < 0 || grade.drift != 0
            println(io, "FAIL: $name: model disagrees with recorded evidence")
            failures += 1
        else
            println(io, "PASS: $name: measured peak is within the conditional model bound")
        end
    end
    isempty(orders) && (incomplete += 1; println(io, "INDETERMINATE: no orders recorded"))
    failures > 0 ? 1 : incomplete > 0 ? 2 : 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    results = isempty(ARGS) ? joinpath(@__DIR__, "..", "docs", "occupancy", "results-2026-10-14.yml") : only(ARGS)
    exit(check_records(YAML.load_file(results)["orders"]))
end
