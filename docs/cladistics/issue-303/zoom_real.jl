# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E4: the lazy zoomable tree and the exact Phred filter, on REAL reads (MiSeq_SOP).
#
# usage: julia zoom_real.jl <directory holding *_R1_001.fastq>
#
# Part A  Phred on real quality strings: exact expected-error filter vs double precision.
# Part B  Zoom consistency on real sequences: does a tree built lazily on a subset S agree with the
#         full neighbour-joining tree cut down to S?  There is no known true tree for real data, so
#         only agreement is measured, never accuracy.
#
# Honest limits, stated up front:
#  - sequences are dereplicated forward reads (240 bases), NOT DADA2-denoised ASVs.  A second set
#    removes anything within one edit of a more abundant sequence, a crude stand-in for denoising.
#  - distances are Jukes-Cantor corrections of edit distance / length, in double precision.
using Random, Printf, Statistics

const TRUNC = 240
const MAXEE = 2

# ---------- FASTQ ----------
function read_fastq(path)
    seqs = String[]; quals = String[]
    open(path) do io
        while !eof(io)
            readline(io); s = readline(io); readline(io); q = readline(io)
            push!(seqs, s); push!(quals, q)
        end
    end
    seqs, quals
end

# ---------- Part A: exact expected errors ----------
# EE = sum 10^(-Q/10).  With Q = 10a + b the term is 10^(-a) * theta^b, theta = 10^(-1/10).
# Keep ten integer coefficients over the common denominator 10^9 (Q <= 99): pure integer counting.
const POW10 = [big(10)^k for k in 0:9]
function ee_coeffs(q::AbstractVector{UInt8})          # q are Phred values, not ASCII
    c = zeros(Int64, 10)
    @inbounds for Q in q
        a, b = divrem(Int(Q), 10); c[b+1] += 10^(9 - a)
    end
    c
end
"sign of EE - T for integer threshold T, exact (bisection on theta; P is monotone in theta)."
function cmp_ee(c::Vector{Int64}, T::Int)
    p = Rational{BigInt}.(c) .// big(10)^9; p[1] -= T
    all(iszero, p) && return 0
    all(iszero, @view p[2:end]) && return Int(sign(p[1]))
    lo, hi = big(0) // 1, big(1) // 1
    while true
        slo = sign(foldr((ck, acc) -> ck + lo * acc, p)); shi = sign(foldr((ck, acc) -> ck + hi * acc, p))
        (slo == shi && slo != 0) && return Int(slo)
        mid = (lo + hi) / 2
        if 10 * mid^10 < 1; lo = mid else hi = mid end
    end
end
ee_float(q) = sum(10.0^(-Int(Q) / 10) for Q in q)

# ---------- distances ----------
function edit_distance(a::Vector{UInt8}, b::Vector{UInt8}, prev::Vector{Int32}, cur::Vector{Int32})
    n = length(a); m = length(b)
    @inbounds for j in 0:m; prev[j+1] = j; end
    @inbounds for i in 1:n
        cur[1] = i; ai = a[i]
        for j in 1:m
            sub = prev[j] + (ai != b[j]); del = prev[j+1] + 1; ins = cur[j] + 1
            cur[j+1] = min(sub, del, ins)
        end
        prev, cur = cur, prev
    end
    Int(prev[m+1])
end
function distance_matrix(seqs::Vector{Vector{UInt8}})
    n = length(seqs); D = zeros(n, n); E = zeros(Int, n, n)
    Threads.@threads for i in 1:n
        prev = zeros(Int32, TRUNC + 1); cur = zeros(Int32, TRUNC + 1)
        for j in i+1:n
            e = edit_distance(seqs[i], seqs[j], prev, cur); p = e / TRUNC
            d = p >= 0.74 ? 5.0 : -0.75 * log(1 - 4p / 3)
            D[i, j] = d; D[j, i] = d; E[i, j] = e; E[j, i] = e
        end
    end
    D, E
end

