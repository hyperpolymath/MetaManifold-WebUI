# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E7: evidence verdicts on placements, with a real ground truth.
#
# usage: julia -O2 -t 4 placement_evidence.jl <silva.bacteria.fasta>
#
# Real full-length 16S sequences (the mothur SILVA bacterial reference alignment).
#   1. Build a reference tree from N full-length sequences (neighbour joining).
#   2. Leave one out: prune sequence q from the tree.  Where it was attached is the TRUTH.
#   3. Place q back using only an amplicon-length fragment of it (the first 240 bases of the
#      V4 window), by weighted least squares against the tree's path distances.
#   4. Bootstrap the fragment's columns B times.  For every clade C of the tree, the share of
#      replicates that place q inside C is the placement mass m(C).
#   5. Verdict for "q belongs to clade C":  entailed if m(C) >= 1 - alpha, refuted if
#      m(C) <= alpha, unresolved otherwise.
#   6. Score the verdicts against the truth.
#
# "Inside C" means attached strictly below the clade's root, so a sequence sister to C is not
# in C.  Mass is monotone under clade inclusion by construction, so an entailed verdict for a
# clade is entailed for every clade that contains it.
using Random, Printf, Statistics

const V4_START = 11894          # mothur MiSeq SOP pcr.seqs coordinates for the V4 region in this alignment
const V4_END = 25319
const FRAG = 240

code(c::UInt8) = c == UInt8('A') ? 0x01 : c == UInt8('C') ? 0x02 : c == UInt8('G') ? 0x03 :
                 (c == UInt8('T') || c == UInt8('U')) ? 0x04 : 0x00

function load_alignment(path, N, rng)
    eligible = Int[]; idx = 0
    open(path) do io
        while !eof(io)
            readline(io); s = codeunits(readline(io)); idx += 1
            tot = 0; v4 = 0
            @inbounds for (k, c) in enumerate(s)
                if code(c) != 0x00; tot += 1; (V4_START <= k <= V4_END) && (v4 += 1); end
            end
            (tot >= 1200 && v4 >= FRAG) && push!(eligible, idx)
        end
    end
    chosen = Set(shuffle(rng, eligible)[1:N]); names = String[]; rows = Vector{Vector{UInt8}}(); idx = 0
    open(path) do io
        while !eof(io)
            h = readline(io); s = readline(io); idx += 1
            if idx in chosen; push!(names, h[2:end]); push!(rows, UInt8[code(c) for c in codeunits(s)]); end
        end
    end
    L = length(rows[1]); keep = [k for k in 1:L if count(r -> r[k] != 0x00, rows) >= 2]
    A = zeros(UInt8, N, length(keep)); for i in 1:N, (j, k) in enumerate(keep); A[i, j] = rows[i][k]; end
    v4cols = [j for (j, k) in enumerate(keep) if V4_START <= k <= V4_END]
    names, A, v4cols, length(eligible)
end

jc(p) = p >= 0.74 ? 5.0 : -0.75 * log(1 - 4p / 3)

function full_distances(A)
    N, L = size(A); D = zeros(N, N)
    Threads.@threads for i in 1:N
        for j in i+1:N
            v = 0; d = 0
            @inbounds for k in 1:L
                a = A[i, k]; b = A[j, k]
                if a != 0x00 && b != 0x00; v += 1; d += (a != b); end
            end
            x = v == 0 ? 5.0 : jc(d / v); D[i, j] = x; D[j, i] = x
        end
    end
    D
end

