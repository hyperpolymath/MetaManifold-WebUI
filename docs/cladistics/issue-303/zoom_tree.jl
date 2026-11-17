# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E2: "thumbnail then zoom" tree reconstruction from distance QUERIES.
#
# Input model: the distance matrix is never materialised.  d(i,j) is an oracle call
# (in practice: compare two sequences), and we count distinct calls.
# Contract: the distances are an additive tree metric with positive integer edge lengths
# (exact arithmetic, no floats).  On such input canonical neighbour joining returns the
# true tree, so "same tree as NJ" and "the true tree" coincide; the NJ baseline below
# checks that on small n.
#
# Method: insert leaves one at a time.  The current tree is the thumbnail; to place a new
# leaf, pick a centroid of the region still in play, ask <= degree(centroid) distances to
# learn which side of the centroid the leaf hangs on, discard the rest, repeat (zoom).
using Random, Printf

# ---------- trees ----------
mutable struct Tree
    adj::Vector{Vector{Tuple{Int,Int}}}   # vertex -> [(neighbour, edge length)]
    leafid::Vector{Int}                    # vertex -> leaf label, 0 for internal
end
Tree() = Tree(Vector{Vector{Tuple{Int,Int}}}(), Int[])
function addvertex!(t::Tree, leaf = 0); push!(t.adj, Tuple{Int,Int}[]); push!(t.leafid, leaf); length(t.adj); end
function addedge!(t::Tree, u, v, w); push!(t.adj[u], (v, w)); push!(t.adj[v], (u, w)); end
function deledge!(t::Tree, u, v); filter!(e -> e[1] != v, t.adj[u]); filter!(e -> e[1] != u, t.adj[v]); end
nverts(t::Tree) = length(t.adj)

"Random binary tree on n leaves. shape = :yule (random splits) or :caterpillar (worst depth)."
function random_tree(rng, n; shape = :yule, wmax = 9)
    t = Tree(); a = addvertex!(t, 1); b = addvertex!(t, 2); addedge!(t, a, b, rand(rng, 1:wmax) + rand(rng, 1:wmax))
    edges = [(a, b)]; last_leaf = b
    for k in 3:n
        (u, v) = shape == :caterpillar ? (first(t.adj[last_leaf])[1], last_leaf) : edges[rand(rng, 1:length(edges))]
        w = first(e[2] for e in t.adj[u] if e[1] == v)
        # an edge of length 1 cannot be split into two positive integers: lengthen it first
        if w < 2; deledge!(t, u, v); w = 2; addedge!(t, u, v, w); end
        w1 = rand(rng, 1:w-1)
        deledge!(t, u, v); m = addvertex!(t); x = addvertex!(t, k)
        addedge!(t, u, m, w1); addedge!(t, m, v, w - w1); addedge!(t, m, x, rand(rng, 1:wmax))
        filter!(e -> e != (u, v) && e != (v, u), edges); push!(edges, (u, m), (m, v), (m, x)); last_leaf = x
    end
    t
end

"Distances from src to every vertex (iterative, tree)."
function dists_from(t::Tree, src)
    d = fill(-1, nverts(t)); d[src] = 0; st = [src]
    while !isempty(st)
        u = pop!(st)
        for (v, w) in t.adj[u]; d[v] < 0 && (d[v] = d[u] + w; push!(st, v)); end
    end
    d
end

# ---------- oracle with query counting ----------
mutable struct Oracle
    truth::Tree; leafvert::Vector{Int}; rows::Dict{Int,Vector{Int}}; asked::Set{Tuple{Int,Int}}
end
function Oracle(t::Tree, n)
    lv = zeros(Int, n); for v in 1:nverts(t); t.leafid[v] > 0 && (lv[t.leafid[v]] = v); end
    Oracle(t, lv, Dict{Int,Vector{Int}}(), Set{Tuple{Int,Int}}())
end
function query!(o::Oracle, i, j)
    i == j && return 0
    push!(o.asked, minmax(i, j))
    row = get!(() -> dists_from(o.truth, o.leafvert[i]), o.rows, i)   # cache is bookkeeping, not a query
    row[o.leafvert[j]]
end

# ---------- zoom insertion ----------
"A leaf reachable from `nb` without passing through `from`; also its distance from `from`."
function leaf_beyond(t::Tree, from, nb, w0)
    prev, cur, dist = from, nb, w0
    while t.leafid[cur] == 0
        (nx, w) = first(e for e in t.adj[cur] if e[1] != prev)
        prev, cur, dist = cur, nx, dist + w
    end
    (t.leafid[cur], dist)
