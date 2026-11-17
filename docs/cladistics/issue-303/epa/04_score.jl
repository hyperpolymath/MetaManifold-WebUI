# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E8 (issue 303): evidence verdicts on placements made by the application's own
# placement step (RAxML EPA).  See ../README.md, section 8.
# usage: julia 04_score.jl epa_dir kind   -> raw/perquery_<kind>.tsv, raw/perclade_<kind>.tsv, raw/checks_<kind>.txt
using Printf
include(joinpath(@__DIR__, "lib_nwk.jl"))
E, kind = ARGS[1], ARGS[2]; W = joinpath(E, "work")
names = [String(split(l, "\t")[1]) for l in eachline(joinpath(W, "names.tsv"))]; N = length(names)
leafidx = Dict(n => i for (i, n) in enumerate(names))
qs = [String.(split(l, "\t")) for l in eachline(joinpath(W, "queries.tsv"))][2:end]
pq = open(joinpath(E, "raw", "perquery_$kind.tsv"), "w"); pc = open(joinpath(E, "raw", "perclade_$kind.tsv"), "w")
ck = open(joinpath(E, "raw", "checks_$kind.txt"), "w")
println(pq, "qi\tquery\tstatus\tnplacements\ttotal_lwr\tbest_lwr\texact\tedges_apart")
println(pc, "qi\tclade_size\tmass\ttruth_inside")
nedges_ok = true; distinct_ok = true; mono_viol = 0; mono_checked = 0; nscored = 0
for q in qs
    qi = parse(Int, q[1]); dir = joinpath(W, "q", @sprintf("q%03d", qi)); kd = joinpath(dir, kind)
    jp = joinpath(kd, "RAxML_portableTree.epa.jplace")
    if !isfile(jp); println(pq, qi, "\t", q[2], "\tMISSING\t0\t0\t0\t0\t0"); continue; end
    g = parse_nwk(strip(read(joinpath(dir, "pruned.nwk"), String)))
    truthleaves = split(strip(read(joinpath(dir, "truth.txt"), String)), "\n")
    refs = sort([n for n in names if n != q[2]]); rl = leafidx[refs[1]]
    nid = Dict(g.names[u] => u for u in eachindex(g.names) if g.names[u] != "")
    par, kids, below, order = root_at(g, nid[refs[1]], leafidx)
    # edge above node u (u != root leaf) <-> below[u]; root leaf's pendant edge == edge above its only child
    root_child = first(kids[nid[refs[1]]])
    edgekey = Dict{BitSet,Int}()   # bipartition (side without refs[1]) -> node
    for u in order; u == nid[refs[1]] && continue; edgekey[below[u]] = u; end
    ne = length(edgekey) + 0  # includes root_child's edge == pendant of root leaf
    expected = 2 * (N - 1) - 3
    # jplace tree
    tree, fields, rows = parse_jplace(jp)
    jg = parse_nwk(tree)
    jn = Dict(jg.names[u] => u for u in eachindex(jg.names) if jg.names[u] != "")
    @assert !haskey(jn, "qry") "query leaf present in jplace tree"
    jpar, jkids, jbelow, jorder = root_at(jg, jn[refs[1]], leafidx)
    enum2node = Dict{Int,Int}(); jkey = Dict{Int,BitSet}()
    for u in jorder; u == jn[refs[1]] && continue; e = jg.lab[u][jpar[u]]; enum2node[e] = u; jkey[e] = jbelow[u]; end
    # the edge above the root leaf's only child and the pendant edge of root leaf are the same unrooted edge: jplace labels it once
    nj = length(jkey)
    if nj != expected; global nedges_ok = false; end
    # edge-number -> bipartition uniqueness
    if length(Set(values(jkey))) != length(jkey); global distinct_ok = false; end
    println(ck, "q$qi: jplace edges=$(length(jkey)) distinct_bipartitions=$(length(Set(values(jkey)))) expected=$expected pruned_tree_edges=$(length(edgekey)) all_in_pruned=$(all(k -> haskey(edgekey, k), values(jkey)))")
    ei = findfirst(==("edge_num"), fields); li = findfirst(==("like_weight_ratio"), fields)
    pls = [(Int(r[ei]), r[li]) for r in rows]
    total = sum(p[2] for p in pls)
    # best placement
    bi = argmax([p[2] for p in pls]); bkey = jkey[pls[bi][1]]
    tkey = BitSet(leafidx[n] for n in truthleaves)
    # truth is the below-set of its child in the pruned tree rooted at refs[1]
    @assert haskey(edgekey, tkey) "truth bipartition not an edge of pruned tree"
    function apart(a, b)
        a == b && return 0
        da = Dict{Int,Int}(); u = a; k = 0; while u != 0 && u != nid[refs[1]]; da[u] = k; u = par[u]; k += 1; end
        u = b; k = 0; while u != 0 && u != nid[refs[1]]; haskey(da, u) && return da[u] + k; u = par[u]; k += 1; end
        typemax(Int)
    end
    tnode = edgekey[tkey]; bnode = edgekey[bkey]
    # root-leaf pendant edge: represent by root_child's node (same edge)
    println(pq, qi, "\t", q[2], "\tOK\t", length(pls), "\t", total, "\t", pls[bi][2], "\t", Int(bkey == tkey), "\t", apart(bnode, tnode))
    # clades: internal nodes other than the root leaf, whose parent... internal non-leaf nodes of the rooted tree (root leaf excluded)
    plnode = [(edgekey[jkey[e]], w) for (e, w) in pls]
    clades = [u for u in order if u != nid[refs[1]] && !isleaf(g, u)]
    masses = Dict{Int,Float64}()
    for c in clades
        S = below[c]; m = 0.0
        for (nd, w) in plnode; below[nd] != S && issubset(below[nd], S) && (m += w); end
        masses[c] = m
        println(pc, qi, "\t", length(S), "\t", m, "\t", Int(tkey != S && issubset(tkey, S)))
    end
    # monotonicity under inclusion: mass(child) <= mass(parent) for parent clade strictly containing
    for c in clades; p = par[c]; (p == nid[refs[1]] || isleaf(g, p)) && continue; global mono_checked += 1; masses[c] <= masses[p] + 1e-12 || (global mono_viol += 1); end
    global nscored += 1
end
println(ck, "SUMMARY scored=$nscored edge_count_ok=$nedges_ok distinct_bipartitions_ok=$distinct_ok monotone_pairs_checked=$mono_checked monotone_violations=$mono_viol")
close(pq); close(pc); close(ck)
println("scored $nscored; ", read(joinpath(E, "raw", "checks_$kind.txt"), String)[end-200:end])
