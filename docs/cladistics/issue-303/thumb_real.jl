# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E5: can the THUMBNAIL be fixed?  Real MiSeq_SOP reads.
#
# usage: julia -t 4 thumb_real.jl <directory holding *_R1_001.fastq>
#
# E4 showed a thumbnail built from one representative sequence per region reproduces only
# 51-70% of the well-supported branches of the full tree.  Here the leaves are partitioned into
# k regions and each region is summarised by MORE than one sequence.  The target is unchanged:
# the full neighbour-joining tree cut down to the k region representatives.  Estimators:
#
#   one-rep        distance between the two representatives (the E4 baseline)
#   members-m      mean distance over m sampled members of each region, minus the mean
#                  within-region distance (estimates the distance between the regions' roots)
#   members-all    the same over every member (not lazy: needs all distances; an upper bound)
#   kmer-rep       alignment-free: L1 distance between the representatives' 5-mer counts
#   kmer-region    alignment-free: L1 distance between the regions' MEAN 5-mer counts.
#                  Costs one pass over the sequences (linear) plus k^2 vector distances.
#
# Regions are assigned with the 5-mer sketch (nearest representative), so the whole pipeline
# for kmer-region never computes a pairwise alignment.
include(joinpath(@__DIR__, "lib_tree.jl"))

const K5 = 5
function sketch(s::Vector{UInt8})
    v = zeros(Float32, 4^K5); code = 0; valid = 0
    @inbounds for c in s
        x = c == UInt8('A') ? 0 : c == UInt8('C') ? 1 : c == UInt8('G') ? 2 : c == UInt8('T') ? 3 : -1
        if x < 0; valid = 0; code = 0; continue; end
        code = ((code << 2) | x) & (4^K5 - 1); valid += 1
        valid >= K5 && (v[code+1] += 1f0)
    end
    v
end
l1(a, b) = (s = 0f0; @inbounds @simd for i in eachindex(a); s += abs(a[i] - b[i]); end; s)
"turn an L1 distance between 5-mer count vectors into a substitution-like distance"
kmer_dist(x) = (p = Float64(x) / (2K5 * TRUNC); p >= 0.74 ? 5.0 : -0.75 * log(1 - 4p / 3))


function recall(est_children, est_blen, m, estkey, target::Dict{UInt64,Float64})
    a = splits(est_children, m, estkey, fill(true, m), est_blen); one = 1 / TRUNC
    tot = length(target); sh = count(k -> haskey(a, k), keys(target))
    w = sum(values(target)); wsh = sum((v for (k, v) in target if haskey(a, k)); init = 0.0)
    t3 = [k for (k, v) in target if v >= 3one]
    (sh / max(tot, 1), wsh / max(w, eps()), isempty(t3) ? NaN : count(k -> haskey(a, k), t3) / length(t3))
end

function run(dir; nmax = 1024, k = 64, draws = 30, scheme = :random)
    rng = MersenneTwister(20261117)
    seqs = load_set(dir, nmax); n = length(seqs)
    D, _ = distance_matrix(seqs); key = rand(rng, UInt64, n); S = [sketch(s) for s in seqs]
    full, _, fblen = nj(D, collect(1:n))
    names = ["one-rep", "members-4", "members-8", "members-all", "kmer-rep", "kmer-region"]
    res = Dict(nm => NTuple{3,Float64}[] for nm in names); aligns = Dict(nm => 0 for nm in names); sizes = Int[]
    for _ in 1:draws
        if scheme == :random
            reps = sort(randperm(rng, n)[1:k])
        else                                         # spread out, chosen with the sketch only
            reps = [rand(rng, 1:n)]; mind = [l1(S[i], S[reps[1]]) for i in 1:n]
            while length(reps) < k; r = argmax(mind); push!(reps, r); for i in 1:n; mind[i] = min(mind[i], l1(S[i], S[r])); end; end
            sort!(reps)
        end
        region = [argmin([l1(S[i], S[r]) for r in reps]) for i in 1:n]
        for (j, r) in enumerate(reps); region[r] = j; end
        members = [findall(==(j), region) for j in 1:k]; append!(sizes, length.(members))
        inS = fill(false, n); inS[reps] .= true
        target = splits(full, n, key, inS, fblen); rk = key[reps]
        function est(M)
            c, m, b = nj(M, collect(1:k))
            recall(c, b, m, rk, target)
        end
        push!(res["one-rep"], est(D[reps, reps])); aligns["one-rep"] = k * (k - 1) ÷ 2
        function member_matrix(pick)
            sel = [pick(members[j], reps[j]) for j in 1:k]; M = zeros(k, k)
            within = [length(s) > 1 ? mean(D[a, b] for a in s for b in s if a < b) : 0.0 for s in sel]
            for a in 1:k, b in a+1:k
                v = mean(D[x, y] for x in sel[a] for y in sel[b]) - (within[a] + within[b]) / 2
                M[a, b] = v; M[b, a] = v
            end
            M, sum(length(sel[a]) * length(sel[b]) for a in 1:k for b in a+1:k) + sum(length(s) * (length(s) - 1) ÷ 2 for s in sel)
        end
        for (nm, m) in (("members-4", 4), ("members-8", 8))
            # the representative plus up to m-1 other members, never more than the region holds
            M, na = member_matrix((mem, r) -> (u = unique(vcat(r, shuffle(rng, mem))); u[1:min(m, length(u))]))
            push!(res[nm], est(M)); aligns[nm] = na
        end
        M, na = member_matrix((mem, r) -> mem); push!(res["members-all"], est(M)); aligns["members-all"] = na
        Mk = zeros(k, k); for a in 1:k, b in a+1:k; v = kmer_dist(l1(S[reps[a]], S[reps[b]])); Mk[a, b] = v; Mk[b, a] = v; end
        push!(res["kmer-rep"], est(Mk))
        means = [reduce(+, S[members[j]]) ./ Float32(length(members[j])) for j in 1:k]
        Mr = zeros(k, k); for a in 1:k, b in a+1:k; v = kmer_dist(l1(means[a], means[b])); Mr[a, b] = v; Mr[b, a] = v; end
        push!(res["kmer-region"], est(Mr))
    end
    @printf("\nn = %d sequences, k = %d regions (%s representatives), %d draws; region size median %d, range %d..%d\n",
            n, k, scheme == :random ? "random" : "spread-out", draws, median(sizes), minimum(sizes), maximum(sizes))
    @printf("  %-13s %7s %9s %24s   %s\n", "summary", "all", "weighted", ">=3 substitutions", "pairwise alignments (full tree needs $(n * (n - 1) ÷ 2))")
    for nm in names
        xs = res[nm]; c3 = filter(!isnan, [x[3] for x in xs])
        @printf("  %-13s %6.1f%% %8.1f%% %7.1f%% (%5.1f .. %5.1f)   %s\n", nm, 100mean(x[1] for x in xs), 100mean(x[2] for x in xs),
                100mean(c3), 100quantile(c3, 0.025), 100quantile(c3, 0.975), aligns[nm] == 0 ? "none" : string(aligns[nm]))
    end
end

dir = ARGS[1]
for (k, scheme) in ((64, :random), (64, :spread), (32, :random))
    run(dir; nmax = 1024, k = k, scheme = scheme)
end