end

"Vertices of the region reached from edge (c -> start), never expanding through blocked vertices."
function region(t::Tree, blocked::BitVector, c, start)
    order = [c, start]; parent = Dict(c => 0, start => c)
    if !blocked[start]
        i = 2
        while i <= length(order)
            u = order[i]; i += 1
            (blocked[u] && u != start) && continue
            for (v, _) in t.adj[u]
                haskey(parent, v) && continue
                parent[v] = u; push!(order, v)
            end
        end
    end
    order, parent
end

"Centroid of a region among its unblocked internal vertices, or 0 if the region is one edge."
function centroid(t::Tree, blocked::BitVector, order, parent)
    size = Dict(v => 1 for v in order)
    for v in Iterators.reverse(order); p = parent[v]; p != 0 && (size[p] += size[v]); end
    total = length(order); best = 0; bestcost = typemax(Int)
    for v in order
        (blocked[v] || t.leafid[v] > 0) && continue
        cost = total - size[v]
        for (u, _) in t.adj[v]; get(parent, u, -1) == v && (cost = max(cost, size[u])); end
        cost < bestcost && ((best, bestcost) = (v, cost))
    end
    best
end

"Insert leaf x into the reconstruction `t` using oracle queries only. Returns levels zoomed."
function insert_leaf!(t::Tree, o::Oracle, x, blocked::BitVector)
    fill!(blocked, false); length(blocked) < nverts(t) + 2 && resize!(blocked, 2nverts(t) + 8) ; blocked[nverts(t)+1:end] .= false
    c0 = 1; start = first(t.adj[c0])[1]; levels = 0
    order, parent = region(t, blocked, c0, start)
    while true
        c = centroid(t, blocked, order, parent)
        if c == 0                                    # region is a single edge u-v: place x on it
            u, v = order[1], order[2]
            w = first(e[2] for e in t.adj[u] if e[1] == v)
            (a, da) = t.leafid[u] > 0 ? (t.leafid[u], 0) : leaf_beyond(t, v, u, 0) |> r -> (r[1], r[2])
            # da = distance from u to leaf a (0 if u is the leaf itself)
            if t.leafid[u] == 0
                nb = first(e for e in t.adj[u] if e[1] != v); (a, da) = leaf_beyond(t, u, nb[1], nb[2])
            end
            (b, db) = t.leafid[v] > 0 ? (t.leafid[v], 0) :
                      (nb = first(e for e in t.adj[v] if e[1] != u); leaf_beyond(t, v, nb[1], nb[2]))
            dax = query!(o, a, x); dbx = query!(o, b, x); dab = da + w + db
            g2 = dax + dab - dbx; @assert iseven(g2); pos = g2 ÷ 2 - da
            @assert 0 < pos < w "leaf attaches at a vertex: not a binary tree with positive edges"
            deledge!(t, u, v); m = addvertex!(t); nx = addvertex!(t, x)
            addedge!(t, u, m, pos); addedge!(t, m, v, w - pos); addedge!(t, m, nx, dax - g2 ÷ 2)
            return levels
        end
        levels += 1
        nbs = t.adj[c]
        (a, D) = leaf_beyond(t, c, nbs[1][1], nbs[1][2]); dax = query!(o, a, x)
        (l2, D2) = leaf_beyond(t, c, nbs[2][1], nbs[2][2]); d2x = query!(o, l2, x)
        g2 = dax + (D + D2) - d2x; @assert iseven(g2); g = g2 ÷ 2      # dist(a, branch point of x on a..l2)
        side = 0
        if g < D; side = 1
        elseif g > D; side = 2
        else
            for j in 3:length(nbs)
                (lj, Dj) = leaf_beyond(t, c, nbs[j][1], nbs[j][2]); djx = query!(o, lj, x)
                h2 = d2x + (D2 + Dj) - djx
                if h2 ÷ 2 > D2; side = j; break; end
            end
            @assert side != 0 "leaf attaches exactly at an existing vertex (multifurcation)"
        end
        blocked[c] = true
        order, parent = region(t, blocked, c, nbs[side][1])
    end
end

function reconstruct(o::Oracle, n, perm)
    t = Tree(); a = addvertex!(t, perm[1]); b = addvertex!(t, perm[2]); addedge!(t, a, b, query!(o, perm[1], perm[2]))
    blocked = falses(4n); maxlev = 0
    for k in 3:n; maxlev = max(maxlev, insert_leaf!(t, o, perm[k], blocked)); end
    t, maxlev
end

