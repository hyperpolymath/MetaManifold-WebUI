# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Check: does the zoomed-in result from E4 survive at n = 1024?  (E4 used 512 and 384.)
# usage: julia -t 4 zoom_real_1024.jl <directory holding *_R1_001.fastq>
include(joinpath(@__DIR__, "lib_tree.jl"))
function run(dir; nmax = 1024, k = 64, draws = 40)
    rng = MersenneTwister(20261117); seqs = load_set(dir, nmax); n = length(seqs)
    D, _ = distance_matrix(seqs); key = rand(rng, UInt64, n); one = 1 / TRUNC
    full, _, fblen = nj(D, collect(1:n))
    function view(S)
        inS = fill(false, n); inS[S] .= true; target = splits(full, n, key, inS, fblen)
        sub, m, sblen = nj(D, S); a = splits(sub, m, key[S], fill(true, m), sblen)
        t3 = [x for (x, v) in target if v >= 3one]; w = sum(values(target))
        (count(x -> haskey(a, x), keys(target)) / max(length(target), 1), sum((v for (x, v) in target if haskey(a, x)); init = 0.0) / max(w, eps()),
         isempty(t3) ? NaN : count(x -> haskey(a, x), t3) / length(t3), length(t3) / max(length(target), 1))
    end
    @printf("n = %d sequences, views of %d, %d draws\n  %-26s %7s %9s %24s   %s\n", n, k, draws, "view", "all", "weighted", ">=3 substitutions", "share of branches >=3")
    for (label, pick) in (("zoomed-in neighbourhood", () -> sort(sortperm(D[rand(rng, 1:n), :])[1:k])), ("random subset", () -> sort(randperm(rng, n)[1:k])))
        rows = [view(pick()) for _ in 1:draws]; c3 = filter(!isnan, [r[3] for r in rows])
        @printf("  %-26s %6.1f%% %8.1f%% %7.1f%% (%5.1f .. %5.1f)   %.1f%%\n", label, 100mean(r[1] for r in rows), 100mean(r[2] for r in rows),
                100mean(c3), 100quantile(c3, 0.025), 100quantile(c3, 0.975), 100mean(r[4] for r in rows))
    end
end
run(ARGS[1])
