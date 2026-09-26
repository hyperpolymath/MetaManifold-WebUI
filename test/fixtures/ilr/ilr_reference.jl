# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Independent reference for the ILR-basis fixtures (issue #20).
#
# This is NOT a copy of src/analysis/ilr_basis.jl and must never call it. It ports the R
# sources the engine is judged against, by their own algorithms, so that agreement is
# evidence rather than tautology:
#
#   * philr 1.x (Silverman et al. 2017): phylo2sbp, buildilrBasep, shiftp, miniclo, clrp,
#     ilrp, the six part.weights and four ilr.weights, calculate.blw (with its zero-length
#     tip-edge replacement) and mean_dist_to_tips. philr builds the DENSE D x (D-1) basis
#     and multiplies; the engine walks the tree in O(D) and never forms it.
#   * compositions: gsi.merge2signary, gsi.buildilrBase, ilr = clr %*% V.
#   * robCompositions: clustCoDa_qmode = hclust(as.dist(variation(x)), method) with the
#     classical ("Pairwise") variation matrix. The clustering here is the textbook
#     generic agglomeration -- global minimum over all active pairs, Lance-Williams
#     update -- not the nearest-neighbour-list algorithm of R's hclust.f that the engine
#     ports. The two agree on tie-free data (asserted below); ties are covered by the
#     hand-computed cases in test_ilr_basis.jl.
#
# Base Julia only (no LinearAlgebra, no Statistics): nothing here can drift with a
# dependency. philr's own known-answer test is re-checked before anything is computed.
#
# The committed inputs (counts.csv, tree.nwk, sbp.csv) are seeded synthetic data and are
# data, not code. The committed expectations (expected_*.csv, merge_*.csv, variation.csv)
# are recomputed from them by this module on every test run (test/unit/test_ilr_basis.jl)
# and must agree to 1e-10. To rewrite them after a deliberate change:
#
#     julia --project=. test/fixtures/ilr/ilr_reference.jl --write

module ILRReference

export REFERENCE_DATASETS, reference_expectations, philr_known_answers, read_matrix

const HERE = @__DIR__

# ------------------------------------------------------------------------------------------
# Newick: an independent recursive-descent parser (quotes, labels, branch lengths)
# ------------------------------------------------------------------------------------------

mutable struct RNode
    label::Union{String,Nothing}
    len::Union{Float64,Nothing}
    children::Vector{RNode}
end

is_tip(n::RNode) = isempty(n.children)

function parse_newick(text::AbstractString)
    s = collect(strip(text))
    (isempty(s) || s[end] != ';') && error("Newick must end with ';'")
    s = s[1:end-1]
    n = length(s)
    pos = Ref(1)

    function read_label()
        p = pos[]
        if p <= n && s[p] == '\''
            p += 1
            out = Char[]
            while true
                p <= n || error("unterminated quoted label")
                if s[p] == '\''
                    if p + 1 <= n && s[p+1] == '\''
                        push!(out, '\'')
                        p += 2
                        continue
                    end
                    p += 1
                    break
                end
                push!(out, s[p])
                p += 1
            end
            pos[] = p
            return String(out)
        end
        q = p
        while q <= n && !(s[q] in "():,;[]'")
            q += 1
        end
        tok = strip(String(s[p:q-1]))
        pos[] = q
        return isempty(tok) ? nothing : String(tok)
    end

    function read_length()
        p = pos[]
        (p <= n && s[p] == ':') || return nothing
        p += 1
        while p <= n && isspace(s[p])
            p += 1
        end
        q = p
        while q <= n && (isdigit(s[q]) || s[q] in "+-.eE")
            q += 1
        end
        pos[] = q
        return parse(Float64, String(s[p:q-1]))
    end

    function subtree()
        node = RNode(nothing, nothing, RNode[])
        if s[pos[]] == '('
            pos[] += 1
            push!(node.children, subtree())
            while s[pos[]] == ','
                pos[] += 1
                push!(node.children, subtree())
            end
            s[pos[]] == ')' || error("expected ')' at character $(pos[])")
            pos[] += 1
        end
        node.label = read_label()
        node.len = read_length()
        return node
    end

    root = subtree()
    pos[] == n + 1 || error("trailing input at character $(pos[])")
    return root
end

tips(n::RNode) = is_tip(n) ? String[something(n.label)] : reduce(vcat, (tips(c) for c in n.children))

