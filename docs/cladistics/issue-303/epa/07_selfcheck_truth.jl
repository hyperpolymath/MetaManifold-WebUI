# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E8 (issue 303): evidence verdicts on placements made by the application's own
# placement step (RAxML EPA).  See ../README.md, section 8.
# usage: julia 07_selfcheck_truth.jl epa_dir  -- independent truth: from leaf-to-leaf path distances in the UNPRUNED tree
# Rule: q hangs by pendant length l from p. For leaves x,y != q: g(x,y) = d(q,x)+d(q,y)-d(x,y).
#   x,y on different sides of p (sides A/B = the two other neighbours' subtrees): g = 2l (the minimum); same side: g = 2(l + d(p, meet)) >= 2l.
# Leaves are clustered by linking pairs with g > min + tol; the two largest components must be the sides.
using Printf, Random
include(joinpath(@__DIR__, "lib_nwk.jl"))
E = ARGS[1]; W = joinpath(E, "work")
names = [String(split(l, "\t")[1]) for l in eachline(joinpath(W, "names.tsv"))]
g = parse_nwk(strip(read(joinpath(W, "tree", "reference.treefile"), String)))
nid = Dict(g.names[u] => u for u in eachindex(g.names) if g.names[u] != "")
function dists(src)
    d = fill(NaN, length(g.names)); d[src] = 0.0; st = [src]
    while !isempty(st); u = pop!(st); for (v, l) in g.adj[u]; isnan(d[v]) && (d[v] = d[u] + l; push!(st, v)); end; end
    d
end
qs = [String.(split(l, "\t")) for l in eachline(joinpath(W, "queries.tsv"))][2:end]
rng = MersenneTwister(99); pick = shuffle(rng, 1:length(qs))[1:5]
big = [i for i in shuffle(rng, 1:length(qs)) if length(readlines(joinpath(W, "q", @sprintf("q%03d", parse(Int, qs[i][1])), "truth.txt"))) >= 5][1:5]; append!(pick, big)
allok = true
for i in pick
    qi = parse(Int, qs[i][1]); qn = qs[i][2]
    truth = Set(split(strip(read(joinpath(W, "q", @sprintf("q%03d", qi), "truth.txt"), String)), "\n"))
    dq = dists(nid[qn]); others = [n for n in names if n != qn]; m = length(others)
    D = Dict(n => dists(nid[n]) for n in others)
    G = [dq[nid[x]] + dq[nid[y]] - D[x][nid[y]] for x in others, y in others]
    mn = minimum(G[i2, j2] for i2 in 1:m, j2 in 1:m if i2 != j2)
    tol = 1e-7
    comp = collect(1:m); find(x) = (while comp[x] != x; comp[x] = comp[comp[x]]; x = comp[x]; end; x)
    for i2 in 1:m, j2 in i2+1:m; G[i2, j2] > mn + tol && (comp[find(i2)] = find(j2)); end
    groups = Dict{Int,Vector{String}}(); for i2 in 1:m; push!(get!(groups, find(i2), String[]), others[i2]); end
    gs = sort(collect(values(groups)); by = length, rev = true)
    sides = [Set(x) for x in gs[1:min(2, length(gs))]]
    # the "truth" side in the prep is the side not containing the alphabetically first reference leaf
    first_leaf = minimum(others)
    cand = [s for s in sides if !(first_leaf in s)]
    ok = length(gs) == 2 && length(cand) == 1 && cand[1] == truth
    global allok &= ok
    @printf("  %s (q%03d): components=%d sizes=%s; independent side without %s has %d leaves; prepared truth has %d leaves; match=%s\n", qn, qi, length(gs), string(length.(gs)), first_leaf, isempty(cand) ? -1 : length(cand[1]), length(truth), ok)
end
println("SELF-CHECK (a): all ten match (5 random + 5 with truth side >= 5 leaves) = ", allok)
