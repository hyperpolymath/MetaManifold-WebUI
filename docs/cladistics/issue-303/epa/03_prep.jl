# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E8 (issue 303): evidence verdicts on placements made by the application's own
# placement step (RAxML EPA).  See ../README.md, section 8.
# usage: julia 03_prep.jl epa_dir Q seed
# Leave-one-out preparation: for each query q, prune, write pruned tree, truth, and three alignments (amp/pos/neg).
using Random, Printf
include(joinpath(@__DIR__, "lib_nwk.jl"))
E, Q, seed = ARGS[1], parse(Int, ARGS[2]), parse(Int, ARGS[3])
W = joinpath(E, "work")
# start from a clean query directory: stale q*/ variants (e.g. pos from an earlier run with more
# controls) must not survive into the scorer
rm(joinpath(W, "q"); recursive = true, force = true)
names = [String(split(l, "\t")[1]) for l in eachline(joinpath(W, "names.tsv"))]; N = length(names)
leafidx = Dict(n => i for (i, n) in enumerate(names))
seqs = Dict{String,String}(); cur = ""
for l in eachline(joinpath(W, "ref_full.fasta")); startswith(l, ">") ? (global cur = l[2:end]) : (seqs[cur] = l); end
v4cols = parse.(Int, split(strip(read(joinpath(W, "v4cols.txt"), String)), ","))
g0 = parse_nwk(strip(read(joinpath(W, "tree", "reference.treefile"), String)))
nid = Dict(g0.names[u] => u for u in eachindex(g0.names) if g0.names[u] != "")
@assert length(nid) == N
rng = MersenneTwister(seed)
queries = sort(shuffle(rng, 1:N)[1:Q]); negsrc = [rand(rng, setdiff(1:N, q)) for q in queries]
function fragment(s::String, cols)
    v = collect(s); out = fill('-', length(v)); k = 0
    for j in cols; if v[j] != '-'; out[j] = v[j]; k += 1; k == 240 && break; end; end
    @assert k == 240; String(out)
end
function newick(g::NG, root)
    io = IOBuffer()
    function w(u, p)
        if isleaf(g, u); print(io, g.names[u]); return; end
        print(io, "("); first = true
        for (v, l) in g.adj[u]; v == p && continue; first || print(io, ","); first = false; w(v, u); print(io, ":", l); end
        print(io, ")")
    end
    # root must be an internal node
    print(io, "("); first = true
    for (v, l) in g.adj[root]; first || print(io, ","); first = false; w(v, root); print(io, ":", l); end
    print(io, ");"); String(take!(io))
end
open(joinpath(W, "queries.tsv"), "w") do qio
  println(qio, "qi\tquery\tnegsrc")
  for (qi, q) in enumerate(queries)
    qn = names[q]; u = nid[qn]
    adj = [copy(d) for d in g0.adj]; g = NG(copy(g0.names), adj, [Dict{Int,Int}() for _ in adj])
    @assert length(adj[u]) == 1
    p = first(keys(adj[u])); @assert length(adj[p]) == 3 "parent of query has degree $(length(adj[p]))"
    delete!(adj[p], u); empty!(adj[u])
    (a, la), (b, lb) = collect(adj[p])
    delete!(adj[a], p); delete!(adj[b], p); empty!(adj[p]); adj[a][b] = la + lb; adj[b][a] = la + lb
    refs = [n for n in names if n != qn]; rl = leafidx[minimum(refs)]
    # truth: root at the alphabetically first leaf; the merged edge a-b, child side
    par, kids, below, order = root_at(g, nid[names[rl]], leafidx)
    child = par[a] == b ? a : (par[b] == a ? b : error("a,b not adjacent after merge"))
    truth = sort([names[i] for i in below[child]])
    dir = joinpath(W, "q", @sprintf("q%03d", qi)); mkpath(dir)
    root = first(u2 for u2 in eachindex(g.names) if !isleaf(g, u2) && length(g.adj[u2]) == 3)
    write(joinpath(dir, "pruned.nwk"), newick(g, root) * "\n")
    write(joinpath(dir, "truth.txt"), join(truth, "\n") * "\n")
    write(joinpath(dir, "query.txt"), qn * "\n")
    for (kind, row) in (("amp", fragment(seqs[qn], v4cols)), ("pos", seqs[qn]), ("neg", fragment(seqs[names[negsrc[qi]]], v4cols)))
        kd = joinpath(dir, kind); mkpath(kd)
        open(joinpath(kd, "aln.fasta"), "w") do io
            for n in refs; println(io, ">", n); println(io, seqs[n]); end
            println(io, ">qry"); println(io, row)
        end
        cp(joinpath(dir, "pruned.nwk"), joinpath(kd, "tree.nwk"); force=true)
    end
    println(qio, qi, "\t", qn, "\t", names[negsrc[qi]])
  end
end
println("prepared $Q queries")
