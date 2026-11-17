# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E9 (issue 303): error of entailed clade verdicts by clade depth, with the
# application's placement step.  See ../README.md, section 9.  These files replace their
# namesakes from ../epa/; 01_select.jl, 07_selfcheck_truth.jl and lib_nwk.jl are used unchanged.
# usage: julia 06_tables.jl new RAW_DIR      -> T1-T6 for draws A, B and pooled (amp), plus pos for A
#        julia 06_tables.jl old OLD_RAW_DIR  -> reproduces the N=200 headline numbers from ../epa/raw/perclade_amp.tsv (no n_refs column there)
using Printf, Statistics
# ---------- Clopper-Pearson (exact, two-sided) by bisection on the BigFloat binomial CDF ----------
setprecision(BigFloat, 256)
function bcdf(x::Int, n::Int, p::BigFloat)   # P(X <= x)
    x < 0 && return big"0.0"; x >= n && return big"1.0"
    s = big"0.0"; q = 1 - p
    for i in 0:x; s += binomial(big(n), big(i)) * p^i * q^(n - i); end
    s
end
function cp_interval(x::Int, n::Int; level = 0.05)
    a = BigFloat(level) / 2
    lo = big"0.0"; hi = big"1.0"
    if x > 0     # lower: P(X >= x | p) = a  (increasing in p)
        l, h = big"0.0", big"1.0"
        for _ in 1:200; m = (l + h) / 2; (1 - bcdf(x - 1, n, m) < a) ? (l = m) : (h = m); end
        lo = (l + h) / 2
    end
    if x < n     # upper: P(X <= x | p) = a  (decreasing in p)
        l, h = big"0.0", big"1.0"
        for _ in 1:200; m = (l + h) / 2; (bcdf(x, n, m) > a) ? (l = m) : (h = m); end
        hi = (l + h) / 2
    else hi = big"1.0" end
    Float64(lo), Float64(hi)
end
# ---------- loading ----------
struct DS; label::String; pq::Dict{Int,Vector{String}}; cl::Dict{Int,Vector{Tuple{Int,Float64,Bool}}}; nref::Int; end
function load(label, pqpath, pcpath; keyoff = 0, nref_default = 199)
    pq = Dict{Int,Vector{String}}(); cl = Dict{Int,Vector{Tuple{Int,Float64,Bool}}}()
    rows = [split(l, "\t") for l in eachline(pqpath)][2:end]
    for r in rows; r[3] == "OK" && (pq[parse(Int, r[1]) + keyoff] = String.(r)); end
    hdr = split(readline(pcpath), "\t"); nref = nref_default
    for l in Iterators.drop(eachline(pcpath), 1)
        r = split(l, "\t"); qi = parse(Int, r[1]) + keyoff
        push!(get!(cl, qi, Tuple{Int,Float64,Bool}[]), (parse(Int, r[2]), parse(Float64, r[3]), r[4] == "1"))
        length(r) >= 5 && (nref = parse(Int, r[5]))
    end
    DS(label, pq, cl, nref)
end
merge_ds(label, a::DS, b::DS) = DS(label, merge(a.pq, b.pq), merge(a.cl, b.cl), a.nref)
isent(m, alpha) = m >= 1 - alpha - 1e-12
isref(m, alpha) = m <= alpha + 1e-12
# ---------- T1 ----------
function t1(d::DS)
    ok = [d.pq[q] for q in sort(collect(keys(d.pq)))]
    ex = [r[7] == "1" for r in ok]; ap = [parse(Int, r[8]) for r in ok]; tot = [parse(Float64, r[5]) for r in ok]; npl = [parse(Int, r[4]) for r in ok]
    @printf("  queries scored %d; placed on exactly the true edge: %d of %d (%.1f%%); within 2 edges: %d of %d; median edges apart %g\n", length(ok), sum(ex), length(ok), 100mean(ex), count(<=(2), ap), length(ok), median(ap))
    @printf("  placements per query: median %g, max %d, queries with a single placement: %d of %d; total LWR per query: min %.4f, median %.4f\n", median(npl), maximum(npl), count(==(1), npl), length(ok), minimum(tot), median(tot))
    for alpha in (0.01, 0.05)
        eo = eb = ro = rb = ui = uo = 0
        for cl in values(d.cl), (sz, m, t) in cl
            if isent(m, alpha); t ? (eo += 1) : (eb += 1)
            elseif isref(m, alpha); t ? (rb += 1) : (ro += 1)
            else t ? (ui += 1) : (uo += 1) end
        end
        @printf("  alpha %.2f: entailed %d, wrong %d | refuted %d, wrong %d | unresolved %d (truth inside %d, truth not inside %d)\n", alpha, eo + eb, eb, ro + rb, rb, ui + uo, ui, uo)
    end
