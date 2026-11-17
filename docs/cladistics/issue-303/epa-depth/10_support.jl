# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E10 (issue 303): are the wrong entailed verdicts of experiment 9 errors of the
# placement, or uncertainty in the reference tree?
#
# usage: julia 10_support.jl DRAW_DIR      (DRAW_DIR = the experiment 9 directory of a draw whose
#                                           tree was built with UFBoot, i.e. draw A)
#
# The truth in experiment 9 is where the full-length sequence q sits in the reference tree built
# WITH q.  That tree carries ultrafast-bootstrap support on its branches.  For a clade S of the
# pruned tree, the verdict "q is in S" is judged against one branch of the full tree:
#
#   truth says q IS in S      <=>  the full tree has the clade S + q;  its support backs the truth.
#   truth says q is NOT in S  <=>  the full tree has the clade S (without q); its support backs it.
#
# So every reported clade gets a "truth support".  A wrong verdict against a weakly supported
# branch may be the reference tree's uncertainty, not a placement error.  A wrong verdict against
# a branch with support >= 95 is a placement error by the reference tree's own standard.
using Printf, Statistics
include(joinpath(@__DIR__, "lib_nwk.jl"))
D = ARGS[1]; W = joinpath(D, "work")
names = [String(split(l, "\t")[1]) for l in eachline(joinpath(W, "names.tsv"))]; N = length(names)
leafidx = Dict(n => i for (i, n) in enumerate(names)); ALL = BitSet(1:N)

# ---- full tree with support labels: every internal branch -> (leaf set below it, support) ----
function supports(s::AbstractString)
    out = Dict{BitSet,Float64}(); pos = Ref(1)
    function rd()
        if s[pos[]] == '('
            pos[] += 1; set = BitSet()
            while true
                union!(set, rd()); c = s[pos[]]; pos[] += 1
                c == ',' && continue; c == ')' && break; error("bad newick at $(pos[])")
            end
            st = pos[]; while s[pos[]] ∉ (':', ',', ')', ';'); pos[] += 1; end
            lbl = s[st:pos[]-1]
            if s[pos[]] == ':'; pos[] += 1; while s[pos[]] ∉ (',', ')', ';'); pos[] += 1; end; end
            isempty(lbl) || (out[canon(set)] = parse(Float64, split(lbl, "/")[end]))
            return set
        else
            st = pos[]; while s[pos[]] ∉ (':', ',', ')', ';'); pos[] += 1; end
            nm = s[st:pos[]-1]
            if s[pos[]] == ':'; pos[] += 1; while s[pos[]] ∉ (',', ')', ';'); pos[] += 1; end; end
            return BitSet([leafidx[nm]])
        end
    end
    rd(); out
end
# a branch is a split of the leaves; name it by the side that does not hold leaf 1
canon(set::BitSet) = 1 in set ? setdiff(ALL, set) : set
SUP = supports(strip(read(joinpath(W, "tree", "reference_with_support.treefile"), String)))
trivial(set) = (c = canon(set); length(c) <= 1 || length(c) >= N - 1)
"support of the full-tree branch with this leaf set on one side; 100 for a pendant branch; NaN if absent"
support(set::BitSet) = trivial(set) ? 100.0 : get(SUP, canon(set), NaN)
@printf("full tree: %d leaves, %d internal branches with a support value (median %.0f, %d below 95, %d below 70)\n",
        N, length(SUP), median(values(SUP)), count(<(95), values(SUP)), count(<(70), values(SUP)))

# ---- per query: the reported clade under the rule "smallest entailed clade of >= k references" ----
qs = [String.(split(l, "\t")) for l in eachline(joinpath(W, "queries.tsv"))][2:end]
struct Rep; q::Int; k::Int; size::Int; wrong::Bool; sup::Float64; end
reps = Rep[]; absent = 0
for q in qs
    qi = parse(Int, q[1]); qn = q[2]; dir = joinpath(W, "q", @sprintf("q%03d", qi))
    jp = joinpath(dir, "amp", "RAxML_portableTree.epa.jplace"); isfile(jp) || continue
    g = parse_nwk(strip(read(joinpath(dir, "pruned.nwk"), String)))
    truth = BitSet(leafidx[n] for n in split(strip(read(joinpath(dir, "truth.txt"), String)), "\n"))
    refs = sort([n for n in names if n != qn])
    nid = Dict(g.names[u] => u for u in eachindex(g.names) if g.names[u] != "")
    par, kids, below, order = root_at(g, nid[refs[1]], leafidx)
    tree, fields, rows = parse_jplace(jp); jg = parse_nwk(tree)
    jn = Dict(jg.names[u] => u for u in eachindex(jg.names) if jg.names[u] != "")
    jpar, jkids, jbelow, jorder = root_at(jg, jn[refs[1]], leafidx)
    jkey = Dict{Int,BitSet}(); for u in jorder; u == jn[refs[1]] && continue; jkey[jg.lab[u][jpar[u]]] = jbelow[u]; end
    ei = findfirst(==("edge_num"), fields); li = findfirst(==("like_weight_ratio"), fields)
    pls = [(jkey[Int(r[ei])], r[li]) for r in rows]
    clades = [below[u] for u in order if u != nid[refs[1]] && !isleaf(g, u)]
    mass(S) = sum((w for (b, w) in pls if b != S && issubset(b, S)); init = 0.0)
    ent = [S for S in clades if mass(S) >= 0.99 - 1e-12]
    qix = leafidx[qn]
    for k in (2, 8, 32)
        c = [S for S in ent if length(S) >= k]; isempty(c) && continue
        S = c[argmin(length.(c))]
        inside = truth != S && issubset(truth, S)
        # the full-tree branch that backs the truth for this clade
        s = inside ? support(union(S, BitSet([qix]))) : support(S)
        isnan(s) && (global absent += 1)
        push!(reps, Rep(qi, k, length(S), !inside, s))
    end
end
println("reported clades whose truth branch was not found in the full tree: $absent")

for k in (2, 8, 32)
    R = [r for r in reps if r.k == k && !isnan(r.sup)]
    println("\nrule: smallest entailed clade of at least $k references ($(length(R)) queries with a clade)")
    @printf("  %-28s %8s %8s %10s\n", "truth branch support", "queries", "wrong", "rate")
    for (lab, f) in (("100 (or pendant)", r -> r.sup >= 100), ("95 to 99", r -> 95 <= r.sup < 100),
                     ("70 to 94", r -> 70 <= r.sup < 95), ("below 70", r -> r.sup < 70),
                     ("95 or more (firm)", r -> r.sup >= 95), ("below 95 (not firm)", r -> r.sup < 95))
        X = filter(f, R); w = count(r -> r.wrong, X)
        @printf("  %-28s %8d %8d %9s\n", lab, length(X), w, isempty(X) ? "n/a" : @sprintf("%.1f%%", 100w / length(X)))
    end
    Wq = [r for r in R if r.wrong]
    println("  wrong queries: clade size / truth support: ", join(sort(["$(r.size)/$(round(Int, r.sup))" for r in Wq]), "  "))
end
