# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E8 (issue 303): evidence verdicts on placements made by the application's own
# placement step (RAxML EPA).  See ../README.md, section 8.
# Independent recomputation of the tables from raw/perclade_*.tsv and raw/perquery_*.tsv, and the
# breakdown of wrong entailed verdicts by clade size.  Written separately from 06_tables.jl as a
# cross-check.  usage: julia 08_by_depth.jl epa_dir
using Printf, Statistics
function load(kind)
    pc = [split(l, '\t') for l in readlines(joinpath(ARGS[1], "raw", "perclade_$kind.tsv"))[2:end]]
    C = [(parse(Int, r[1]), parse(Int, r[2]), parse(Float64, r[3]), r[4] == "1") for r in pc]
    pq = [split(l, '\t') for l in readlines(joinpath(ARGS[1], "raw", "perquery_$kind.tsv"))[2:end]]
    Q = Dict(parse(Int, r[1]) => (n = parse(Int, r[4]), tot = parse(Float64, r[5]), best = parse(Float64, r[6]), exact = r[7] == "1", apart = parse(Int, r[8])) for r in pq)
    C, Q
end
for kind in ("amp", "pos", "neg")
    C, Q = load(kind)
    println("== $kind: $(length(C)) clade rows, $(length(Q)) queries")
    for a in (0.01, 0.05)
        ent = [c for c in C if c[3] >= 1 - a]; ref = [c for c in C if c[3] <= a]
        ew = count(c -> !c[4], ent); rw = count(c -> c[4], ref)
        # smallest entailed clade per query
        sm = Dict{Int,Tuple{Int,Bool}}()
        for c in ent; (!haskey(sm, c[1]) || c[2] < sm[c[1]][1]) && (sm[c[1]] = (c[2], c[4])); end
        wrongq = sort([q for (q, v) in sm if !v[2]])
        @printf(" alpha %.2f: entailed %d wrong %d | refuted %d wrong %d | smallest entailed: %d queries, median size %.1f, wrong %d\n",
                a, length(ent), ew, length(ref), rw, length(sm), median([v[1] for v in values(sm)]), length(wrongq))
        if kind == "amp"
            println("   wrong-smallest queries (qi: clade size, edges apart, placements, best LWR): ",
                    join(["$q: $(sm[q][1]), $(Q[q].apart), $(Q[q].n), $(round(Q[q].best, digits=3))" for q in wrongq], " | "))
            # entailed error by clade size
            for (lo, hi) in ((2, 3), (4, 7), (8, 15), (16, 49), (50, 199))
                e = [c for c in ent if lo <= c[2] <= hi]
                @printf("   entailed, clade size %3d..%3d: %5d verdicts, wrong %2d\n", lo, hi, length(e), count(c -> !c[4], e))
            end
            # rule: smallest entailed clade of size >= k
            for k in (2, 4, 8, 16)
                s2 = Dict{Int,Tuple{Int,Bool}}()
                for c in ent; c[2] >= k || continue; (!haskey(s2, c[1]) || c[2] < s2[c[1]][1]) && (s2[c[1]] = (c[2], c[4])); end
                @printf("   smallest entailed clade of size >= %2d: %3d queries, median size %.1f, wrong %d\n", k, length(s2), median([v[1] for v in values(s2)]), count(v -> !v[2], values(s2)))
            end
            # by number of placements reported
            for (lab, f) in (("1 placement", n -> n == 1), ("2+ placements", n -> n >= 2))
                qs = [q for q in keys(sm) if f(Q[q].n)]
                @printf("   %s: %d queries with an entailed clade, wrong smallest %d\n", lab, length(qs), count(q -> !sm[q][2], qs))
            end
        end
    end
end
