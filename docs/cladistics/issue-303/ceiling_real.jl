# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E6: is the TARGET itself stable?  Real MiSeq_SOP reads.
#
# usage: julia -t 4 ceiling_real.jl <directory holding *_R1_001.fastq>
#
# E5 found no region summary reproduces more than about 56% of the well-supported branches of
# the full tree cut down to 64 representatives.  Before blaming the summaries, ask how well the
# full tree agrees with ITSELF when the set of other sequences changes: build the tree on all n
# sequences and on a random subset T of them, cut both down to the same 64 leaves S (S inside T),
# and compare.  If two "full" trees disagree about the same 64 leaves, no thumbnail can match both.
include(joinpath(@__DIR__, "lib_tree.jl"))

function run(dir; nmax = 1024, k = 64, draws = 30)
    rng = MersenneTwister(20261117); seqs = load_set(dir, nmax); n = length(seqs)
    D, _ = distance_matrix(seqs); key = rand(rng, UInt64, n); one = 1 / TRUNC
    full, _, fblen = nj(D, collect(1:n))
    @printf("n = %d sequences; views of %d leaves; %d draws per row\n", n, k, draws)
    @printf("  %-34s %7s %9s %24s\n", "tree compared with the n-leaf tree", "all", "weighted", ">=3 substitutions")
    for tsize in (k, 128, 256, 512, 768)
        rows = NTuple{3,Float64}[]
        for _ in 1:draws
            T = sort(randperm(rng, n)[1:tsize]); S = sort(T[randperm(rng, tsize)[1:k]])
            inS = fill(false, n); inS[S] .= true; target = splits(full, n, key, inS, fblen)
            sub, m, sblen = nj(D, T); inST = [t in S for t in T] |> collect
            a = splits(sub, m, key[T], Vector{Bool}(inST), sblen)
            tot = length(target); sh = count(x -> haskey(a, x), keys(target))
            w = sum(values(target)); wsh = sum((v for (x, v) in target if haskey(a, x)); init = 0.0)
            t3 = [x for (x, v) in target if v >= 3one]
            push!(rows, (sh / max(tot, 1), wsh / max(w, eps()), isempty(t3) ? NaN : count(x -> haskey(a, x), t3) / length(t3)))
        end
        c3 = filter(!isnan, [r[3] for r in rows])
        @printf("  tree built on %4d of the %d      %6.1f%% %8.1f%% %7.1f%% (%5.1f .. %5.1f)\n", tsize, n,
                100mean(r[1] for r in rows), 100mean(r[2] for r in rows), 100mean(c3), 100quantile(c3, 0.025), 100quantile(c3, 0.975))
    end
end
run(ARGS[1])