end
# ---------- T2 ----------
const BINS = [(2, 3), (4, 7), (8, 15), (16, 31), (32, 63), (64, 127), (128, 10^6)]
binlabel(b) = b[2] >= 10^6 ? @sprintf("%d-%d", b[1], 399) : @sprintf("%d-%d", b[1], b[2])
function t2(d::DS, alpha)
    println("  bin        entailed verdicts   wrong   distinct queries with a wrong verdict")
    for b in BINS
        ne = nw = 0; wq = Set{Int}()
        for (q, cl) in d.cl, (sz, m, t) in cl
            (b[1] <= sz <= b[2] && isent(m, alpha)) || continue
            ne += 1; if !t; nw += 1; push!(wq, q); end
        end
        @printf("  %-9s %9d %12d %12d\n", binlabel(b), ne, nw, length(wq))
    end
end
# ---------- T3 ----------
function smallest_entailed(d::DS, alpha, k)   # -> Dict qi => (size, truth_inside)
    out = Dict{Int,Tuple{Int,Bool}}()
    for (q, cl) in d.cl
        best = nothing
        for (sz, m, t) in cl
            (sz >= k && isent(m, alpha)) || continue
            (best === nothing || sz < best[1]) && (best = (sz, t))
        end
        best !== nothing && (out[q] = best)
    end
    out
end
function t3(d::DS, alpha; ks = (2, 4, 8, 16, 32, 64))
    nq = length(d.pq)
    println("  k    queries with a clade (of $nq)   median size   wrong   wrong rate    exact 95% CI (Clopper-Pearson)")
    for k in ks
        s = smallest_entailed(d, alpha, k); n = length(s)
        if n == 0; @printf("  %-4d %6d\n", k, 0); continue; end
        w = count(v -> !v[2], values(s)); lo, hi = cp_interval(w, n)
        @printf("  %-4d %6d %18g %14d %9.4f   (%.4f, %.4f)   [%d of %d]\n", k, n, median([v[1] for v in values(s)]), w, w / n, lo, hi, w, n)
    end
end
# ---------- T4 ----------
function t4(ds::Vector{DS}, pooled::DS, alpha)
    for d in vcat(ds, [pooled])
        s = smallest_entailed(d, alpha, 2); wr = sort([q for (q, v) in s if !v[2]])
        npl1 = count(q -> d.pq[q][4] == "1", wr); b99 = count(q -> parse(Float64, d.pq[q][6]) >= 0.99, wr)
        @printf("  %s: %d queries with an entailed clade, %d wrong; of the wrong: single reported placement %d of %d; best LWR >= 0.99: %d of %d\n", d.label, length(s), length(wr), npl1, length(wr), b99, length(wr))
    end
    println("  list (key = draw+query index; pooled keys: A = qi, B = 1000+qi):  key  clade_size  edges_best_to_truth  placements  best_lwr")
    for q in sort([q for (q, v) in smallest_entailed(pooled, alpha, 2) if !v[2]])
        r = pooled.pq[q]; sz = smallest_entailed(pooled, alpha, 2)[q][1]
        @printf("   %5d %6d %6s %6s %10.4f\n", q, sz, r[8], r[4], parse(Float64, r[6]))
    end
