# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E9 (issue 303): error of entailed clade verdicts by clade depth, with the
# application's placement step.  See ../README.md, section 9.  These files replace their
# namesakes from ../epa/; 01_select.jl, 07_selfcheck_truth.jl and lib_nwk.jl are used unchanged.
# Cross-check of 06_tables.jl, written separately: the size-bin table, the per-query rule, the
# errors on the largest clades, and the same errors binned by the smaller side of the branch.
# usage: julia 08_crosscheck.jl RAW_DIR
using Printf, Statistics
# Same boundary tolerance as 06_tables.jl (isent), so a mass of 0.9899999999999999 counts at alpha 0.01.
const TOL = 1e-12
medstr(x) = isempty(x) ? "n/a" : @sprintf("%.1f", median(x))
function load(tag)
    C = [(r = split(l, '\t'); (parse(Int, r[1]), parse(Int, r[2]), parse(Float64, r[3]), r[4] == "1")) for l in readlines(joinpath(ARGS[1], "perclade_$tag.tsv"))[2:end]]
    Q = Dict((r = split(l, '\t'); parse(Int, r[1]) => (n = parse(Int, r[4]), best = parse(Float64, r[6]), exact = r[7] == "1", apart = parse(Int, r[8]))) for l in readlines(joinpath(ARGS[1], "perquery_$tag.tsv"))[2:end])
    C, Q
end
A, QA = load("A_amp"); B, QB = load("B_amp"); P, QP = load("A_pos")
println("rows A $(length(A)) B $(length(B)); queries A $(length(QA)) B $(length(QB)); pos exact $(count(q -> q.exact, values(QP))) of $(length(QP))")
bins = ((2, 3), (4, 7), (8, 15), (16, 31), (32, 63), (64, 127), (128, 399))
for a in (0.01, 0.05)
    tot = 0; wr = 0
    for (lo, hi) in bins
        s = ""; n = 0; w = 0; qs = Set{Tuple{Char,Int}}()
        for (tag, C) in (('A', A), ('B', B)), c in C
            (c[3] >= 1 - a - TOL && lo <= c[2] <= hi) || continue
            n += 1; c[4] || (w += 1; push!(qs, (tag, c[1])))
        end
        tot += n; wr += w
        @printf(" alpha %.2f size %3d..%3d: entailed %5d wrong %2d (queries %d)\n", a, lo, hi, n, w, length(qs))
    end
    println(" alpha $a total entailed $tot wrong $wr")
    for k in (2, 4, 8, 16, 32, 64)
        n = 0; w = 0; sizes = Int[]
        for C in (A, B)
            sm = Dict{Int,Tuple{Int,Bool}}()
            for c in C; (c[3] >= 1 - a - TOL && c[2] >= k) || continue; (!haskey(sm, c[1]) || c[2] < sm[c[1]][1]) && (sm[c[1]] = (c[2], c[4])); end
            n += length(sm); w += count(v -> !v[2], values(sm)); append!(sizes, [v[1] for v in values(sm)])
        end
        @printf(" alpha %.2f k>=%2d: queries %d median size %s wrong %d\n", a, k, n, medstr(sizes), w)
    end
end
println("wrong entailed verdicts on clades of 128+ at alpha 0.01 (draw, query, clade size, edges apart, placements, best LWR):")
for (tag, C, Q) in (('A', A, QA), ('B', B, QB)), c in C
    (c[3] >= 0.99 - TOL && c[2] >= 128 && !c[4]) && println("  $tag q$(c[1]) size $(c[2]) apart $(Q[c[1]].apart) n $(Q[c[1]].n) best $(round(Q[c[1]].best, digits=3)) mass $(round(c[3], digits=4))")
end
# How far is the best placement from the truth for wrong vs right smallest-entailed queries (k=2)
for (tag, C, Q) in (('A', A, QA), ('B', B, QB))
    sm = Dict{Int,Tuple{Int,Bool}}()
    for c in C; c[3] >= 0.99 - TOL || continue; (!haskey(sm, c[1]) || c[2] < sm[c[1]][1]) && (sm[c[1]] = (c[2], c[4])); end
    wq = [q for (q, v) in sm if !v[2]]
    println(" draw $tag: wrong smallest-entailed queries $(length(wq)); edges apart: ", sort([Q[q].apart for q in wq]))
end

# ---- by the smaller side of the branch: min(clade size, references outside it) ----
rows2(tag) = [(r = split(l, '\t'); (tag, parse(Int, r[1]), parse(Int, r[2]), parse(Float64, r[3]), r[4] == "1", parse(Int, r[5]))) for l in readlines(joinpath(ARGS[1], "perclade_$tag.tsv"))[2:end]]
C2 = vcat(rows2("A_amp"), rows2("B_amp"))
for a in (0.01, 0.05)
    for (lo, hi) in ((1, 1), (2, 3), (4, 7), (8, 15), (16, 31), (32, 63), (64, 127), (128, 200))
        n = 0; w = 0; qs = Set{Tuple{String,Int}}()
        for c in C2
            m = min(c[3], c[6] - c[3]); (c[4] >= 1 - a - TOL && lo <= m <= hi) || continue
            n += 1; c[5] || (w += 1; push!(qs, (c[1], c[2])))
        end
        @printf(" alpha %.2f smaller side %3d..%3d: entailed %5d wrong %2d (queries %d)\n", a, lo, hi, n, w, length(qs))
    end
end
