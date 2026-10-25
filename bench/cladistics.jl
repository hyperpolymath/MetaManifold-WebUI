#!/usr/bin/env julia
# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).
#
# Lightweight regression timing for the CladeCumulus roll-up and diversity path.
# Run with: julia --project=. bench/cladistics.jl [tip_count] [sample_count]
# No benchmark artefacts are written; compare the printed seconds on the same
# machine before and after a change to this hot path.

using MetaManifold, Random, Printf
const CC = MetaManifold.CladeCumulus

function balanced_newick(labels::Vector{String})
    length(labels) == 1 && return only(labels)
    middle = cld(length(labels), 2)
    "($(balanced_newick(labels[1:middle])):0.01,$(balanced_newick(labels[middle+1:end])):0.01)"
end

function main()
    tips = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 512
    samples = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 48
    tips >= 2 && samples >= 2 || error("Use at least two tips and two samples")
    labels = ["ASV_$i" for i in 1:tips]
    tree = CC.parse_phylogenetic_tree(balanced_newick(labels) * ";")
    counts = Float64.(rand(MersenneTwister(123), 0:20, samples, tips))
    sample_names = ["sample_$i" for i in 1:samples]

    CC.analyse_phylogeny(tree, counts, labels, sample_names)  # warm up compilation
    elapsed = @elapsed result = CC.analyse_phylogeny(tree, counts, labels, sample_names)
    @assert length(result.nodes) == 2 * tips - 1
    @assert all(isapprox.(result.sample_reads, vec(sum(counts; dims=2))))
    @printf("CladeCumulus: %d tips, %d samples, %d nodes, %.3f s\n",
            tips, samples, length(result.nodes), elapsed)
    println("Includes one cumulative roll-up, Faith PD, and both UniFrac matrices; no I/O.")
end

abspath(PROGRAM_FILE) == @__FILE__ && main()