# canonical neighbour joining, rooted at the last join; leaves 1..N, internal nodes after
function nj_tree(D::Matrix{Float64})
    m = size(D, 1); N = 2m - 1; d = zeros(N, N); d[1:m, 1:m] .= D
    children = fill((0, 0), N); parent = zeros(Int, N); blen = zeros(N); active = collect(1:m)
    tsum = zeros(N); for i in 1:m; tsum[i] = sum(@view d[i, 1:m]); end
    nxt = m
    while length(active) > 2
        r = length(active); bi = 0; bj = 0; bq = Inf
        @inbounds for x in 1:r, y in x+1:r
            i = active[x]; j = active[y]; q = (r - 2) * d[i, j] - tsum[i] - tsum[j]
            if q < bq; bq = q; bi = i; bj = j; end
        end
        nxt += 1; u = nxt; children[u] = (bi, bj); parent[bi] = u; parent[bj] = u
        li = d[bi, bj] / 2 + (tsum[bi] - tsum[bj]) / (2 * (r - 2)); blen[bi] = max(li, 0.0); blen[bj] = max(d[bi, bj] - li, 0.0)
        s = 0.0
        @inbounds for k in active
            (k == bi || k == bj) && continue
            v = (d[bi, k] + d[bj, k] - d[bi, bj]) / 2; d[u, k] = v; d[k, u] = v; s += v
            tsum[k] += v - d[bi, k] - d[bj, k]
        end
        tsum[u] = s; filter!(k -> k != bi && k != bj, active); push!(active, u)
    end
    a, b = active; root = N; children[root] = (a, b); parent[a] = root; parent[b] = root
    blen[a] = max(d[a, b], 0.0) / 2; blen[b] = blen[a]
    children, parent, blen, root
end

"Prune leaf q.  Returns (children, parent, blen, root, alive, truth) with truth = the node above which q hung."
function prune(children, parent, blen, root, q)
    ch = copy(children); pa = copy(parent); bl = copy(blen); alive = trues(length(pa))
    p = pa[q]; s = ch[p][1] == q ? ch[p][2] : ch[p][1]; alive[q] = false; alive[p] = false
    if p == root
        pa[s] = 0; return ch, pa, bl, s, alive, 0          # truth undefined: q hung from the root
    end
    g = pa[p]; pa[s] = g; ch[g] = ch[g][1] == p ? (s, ch[g][2]) : (ch[g][1], s); bl[s] += bl[p]
    ch, pa, bl, root, alive, s
end

"Post-order of live nodes below root, and for every node the set of leaves below it."
function below_sets(ch, root, nleaves, nn)
    order = Int[]; st = [root]
    while !isempty(st); u = pop!(st); push!(order, u); a, b = ch[u]; a != 0 && push!(st, a, b); end
    below = [falses(nleaves) for _ in 1:nn]
    for u in Iterators.reverse(order)
        a, b = ch[u]
        if a == 0; below[u][u] = true else below[u] .= below[a] .| below[b] end
    end
    order, below
end

"Path distance from every live node to every leaf."
function node_leaf_dist(ch, pa, bl, order, nleaves, nn)
    Dn = zeros(nn, nleaves)
    for r in 1:nleaves
        (r in order) || continue
        dist = fill(-1.0, nn); dist[r] = 0.0; st = [r]
        while !isempty(st)
            u = pop!(st)
            p = pa[u]; if p != 0 && dist[p] < 0; dist[p] = dist[u] + bl[u]; push!(st, p); end
            a, b = ch[u]
            if a != 0
                for c in (a, b); if dist[c] < 0; dist[c] = dist[u] + bl[c]; push!(st, c); end; end
            end
        end
        for u in order; Dn[u, r] = dist[u]; end
    end
    Dn
end

"Weighted least-squares placement.  Returns the node whose edge-above receives the query."
function place(delta::Vector{Float64}, w::Vector{Float64}, order, pa, bl, below, Dn, root)
    best = 0; bestsse = Inf; n = length(delta)
    for e in order
        e == root && continue
        par = pa[e]; ell = bl[e]; B = below[e]
        wB = 0.0; sB = 0.0; qB = 0.0; wA = 0.0; sA = 0.0; qA = 0.0
        @inbounds for r in 1:n
            wr = w[r]; wr == 0.0 && continue
            if B[r]
                a = delta[r] - Dn[e, r]; wB += wr; sB += wr * a; qB += wr * a * a
            else
                b = delta[r] - Dn[par, r] - ell; wA += wr; sA += wr * b; qA += wr * b * b
            end
        end
        (wB == 0.0 || wA == 0.0) && continue
        s = sB / wB; t = sA / wA                     # s = p + x, t = p - x, x measured upward from e
        x = clamp((s - t) / 2, 0.0, ell)
        p = max(((sB - x * wB) + (sA + x * wA)) / (wB + wA), 0.0)
        cB = p + x; cA = p - x
        sse = (qB - 2cB * sB + cB * cB * wB) + (qA - 2cA * sA + cA * cA * wA)
        if sse < bestsse; bestsse = sse; best = e; end
    end
    best
