module CladeCumulus

# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Phylogenetic roll-ups and diversity for the study-scoped CladeCumulus view.
#
# This is deliberately independent of R and of the external tree builders. The
# pipeline produces a Newick tree; this module parses it and performs the small,
# exact (up to floating-point summation) calculations that can be tested against
# hand-worked examples. Count matrices are samples × tips throughout.

using SHA

export PhyloNode, PhylogeneticTree, parse_newick, asv_tip_name, clade_counts,
       faith_pd, unifrac, analyse_phylogeny

"""A node in a parsed Newick tree. `length` is the branch above this node."""
mutable struct PhyloNode
    name::String
    length::Union{Float64,Nothing}
    parent::Int                         # 0 only for the root
    children::Vector{Int}
end

"""
A rooted view of a Newick topology. The root may have three children (the usual
representation of an unrooted binary tree); metrics do not invent a root branch.
Node ids are 1-based and parents always precede their children.
"""
struct PhylogeneticTree
    nodes::Vector{PhyloNode}
    root::Int
    tips::Dict{String,Int}
end

"""Stable, tool-safe ASV tip name tied to sequence content, not to a row number."""
function asv_tip_name(sequence::AbstractString)
    normalised = uppercase(replace(strip(sequence), r"[\s\-.]" => ""))
    isempty(normalised) && throw(ArgumentError("an ASV sequence is empty"))
    "ASV_" * bytes2hex(sha256(normalised))[1:20]
end

## Newick parser

mutable struct _Parser
    bytes::Vector{UInt8}
    pos::Int
    nodes::Vector{PhyloNode}
    tips::Dict{String,Int}
end

@inline _done(p::_Parser) = p.pos > length(p.bytes)
@inline _peek(p::_Parser) = _done(p) ? 0x00 : p.bytes[p.pos]
@inline _is_space(b::UInt8) = b in (0x09, 0x0a, 0x0d, 0x20)
@inline _is_delim(b::UInt8) = _is_space(b) || b in (
    UInt8('('), UInt8(')'), UInt8(','), UInt8(':'), UInt8(';'),
    UInt8('['), UInt8(']'))

_fail(p::_Parser, message::AbstractString) =
    throw(ArgumentError("Newick byte $(p.pos): $message"))

# Whitespace and square-bracket comments may occur between every token. Comments
# nest in several Newick writers, so track depth rather than looking for the first
# closing bracket.
function _skip!(p::_Parser)
    while !_done(p)
        if _is_space(_peek(p))
            p.pos += 1
        elseif _peek(p) == UInt8('[')
            depth = 0
            while !_done(p)
                b = _peek(p)
                p.pos += 1
                b == UInt8('[') && (depth += 1)
                if b == UInt8(']')
                    depth -= 1
                    depth == 0 && break
                end
            end
            depth == 0 || _fail(p, "unclosed comment")
        else
            break
        end
    end
end

function _take!(p::_Parser, expected::UInt8)
    _skip!(p)
    _peek(p) == expected || _fail(p, "expected '$(Char(expected))'")
    p.pos += 1
end

function _label!(p::_Parser)::String
    _skip!(p)
    _done(p) && return ""
    quote = _peek(p)
    if quote in (UInt8('\''), UInt8('"'))
        p.pos += 1
        out = UInt8[]
        while !_done(p)
            b = _peek(p)
            p.pos += 1
            if b == quote
                if !_done(p) && _peek(p) == quote  # doubled quote in a quoted label
                    push!(out, quote)
                    p.pos += 1
                else
                    return String(out)
                end
            else
                push!(out, b)
            end
        end
        _fail(p, "unclosed quoted label")
    end
    first = p.pos
    while !_done(p) && !_is_delim(_peek(p))
        p.pos += 1
    end
    String(p.bytes[first:p.pos-1])
end

function _length!(p::_Parser)::Float64
    _skip!(p)
    first = p.pos
    while !_done(p) && !_is_delim(_peek(p))
        p.pos += 1
    end
    first < p.pos || _fail(p, "missing branch length after ':'")
    token = String(p.bytes[first:p.pos-1])
    value = try parse(Float64, token) catch
        _fail(p, "invalid branch length '$token'")
    end
    (isfinite(value) && value >= 0) ||
        _fail(p, "branch lengths must be finite and non-negative")
    value
end

function _node!(p::_Parser, parent::Int)
    push!(p.nodes, PhyloNode("", nothing, parent, Int[]))
    length(p.nodes)
end