end
# ---------- T5 ----------
function t5(d::DS)
    edges = [0.05, 0.25, 0.5, 0.75, 0.95]; hit = zeros(Int, 7); cnt = zeros(Int, 7)
    for cl in values(d.cl), (sz, m, t) in cl
        b = m <= 0 ? 1 : m > 0.95 + 1e-12 ? 7 : 1 + findfirst(x -> m <= x + 1e-12, edges)
        cnt[b] += 1; hit[b] += t
    end
    labels = ["0", "(0, .05]", "(.05, .25]", "(.25, .5]", "(.5, .75]", "(.75, .95]", "(.95, 1]"]
    for b in 1:7; cnt[b] > 0 && @printf("  mass %-11s clades %8d   truth inside %8d (%.2f%%)\n", labels[b], cnt[b], hit[b], 100hit[b] / cnt[b]); end
end
# ---------- T6 ----------
function t6(A::DS, B::DS)
    for alpha in (0.01, 0.05)
        @printf("  alpha %.2f   k   draw A: wrong/n  rate  CI   |   draw B: wrong/n  rate  CI\n", alpha)
        for k in (2, 8, 32)
            f(d) = begin s = smallest_entailed(d, alpha, k); n = length(s); w = count(v -> !v[2], values(s)); lo, hi = cp_interval(w, n); @sprintf("%d/%d  %.4f  (%.4f, %.4f)", w, n, w / n, lo, hi) end
            @printf("             %-3d  %s   |   %s\n", k, f(A), f(B))
        end
    end
end
# ---------- main ----------
mode, R = ARGS[1], ARGS[2]
if mode == "cptest"
    for (x, n) in ((0, 100), (7, 146), (13, 2388), (5, 5), (0, 1))
        lo, hi = cp_interval(x, n); @printf("CP %d of %d: (%.4f, %.4f)\n", x, n, lo, hi)
    end
elseif mode == "old"
    d = load("old", joinpath(R, "perquery_amp.tsv"), joinpath(R, "perclade_amp.tsv"))
    for alpha in (0.01, 0.05)
        eo = eb = 0
        for cl in values(d.cl), (sz, m, t) in cl; isent(m, alpha) && (t ? (eo += 1) : (eb += 1)); end
        @printf("OLD N=200 reproduction, alpha %.2f: entailed %d wrong %d\n", alpha, eo + eb, eb)
    end
    s = smallest_entailed(d, 0.01, 2); @printf("OLD smallest entailed clade alpha 0.01: queries with clade %d, wrong %d\n", length(s), count(v -> !v[2], values(s)))
else
    A = load("A", joinpath(R, "perquery_A_amp.tsv"), joinpath(R, "perclade_A_amp.tsv"))
    B = load("B", joinpath(R, "perquery_B_amp.tsv"), joinpath(R, "perclade_B_amp.tsv"), keyoff = 1000)
    P = merge_ds("pooled", A, B)
    Apos = load("A-pos", joinpath(R, "perquery_A_pos.tsv"), joinpath(R, "perclade_A_pos.tsv"))
    println("Per-query unit note: verdicts on nested clades of one query are NOT independent; T3 (one result per query) is the statistically honest unit. T2 counts verdicts and is descriptive only.")
    println("Clade size = number of references below the node; n_refs = $(A.nref) (pruned tree). Pooled = draw A + draw B queries (a reference present in both draws may be a query in both).\n")
    for d in (A, B, P)
        println("\n################ ", d.label, " (amp) ################"); println("T1"); t1(d)
        for alpha in (0.01, 0.05)
            @printf("\nT2 alpha %.2f (%s)\n", alpha, d.label); t2(d, alpha)
            @printf("\nT3 alpha %.2f (%s)\n", alpha, d.label); t3(d, alpha)
        end
        println("\nT5 calibration (", d.label, ")"); t5(d)
    end
    println("\n################ A-pos (positive control: full-length sequence, first 60 queries of draw A) ################"); t1(Apos)
    for alpha in (0.01, 0.05); @printf("\nT3 alpha %.2f (A-pos)\n", alpha); t3(Apos, alpha); end
    for alpha in (0.01, 0.05); @printf("\nT4 alpha %.2f (smallest entailed clade, k=2, wrong)\n", alpha); t4([A, B], P, alpha); end
    println("\nT6 agreement between draws"); t6(A, B)
end
