# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Shared code for the issue-303 experiments: FASTQ reading, exact Phred expected errors, edit distance,
# canonical neighbour joining with branch lengths, and tree splits restricted to a leaf subset.
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


# ---------- real reads: filter, dereplicate, crude denoise ----------
"Distinct forward reads (truncated, EE-filtered, no N), most abundant first, dropping anything
within one edit of a kept sequence and anything seen once. At most nmax sequences."
function load_set(dir, nmax)
    files = sort(filter(f -> endswith(f, "_R1_001.fastq"), readdir(dir; join = true)))
    counts = Dict{String,Int}()
    for f in files
        seqs, quals = read_fastq(f)
        for (s, qs) in zip(seqs, quals)
            length(s) < TRUNC && continue
            q = UInt8[UInt8(c) - 0x21 for c in codeunits(qs)[1:TRUNC]]
            ee_float(q) > MAXEE && continue          # E4: identical to the exact filter on every read here
            st = s[1:TRUNC]; occursin('N', st) && continue
            counts[st] = get(counts, st, 0) + 1
        end
    end
    uniq = sort(collect(counts); by = x -> (-x[2], x[1]))
    kept = Vector{Vector{UInt8}}(); prev = zeros(Int32, TRUNC + 1); cur = zeros(Int32, TRUNC + 1)
    for x in uniq                                     # crude denoise, as E4 set 2
        x[2] < 2 && break
        s = Vector{UInt8}(codeunits(x[1]))
        any(t -> edit_distance(s, t, prev, cur) <= 1, kept) || push!(kept, s)
        length(kept) >= nmax && break
    end
    kept
end