function _parse_node!(p::_Parser, parent::Int)::Int
    _skip!(p)
    _done(p) && _fail(p, "expected a node")
    id = _node!(p, parent)
    leaf = _peek(p) != UInt8('(')
    if !leaf
        _take!(p, UInt8('('))
        while true
            child = _parse_node!(p, id)
            push!(p.nodes[id].children, child)
            _skip!(p)
            if _peek(p) == UInt8(',')
                p.pos += 1
                continue
            end
            _peek(p) == UInt8(')') || _fail(p, "expected ',' or ')'")
            p.pos += 1
            break
        end
        isempty(p.nodes[id].children) && _fail(p, "an internal node needs children")
    end

    label = _label!(p)
    if leaf
        isempty(label) && _fail(p, "a tip needs a non-empty label")
        haskey(p.tips, label) && _fail(p, "duplicate tip '$label'")
        p.tips[label] = id
    end
    p.nodes[id].name = label
    _skip!(p)
    if _peek(p) == UInt8(':')
        p.pos += 1
        p.nodes[id].length = _length!(p)
    end
    id
end

"""
    parse_newick(text) -> PhylogeneticTree

Parse one Newick tree, including quoted/Unicode tip labels, bracket comments,
internal support labels and non-binary nodes. Duplicate or empty tip labels and
negative/non-finite branch lengths are rejected. Missing branch lengths remain
`nothing` and are rejected later by Faith PD/UniFrac rather than silently treated
as zero-length biology.
"""
function parse_newick(text::AbstractString)::PhylogeneticTree
    p = _Parser(Vector{UInt8}(codeunits(text)), 1, PhyloNode[], Dict{String,Int}())
    root = _parse_node!(p, 0)
    _take!(p, UInt8(';'))
    _skip!(p)
    _done(p) || _fail(p, "unexpected content after ';'")
    isempty(p.tips) && throw(ArgumentError("Newick tree has no tips"))
    root == 1 || error("internal parser error: root is not the first node")
    PhylogeneticTree(p.nodes, root, p.tips)
end

## Roll-ups and metrics

function _check_counts(tree::PhylogeneticTree, counts, tip_names)
    ndims(counts) == 2 || throw(DimensionMismatch("counts must be a samples × ASVs matrix"))
    size(counts, 2) == length(tip_names) || throw(DimensionMismatch(
        "counts has $(size(counts, 2)) columns but $(length(tip_names)) tip names were supplied"))
    length(unique(String.(tip_names))) == length(tip_names) ||
        throw(ArgumentError("tip names must be unique"))
    all(v -> isfinite(v) && v >= 0, counts) ||
        throw(ArgumentError("counts must be finite and non-negative"))
    for name in tip_names
        haskey(tree.tips, String(name)) || throw(ArgumentError(
            "count feature '$name' is not a tip in the tree; refusing to discard its reads"))
    end
    nothing
end

"""
    clade_counts(tree, counts, tip_names) -> Matrix{Float64}

Return a nodes × samples matrix. Each tip receives its ASV counts, then a single
reverse-node-order pass adds every child's counts to its parent. Thus every node
contains the cumulative abundance of its whole phylogenetic clade in O(nodes ×
samples + ASVs × samples), not repeated subtree scans.
"""
function clade_counts(tree::PhylogeneticTree, counts::AbstractMatrix{<:Real},
                      tip_names::AbstractVector{<:AbstractString})::Matrix{Float64}
    _check_counts(tree, counts, tip_names)
    samples = size(counts, 1)
    cumulative = zeros(Float64, length(tree.nodes), samples)
    for (j, name) in enumerate(tip_names), sample in 1:samples
        cumulative[tree.tips[String(name)], sample] += Float64(counts[sample, j])
    end
    for id in length(tree.nodes):-1:1
        parent = tree.nodes[id].parent
        parent == 0 && continue
        for sample in 1:samples
            cumulative[parent, sample] += cumulative[id, sample]
        end
    end
    cumulative
end

function _lengths(tree::PhylogeneticTree)::Vector{Float64}
    lengths = zeros(Float64, length(tree.nodes))
    for id in eachindex(tree.nodes)
        id == tree.root && continue  # a root's optional length is not a branch in the tree
        length = tree.nodes[id].length
        isnothing(length) && throw(ArgumentError(
            "Faith PD and UniFrac need a length on every non-root branch"))
        lengths[id] = something(length, 0.0)
    end
    lengths
end

function _check_cumulative(tree::PhylogeneticTree, cumulative)
    size(cumulative, 1) == length(tree.nodes) || throw(DimensionMismatch(
        "cumulative matrix has the wrong node count"))
    all(v -> isfinite(v) && v >= 0, cumulative) ||
        throw(ArgumentError("cumulative counts must be finite and non-negative"))
end

"""Faith's phylogenetic diversity for each sample column of a nodes × samples roll-up."""
function faith_pd(tree::PhylogeneticTree, cumulative::AbstractMatrix{<:Real})::Vector{Float64}
    _check_cumulative(tree, cumulative)
    lengths = _lengths(tree)
    samples = size(cumulative, 2)
    out = zeros(Float64, samples)
    for id in eachindex(tree.nodes)
        id == tree.root && continue
        for sample in 1:samples
            cumulative[id, sample] > 0 && (out[sample] += lengths[id])
        end
    end
    out