# ---------- canonical neighbour joining (same code as the simulation, E3) ----------
function nj(D::Matrix{Float64}, idx::Vector{Int})
    m = length(idx); d = D[idx, idx]; N = 2m - 2
    d = vcat(hcat(d, zeros(m, N - m)), zeros(N - m, N)); children = fill((0, 0), m); active = collect(1:m); blen = zeros(N)
    tsum = zeros(N); for i in 1:m; tsum[i] = sum(@view d[i, 1:m]); end
    nxt = m
    while length(active) > 2
        r = length(active); bi = 0; bj = 0; bq = Inf
        @inbounds for x in 1:r, y in x+1:r
            i = active[x]; j = active[y]; q = (r - 2) * d[i, j] - tsum[i] - tsum[j]
            if q < bq; bq = q; bi = i; bj = j; end
        end
        nxt += 1; u = nxt; push!(children, (bi, bj)); s = 0.0
        li = d[bi, bj] / 2 + (tsum[bi] - tsum[bj]) / (2 * (r - 2)); blen[bi] = max(li, 0.0); blen[bj] = max(d[bi, bj] - li, 0.0)
        @inbounds for k in active
            (k == bi || k == bj) && continue
            v = (d[bi, k] + d[bj, k] - d[bi, bj]) / 2; d[u, k] = v; d[k, u] = v; s += v
            tsum[k] += v - d[bi, k] - d[bj, k]
        end
        tsum[u] = s; filter!(k -> k != bi && k != bj, active); push!(active, u)
    end
    push!(children, (active[1], active[2])); blen[active[1]] = max(d[active[1], active[2]], 0.0)
    children, m, blen
end
function splits(children, nleaves, key::Vector{UInt64}, inS::Vector{Bool}, blen::Vector{Float64})
    N = length(children); h = zeros(UInt64, N); c = zeros(Int, N)
    for u in 1:nleaves; inS[u] && (h[u] = key[u]; c[u] = 1); end
    for u in nleaves+1:N; (a, b) = children[u]; h[u] = h[a] ⊻ h[b]; c[u] = c[a] + c[b]; end
    tot = c[N]; all = h[N]; out = Dict{UInt64,Float64}()      # split => summed length of the edges that induce it
    for u in 1:N-1; if 2 <= c[u] <= tot - 2; k = min(h[u], all ⊻ h[u]); out[k] = get(out, k, 0.0) + blen[u]; end; end
    out
end

ci(xs) = (mean(xs), quantile(xs, 0.025), quantile(xs, 0.975))

function zoom_test(rng, name, seqs, k; nviews = 40)
    n = length(seqs); D, E = distance_matrix(seqs); key = rand(rng, UInt64, n)
    full, _, fblen = nj(D, collect(1:n))
    offdiag = [E[i, j] for i in 1:n for j in i+1:n]
    @printf("\n%s: n = %d sequences; edit distance median %d, range %d..%d; %.1f%% of pairs within 3 edits\n",
            name, n, median(offdiag), minimum(offdiag), maximum(offdiag), 100mean(offdiag .<= 3))
    one = 1 / TRUNC                                   # one substitution, as a distance
    # For a view S: every split of the full tree cut down to S, with the length of the branch that
    # carries it.  Report how much of that structure the lazy view reproduces:
    #   all      every split counted equally (includes zero-length, i.e. unsupported, branches)
    #   weighted each split counted by its branch length
    #   >=1, >=3 only splits whose branch is at least 1 or 3 substitutions long
    function view(S, fullkey)
        inS = fill(false, n); inS[S] .= true
        sub, m, sblen = nj(D, S); a = splits(sub, m, key[S], fill(true, m), sblen); b = splits(full, n, fullkey, inS, fblen)
        tot = length(b); shared = count(kk -> haskey(a, kk), keys(b))
        wtot = sum(values(b)); wsh = sum((v for (kk, v) in b if haskey(a, kk)); init = 0.0)
        b1 = [kk for (kk, v) in b if v >= one]; b3 = [kk for (kk, v) in b if v >= 3one]
        (shared / max(tot, 1), wsh / max(wtot, eps()), isempty(b1) ? NaN : count(kk -> haskey(a, kk), b1) / length(b1),
         isempty(b3) ? NaN : count(kk -> haskey(a, kk), b3) / length(b3), length(b1) / max(tot, 1), length(b3) / max(tot, 1))
    end
    views = Dict{String,Vector{NTuple{6,Float64}}}()
    views["random subset"] = [view(sort(randperm(rng, n)[1:k]), key) for _ in 1:nviews]
    views["zoomed-in neighbourhood"] = [view(sort(sortperm(D[rand(rng, 1:n), :])[1:k]), key) for _ in 1:nviews]
    th = NTuple{6,Float64}[]
    for _ in 1:nviews
        reps = [rand(rng, 1:n)]; mind = copy(D[reps[1], :])
        while length(reps) < k; r = argmax(mind); push!(reps, r); mind .= min.(mind, @view D[r, :]); end
        push!(th, view(sort(reps), key))
    end
    views["thumbnail (spread out)"] = th
    keyp = key[randperm(rng, n)]
    views["chance (labels shuffled)"] = [view(sort(randperm(rng, n)[1:k]), keyp) for _ in 1:nviews]
    @printf("  %-26s %9s %9s %16s %16s   %s\n", "view", "all", "weighted", ">=1 subst", ">=3 subst", "share of splits with a >=1 / >=3 branch")
    for label in ("random subset", "thumbnail (spread out)", "zoomed-in neighbourhood", "chance (labels shuffled)")
        xs = views[label]; col(i) = filter(!isnan, [x[i] for x in xs])
        f(i) = (c = col(i); isempty(c) ? "    n/a" : @sprintf("%5.1f%%", 100mean(c)))
        g(i) = (c = col(i); isempty(c) ? "n/a" : @sprintf("%5.1f%% (%4.1f..%5.1f)", 100mean(c), 100quantile(c, 0.025), 100quantile(c, 0.975)))
        @printf("  %-26s %9s %9s %16s %16s   %s / %s\n", label, f(1), f(2), g(3), g(4), f(5), f(6))
    end
    @printf("  distance look-ups: full tree %d, one view of %d: %d (%.2f%%)\n", n * (n - 1) ÷ 2, k, k * (k - 1) ÷ 2,
            100 * (k * (k - 1) ÷ 2) / (n * (n - 1) ÷ 2))
