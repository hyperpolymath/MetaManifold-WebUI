# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E3: does a LAZY ZOOMABLE tree show the same thing as the full tree, on noisy data?
#
# A lazy zoomable tree never builds the tree on all n leaves.  It builds a tree on a subset S
# (a thumbnail of representatives, or the members of one region when the user zooms in).
# That view is trustworthy iff
#        NJ(D restricted to S)  ==  NJ(D) restricted to S          ("zoom consistency")
# For exact tree-like distances this is automatic.  Within the Atteson radius it is a theorem:
# restricting to S only merges edges, so the shortest edge cannot shrink, so the radius
# condition survives restriction and both sides equal the true tree on S.
# Real distances come from finite sequences and are far outside that radius.  This script
# measures what actually happens: sequences evolve down a random tree (Jukes-Cantor), distances
# are estimated from L sites, and we compare the two sides, and each side against the truth.
using Random, Printf, Statistics

# ---------- rooted binary trees as child lists ----------
struct RTree
    children::Vector{Tuple{Int,Int}}   # (0,0) for a leaf
    blen::Vector{Float64}              # length of the edge above each node
    nleaves::Int                       # leaves are nodes 1..nleaves
    root::Int
end

"Random topology by joining random pairs; edge lengths uniform in [lo, hi] substitutions per site."
function random_rtree(rng, n; lo = 0.005, hi = 0.05)
    children = fill((0, 0), n); blen = [lo + (hi - lo) * rand(rng) for _ in 1:n]; active = collect(1:n)
    while length(active) > 1
        i = rand(rng, 1:length(active)); a = active[i]; deleteat!(active, i)
        j = rand(rng, 1:length(active)); b = active[j]; deleteat!(active, j)
        push!(children, (a, b)); push!(blen, lo + (hi - lo) * rand(rng)); push!(active, length(children))
    end
    RTree(children, blen, n, length(children))
end

"Evolve sequences of L sites down the tree under Jukes-Cantor; returns leaf sequences."
function evolve(rng, t::RTree, L)
    seqs = Vector{Vector{UInt8}}(undef, length(t.children)); seqs[t.root] = rand(rng, UInt8(0):UInt8(3), L)
    stack = [t.root]
    while !isempty(stack)
        u = pop!(stack); (a, b) = t.children[u]; a == 0 && continue
        for c in (a, b)
            p = 0.75 * (1 - exp(-4 * t.blen[c] / 3)); s = copy(seqs[u])
            @inbounds for k in 1:L
                rand(rng) < p && (s[k] = (s[k] + rand(rng, UInt8(1):UInt8(3))) % UInt8(4))
            end
            seqs[c] = s; push!(stack, c)
        end
    end
    seqs[1:t.nleaves]
end

function jc_matrix(seqs)
    n = length(seqs); L = length(seqs[1]); D = zeros(n, n); ties = 0
    @inbounds for i in 1:n, j in i+1:n
        h = 0; si = seqs[i]; sj = seqs[j]
        for k in 1:L; h += si[k] != sj[k]; end
        p = h / L; d = p >= 0.74 ? 5.0 : -0.75 * log(1 - 4p / 3); D[i, j] = d; D[j, i] = d
    end
    D
end

"True path-length distances between leaves."
function true_matrix(t::RTree)
    N = length(t.children); par = zeros(Int, N); for u in 1:N; (a, b) = t.children[u]; a != 0 && (par[a] = u; par[b] = u); end
    depth = zeros(N); order = [t.root]; i = 1
    while i <= length(order); u = order[i]; i += 1; (a, b) = t.children[u]; a != 0 && (depth[a] = depth[u] + t.blen[a]; depth[b] = depth[u] + t.blen[b]; push!(order, a, b)); end
    anc = [Int[] for _ in 1:t.nleaves]
    for l in 1:t.nleaves; u = l; while u != 0; push!(anc[l], u); u = par[u]; end; end
    n = t.nleaves; D = zeros(n, n)
    for i in 1:n, j in i+1:n
        si = Set(anc[i]); lca = first(u for u in anc[j] if u in si)
        d = depth[i] + depth[j] - 2depth[lca]; D[i, j] = d; D[j, i] = d
    end
    D
end

# ---------- canonical neighbour joining on a (sub)matrix: returns the tree as child lists ----------
function nj(D::Matrix{Float64}, idx::Vector{Int})
    m = length(idx); d = D[idx, idx]; N = 2m - 2
    d = vcat(hcat(d, zeros(m, N - m)), zeros(N - m, N)); children = fill((0, 0), m); active = collect(1:m)
    tsum = zeros(N); for i in 1:m; tsum[i] = sum(@view d[i, 1:m]); end
    nxt = m
    while length(active) > 2
        r = length(active); bi = 0; bj = 0; bq = Inf
        @inbounds for x in 1:r, y in x+1:r
            i = active[x]; j = active[y]; q = (r - 2) * d[i, j] - tsum[i] - tsum[j]
            if q < bq; bq = q; bi = i; bj = j; end
        end
        nxt += 1; u = nxt; push!(children, (bi, bj)); s = 0.0
        @inbounds for k in active
            (k == bi || k == bj) && continue
            v = (d[bi, k] + d[bj, k] - d[bi, bj]) / 2; d[u, k] = v; d[k, u] = v; s += v
            tsum[k] += v - d[bi, k] - d[bj, k]
        end
        tsum[u] = s; filter!(k -> k != bi && k != bj, active); push!(active, u)
    end
    push!(children, (active[1], active[2]))            # final join closes an (arbitrary) root
    children, m                                        # leaves 1..m correspond to idx