"ape node numbering for a read.tree'd tree: internal nodes in preorder, Newick child order."
function internal_preorder(n::RNode)
    is_tip(n) && return RNode[]
    out = RNode[n]
    for c in n.children
        append!(out, internal_preorder(c))
    end
    return out
end

"ape::keep.tip semantics: prune, collapse unary nodes, summing their lengths."
function keep_tips(n::RNode, keep::Set{String})
    if is_tip(n)
        return n.label in keep ? RNode(n.label, n.len, RNode[]) : nothing
    end
    kids = RNode[]
    for c in n.children
        k = keep_tips(c, keep)
        k === nothing || push!(kids, k)
    end
    isempty(kids) && return nothing
    if length(kids) == 1
        k = kids[1]
        if n.len !== nothing || k.len !== nothing
            k.len = something(k.len, 0.0) + something(n.len, 0.0)
        end
        return k
    end
    return RNode(n.label, n.len, kids)
end

# ------------------------------------------------------------------------------------------
# philr port (R/phylo2sbp.R, R/weighted_ILR.R, R/philr.R, R/branch_length_calculations.R).
# x is samples x taxa, as in philr.
# ------------------------------------------------------------------------------------------

function phylo2sbp(tree::RNode)
    tl = tips(tree)
    idx = Dict(t => i for (i, t) in enumerate(tl))
    nodes = internal_preorder(tree)
    sbp = zeros(Float64, length(tl), length(nodes))
    for (j, nd) in enumerate(nodes)
        length(nd.children) == 2 || error("phylo2sbp needs a bifurcating tree")
        for t in tips(nd.children[1])
            sbp[idx[t], j] = 1.0
        end
        for t in tips(nd.children[2])
            sbp[idx[t], j] = -1.0
        end
    end
    return sbp, tl, [nd.label for nd in nodes]
end

miniclo(c::AbstractMatrix) = c ./ sum(c; dims=2)
shiftp(x::AbstractMatrix, p::AbstractVector) = x ./ reshape(p, 1, :)

"g.rowMeans: the p-weighted geometric mean of each row."
function g_rowmeans(y::AbstractMatrix, p::AbstractVector)
    return [exp(sum(log(y[i, j]) * p[j] for j in axes(y, 2)) / sum(p)) for i in axes(y, 1)]
end

function clrp(y::AbstractMatrix, p::AbstractVector)
    y = miniclo(y)
    g = g_rowmeans(y, p)
    return log.(y ./ g)
end

function normp(y::AbstractVector, p::AbstractVector)
    c = clrp(reshape(collect(y), 1, :), p)
    return sqrt(sum(p[j] * c[1, j]^2 for j in eachindex(p)))
end

"philr's buildilrBasep: the dense basis, +c/r on the numerator and -c/s on the denominator."
function build_ilr_base(W::AbstractMatrix, p::AbstractVector)
    D, K = size(W)
    V = zeros(Float64, D, K)
    for k in 1:K
        npos = sum(p[i] for i in 1:D if W[i, k] > 0)
        nneg = sum(p[i] for i in 1:D if W[i, k] < 0)
        c = sqrt(npos * nneg / (npos + nneg))
        for i in 1:D
            V[i, k] = W[i, k] > 0 ? c / npos : W[i, k] < 0 ? -c / nneg : 0.0
        end
    end
    return V
end

"ilrp = clrp(y, p) %*% diag(p) %*% V."
function ilrp(y::AbstractMatrix, p::AbstractVector, V::AbstractMatrix)
    c = clrp(y, p)
    n, D = size(c)
    K = size(V, 2)
    return [sum(c[s, i] * p[i] * V[i, k] for i in 1:D) for s in 1:n, k in 1:K]
end

function part_weights(x::AbstractMatrix, kind::AbstractString)
    n, D = size(x)
    gm = [exp(sum(log(x[s, j]) for s in 1:n) / n) for j in 1:D]
    closed_t = miniclo(permutedims(x))          # taxa x samples, each taxon closed over samples
    anorm = [normp(closed_t[j, :], ones(n)) for j in 1:D]
    enorm = [sqrt(sum(closed_t[j, s]^2 for s in 1:n)) for j in 1:D]
    kind == "uniform" && return ones(D)
    kind == "gm_counts" && return gm
    kind == "anorm" && return anorm
    kind == "anorm_x_gm_counts" && return gm .* anorm
    kind == "enorm" && return enorm
    kind == "enorm_x_gm_counts" && return gm .* enorm
    error("unknown part weights '$kind'")
end