end

strictly_below(a, e, pa) = (u = pa[a]; while u != 0; u == e && return true; u = pa[u]; end; false)
function edges_apart(a, b, pa)
    a == b && return 0
    da = Dict{Int,Int}(); u = a; k = 0; while u != 0; da[u] = k; u = pa[u]; k += 1; end
    u = b; k = 0; while u != 0; haskey(da, u) && return da[u] + k; u = pa[u]; k += 1; end
    typemax(Int)
end

function experiment(A, v4cols, tree, rng; Q = 150, Bboot = 100, fraglen = FRAG, shuffle_truth = false)
    children, parent, blen, root = tree; N = size(A, 1); nn = length(parent)
    queries = shuffle(rng, 1:N)[1:Q]; results = Vector{Any}(undef, Q)
    seeds = rand(rng, UInt64, Q)
    Threads.@threads for qi in 1:Q
        q = queries[qi]; lrng = MersenneTwister(seeds[qi])
        ch, pa, bl, rt, alive, truth = prune(children, parent, blen, root, q)
        if truth == 0; results[qi] = nothing; continue; end
        order, below = below_sets(ch, rt, N, nn); Dn = node_leaf_dist(ch, pa, bl, order, N, nn)
        cols = fraglen == 0 ? collect(1:size(A, 2)) : [k for k in v4cols if A[q, k] != 0x00][1:fraglen]
        src = shuffle_truth ? rand(lrng, setdiff(1:N, q)) : q    # negative control: place a different sequence
        K = length(cols); valid = falses(N, K); diff = falses(N, K)
        for r in 1:N, (j, k) in enumerate(cols)
            a = A[src, k]; b = A[r, k]
            if a != 0x00 && b != 0x00; valid[r, j] = true; diff[r, j] = (a != b); end
        end
        function dist_weights(cnt)
            delta = zeros(N); w = zeros(N)
            for r in 1:N
                (r == q || r == src) && continue
                v = 0; d = 0
                @inbounds for j in 1:K; c = cnt[j]; c == 0 && continue; valid[r, j] && (v += c; diff[r, j] && (d += c)); end
                v < 50 && continue
                delta[r] = jc(d / v); w[r] = 1 / (delta[r] + 0.01)^2
            end
            delta, w
        end
        d0, w0 = dist_weights(ones(Int, K)); a0 = place(d0, w0, order, pa, bl, below, Dn, rt)
        boots = Int[]
        for _ in 1:Bboot
            cnt = zeros(Int, K); for _ in 1:K; cnt[rand(lrng, 1:K)] += 1; end
            d, w = dist_weights(cnt); push!(boots, place(d, w, order, pa, bl, below, Dn, rt))
        end
        clades = [e for e in order if e != rt && ch[e][1] != 0]
        mass = Dict(e => count(a -> strictly_below(a, e, pa), boots) / Bboot for e in clades)
        intruth = Dict(e => strictly_below(truth, e, pa) for e in clades)
        csize = Dict(e => count(below[e]) for e in clades)
        results[qi] = (exact = a0 == truth, apart = edges_apart(a0, truth, pa), mass = mass, intruth = intruth, size = csize, nref = N - 1)
    end
    filter(!isnothing, results)
end