end

# ---------- splits of a tree restricted to a leaf subset ----------
"Non-trivial bipartitions of leaf set S (given as key per leaf, 0 = not in S) induced by the tree."
function splits(children, nleaves, key::Vector{UInt64}, inS::Vector{Bool})
    N = length(children); h = zeros(UInt64, N); c = zeros(Int, N)
    for u in 1:nleaves; inS[u] && (h[u] = key[u]; c[u] = 1); end
    for u in nleaves+1:N; (a, b) = children[u]; h[u] = h[a] ⊻ h[b]; c[u] = c[a] + c[b]; end   # children precede parents
    tot = c[N]; all = h[N]; out = Set{UInt64}()
    for u in 1:N; (2 <= c[u] <= tot - 2) && push!(out, min(h[u], all ⊻ h[u])); end
    out
end

# ---------- one replicate ----------
function replicate(rng, n, L, k)
    t = random_rtree(rng, n); seqs = evolve(rng, t, L); D = jc_matrix(seqs); DT = true_matrix(t)
    key = rand(rng, UInt64, n); allin = fill(true, n)
    mu = minimum(t.blen); atteson = maximum(abs.(D .- DT)) / (mu / 2)        # < 1 means inside the radius
    full_children, _ = nj(D, collect(1:n))
    truth_all = splits(t.children, n, key, allin); full_all = splits(full_children, n, key, allin)
    acc_full = length(intersect(truth_all, full_all)) / (n - 3)
    res = Dict{Symbol,Vector{NTuple{3,Float64}}}()
    function view(S::Vector{Int})
        inS = fill(false, n); inS[S] .= true
        sub_children, m = nj(D, S); subkey = key[S]
        sub = splits(sub_children, m, subkey, fill(true, m))               # NJ(D|S)
        restr = splits(full_children, n, key, inS)                         # NJ(D)|S
        truth = splits(t.children, n, key, inS)                            # T|S
        denom = length(S) - 3
        (length(intersect(sub, restr)) / denom, length(intersect(sub, truth)) / denom, length(intersect(restr, truth)) / denom)
    end
    # (a) random subset
    res[:random] = [view(sort(randperm(rng, n)[1:k])) for _ in 1:4]
    # (b) thumbnail: farthest-point representatives (spread out across the data)
    reps = [rand(rng, 1:n)]; mind = copy(D[reps[1], :])
    while length(reps) < k; r = argmax(mind); push!(reps, r); mind .= min.(mind, @view D[r, :]); end
    res[:thumbnail] = [view(sort(reps))]
    # (c) zoom: the k leaves nearest to a random leaf (one neighbourhood)
    res[:zoom] = [view(sort(sortperm(D[rand(rng, 1:n), :])[1:k])) for _ in 1:4]
    (acc_full = acc_full, atteson = atteson, res = res)
end

function main()
    rng = MersenneTwister(20261116); n = 512; k = 64; reps = 5
    println("n = $n leaves, views of k = $k, $reps random trees per row, edge lengths 0.005-0.05 subs/site")
    println("Columns: agree = splits shared by the lazy view NJ(D|S) and the full tree cut down to S;")
    println("         lazy-true / full-true = share of the true splits on S each of them recovers.\n")
    @printf("%-7s %-10s %8s %10s %10s %10s   %s\n", "sites", "view", "agree", "lazy-true", "full-true", "full NJ", "max error / Atteson radius")
    for L in (250, 1000, 5000, 50000)
        rs = [replicate(rng, n, L, k) for _ in 1:reps]
        for v in (:random, :thumbnail, :zoom)
            xs = reduce(vcat, [r.res[v] for r in rs])
            @printf("%-7d %-10s %7.1f%% %9.1f%% %9.1f%% %9.1f%%   %.1f\n", L, v,
                    100mean(x[1] for x in xs), 100mean(x[2] for x in xs), 100mean(x[3] for x in xs),
                    100mean(r.acc_full for r in rs), mean(r.atteson for r in rs))
        end
    end
    println("\n== control: exact tree-like distances (no noise) must give 100% everywhere ==")
    t = random_rtree(rng, n); DT = true_matrix(t); key = rand(rng, UInt64, n)
    fc, _ = nj(DT, collect(1:n)); S = sort(randperm(rng, n)[1:k]); inS = fill(false, n); inS[S] .= true
    sc, m = nj(DT, S)
    a = splits(sc, m, key[S], fill(true, m)); b = splits(fc, n, key, inS); c = splits(t.children, n, key, inS)
    @printf("agree %.1f%%  lazy-true %.1f%%  full-true %.1f%%  (full NJ vs truth %.1f%%)\n", 100length(intersect(a, b)) / (k - 3),
            100length(intersect(a, c)) / (k - 3), 100length(intersect(b, c)) / (k - 3),
            100length(intersect(splits(fc, n, key, fill(true, n)), splits(t.children, n, key, fill(true, n)))) / (n - 3))
    println("\ndistance look-ups: full tree needs ", n * (n - 1) ÷ 2, "; one view of $k needs ", k * (k - 1) ÷ 2,
            " (", round(100 * (k * (k - 1) ÷ 2) / (n * (n - 1) ÷ 2), digits = 2), "%); choosing spread-out representatives costs ", k * n, " more")
end
main()