"calculate.blw's rule: zero-length tip edges become the smallest non-zero edge length."
function replace_zero_tip_edges(tree::RNode)
    lengths = Float64[]
    function collect_lengths(m::RNode, is_root::Bool)
        is_root || m.len === nothing || push!(lengths, m.len)
        for c in m.children
            collect_lengths(c, false)
        end
    end
    collect_lengths(tree, true)
    min_nonzero = minimum(l for l in lengths if l > 0)
    function rebuild(m::RNode, is_root::Bool)
        out = RNode(m.label, m.len, RNode[rebuild(c, false) for c in m.children])
        if !is_root && is_tip(m) && m.len == 0.0
            out.len = min_nonzero
        end
        return out
    end
    return rebuild(tree, true)
end

"Mean path length from a node to its descendant tips (0 for a tip)."
function mean_dist_to_tips(n::RNode)
    is_tip(n) && return 0.0
    dists = Float64[]
    function walk(m::RNode, acc::Float64)
        if is_tip(m)
            push!(dists, acc)
            return
        end
        for c in m.children
            walk(c, acc + something(c.len))
        end
    end
    walk(n, 0.0)
    return sum(dists) / length(dists)
end

function ilr_weights(tree::RNode, kind::AbstractString)
    nodes = internal_preorder(tree)
    kind == "uniform" && return ones(length(nodes))
    nodes2 = internal_preorder(replace_zero_tip_edges(tree))
    if kind == "blw" || kind == "blw_sqrt"
        w = [sum(something(c.len) for c in nd.children) for nd in nodes2]
        return kind == "blw_sqrt" ? sqrt.(w) : w
    end
    if kind == "mean_descendants"
        return [sum(something(c.len) + mean_dist_to_tips(c) for c in nd.children) for nd in nodes2]
    end
    error("unknown ilr weights '$kind'")
end

"philr.data.frame(x, tree, part.weights, ilr.weights, pseudocount = 0); x is samples x taxa."
function philr(x::AbstractMatrix, taxa::Vector{String}, tree::RNode, part::AbstractString, ilrw::AbstractString)
    all(>(0), x) || error("philr reference needs a strictly positive table")
    sbp, tl, labels = phylo2sbp(tree)
    order = [findfirst(==(t), tl) for t in taxa]     # sbp <- sbp[colnames(x), ]
    sbp = sbp[order, :]
    p = part_weights(x, part)
    y = shiftp(miniclo(x), p)
    V = build_ilr_base(sbp, p)
    out = ilrp(y, p, V)
    w = ilr_weights(tree, ilrw)
    return out .* reshape(w, 1, :), labels
end

# ------------------------------------------------------------------------------------------
# compositions / robCompositions
# ------------------------------------------------------------------------------------------

"robCompositions::variation(x, method = \"Pairwise\"): var(log(x_i / x_j)), denominator n - 1."
function variation(x::AbstractMatrix)
    n, D = size(x)
    L = log.(x)
    T = zeros(Float64, D, D)
    for i in 1:D, j in (i+1):D
        d = [L[s, i] - L[s, j] for s in 1:n]
        m = sum(d) / n
        T[i, j] = T[j, i] = sum((v - m)^2 for v in d) / (n - 1)
    end
    return T
end

"""
    generic_hclust(diss, method) -> (merge, height)

Textbook agglomerative clustering on a full dissimilarity matrix: at every step merge the
active pair with the globally smallest dissimilarity, then update by Lance-Williams; ward
is R's ward.D2 (Lance-Williams on squared dissimilarities, height = square root). Output in
the conventions of the merge matrix R's hclust() returns (singletons negative, clusters by merge step; a singleton
before a cluster, the lower-numbered singleton or the earlier cluster first). Refuses data
whose minimum is not unique: this reference is for tie-free fixtures only.
"""
function generic_hclust(diss::AbstractMatrix, method::AbstractString)
    D = size(diss, 1)
    ward = method == "ward"
    d = ward ? diss .^ 2 : copy(float.(diss))
    code = [-i for i in 1:D]          # R code of the cluster held at each position
    sz = ones(Int, D)
    active = trues(D)
    merge = zeros(Int, D - 1, 2)
    height = zeros(Float64, D - 1)
    for step in 1:(D-1)
        best = Inf
        second = Inf
        bi = bj = 0
        for i in 1:D, j in (i+1):D
            (active[i] && active[j]) || continue
            v = d[i, j]
            if v < best
                second = best
                best = v
                bi, bj = i, j
            elseif v < second
                second = v
            end
        end
        second - best > 1e-12 * max(1.0, abs(best)) ||
            error("tied minimum at step $step: the generic reference is for tie-free data")
        a, b = code[bi], code[bj]
        if a > 0 && b < 0
            a, b = b, a
        elseif a < 0 && b < 0
            a, b = max(a, b), min(a, b)
        elseif a > 0 && b > 0
            a, b = min(a, b), max(a, b)
        end
        merge[step, 1] = a
        merge[step, 2] = b
        height[step] = ward ? sqrt(best) : best
        ni, nj = sz[bi], sz[bj]
        for k in 1:D
            (active[k] && k != bi && k != bj) || continue
            nk = sz[k]
            dki, dkj = d[k, bi], d[k, bj]
            new = if ward
                ((ni + nk) * dki + (nj + nk) * dkj - nk * best) / (ni + nj + nk)
            elseif method == "complete"
                max(dki, dkj)
            elseif method == "average"
                (ni * dki + nj * dkj) / (ni + nj)
            else
                error("unknown method '$method'")
            end
            d[k, bi] = d[bi, k] = new
        end
        active[bj] = false
        sz[bi] = ni + nj
        code[bi] = step
    end
    return merge, height