function report(name, res; alphas = (0.0, 0.05))
    println("\n== ", name, " ==")
    @printf("queries scored: %d;  placed on exactly the true edge: %.1f%%;  within 2 edges: %.1f%%;  median edges apart: %d\n",
            length(res), 100mean(r.exact for r in res), 100mean(r.apart <= 2 for r in res), median(r.apart for r in res))
    for alpha in alphas
        ent_ok = 0; ent_bad = 0; ref_ok = 0; ref_bad = 0; unr_in = 0; unr_out = 0; pin = Int[]; pin_ok = 0; nopin = 0
        for r in res
            best = 0; bestsize = typemax(Int)
            for (e, m) in r.mass
                t = r.intruth[e]
                if m >= 1 - alpha
                    t ? (ent_ok += 1) : (ent_bad += 1)
                    r.size[e] < bestsize && ((best, bestsize) = (e, r.size[e]))
                elseif m <= alpha
                    t ? (ref_bad += 1) : (ref_ok += 1)
                else
                    t ? (unr_in += 1) : (unr_out += 1)
                end
            end
            if best == 0; nopin += 1 else push!(pin, bestsize); r.intruth[best] && (pin_ok += 1) end
        end
        @printf("\nverdict rule: entailed if mass >= %.2f, refuted if mass <= %.2f\n", 1 - alpha, alpha)
        @printf("  entailed   %7d verdicts, wrong %5d  -> sound %.2f%%\n", ent_ok + ent_bad, ent_bad, 100ent_ok / max(ent_ok + ent_bad, 1))
        @printf("  refuted    %7d verdicts, wrong %5d  -> sound %.3f%%\n", ref_ok + ref_bad, ref_bad, 100ref_ok / max(ref_ok + ref_bad, 1))
        @printf("  unresolved %7d verdicts (%d where the truth is inside, %d where it is not)\n", unr_in + unr_out, unr_in, unr_out)
        @printf("  of the clades that truly contain the sequence: entailed %.1f%%, unresolved %.1f%%, wrongly refuted %.1f%%\n",
                100ent_ok / (ent_ok + unr_in + ref_bad), 100unr_in / (ent_ok + unr_in + ref_bad), 100ref_bad / (ent_ok + unr_in + ref_bad))
        if !isempty(pin)
            @printf("  smallest entailed clade per query: median %d of %d references (quartiles %d, %d); it contains the truth for %.1f%% of queries; no entailed clade for %d queries\n",
                    median(pin), res[1].nref, quantile(pin, 0.25), quantile(pin, 0.75), 100pin_ok / length(pin), nopin)
        end
    end
    println("\ncalibration of placement mass (is a clade given mass m right about m of the time?)")
    edges = [0.0, 0.05, 0.25, 0.5, 0.75, 0.95, 1.0]; hit = zeros(Int, 7); tot = zeros(Int, 7)
    for r in res, (e, m) in r.mass
        b = m == 0.0 ? 1 : m == 1.0 ? 7 : findfirst(x -> m <= x, edges[2:end]) + 1
        tot[b] += 1; hit[b] += r.intruth[e]
    end
    labels = ["0", "(0, .05]", "(.05, .25]", "(.25, .5]", "(.5, .75]", "(.75, .95]", "(.95, 1]"]
    for b in 1:7
        tot[b] > 0 && @printf("  mass %-11s clades %7d   truth inside %6.2f%%\n", labels[b], tot[b], 100hit[b] / tot[b])
    end
end

function main(path)
    rng = MersenneTwister(20261117); N = 400
    names, A, v4cols, nelig = load_alignment(path, N, rng)
    @printf("alignment: %d eligible sequences; using %d; %d informative columns, %d of them in the V4 window\n", nelig, N, size(A, 2), length(v4cols))
    D = full_distances(A); tree = nj_tree(D)
    od = [D[i, j] for i in 1:N for j in i+1:N]
    @printf("full-length distances: median %.3f, range %.3f .. %.3f\n", median(od), minimum(od), maximum(od))
    report("amplicon fragment (first $FRAG bases of the V4 window)", experiment(A, v4cols, tree, MersenneTwister(1)))
    report("positive control: the whole sequence as the query", experiment(A, v4cols, tree, MersenneTwister(1); fraglen = 0))
    report("negative control: a different sequence placed, scored against this one's truth", experiment(A, v4cols, tree, MersenneTwister(1); shuffle_truth = true))
end
main(ARGS[1])