end

faith_pd(tree::PhylogeneticTree, counts::AbstractMatrix{<:Real},
         tip_names::AbstractVector{<:AbstractString}) =
    faith_pd(tree, clade_counts(tree, counts, tip_names))

"""
    unifrac(tree, cumulative; weighted=false) -> Matrix{Float64}

Pairwise UniFrac between sample columns of a nodes × samples roll-up.

Unweighted UniFrac is unique branch length divided by branch length present in
either sample. Weighted UniFrac uses clade relative abundances and is normalized
by `sum(length * (a + b))`, giving a distance in [0, 1]. Two empty samples have
distance 0; one empty and one non-empty sample have distance 1. The web workflow
omits empty samples up front, but these definitions keep the pure API total.
"""
function unifrac(tree::PhylogeneticTree, cumulative::AbstractMatrix{<:Real};
                 weighted::Bool=false)::Matrix{Float64}
    _check_cumulative(tree, cumulative)
    lengths = _lengths(tree)
    samples = size(cumulative, 2)
    totals = vec(sum(cumulative[tree.root, :] ; dims=1))
    out = zeros(Float64, samples, samples)
    for a in 1:samples, b in a+1:samples
        numerator = 0.0
        denominator = 0.0
        for id in eachindex(tree.nodes)
            id == tree.root && continue
            av = Float64(cumulative[id, a])
            bv = Float64(cumulative[id, b])
            length = lengths[id]
            if weighted
                ar = totals[a] > 0 ? av / totals[a] : 0.0
                br = totals[b] > 0 ? bv / totals[b] : 0.0
                numerator += length * abs(ar - br)
                denominator += length * (ar + br)
            else
                ap = av > 0
                bp = bv > 0
                ap != bp && (numerator += length)
                (ap || bp) && (denominator += length)
            end
        end
        one_empty = (totals[a] > 0) != (totals[b] > 0)
        distance = denominator > 0 ? numerator / denominator : (one_empty ? 1.0 : 0.0)
        out[a, b] = out[b, a] = distance
    end
    out
end

unifrac(tree::PhylogeneticTree, counts::AbstractMatrix{<:Real},
        tip_names::AbstractVector{<:AbstractString}; weighted::Bool=false) =
    unifrac(tree, clade_counts(tree, counts, tip_names); weighted)

"""
    analyse_phylogeny(tree, counts, tip_names, sample_names) -> NamedTuple

Compute the complete JSON-ready CladeCumulus result: cumulative clade counts and
frequencies, Faith PD, and both UniFrac matrices. The two matrices share one
roll-up, so tree traversal and validation happen only once.
"""
function analyse_phylogeny(tree::PhylogeneticTree, counts::AbstractMatrix{<:Real},
                           tip_names::AbstractVector{<:AbstractString},
                           sample_names::AbstractVector{<:AbstractString})
    size(counts, 1) == length(sample_names) || throw(DimensionMismatch(
        "counts has $(size(counts, 1)) rows but $(length(sample_names)) sample names were supplied"))
    length(unique(String.(sample_names))) == length(sample_names) ||
        throw(ArgumentError("sample names must be unique"))
    cumulative = clade_counts(tree, counts, tip_names)
    samples = String.(sample_names)
    totals = vec(cumulative[tree.root, :])
    grand_total = sum(totals)

    tip_counts = zeros(Int, length(tree.nodes))
    for id in length(tree.nodes):-1:1
        node = tree.nodes[id]
        tip_counts[id] = isempty(node.children) ? 1 : sum(tip_counts[c] for c in node.children)
    end
    tip_ids = Set(values(tree.tips))
    nodes = map(eachindex(tree.nodes)) do id
        node = tree.nodes[id]
        parent = node.parent == 0 ? nothing : "n$(node.parent)"
        count = sum(cumulative[id, :])
        (; id = "n$id", parent_id = parent,
           label = isempty(node.name) ? (id in tip_ids ? "Tip $id" : "Clade $id") : node.name,
           branch_length = id == tree.root ? nothing : node.length,
           is_tip = id in tip_ids,
           tip_count = tip_counts[id],
           cumulative_count = count,
           cumulative_frequency = grand_total > 0 ? count / grand_total : 0.0)
    end

    (; nodes, samples,
       sample_reads = collect(totals),
       faith_pd = faith_pd(tree, cumulative),
       unweighted_unifrac = unifrac(tree, cumulative),
       weighted_unifrac = unifrac(tree, cumulative; weighted=true),
       total_branch_length = sum(_lengths(tree)))
end

end # module CladeCumulus