end

"compositions::gsi.merge2signary, returned as D x (D-1): column k is merge step k."
function merge2signary(M::AbstractMatrix{<:Integer})
    nm = size(M, 1)
    V = zeros(Float64, nm, nm + 1)
    for i in 1:nm, j in 1:2
        weight = j == 1 ? -1.0 : 1.0
        k = M[i, j]
        if k < 0
            V[i, -k] = weight
        else
            take = V[k, :] .!= 0
            V[i, take] .= weight
        end
    end
    return permutedims(V)
end

"Merge steps in preorder from the root, the numerator (second) child first."
function signary_preorder(M::AbstractMatrix{<:Integer})
    order = Int[]
    function rec(step::Int)
        push!(order, step)
        for c in (M[step, 2], M[step, 1])
            c > 0 && rec(c)
        end
    end
    rec(size(M, 1))
    return order
end

"compositions::ilr(x, gsi.buildilrBase(W)) = clr(x) %*% V; x is samples x taxa."
function ilr_uniform(x::AbstractMatrix, W::AbstractMatrix)
    n, D = size(x)
    L = log.(x)
    clr = L .- sum(L; dims=2) ./ D
    V = build_ilr_base(W, ones(D))
    return [sum(clr[s, i] * V[i, k] for i in 1:D) for s in 1:n, k in 1:size(V, 2)]
end

# ------------------------------------------------------------------------------------------
# philr's own known-answer test, re-checked before anything is computed
# ------------------------------------------------------------------------------------------

function philr_known_answers()
    sbp = [1.0 0.0; -1.0 1.0; -1.0 -1.0]
    p = [1.0, 1.0, 0.5]
    V = build_ilr_base(sbp, p)
    expected = [0.7745967 0.0; -0.5163978 0.5773503; -0.5163978 -1.1547005]
    maximum(abs.(V .- expected)) < 1e-7 || error("philr known answer (buildilrBasep) failed: $V")
    shiftp([1.0 2.0 3.0], [1.0, 0.1, 0.5]) ≈ [1.0 20.0 6.0] || error("philr known answer (shiftp) failed")
    for a in 1:2, b in 1:2          # orthonormal under the p-weighted inner product
        g = sum(V[i, a] * p[i] * V[i, b] for i in 1:3)
        abs(g - (a == b ? 1.0 : 0.0)) < 1e-12 || error("basis not p-orthonormal: G[$a,$b] = $g")
    end
    return true
end

# ------------------------------------------------------------------------------------------
# Fixture I/O and the expectations
# ------------------------------------------------------------------------------------------

"rows x cols matrix from a fixture CSV (first column row ids; header corner + column ids)."
function read_matrix(path::AbstractString)
    lines = [String(strip(l)) for l in readlines(path) if !isempty(strip(l))]
    cols = map(String, split(lines[1], ',')[2:end])
    rows = String[]
    M = zeros(Float64, length(lines) - 1, length(cols))
    for (r, l) in enumerate(lines[2:end])
        f = split(l, ',')
        push!(rows, String(f[1]))
        for c in eachindex(cols)
            M[r, c] = parse(Float64, f[c+1])
        end
    end
    return rows, cols, M
end

