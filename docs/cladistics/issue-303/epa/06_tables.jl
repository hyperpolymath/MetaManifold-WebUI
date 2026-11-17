# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E8 (issue 303): evidence verdicts on placements made by the application's own
# placement step (RAxML EPA).  See ../README.md, section 8.
# usage: julia 06_tables.jl epa_dir kind [kind...]  -> prints tables from raw/perquery_<kind>.tsv and raw/perclade_<kind>.tsv
using Printf, Statistics
E = ARGS[1]
function table(kind)
    pq = [split(l, "\t") for l in eachline(joinpath(E, "raw", "perquery_$kind.tsv"))][2:end]
    ok = filter(r -> r[3] == "OK", pq)
    missing_n = length(pq) - length(ok)
    pc = [split(l, "\t") for l in eachline(joinpath(E, "raw", "perclade_$kind.tsv"))][2:end]
    byq = Dict{Int,Vector{Tuple{Int,Float64,Bool}}}()
    for r in pc; push!(get!(byq, parse(Int, r[1]), Tuple{Int,Float64,Bool}[]), (parse(Int, r[2]), parse(Float64, r[3]), r[4] == "1")); end
    ex = [r[7] == "1" for r in ok]; ap = [parse(Int, r[8]) for r in ok]; tot = [parse(Float64, r[5]) for r in ok]; npl = [parse(Int, r[4]) for r in ok]
    println("\n===== ", kind, " =====")
    @printf("queries scored: %d (missing/failed: %d); placed on exactly the true edge: %.1f%% (%d); within 2 edges: %.1f%%; median edges apart: %g\n",
            length(ok), missing_n, 100mean(ex), sum(ex), 100mean(ap .<= 2), median(ap))
    @printf("placements reported per query: median %g, max %d; queries with a single placement: %d; total LWR reported per query: min %.4f, median %.4f, max %.4f\n",
            median(npl), maximum(npl), count(==(1), npl), minimum(tot), median(tot), maximum(tot))
    for alpha in (0.01, 0.05)
        ent_ok = ent_bad = ref_ok = ref_bad = unr_in = unr_out = 0; pin = Int[]; pin_ok = 0; nopin = 0; q_wrong = 0
        for (qi, cl) in byq
            best = 0; bsz = typemax(Int); bt = false
            for (sz, m, t) in cl
                if m >= 1 - alpha - 1e-12
                    t ? (ent_ok += 1) : (ent_bad += 1)
                    sz < bsz && ((bsz, bt, best) = (sz, t, 1))
                elseif m <= alpha + 1e-12
                    t ? (ref_bad += 1) : (ref_ok += 1)
                else
                    t ? (unr_in += 1) : (unr_out += 1)
                end
            end
            if best == 0; nopin += 1 else push!(pin, bsz); bt ? (pin_ok += 1) : (q_wrong += 1) end
        end
        @printf("\n alpha = %.2f: entailed if mass >= %.2f, refuted if mass <= %.2f\n", alpha, 1 - alpha, alpha)
        @printf("  entailed   %7d verdicts, wrong %5d (truth not inside) -> sound %.2f%%\n", ent_ok + ent_bad, ent_bad, 100ent_ok / max(ent_ok + ent_bad, 1))
        @printf("  refuted    %7d verdicts, wrong %5d (truth inside)     -> sound %.3f%%\n", ref_ok + ref_bad, ref_bad, 100ref_ok / max(ref_ok + ref_bad, 1))
        @printf("  unresolved %7d verdicts (%d truth inside, %d truth not inside)\n", unr_in + unr_out, unr_in, unr_out)
        d = ent_ok + unr_in + ref_bad
        @printf("  of the %d clades that truly contain the query: entailed %.1f%%, unresolved %.1f%%, wrongly refuted %.1f%%\n", d, 100ent_ok / d, 100unr_in / d, 100ref_bad / d)
        if !isempty(pin)
            @printf("  smallest entailed clade per query: median size %g (quartiles %g, %g) of %d references; contains truth for %.1f%% of %d queries; no entailed clade for %d queries\n",
                    median(pin), quantile(pin, 0.25), quantile(pin, 0.75), 199, 100pin_ok / length(pin), length(pin), nopin)
        else
            @printf("  no entailed clade for any query (%d)\n", nopin)
        end
        @printf("  queries whose smallest entailed clade is wrong: %d of %d (with an entailed clade)\n", q_wrong, length(pin))
    end
    println("\n calibration of clade mass (share of clades that contain the truth)")
    edges = [0.05, 0.25, 0.5, 0.75, 0.95]; hit = zeros(Int, 7); cnt = zeros(Int, 7)
    for cl in values(byq), (sz, m, t) in cl
        b = m <= 0 ? 1 : m > 0.95 + 1e-12 ? 7 : 1 + findfirst(x -> m <= x + 1e-12, edges)
        cnt[b] += 1; hit[b] += t
    end
    labels = ["0", "(0, .05]", "(.05, .25]", "(.25, .5]", "(.5, .75]", "(.75, .95]", "(.95, 1]"]
    for b in 1:7; cnt[b] > 0 && @printf("  mass %-11s clades %7d   truth inside %6.2f%%\n", labels[b], cnt[b], 100hit[b] / cnt[b]); end
end
for k in ARGS[2:end]; table(k); end