# ---------- comparison: bipartitions with lengths ----------
function splits(t::Tree, keys::Vector{UInt64})
    root = findfirst(>(0), t.leafid); order = [root]; parent = Dict(root => (0, 0)); i = 1
    while i <= length(order)
        u = order[i]; i += 1
        for (v, w) in t.adj[u]; haskey(parent, v) || (parent[v] = (u, w); push!(order, v)); end
    end
    h = Dict(v => (t.leafid[v] > 0 ? keys[t.leafid[v]] : UInt64(0)) for v in order)
    for v in Iterators.reverse(order); p = parent[v][1]; p != 0 && (h[p] ⊻= h[v]); end
    all = h[root]
    Set((min(h[v], all ⊻ h[v]), parent[v][2]) for v in order if parent[v][1] != 0)
end

# ---------- canonical neighbour joining (baseline, exact rationals, O(n^3)) ----------
function nj_splits(D::Matrix{Rational{BigInt}}, keys)
    n = size(D, 1); active = collect(1:n); hk = Dict(i => keys[i] for i in 1:n); all = reduce(⊻, keys)
    D = copy(D); out = Set{UInt64}(); nxt = n
    Dd = Dict((i, j) => D[i, j] for i in 1:n, j in 1:n)
    while length(active) > 3
        r = length(active); tsum = Dict(i => sum(Dd[(i, k)] for k in active) for i in active)
        best = nothing; bq = nothing
        for x in 1:r, y in x+1:r
            i, j = active[x], active[y]; q = (r - 2) * Dd[(i, j)] - tsum[i] - tsum[j]
            (bq === nothing || q < bq) && ((best, bq) = ((i, j), q))
        end
        (i, j) = best; nxt += 1; u = nxt; hk[u] = hk[i] ⊻ hk[j]; push!(out, min(hk[u], all ⊻ hk[u]))
        for k in active
            (k == i || k == j) && continue
            duk = (Dd[(i, k)] + Dd[(j, k)] - Dd[(i, j)]) / 2; Dd[(u, k)] = duk; Dd[(k, u)] = duk
        end
        Dd[(u, u)] = 0 // 1; filter!(k -> k != i && k != j, active); push!(active, u)
    end
    out
end

# ---------- runs ----------
function run(rng, n, shape; check_nj = false)
    truth = random_tree(rng, n; shape); o = Oracle(truth, n)
    rec, maxlev = reconstruct(o, n, randperm(rng, n))
    keys = rand(rng, UInt64, n); st = splits(truth, keys); sr = splits(rec, keys)
    rf = length(symdiff(st, sr))                       # 0 means identical topology AND edge lengths
    njok = missing
    if check_nj
        lv = o.leafvert; D = [Rational{BigInt}(dists_from(truth, lv[i])[lv[j]]) for i in 1:n, j in 1:n]
        topo(s) = Set(k for (k, _) in s if count_ones(0) == 0)   # keys only
        internal = Set(k for (k, _) in st) ; leafkeys = Set(min(keys[i], reduce(⊻, keys) ⊻ keys[i]) for i in 1:n)
        njok = issubset(nj_splits(D, keys), setdiff(internal, leafkeys))
    end
    (queries = length(o.asked), full = n * (n - 1) ÷ 2, rf = rf, maxlev = maxlev, nj = njok)
end

rng = MersenneTwister(20261116)
println("== correctness: reconstruction equals the true tree (splits and edge lengths), and NJ agrees ==")
for shape in (:yule, :caterpillar), n in (8, 16, 32, 64)
    bad = 0; njbad = 0
    for _ in 1:20
        r = run(rng, n, shape; check_nj = true); bad += (r.rf != 0); njbad += (r.nj !== true)
    end
    @printf("%-12s n=%3d  20 trees: mismatches vs truth %d, NJ joins not in the true tree %d\n", shape, n, bad, njbad)
end

println("\n== scaling: distance queries used vs the full matrix ==")
@printf("%-12s %7s %12s %14s %9s %12s %8s %6s\n", "shape", "n", "queries", "full matrix", "fraction", "q/(n log2 n)", "levels", "RF")
for shape in (:yule, :caterpillar), n in (256, 1024, 4096, 16384)
    t0 = time(); r = run(rng, n, shape); dt = time() - t0
    @printf("%-12s %7d %12d %14d %8.3f%% %12.3f %8d %6d   (%.1fs)\n", shape, n, r.queries, r.full,
            100r.queries / r.full, r.queries / (n * log2(n)), r.maxlev, r.rf, dt)
end