"samples x taxa table, taxa and sample ids from a fixture counts.csv (taxa x samples)."
function read_counts(dir::AbstractString)
    taxa, samples, M = read_matrix(joinpath(dir, "counts.csv"))
    return permutedims(M), taxa, samples
end

# (dataset, [(part.weights, ilr.weights), ...]) -- the combinations committed as fixtures
const REFERENCE_DATASETS = [
    ("philr_d8", [("uniform", "uniform"), ("gm_counts", "blw"), ("enorm_x_gm_counts", "blw_sqrt")]),
    ("philr_d25", [("uniform", "uniform"), ("anorm", "blw"), ("anorm_x_gm_counts", "mean_descendants")]),
    ("philr_d60_pruned", [("uniform", "uniform"), ("enorm", "uniform"), ("gm_counts", "mean_descendants")]),
]

const DENDROGRAM_METHODS = ("ward", "complete", "average")

"Balance ids as the fixtures name them: node labels when all present, unique and non-numeric, else n1..n(D-1)."
function balance_names(labels)
    usable = all(l -> l !== nothing && !isempty(l) && tryparse(Float64, l) === nothing, labels) &&
             allunique(labels)
    return usable ? String[l for l in labels] : ["n$k" for k in eachindex(labels)]
end

"""
    reference_expectations(root = HERE) -> Vector{NamedTuple}

Every committed expectation recomputed from the committed inputs:
`(file, corner, rows, cols, values)` with `file` relative to `root`. merge_*.csv entries
have rows = steps, cols = ["a", "b", "height"].
"""
function reference_expectations(root::AbstractString=HERE)
    philr_known_answers()
    out = NamedTuple[]
    for (name, combos) in REFERENCE_DATASETS
        dir = joinpath(root, name)
        x, taxa, samples = read_counts(dir)
        full = parse_newick(read(joinpath(dir, "tree.nwk"), String))
        tree = keep_tips(full, Set(taxa))
        for (part, ilrw) in combos
            vals, labels = philr(x, taxa, tree, part, ilrw)
            push!(out, (file=joinpath(name, "expected_$(part)__$(ilrw).csv"), corner="balance",
                        rows=balance_names(labels), cols=samples, values=permutedims(vals)))
        end
    end

    # SBP: rows of sbp.csv are deliberately in a different order from the table
    dir = joinpath(root, "sbp_d12")
    x, taxa, samples = read_counts(dir)
    sbp_taxa, bal, Wf = read_matrix(joinpath(dir, "sbp.csv"))
    W = Wf[[findfirst(==(t), sbp_taxa) for t in taxa], :]
    push!(out, (file=joinpath("sbp_d12", "expected.csv"), corner="balance", rows=bal, cols=samples,
                values=permutedims(ilr_uniform(x, W))))

    # Balance dendrogram
    dir = joinpath(root, "dendrogram_d30")
    x, taxa, samples = read_counts(dir)
    T = variation(x)
    push!(out, (file=joinpath("dendrogram_d30", "variation.csv"), corner="taxon", rows=taxa, cols=taxa, values=T))
    for method in DENDROGRAM_METHODS
        M, h = generic_hclust(T, method)
        all(diff(h) .>= 0) || error("$method heights are not monotone")
        steps = [string(k) for k in 1:size(M, 1)]
        push!(out, (file=joinpath("dendrogram_d30", "merge_$method.csv"), corner="step", rows=steps,
                    cols=["a", "b", "height"], values=hcat(float(M), h)))
        order = signary_preorder(M)
        vals = ilr_uniform(x, merge2signary(M)[:, order])
        push!(out, (file=joinpath("dendrogram_d30", "expected_$method.csv"), corner="balance",
                    rows=["m$k" for k in order], cols=samples, values=permutedims(vals)))
    end
    return out
end

function write_expectation(root::AbstractString, e)
    open(joinpath(root, e.file), "w") do io
        println(io, join(vcat(e.corner, e.cols), ","))
        integer_cols = e.corner == "step" ? (1, 2) : ()
        for (r, id) in enumerate(e.rows)
            cells = [c in integer_cols ? string(Int(e.values[r, c])) : repr(e.values[r, c]) for c in eachindex(e.cols)]
            println(io, join(vcat(id, cells), ","))
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    "--write" in ARGS || (println("usage: julia --project=. test/fixtures/ilr/ilr_reference.jl --write"); exit(2))
    for e in reference_expectations()
        write_expectation(HERE, e)
        println("wrote ", e.file)
    end
end

end # module ILRReference