end

function main(dir)
    rng = MersenneTwister(20261117)
    files = sort(filter(f -> endswith(f, "_R1_001.fastq"), readdir(dir; join = true)))
    println("forward-read files: ", length(files))
    counts = Dict{String,Int}(); nreads = 0; kept = 0; short = 0; hasN = 0
    qhist = zeros(Int, 100); float_wrong = 0; exact_ties = 0; minabs = Inf; order_dep = 0; over = 0
    t_exact = 0.0; t_float = 0.0
    for f in files
        seqs, quals = read_fastq(f)
        for (s, qs) in zip(seqs, quals)
            nreads += 1
            if length(s) < TRUNC; short += 1; continue; end
            st = s[1:TRUNC]
            q = UInt8[UInt8(c) - 0x21 for c in codeunits(qs)[1:TRUNC]]
            for Q in q; qhist[Q+1] += 1; end
            t_exact += @elapsed (sgn = cmp_ee(ee_coeffs(q), MAXEE))
            t_float += @elapsed (ef = ee_float(q))
            sf = ef > MAXEE ? 1 : (ef < MAXEE ? -1 : 0)
            float_wrong += (sf != sgn); exact_ties += (sgn == 0); minabs = min(minabs, abs(ef - MAXEE))
            order_dep += (ee_float(sort(q)) != ef)
            if sgn > 0; over += 1; continue; end
            if occursin('N', st); hasN += 1; continue; end
            kept += 1; counts[st] = get(counts, st, 0) + 1
        end
    end
    println("\n== Part A: Phred expected-error filter on real reads (truncated to $TRUNC, maxEE = $MAXEE) ==")
    @printf("reads %d; shorter than %d: %d; EE > %d (exact): %d; containing N: %d; kept: %d\n", nreads, TRUNC, short, MAXEE, over, hasN, kept)
    println("distinct quality values seen: ", join([Q - 1 for Q in 1:100 if qhist[Q] > 0], " "))
    @printf("double precision disagrees with exact on %d of %d reads; exact ties with the threshold: %d\n", float_wrong, nreads - short, exact_ties)
    @printf("closest any read came to the threshold: |EE - %d| = %.3g\n", MAXEE, minabs)
    @printf("reads whose double-precision EE changes if the bases are summed in sorted order: %d (%.1f%%)\n", order_dep, 100order_dep / (nreads - short))
    @printf("time: exact (integer counts + exact compare) %.2f s, double %.2f s (ratio %.1fx)\n", t_exact, t_float, t_exact / t_float)

    println("\n== Part B: zoom consistency on real sequences ==")
    uniq = sort(collect(counts); by = x -> -x[2])
    @printf("distinct sequences: %d; with abundance >= 2: %d; >= 8: %d\n", length(uniq), count(x -> x[2] >= 2, uniq), count(x -> x[2] >= 8, uniq))
    tobytes(s) = Vector{UInt8}(codeunits(s))
    top = [tobytes(x[1]) for x in uniq[1:min(512, length(uniq))]]
    zoom_test(rng, "Set 1 (512 most abundant distinct reads, error variants included)", top, 64)
    # crude denoise: walk down by abundance, drop anything within one edit of a kept sequence
    keptseqs = Vector{Vector{UInt8}}(); prev = zeros(Int32, TRUNC + 1); cur = zeros(Int32, TRUNC + 1)
    for x in uniq
        x[2] < 2 && break
        s = tobytes(x[1]); near = false
        for t in keptseqs
            if edit_distance(s, t, prev, cur) <= 1; near = true; break; end
        end
        near || push!(keptseqs, s)
        length(keptseqs) >= 384 && break
    end
    zoom_test(rng, "Set 2 (crude denoise: nothing within one edit of a more abundant sequence)", keptseqs, 64)
end
main(ARGS[1])
