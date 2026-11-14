# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# SPDX-License-Identifier: MPL-2.0

# Writes the two small synthetic count tables the native ALDEx2 tests compare
# against R. Both are committed; this script records how they were made.
#
#   julia --project=. test/fixtures/native_da/make_counts.jl
#
# Both have 12 samples (6 "control", 6 "treated") by 10 taxa, library sizes drawn
# between 2000 and 6000 reads, log-normal taxon base weights, and multinomial
# reads. Both are synthetic: they have a planted difference and no biological
# meaning.
#
# counts.tsv (Random.MersenneTwister(2026)): taxa t1 and t2 are 6 times more
# abundant and t3 is 4 times less abundant in "treated". The smallest count is 5,
# so it has no zeros.
#
# counts_zeros.tsv (Random.MersenneTwister(2027)): the same design, with zeros
# on purpose, so that ALDEx2's Dirichlet prior and its handling of zeros are
# exercised.
#   t8   has probability 0 in every "control" sample (all zero in that group,
#        present in "treated")
#   t10  has probability 0 in every third sample (s3, s6, ..., s12), in both
#        groups
#   t9   has a base weight 300 times smaller than a typical taxon, so it is
#        rare and has chance zeros
# Every sample still has reads, and every taxon is nonzero in at least one sample.

using Random, Statistics

const DIR = @__DIR__

function multinomial(rng, n, p)
    counts = zeros(Int, length(p))
    cdf = cumsum(p)
    for _ in 1:n
        counts[min(searchsortedfirst(cdf, rand(rng)), length(p))] += 1
    end
    counts
end

# `adjust!(w, g, i)` may change the sample weights `w` of sample `i` in group `g`
# (1 control, 2 treated) before the reads are drawn.
function write_table(path, rng; base_adjust! = (base) -> nothing, adjust! = (w, g, i) -> nothing)
    ntaxa = 10
    base = exp.(1.2 .* randn(rng, ntaxa))
    base_adjust!(base)
    fold = ones(ntaxa); fold[1:2] .= 6; fold[3] = 0.25
    open(path, "w") do io
        println(io, join(["sample", "group", ("t$j" for j in 1:ntaxa)...], '\t'))
        for (g, group) in enumerate(("control", "treated")), i in 1:6
            w = base .* (g == 2 ? fold : ones(ntaxa)) .* exp.(0.3 .* randn(rng, ntaxa))
            adjust!(w, g, i)
            row = multinomial(rng, rand(rng, 2000:6000), w ./ sum(w))
            println(io, join([string(group, "_", i), group, row...], '\t'))
        end
    end
    println("wrote ", path)
end

write_table(joinpath(DIR, "counts.tsv"), MersenneTwister(2026))

write_table(joinpath(DIR, "counts_zeros.tsv"), MersenneTwister(2027);
    base_adjust! = base -> (base[9] = median(base) / 300),
    adjust! = (w, g, i) -> begin
        g == 1 && (w[8] = 0.0)                     # t8: absent from every control sample
        (6 * (g - 1) + i) % 3 == 0 && (w[10] = 0.0) # t10: absent from every third sample
    end)
