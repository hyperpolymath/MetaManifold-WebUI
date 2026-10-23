# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

"""
CladeCumulus phylogenetic and taxonomic cladistic explorer, strict raw `.jplace`
evidence reader, Faith's Phylogenetic Diversity, and Unweighted / Weighted UniFrac.
"""
module CladeCumulus

using DataFrames
using JSON3
using OrderedCollections
using SHA
import ..Epistemic
import ..Phylogeny

export PhyloNode, QueryCandidate, QueryPlacement, JplaceDocument,
       CladeNode, CladeTreeResult,
       parse_newick, midpoint_root, parse_jplace,
       faith_pd, faith_pd_table, clade_faith_pd,
       unweighted_unifrac, weighted_unifrac, unifrac_matrix,
       branch_unifrac_contributions,
       build_clade_tree, validate_drag_drop,
       to_plotly_figure, clade_node_to_dict

const DEFAULT_TAXONOMIC_RANKS = [
    "Domain", "Kingdom", "Supergroup", "Division", "Phylum",
    "Class", "Order", "Family", "Genus", "Species",
]

# Multi-candidate placements partition probability mass across kept edges and
# must sum to 1 within floating-point tolerance; single-candidate placements
# leave unplaced mass off the tree and require at least half the mass at the
# reported site (`PLACEMENT_SINGLE_MIN_LWR`).
const PLACEMENT_WEIGHT_SUM_TOL = 1e-5
const PLACEMENT_SINGLE_MIN_LWR = 0.5

## Phylogenetic tree structures & Newick / jplace parsers
mutable struct PhyloNode
    id            :: String
    name          :: String
    branch_length :: Float64
    support       :: Union{Float64,Nothing}
    edge_number   :: Union{Int,Nothing}
    children      :: Vector{PhyloNode}
end

struct QueryCandidate
    ordinal       :: Int
    edge_num      :: Int
    like_weight   :: Float64
    pendant_len   :: Float64
    distal_len    :: Float64
end

struct QueryPlacement
    ordinal       :: Int
    names         :: Vector{Tuple{String,Float64}}
    candidates    :: Vector{QueryCandidate}
    status        :: Symbol        # :valid | :undecided
    reason        :: String
    max_lwr       :: Union{Float64,Nothing}
end

struct JplaceDocument
    tree_newick   :: String
    root          :: PhyloNode
    fields        :: Vector{String}
    edge_to_node  :: Dict{Int,PhyloNode}
    queries       :: Vector{QueryPlacement}
    warnings      :: Vector{String}
end

struct CladeNode
    id                   :: String
    name                 :: String
    rank                 :: String
    direct_count         :: Float64
    cumulative_count     :: Float64
    cumulative_frequency :: Float64
    residual_count       :: Float64
    cloud_size           :: Float64
    branch_length        :: Float64
    support              :: Union{Float64,Nothing}
    subtree_pd           :: Float64
    dominant_taxon       :: Union{String,Nothing}
    taxon_purity         :: Union{Float64,Nothing}
    monophyletic         :: Union{Bool,Nothing}
    epistemic_status     :: Symbol
    colour               :: String
    children             :: Vector{CladeNode}
end

struct CladeTreeResult
    mode              :: Symbol
    root              :: CladeNode
    case              :: Epistemic.Case
    phylo_root        :: Union{PhyloNode,Nothing}
    newick            :: Union{String,Nothing}
    midpoint_rooted   :: Bool
    dispersed_taxa    :: Vector{OrderedDict{String,Any}}
    discordant_clades :: Vector{OrderedDict{String,Any}}
    warnings          :: Vector{String}
    tool_records      :: Vector{OrderedDict{String,Any}}
    subsampled        :: Bool
    total_input_asvs  :: Int
    retained_asvs     :: Int
    retained_fraction :: Float64
end

# Normalize raw bootstrap/SH-like support values into [0.0, 1.0].
function _normalize_support(raw::Float64)::Union{Float64,Nothing}
    isfinite(raw) || return nothing
    raw < 0.0 && return nothing
    raw <= 1.0 && return raw
    raw <= 100.0 && return raw / 100.0
    nothing
end

function _parse_label_and_support(
    raw_label::AbstractString,
    nhx_support::Union{Float64,Nothing},
    is_internal::Bool,
)::Tuple{String,Union{Float64,Nothing}}
    lbl = strip(raw_label)
    isempty(lbl) && return ("", nhx_support)
    if is_internal
        # Plain numeric support e.g. `0.94` or `96`
        num = tryparse(Float64, lbl)
        if num !== nothing
            return ("", _normalize_support(num))
        end
        # Dual IQ-TREE support e.g. `88.4/96` or `CladeA/95`
        parts = split(lbl, '/')
        if length(parts) == 2
            n1 = tryparse(Float64, parts[1])
            n2 = tryparse(Float64, parts[2])
            if n1 !== nothing && n2 !== nothing
                s1 = _normalize_support(n1)
                s2 = _normalize_support(n2)
                s = (s1 !== nothing && s2 !== nothing) ? min(s1, s2) : something(s1, s2, nhx_support)
                return ("", s)
            elseif n2 !== nothing
                return (String(parts[1]), _normalize_support(n2))
            end
        end
    end
    return (String(lbl), nhx_support)
end

"""
    parse_newick(src::AbstractString; warnings=String[]) -> PhyloNode

Parse a Newick tree string supporting single-quoted labels with doubled-quote
escapes, leading `[&R]`/`[&U]` comments, NHX `[&&NHX:B=...]` support tags,
IQ-TREE dual supports (`SH-aLRT/UFBoot`), FastTree local supports, and `.jplace`
`{edge_num}` edge tags. Negative branch lengths are clamped to `0.0` with a
recorded warning.
"""
function parse_newick(src::AbstractString; warnings::Vector{String} = String[])::PhyloNode
    s = strip(src)
    isempty(s) && throw(ArgumentError("Empty Newick string"))
    bytes = codeunits(s)
    n = length(bytes)
    pos = Ref(1)
    auto_id = Ref(0)

    function skip_ws_and_leading_comments!(; capture_nhx::Union{Ref{Union{Float64,Nothing}},Nothing} = nothing,
                                            capture_edge::Union{Ref{Union{Int,Nothing}},Nothing} = nothing)
        while pos[] <= n
            b = bytes[pos[]]
            if b == UInt8(' ') || b == UInt8('\t') || b == UInt8('\r') || b == UInt8('\n')
                pos[] += 1
            elseif b == UInt8('[')
                start_i = pos[] + 1
                pos[] += 1
                while pos[] <= n && bytes[pos[]] != UInt8(']')
                    pos[] += 1
                end
                pos[] <= n || throw(ArgumentError("Unclosed '[' comment in Newick"))
                body = SubString(s, start_i, pos[] - 1)
                pos[] += 1
                if capture_nhx !== nothing
                    m_nhx = match(r"(?:^|:)B=([0-9]+(?:\.[0-9]+)?)"i, body)
                    if m_nhx !== nothing
                        v = tryparse(Float64, m_nhx.captures[1])
                        v !== nothing && (capture_nhx[] = _normalize_support(v))
                    else
                        v = tryparse(Float64, strip(body))
                        v !== nothing && (capture_nhx[] = _normalize_support(v))
                    end
                end
            elseif b == UInt8('{') && capture_edge !== nothing
                start_i = pos[] + 1
                pos[] += 1
                while pos[] <= n && bytes[pos[]] != UInt8('}')
                    pos[] += 1
                end
                pos[] <= n || throw(ArgumentError("Unclosed '{' edge number in Newick"))
                ev = tryparse(Int, strip(SubString(s, start_i, pos[] - 1)))
                ev === nothing && throw(ArgumentError("Non-integer jplace edge tag in Newick"))
                capture_edge[] = ev
                pos[] += 1
            else
                break
            end
        end
    end

    function read_label_and_quoted(; capture_nhx::Union{Ref{Union{Float64,Nothing}},Nothing} = nothing,
                                     capture_edge::Union{Ref{Union{Int,Nothing}},Nothing} = nothing)::Tuple{String,Bool}
        # An NHX comment immediately after ')' precedes the (usually empty)
        # label, so the capture refs must be threaded through this first skip
        # or the support tag is consumed as an anonymous comment.
        skip_ws_and_leading_comments!(capture_nhx = capture_nhx, capture_edge = capture_edge)
        pos[] > n && return ("", false)
        if bytes[pos[]] == UInt8('\'')
            pos[] += 1
            buf = IOBuffer()
            while pos[] <= n
                c = bytes[pos[]]
                if c == UInt8('\'')
                    if pos[] + 1 <= n && bytes[pos[] + 1] == UInt8('\'')
                        write(buf, '\'')
                        pos[] += 2
                    else
                        pos[] += 1
                        return (String(take!(buf)), true)
                    end
                else
                    ch = s[pos[]]
                    write(buf, ch)
                    pos[] += ncodeunits(ch)
                end
            end
            throw(ArgumentError("Unterminated quoted label in Newick"))
        end
        start_i = pos[]
        while pos[] <= n
            b = bytes[pos[]]
            if b == UInt8(':') || b == UInt8(',') || b == UInt8(')') ||
               b == UInt8('(') || b == UInt8(';') || b == UInt8('[') || b == UInt8('{')
                break
            end
            pos[] += 1
        end
        return (strip(String(SubString(s, start_i, pos[] - 1))), false)
    end

    function parse_subtree()::PhyloNode
        skip_ws_and_leading_comments!()
        children = PhyloNode[]
        if pos[] <= n && bytes[pos[]] == UInt8('(')
            pos[] += 1
            while true
                push!(children, parse_subtree())
                skip_ws_and_leading_comments!()
                pos[] <= n || throw(ArgumentError("Unexpected end inside '(' in Newick"))
                if bytes[pos[]] == UInt8(',')
                    pos[] += 1
                elseif bytes[pos[]] == UInt8(')')
                    pos[] += 1
                    break
                else
                    throw(ArgumentError("Expected ',' or ')' at byte $(pos[]) in Newick"))
                end
            end
        end

        nhx_sup = Ref{Union{Float64,Nothing}}(nothing)
        edge_num = Ref{Union{Int,Nothing}}(nothing)
        raw_lbl, was_quoted = read_label_and_quoted(capture_nhx = nhx_sup, capture_edge = edge_num)
        skip_ws_and_leading_comments!(capture_nhx = nhx_sup, capture_edge = edge_num)

        branch_len = 0.0
        if pos[] <= n && bytes[pos[]] == UInt8(':')
            pos[] += 1
            skip_ws_and_leading_comments!(capture_nhx = nhx_sup, capture_edge = edge_num)
            num_start = pos[]
            while pos[] <= n
                b = bytes[pos[]]
                if b == UInt8(',') || b == UInt8(')') || b == UInt8(';') ||
                   b == UInt8('[') || b == UInt8('{') || b == UInt8(' ') ||
                   b == UInt8('\t') || b == UInt8('\r') || b == UInt8('\n')
                    break
                end
                pos[] += 1
            end
            num_str = strip(String(SubString(s, num_start, pos[] - 1)))
            parsed_len = tryparse(Float64, num_str)
            (parsed_len === nothing || !isfinite(parsed_len)) &&
                throw(ArgumentError("Invalid branch length $(repr(num_str)) in Newick"))
            if parsed_len < 0.0
                push!(warnings, "Clamped negative branch length ($parsed_len) to 0.0.")
                branch_len = 0.0
            else
                branch_len = parsed_len
            end
            skip_ws_and_leading_comments!(capture_nhx = nhx_sup, capture_edge = edge_num)
        end

        is_internal = !isempty(children)
        name, support = was_quoted ? (raw_lbl, nhx_sup[]) :
            _parse_label_and_support(raw_lbl, nhx_sup[], is_internal)
        auto_id[] += 1
        node_id = if !is_internal && !isempty(name)
            name
        elseif !isempty(name)
            string("clade:", name, "#", auto_id[])
        else
            string("clade#", auto_id[])
        end
        PhyloNode(node_id, name, branch_len, support, edge_num[], children)
    end

    root = parse_subtree()
    skip_ws_and_leading_comments!()
    if pos[] <= n && bytes[pos[]] == UInt8(';')
        pos[] += 1
    else
        throw(ArgumentError("Missing terminating ';' in Newick"))
    end
    skip_ws_and_leading_comments!()
    pos[] <= n && throw(ArgumentError("Trailing characters after ';' in Newick"))
    return root
end

## Midpoint rooting (exact patristic diameter bisection matching scikit-bio)
struct _UndirEdge
    to      :: Int
    weight  :: Float64
    support :: Union{Float64,Nothing}
    edge_no :: Union{Int,Nothing}
end

"""
    midpoint_root(orig_root::PhyloNode) -> Tuple{PhyloNode, Bool}

If `orig_root` is already bifurcating (`length(children) <= 2`), return
`(orig_root, false)` unchanged. Otherwise bisect the longest tip-to-tip
patristic path at `0.5 * diameter` while preserving all pairwise patristic
distances, branch lengths, and bipartition supports.
"""
function midpoint_root(orig_root::PhyloNode)::Tuple{PhyloNode,Bool}
    length(orig_root.children) <= 2 && return (orig_root, false)

    nodes = PhyloNode[]
    function collect_nodes!(u::PhyloNode)
        push!(nodes, u)
        u_idx = length(nodes)
        for ch in u.children
            collect_nodes!(ch)
        end
        u_idx
    end
    collect_nodes!(orig_root)
    M = length(nodes)
    idx_of = Dict{UInt,Int}(objectid(nodes[i]) => i for i in 1:M)
    adj = [Vector{_UndirEdge}() for _ in 1:M]
    for i in 1:M
        u = nodes[i]
        for ch in u.children
            j = idx_of[objectid(ch)]
            w = max(0.0, ch.branch_length)
            push!(adj[i], _UndirEdge(j, w, ch.support, ch.edge_number))
            push!(adj[j], _UndirEdge(i, w, ch.support, ch.edge_number))
        end
    end

    tips = [i for i in 1:M if isempty(nodes[i].children)]
    length(tips) < 2 && return (orig_root, false)

    function tree_distances(start_idx::Int)
        dist = fill(-1.0, M)
        parent = zeros(Int, M)
        dist[start_idx] = 0.0
        stack = [start_idx]
        while !isempty(stack)
            u = pop!(stack)
            for e in adj[u]
                if dist[e.to] < 0.0
                    dist[e.to] = dist[u] + e.weight
                    parent[e.to] = u
                    push!(stack, e.to)
                end
            end
        end
        (dist, parent)
    end

    d1, _ = tree_distances(tips[1])
    tip_a = tips[1]
    for t in tips
        d1[t] > d1[tip_a] && (tip_a = t)
    end

    da, parent_from_a = tree_distances(tip_a)
    tip_b = tip_a
    for t in tips
        da[t] > da[tip_b] && (tip_b = t)
    end

    diameter = da[tip_b]
    path = Int[]
    cur = tip_b
    while cur != 0
        push!(path, cur)
        cur = parent_from_a[cur]
    end
    reverse!(path)
    half = 0.5 * diameter

    split_u = path[1]
    split_v = path[2]
    w_u = 0.0
    w_v = 0.0
    split_sup = nothing
    acc = 0.0
    for k in 1:(length(path) - 1)
        u = path[k]
        v = path[k + 1]
        ed = nothing
        for e in adj[u]
            if e.to == v
                ed = e
                break
            end
        end
        ed === nothing && error("Internal path discontinuity during midpoint rooting")
        if acc + ed.weight >= half || k == length(path) - 1
            split_u = u
            split_v = v
            w_u = clamp(half - acc, 0.0, ed.weight)
            w_v = max(0.0, ed.weight - w_u)
            split_sup = ed.support
            break
        end
        acc += ed.weight
    end

    rebuilt_id = Ref(0)
    function orient_from(
        curr_idx::Int,
        blocked_idx::Int,
        in_len::Float64,
        in_sup::Union{Float64,Nothing},
        in_edge::Union{Int,Nothing},
    )::PhyloNode
        orig = nodes[curr_idx]
        kids = PhyloNode[
            orient_from(e.to, curr_idx, e.weight, e.support, e.edge_no)
            for e in adj[curr_idx] if e.to != blocked_idx
        ]
        rebuilt_id[] += 1
        nid = isempty(kids) ? orig.id :
              (!isempty(orig.name) ? string("clade:", orig.name, "#", rebuilt_id[]) :
                                     string("clade#", rebuilt_id[]))
        PhyloNode(nid, orig.name, in_len, in_sup, in_edge, kids)
    end

    left_child = orient_from(split_u, split_v, w_u, split_sup, nothing)
    right_child = orient_from(split_v, split_u, w_v, split_sup, nothing)
    new_root = PhyloNode("MidpointRoot", "Root", 0.0, nothing, nothing, [left_child, right_child])
    return (new_root, true)
end

## Strict raw `.jplace` evidence parser (never manufactures LWR=1 on missing data)
"""
    parse_jplace(raw_json::AbstractString) -> JplaceDocument

Strictly parse a `.jplace` document before any display normalization:
- Validates unique integer `{edge_num}` annotations across the tree
- Validates explicit unique `"like_weight_ratio"` column in `"fields"`
- Validates each query's `p` candidates, finite weights in `[0, 1]`, edge
  references present on non-root edges, and total weight within `1e-5` of `1.0`
- Preserves raw query/candidate ordinals and `n` / `nm` multiplicities without
  re-normalizing weights or collapsing tied maxima.
"""
function parse_jplace(raw_json::AbstractString)::JplaceDocument
    doc = JSON3.read(raw_json)
    doc isa AbstractDict || throw(ArgumentError("Malformed jplace JSON: top-level must be an object"))
    haskey(doc, :tree) || throw(ArgumentError("Malformed jplace JSON: missing 'tree' field"))
    haskey(doc, :fields) || throw(ArgumentError("Malformed jplace JSON: missing 'fields' array"))
    haskey(doc, :placements) || throw(ArgumentError("Malformed jplace JSON: missing 'placements' array"))

    warnings = String[]
    tree_str = String(doc[:tree])
    root = parse_newick(tree_str; warnings = warnings)

    edge_to_node = Dict{Int,PhyloNode}()
    root_edge_nums = Set{Int}()
    function index_edges!(u::PhyloNode, is_root::Bool)
        if u.edge_number !== nothing
            haskey(edge_to_node, u.edge_number) &&
                throw(ArgumentError("Duplicate edge number $(u.edge_number) in jplace tree"))
            edge_to_node[u.edge_number] = u
            is_root && push!(root_edge_nums, u.edge_number)
        end
        for ch in u.children
            index_edges!(ch, false)
        end
    end
    index_edges!(root, true)

    fields = String[String(f) for f in doc[:fields]]
    edge_col = findall(==("edge_num"), fields)
    lwr_col = findall(==("like_weight_ratio"), fields)
    length(edge_col) == 1 ||
        throw(ArgumentError("jplace 'fields' must contain a unique 'edge_num' entry"))
    length(lwr_col) == 1 ||
        throw(ArgumentError("jplace 'fields' must contain an explicit unique 'like_weight_ratio' entry"))
    pend_col = findfirst(==("pendant_length"), fields)
    dist_col = findfirst(==("distal_length"), fields)

    ei = edge_col[1]
    li = lwr_col[1]

    queries = QueryPlacement[]
    for (q_ord, pentry) in enumerate(doc[:placements])
        pentry isa AbstractDict || throw(ArgumentError("Placement entry #$q_ord is not an object"))
        has_n = haskey(pentry, :n)
        has_nm = haskey(pentry, :nm)
        (has_n && has_nm) &&
            throw(ArgumentError("Placement entry #$q_ord specifies both 'n' and 'nm'"))
        (!has_n && !has_nm) &&
            throw(ArgumentError("Placement entry #$q_ord specifies neither 'n' nor 'nm'"))

        q_names = Tuple{String,Float64}[]
        if has_n
            for nm in pentry[:n]
                nm isa AbstractString || throw(ArgumentError("Non-string query name in entry #$q_ord"))
                push!(q_names, (String(nm), 1.0))
            end
        else
            for pair in pentry[:nm]
                (pair isa AbstractVector && length(pair) == 2 && pair[1] isa AbstractString &&
                 pair[2] isa Real && !(pair[2] isa Bool) && isfinite(Float64(pair[2])) && Float64(pair[2]) > 0.0) ||
                    throw(ArgumentError("Malformed 'nm' multiplicity in entry #$q_ord"))
                push!(q_names, (String(pair[1]), Float64(pair[2])))
            end
        end
        isempty(q_names) && throw(ArgumentError("Placement entry #$q_ord has empty query name list"))

        raw_p = get(pentry, :p, nothing)
        if !(raw_p isa AbstractVector) || isempty(raw_p)
            push!(queries, QueryPlacement(q_ord, q_names, QueryCandidate[], :undecided, "empty_candidates", nothing))
            continue
        end

        cands = QueryCandidate[]
        bad_reason = ""
        weight_sum = 0.0
        for (c_ord, row) in enumerate(raw_p)
            if !(row isa AbstractVector) || length(row) < length(fields)
                bad_reason = "short_candidate_row"
                break
            end
            ev = row[ei]
            wv = row[li]
            if !(ev isa Integer && !(ev isa Bool)) || !haskey(edge_to_node, Int(ev)) || (Int(ev) in root_edge_nums)
                bad_reason = "invalid_or_root_edge_reference"
                break
            end
            if !(wv isa Real && !(wv isa Bool)) || !isfinite(Float64(wv)) || Float64(wv) < 0.0 || Float64(wv) > 1.0
                bad_reason = "invalid_like_weight_ratio"
                break
            end
            wf = Float64(wv)
            weight_sum += wf
            pl = (pend_col !== nothing && row[pend_col] isa Real) ? Float64(row[pend_col]) : 0.0
            dl = (dist_col !== nothing && row[dist_col] isa Real) ? Float64(row[dist_col]) : 0.0
            push!(cands, QueryCandidate(c_ord, Int(ev), wf, pl, dl))
        end

        if !isempty(bad_reason)
            push!(queries, QueryPlacement(q_ord, q_names, QueryCandidate[], :undecided, bad_reason, nothing))
        elseif length(cands) == 1 && cands[1].like_weight < PLACEMENT_SINGLE_MIN_LWR
            push!(queries, QueryPlacement(q_ord, q_names, cands, :undecided,
                "weight_sum_out_of_tolerance ($(round(weight_sum; digits=6)))", nothing))
        elseif length(cands) > 1 && abs(weight_sum - 1.0) > PLACEMENT_WEIGHT_SUM_TOL
            push!(queries, QueryPlacement(q_ord, q_names, cands, :undecided,
                "weight_sum_out_of_tolerance ($(round(weight_sum; digits=6)))", nothing))
        else
            best_w = maximum(c.like_weight for c in cands)
            push!(queries, QueryPlacement(q_ord, q_names, cands, :valid, "complete", best_w))
        end
    end

    JplaceDocument(tree_str, root, fields, edge_to_node, queries, warnings)
end

## Phylogenetic Diversity Metrics (exact parity with scikit-bio)
function _ensure_rooted_tree(tree::Union{PhyloNode,AbstractString})::PhyloNode
    parsed = tree isa PhyloNode ? tree : parse_newick(tree)
    rooted, _ = midpoint_root(parsed)
    rooted
end

function _collect_tree_tips!(out::Set{String}, u::PhyloNode)
    if isempty(u.children)
        push!(out, u.name)
    else
        for ch in u.children
            _collect_tree_tips!(out, ch)
        end
    end
    out
end

function _validate_counts_and_taxa(
    counts::AbstractVector{<:Real},
    taxa::AbstractVector{<:AbstractString},
    root::PhyloNode,
)::Dict{String,Float64}
    length(counts) == length(taxa) ||
        throw(ArgumentError("counts length ($(length(counts))) != taxa length ($(length(taxa)))"))
    tip_names = _collect_tree_tips!(Set{String}(), root)
    abundance = Dict{String,Float64}()
    for (c, t) in zip(counts, taxa)
        v = Float64(c)
        (isfinite(v) && v >= 0.0) ||
            throw(ArgumentError("Counts must be finite and non-negative, got $c for $t"))
        ts = String(t)
        ts in tip_names ||
            throw(ArgumentError("Taxon '$ts' is not present as a tip in the phylogenetic tree"))
        abundance[ts] = get(abundance, ts, 0.0) + v
    end
    abundance
end

"""
    clade_faith_pd(node::PhyloNode, active_tips::AbstractSet{<:AbstractString}; is_root=false) -> Float64

Sum of non-root branch lengths within `node` whose descendant tips intersect `active_tips`.
"""
function clade_faith_pd(
    node::PhyloNode,
    active_tips::AbstractSet{<:AbstractString};
    is_root::Bool = false,
)::Float64
    pd, _ = _pd_accum(node, active_tips, is_root)
    pd
end

function _pd_accum(
    node::PhyloNode,
    active_tips::AbstractSet{<:AbstractString},
    is_root::Bool,
)::Tuple{Float64,Bool}
    if isempty(node.children)
        act = node.name in active_tips
        return (act && !is_root ? max(0.0, node.branch_length) : 0.0, act)
    end
    sub_pd = 0.0
    any_act = false
    for ch in node.children
        cpd, cact = _pd_accum(ch, active_tips, false)
        sub_pd += cpd
        any_act = any_act || cact
    end
    own = (any_act && !is_root) ? max(0.0, node.branch_length) : 0.0
    (sub_pd + own, any_act)
end

"""
    faith_pd(counts, taxa, tree) -> Float64

Faith's Phylogenetic Diversity across all non-root branches connecting observed
(`count > 0`) taxa to the root of `tree` (midpoint-rooting unrooted trees first).
"""
function faith_pd(
    counts::AbstractVector{<:Real},
    taxa::AbstractVector{<:AbstractString},
    tree::Union{PhyloNode,AbstractString},
)::Float64
    root = _ensure_rooted_tree(tree)
    abund = _validate_counts_and_taxa(counts, taxa, root)
    active = Set{String}(k for (k, v) in abund if v > 0.0)
    clade_faith_pd(root, active; is_root = true)
end

function faith_pd_table(
    sample_counts::AbstractDict{<:AbstractString,<:AbstractVector{<:Real}},
    taxa::AbstractVector{<:AbstractString},
    tree::Union{PhyloNode,AbstractString},
)::OrderedDict{String,Float64}
    root = _ensure_rooted_tree(tree)
    out = OrderedDict{String,Float64}()
    for (sname, cnts) in pairs(sample_counts)
        out[String(sname)] = faith_pd(cnts, taxa, root)
    end
    out
end

"""
    unweighted_unifrac(counts_a, counts_b, taxa, tree) -> Float64

Lozupone & Knight (2005) unweighted UniFrac distance in `[0.0, 1.0]`: fraction of
union active branch length unique to either `counts_a` or `counts_b`.
"""
function unweighted_unifrac(
    counts_a::AbstractVector{<:Real},
    counts_b::AbstractVector{<:Real},
    taxa::AbstractVector{<:AbstractString},
    tree::Union{PhyloNode,AbstractString},
)::Float64
    root = _ensure_rooted_tree(tree)
    ab_a = _validate_counts_and_taxa(counts_a, taxa, root)
    ab_b = _validate_counts_and_taxa(counts_b, taxa, root)

    function walk(u::PhyloNode, is_root::Bool)::Tuple{Float64,Float64,Bool,Bool}
        if isempty(u.children)
            ia = get(ab_a, u.name, 0.0) > 0.0
            ib = get(ab_b, u.name, 0.0) > 0.0
            len = is_root ? 0.0 : max(0.0, u.branch_length)
            num = (ia != ib) ? len : 0.0
            den = (ia || ib) ? len : 0.0
            return (num, den, ia, ib)
        end
        num_sum = 0.0
        den_sum = 0.0
        ia = false
        ib = false
        for ch in u.children
            cn, cd, ca, cb = walk(ch, false)
            num_sum += cn
            den_sum += cd
            ia = ia || ca
            ib = ib || cb
        end
        if !is_root
            len = max(0.0, u.branch_length)
            ia != ib && (num_sum += len)
            (ia || ib) && (den_sum += len)
        end
        (num_sum, den_sum, ia, ib)
    end

    num, den, _, _ = walk(root, true)
    den <= 0.0 ? 0.0 : num / den
end

"""
    weighted_unifrac(counts_a, counts_b, taxa, tree; normalized=false) -> Float64

Lozupone et al. (2007) raw (`normalized=false`) or normalized (`normalized=true`)
weighted UniFrac distance: branch-length-weighted L1 distance between the two
samples' CladeCumulus cumulative relative abundance trees.
"""
function weighted_unifrac(
    counts_a::AbstractVector{<:Real},
    counts_b::AbstractVector{<:Real},
    taxa::AbstractVector{<:AbstractString},
    tree::Union{PhyloNode,AbstractString};
    normalized::Bool = false,
)::Float64
    root = _ensure_rooted_tree(tree)
    ab_a = _validate_counts_and_taxa(counts_a, taxa, root)
    ab_b = _validate_counts_and_taxa(counts_b, taxa, root)
    tot_a = sum(values(ab_a); init = 0.0)
    tot_b = sum(values(ab_b); init = 0.0)
    (tot_a <= 0.0 && tot_b <= 0.0) && return 0.0

    function walk(u::PhyloNode, depth_from_root::Float64, is_root::Bool)::Tuple{Float64,Float64,Float64,Float64}
        own_len = is_root ? 0.0 : max(0.0, u.branch_length)
        cur_depth = depth_from_root + own_len
        if isempty(u.children)
            pa = tot_a > 0.0 ? get(ab_a, u.name, 0.0) / tot_a : 0.0
            pb = tot_b > 0.0 ? get(ab_b, u.name, 0.0) / tot_b : 0.0
            num = own_len * abs(pa - pb)
            den = cur_depth * (pa + pb)
            return (num, den, pa, pb)
        end
        num_sum = 0.0
        den_sum = 0.0
        pa = 0.0
        pb = 0.0
        for ch in u.children
            cn, cd, ca, cb = walk(ch, cur_depth, false)
            num_sum += cn
            den_sum += cd
            pa += ca
            pb += cb
        end
        if !is_root
            num_sum += own_len * abs(pa - pb)
        end
        (num_sum, den_sum, pa, pb)
    end

    num, den, _, _ = walk(root, 0.0, true)
    if !normalized
        return num
    end
    den <= 0.0 ? 0.0 : num / den
end

function branch_unifrac_contributions(
    counts_a::AbstractVector{<:Real},
    counts_b::AbstractVector{<:Real},
    taxa::AbstractVector{<:AbstractString},
    tree::Union{PhyloNode,AbstractString},
)::Vector{OrderedDict{String,Any}}
    root = _ensure_rooted_tree(tree)
    ab_a = _validate_counts_and_taxa(counts_a, taxa, root)
    ab_b = _validate_counts_and_taxa(counts_b, taxa, root)
    tot_a = sum(values(ab_a); init = 0.0)
    tot_b = sum(values(ab_b); init = 0.0)

    contribs = OrderedDict{String,Any}[]
    function walk(u::PhyloNode, is_root::Bool)::Tuple{Float64,Float64}
        if isempty(u.children)
            pa = tot_a > 0.0 ? get(ab_a, u.name, 0.0) / tot_a : 0.0
            pb = tot_b > 0.0 ? get(ab_b, u.name, 0.0) / tot_b : 0.0
            if !is_root
                c = max(0.0, u.branch_length) * abs(pa - pb)
                c > 0.0 && push!(contribs, OrderedDict{String,Any}(
                    "clade_id"      => u.id,
                    "label"         => isempty(u.name) ? u.id : u.name,
                    "is_tip"        => true,
                    "branch_length" => max(0.0, u.branch_length),
                    "freq_a"        => pa,
                    "freq_b"        => pb,
                    "contribution"  => c,
                ))
            end
            return (pa, pb)
        end
        pa = 0.0
        pb = 0.0
        for ch in u.children
            ca, cb = walk(ch, false)
            pa += ca
            pb += cb
        end
        if !is_root
            c = max(0.0, u.branch_length) * abs(pa - pb)
            c > 0.0 && push!(contribs, OrderedDict{String,Any}(
                "clade_id"      => u.id,
                "label"         => isempty(u.name) ? u.id : u.name,
                "is_tip"        => false,
                "branch_length" => max(0.0, u.branch_length),
                "freq_a"        => pa,
                "freq_b"        => pb,
                "contribution"  => c,
            ))
        end
        (pa, pb)
    end
    walk(root, true)
    sort!(contribs; by = d -> -Float64(d["contribution"]))
    contribs
end

function unifrac_matrix(
    sample_matrix::AbstractMatrix{<:Real},
    taxa::AbstractVector{<:AbstractString},
    samples::AbstractVector{<:AbstractString},
    tree::Union{PhyloNode,AbstractString};
    metric::Symbol = :weighted,
    normalized::Bool = false,
)::Matrix{Float64}
    size(sample_matrix, 1) == length(taxa) ||
        throw(ArgumentError("sample_matrix rows ($(size(sample_matrix, 1))) != length(taxa) ($(length(taxa)))"))
    size(sample_matrix, 2) == length(samples) ||
        throw(ArgumentError("sample_matrix cols ($(size(sample_matrix, 2))) != length(samples) ($(length(samples)))"))
    root = _ensure_rooted_tree(tree)
    k = length(samples)
    M = zeros(Float64, k, k)
    for i in 1:(k - 1)
        ci = @view sample_matrix[:, i]
        for j in (i + 1):k
            cj = @view sample_matrix[:, j]
            d = if metric === :unweighted
                unweighted_unifrac(ci, cj, taxa, root)
            elseif metric === :weighted
                weighted_unifrac(ci, cj, taxa, root; normalized = normalized)
            else
                throw(ArgumentError("Unsupported UniFrac metric $(repr(metric))"))
            end
            M[i, j] = d
            M[j, i] = d
        end
    end
    M
end

## Dual-hierarchy CladeCumulus construction (:phylogenetic, :taxonomic, :combined)
function _detect_id_col(df::DataFrame)::String
    for cand in ("SeqName", "ASV", "OTU", "id")
        cand in names(df) && return cand
    end
    first(names(df))
end

function _detect_sequence_col(df::DataFrame)::Union{String,Nothing}
    for cand in ("Sequence", "sequence", "seq", "DNA")
        cand in names(df) && return cand
    end
    nothing
end

function _detect_rank_cols(df::DataFrame, requested::Union{AbstractVector{<:AbstractString},Nothing})::Vector{String}
    cols = Set(names(df))
    if requested !== nothing
        return String[String(r) for r in requested if String(r) in cols]
    end
    String[r for r in DEFAULT_TAXONOMIC_RANKS if r in cols]
end

function _detect_sample_cols(
    df::DataFrame,
    id_col::String,
    seq_col::Union{String,Nothing},
    rank_cols::Vector{String},
    requested::Union{AbstractVector{<:AbstractString},Nothing},
)::Vector{String}
    cols = Set(names(df))
    if requested !== nothing
        return String[String(s) for s in requested if String(s) in cols]
    end
    excluded = Set{String}([id_col; rank_cols; ["Total", "total", "Prevalence", "prevalence", "Pident", "pident"]])
    seq_col !== nothing && push!(excluded, seq_col)
    out = String[]
    for c in names(df)
        c in excluded && continue
        endswith(lowercase(c), "_boot") && continue
        startswith(lowercase(c), "bootstrap") && continue
        el = nonmissingtype(eltype(df[!, c]))
        el <: Real && !(el <: Bool) && push!(out, c)
    end
    out
end

function _clean_taxon_value(v)::Union{String,Nothing}
    (v === nothing || ismissing(v)) && return nothing
    s = strip(string(v))
    isempty(s) && return nothing
    low = lowercase(s)
    low in ("na", "unassigned", "unknown", "unclassified", "none", "null") && return nothing
    String(s)
end

function _row_lineage_and_confidence(
    row,
    ranks::Vector{String},
    all_cols::Set{String},
)::Tuple{Vector{Union{String,Nothing}},Float64}
    lin = Union{String,Nothing}[_clean_taxon_value(row[r]) for r in ranks]
    vals = Float64[]
    for (ri, r) in enumerate(ranks)
        primary_val = lin[ri]
        is_dada2_rank = endswith(lowercase(r), "_dada2")
        base_r = is_dada2_rank ? r[1:(end - 6)] : r
        dada2_col = string(base_r, "_dada2")
        has_separate_dada2 = !is_dada2_rank && (dada2_col in all_cols)

        # In merged tables (`<Rank>` from primary classifier + `<Rank>_dada2` + `<Rank>_boot`
        # from DADA2), never apply DADA2 bootstrap support to a disagreeing primary label.
        if has_separate_dada2
            dada2_val = _clean_taxon_value(row[dada2_col])
            if primary_val !== nothing && dada2_val !== nothing && primary_val != dada2_val
                push!(vals, 0.5)
                continue
            elseif primary_val !== nothing && dada2_val === nothing
                continue
            end
        end

        for cand in (string(base_r, "_boot"), string("boot_", base_r), string(r, "_boot"), string("boot_", r))
            if cand in all_cols
                v = row[cand]
                if !(v === nothing || ismissing(v)) && v isa Real
                    nv = _normalize_support(Float64(v))
                    nv !== nothing && push!(vals, nv)
                end
                break
            end
        end
    end
    (lin, isempty(vals) ? 1.0 : minimum(vals))
end

struct _GraftedQuerySpec
    tip_id :: String
    qname  :: String
    share  :: Float64
    distal :: Float64
    pendant:: Float64
    lwr    :: Float64
end

function _graft_jplace_queries(
    base_root::PhyloNode,
    jd::JplaceDocument,
    asv_reads::OrderedDict{String,Float64},
    asv_deepest_taxon::Dict{String,Union{String,Nothing}},
    asv_tax_conf::Dict{String,Float64},
    query_lwr::Dict{String,Float64},
)::PhyloNode
    existing_tips = _collect_tree_tips!(Set{String}(), base_root)
    by_edge = Dict{Int,Vector{_GraftedQuerySpec}}()

    for q in jd.queries
        q.status === :valid && !isempty(q.candidates) || continue
        total_w = sum((c.like_weight for c in q.candidates); init = 0.0)
        total_w > 0.0 || continue
        multi = length(q.candidates) > 1
        for (qname, mult) in q.names
            qname in existing_tips && continue
            base_cnt = get(asv_reads, qname, Float64(mult))
            tx = get(asv_deepest_taxon, qname, nothing)
            tconf = get(asv_tax_conf, qname, 1.0)
            for (ci, cand) in enumerate(q.candidates)
                share = cand.like_weight / total_w
                tip_id = multi ? string(qname, "@edge", cand.edge_num, "#", ci) : qname
                if multi
                    asv_reads[tip_id] = get(asv_reads, tip_id, 0.0) + base_cnt * share
                    asv_deepest_taxon[tip_id] = tx
                    asv_tax_conf[tip_id] = tconf
                elseif !haskey(asv_reads, tip_id)
                    asv_reads[tip_id] = base_cnt
                end
                query_lwr[tip_id] = cand.like_weight
                push!(get!(by_edge, cand.edge_num, _GraftedQuerySpec[]),
                    _GraftedQuerySpec(tip_id, qname, share, max(0.0, cand.distal_len), max(0.0, cand.pendant_len), cand.like_weight))
            end
        end
    end

    isempty(by_edge) && return base_root
    seq_auto = Ref(0)

    function walk(u::PhyloNode)::PhyloNode
        rebuilt_kids = PhyloNode[walk(ch) for ch in u.children]
        cur = PhyloNode(u.id, u.name, u.branch_length, u.support, u.edge_number, rebuilt_kids)
        specs = u.edge_number === nothing ? nothing : get(by_edge, u.edge_number, nothing)
        (specs === nothing || isempty(specs)) && return cur

        # Order grafts from most distal (closest to `cur`, smallest `distal`) to most proximal.
        ordered = sort(specs; by = s -> s.distal)
        prev_distal = 0.0
        total_len = max(0.0, cur.branch_length)
        sub = cur
        for sp in ordered
            d_clamped = clamp(sp.distal, prev_distal, total_len)
            seg_len = d_clamped - prev_distal
            prev_distal = d_clamped
            sub = PhyloNode(sub.id, sub.name, seg_len, sub.support, nothing, sub.children)
            qtip = PhyloNode(sp.tip_id, sp.tip_id, sp.pendant, sp.lwr, nothing, PhyloNode[])
            seq_auto[] += 1
            sub = PhyloNode(string("jplace_clade#", seq_auto[]), "", 0.0, 1.0, nothing, PhyloNode[sub, qtip])
        end
        rem_len = max(0.0, total_len - prev_distal)
        PhyloNode(sub.id, sub.name, rem_len, cur.support, cur.edge_number, sub.children)
    end

    walk(base_root)
end

function _build_independent_epistemic_case(
    label::AbstractString,
    active_ids::Set{String},
    unanchored_ids::Set{String},
    node_supports::Dict{String,Float64},
    node_lwrs::Dict{String,Float64};
    support_threshold::Float64 = 0.80,
    lwr_threshold::Float64 = 0.95,
)::Epistemic.Case
    perm_sup = max(0.25, 0.5 * support_threshold)
    perm_lwr = max(0.25, 0.5 * lwr_threshold)

    strict_support_present = Set{String}(
        id for id in active_ids if get(node_supports, id, 1.0) >= support_threshold
    )
    placement_lwr_present = Set{String}(
        id for id in active_ids if !haskey(node_lwrs, id) || node_lwrs[id] >= lwr_threshold
    )
    permissive_present = Set{String}(
        id for id in active_ids
        if get(node_supports, id, 1.0) >= perm_sup &&
           (!haskey(node_lwrs, id) || node_lwrs[id] >= perm_lwr)
    )

    worlds = Epistemic.WorldCandidate[
        Epistemic.WorldCandidate("strict_support"; present_ids = strict_support_present),
        Epistemic.WorldCandidate("placement_lwr"; present_ids = placement_lwr_present),
        Epistemic.WorldCandidate("permissive_evidence"; present_ids = permissive_present),
    ]
    Epistemic.Case(String(label), worlds; unanchored_ids = unanchored_ids, threshold = support_threshold)
end

function _emit_simple_newick(u::PhyloNode, is_root::Bool)::String
    if isempty(u.children)
        lbl = occursin(r"^[A-Za-z0-9_.\-]+$", u.name) ? u.name : "'" * replace(u.name, "'" => "''") * "'"
        return is_root ? lbl : string(lbl, ":", repr(round(u.branch_length; digits=9)))
    end
    inner = join([_emit_simple_newick(ch, false) for ch in u.children], ",")
    sup = u.support === nothing ? "" : repr(round(u.support; digits=3))
    base = string("(", inner, ")", sup)
    is_root ? base * ";" : string(base, ":", repr(round(u.branch_length; digits=9)))
end

"""
    build_clade_tree(df::DataFrame; mode=:combined, newick=nothing, jplace_json=nothing, ...) -> CladeTreeResult

Construct a dual-hierarchy or single-hierarchy `CladeTreeResult` with bottom-up
`cumulative_count`, `cumulative_frequency`, placement + bootstrap `residual_count`,
`cloud_size = log(1 + residual_count) * 10 + 5`, epistemic admissibility statuses
(`#2e7d32`, `#f9a825`, `#9e9e9e`, `#c62828`), subtree Faith's PD, and cladistic
monophyly / dispersion diagnostics.
"""
function build_clade_tree(
    df::DataFrame;
    mode::Symbol = :combined,
    newick::Union{AbstractString,Nothing} = nothing,
    jplace_json::Union{AbstractString,Nothing} = nothing,
    sample_cols::Union{AbstractVector{<:AbstractString},Nothing} = nothing,
    rank_cols::Union{AbstractVector{<:AbstractString},Nothing} = nothing,
    support_threshold::Real = 0.80,
    lwr_threshold::Real = 0.95,
    tree_method::Symbol = :auto,
    max_asvs::Int = 500,
    seed::Int = 42,
)::CladeTreeResult
    mode in (:phylogenetic, :taxonomic, :combined) ||
        throw(ArgumentError("Unsupported CladeCumulus mode $(repr(mode)); expected :phylogenetic, :taxonomic, or :combined"))

    id_col = _detect_id_col(df)
    seq_col = _detect_sequence_col(df)
    ranks = _detect_rank_cols(df, rank_cols)
    if mode === :taxonomic && isempty(ranks)
        throw(ArgumentError(
            "Taxonomic hierarchy mode requires at least one taxonomic rank column (Domain..Species) in the selected table"))
    end
    scols = _detect_sample_cols(df, id_col, seq_col, ranks, sample_cols)
    all_cols = Set(names(df))

    warnings = String[]
    tool_records = OrderedDict{String,Any}[]

    # Per-ASV read counts, taxonomic lineage, and confidence.
    asv_reads = OrderedDict{String,Float64}()
    asv_lineage = Dict{String,Vector{Union{String,Nothing}}}()
    asv_deepest_taxon = Dict{String,Union{String,Nothing}}()
    asv_tax_conf = Dict{String,Float64}()
    asv_seqs = Pair{String,String}[]

    for row in eachrow(df)
        aid = String(strip(string(row[id_col])))
        isempty(aid) && continue
        rcount = sum((ismissing(row[c]) ? 0.0 : max(0.0, Float64(row[c])) for c in scols); init = 0.0)
        asv_reads[aid] = get(asv_reads, aid, 0.0) + rcount

        lin, rconf = _row_lineage_and_confidence(row, ranks, all_cols)
        asv_lineage[aid] = lin
        deepest = nothing
        for v in lin
            v !== nothing && (deepest = v)
        end
        asv_deepest_taxon[aid] = deepest
        asv_tax_conf[aid] = rconf

        if seq_col !== nothing && !ismissing(row[seq_col])
            seq_s = strip(string(row[seq_col]))
            !isempty(seq_s) && push!(asv_seqs, aid => seq_s)
        end
    end

    # Optional strict `.jplace` query evidence: maps query ASV ID -> (max_lwr, status).
    query_lwr = Dict{String,Float64}()
    unanchored_queries = Set{String}()
    jplace_doc = if jplace_json !== nothing && !isempty(strip(jplace_json))
        jd = parse_jplace(jplace_json)
        append!(warnings, jd.warnings)
        for q in jd.queries
            for (qname, _) in q.names
                if q.status === :valid && q.max_lwr !== nothing
                    query_lwr[qname] = min(get(query_lwr, qname, 1.0), q.max_lwr)
                else
                    push!(unanchored_queries, qname)
                end
            end
        end
        jd
    else
        nothing
    end

    table_asv_reads = copy(asv_reads)

    phylo_root = nothing
    final_newick = nothing
    did_midpoint = false
    subsampled = false
    total_in_asvs = length(table_asv_reads)
    retained_asvs = length(table_asv_reads)
    retained_frac = 1.0

    if mode === :phylogenetic || mode === :combined
        if newick !== nothing && !isempty(strip(newick))
            raw_root = parse_newick(newick; warnings = warnings)
            rooted, mp = midpoint_root(raw_root)
            phylo_root = rooted
            did_midpoint = mp
            final_newick = mp ? _emit_simple_newick(rooted, true) : String(strip(newick))
            mp && push!(warnings, "Unrooted Newick phylogeny was midpoint-rooted prior to cumulative clade aggregation and diversity calculation.")
        elseif jplace_doc !== nothing
            grafted = _graft_jplace_queries(
                jplace_doc.root, jplace_doc, asv_reads, asv_deepest_taxon, asv_tax_conf, query_lwr
            )
            rooted, mp = midpoint_root(grafted)
            phylo_root = rooted
            did_midpoint = mp
            final_newick = _emit_simple_newick(rooted, true)
        elseif !isempty(asv_seqs)
            built = Phylogeny.build_amplicon_phylogeny(
                asv_seqs;
                abundances = asv_reads,
                method = tree_method,
                max_asvs = max_asvs,
                seed = seed,
            )
            append!(warnings, built.warnings)
            append!(tool_records, built.tool_records)
            subsampled = built.subsampled
            total_in_asvs = built.total_input_asvs
            retained_asvs = built.retained_asvs
            retained_frac = built.retained_read_fraction
            raw_root = parse_newick(built.newick; warnings = warnings)
            rooted, mp = midpoint_root(raw_root)
            phylo_root = rooted
            did_midpoint = mp
            final_newick = _emit_simple_newick(rooted, true)
            mp && push!(warnings, "Unrooted amplicon phylogeny was midpoint-rooted prior to cumulative clade aggregation and diversity calculation.")
        else
            throw(ArgumentError(
                "Phylogenetic mode requires either a Newick tree, a .jplace document, or a Sequence column in the ASV table"))
        end
    end

    if mode === :taxonomic
        root_node, case_obj = _build_taxonomic_clade_tree(
            asv_reads, asv_lineage, asv_tax_conf, query_lwr, unanchored_queries, ranks;
            support_threshold = Float64(support_threshold),
            lwr_threshold = Float64(lwr_threshold),
        )
        return CladeTreeResult(
            :taxonomic, root_node, case_obj, nothing, nothing, false,
            OrderedDict{String,Any}[], OrderedDict{String,Any}[],
            warnings, tool_records, false, total_in_asvs, retained_asvs, 1.0,
        )
    end

    function rescale_frequencies(u::CladeNode, denom::Float64)::CladeNode
        kids = CladeNode[rescale_frequencies(c, denom) for c in u.children]
        CladeNode(
            u.id, u.name, u.rank, u.direct_count, u.cumulative_count,
            denom > 0.0 ? u.cumulative_count / denom : 0.0,
            u.residual_count, u.cloud_size, u.branch_length, u.support, u.subtree_pd,
            u.dominant_taxon, u.taxon_purity, u.monophyletic, u.epistemic_status, u.colour, kids,
        )
    end

    raw_tree_tips = _collect_tree_tips!(Set{String}(), phylo_root::PhyloNode)
    covered_base_ids = Set{String}(
        occursin("@edge", t) ? String(first(split(t, "@edge"; limit = 2))) : t
        for t in raw_tree_tips
    )
    total_table_reads = sum(values(table_asv_reads); init = 0.0)
    matched_asvs = 0
    matched_reads = 0.0
    omitted_asvs = 0
    omitted_reads = 0.0
    for (aid, cnt) in table_asv_reads
        if aid in covered_base_ids
            matched_asvs += 1
            matched_reads += cnt
        else
            omitted_asvs += 1
            omitted_reads += cnt
        end
    end
    if matched_asvs == 0 && !isempty(table_asv_reads)
        throw(ArgumentError(
            "None of the $(length(table_asv_reads)) ASV identifiers in the selected table matched any tip on the supplied tree"))
    end
    total_in_asvs = length(table_asv_reads)
    retained_asvs = matched_asvs
    retained_frac = total_table_reads > 0.0 ? clamp(matched_reads / total_table_reads, 0.0, 1.0) : 1.0
    if omitted_asvs > 0
        subsampled = true
        push!(warnings,
            "Tree covers $matched_asvs of $total_in_asvs table ASVs ($(round(retained_frac * 100; digits=2))% of reads); " *
            "$omitted_asvs unplaced ASV(s) ($(round(omitted_reads; digits=1)) reads) are preserved under 'Unplaced ASVs' (sans_fibre).")
    end

    # Build phylogenetic or combined CladeTree anchored on `phylo_root`.
    root_node, case_obj, dispersed, discordant = _build_phylo_or_combined_tree(
        phylo_root::PhyloNode,
        mode,
        asv_reads,
        asv_deepest_taxon,
        asv_tax_conf,
        query_lwr,
        unanchored_queries;
        support_threshold = Float64(support_threshold),
        lwr_threshold = Float64(lwr_threshold),
    )

    if omitted_asvs > 0
        push!(case_obj.unanchored_ids, "unplaced:omitted")
        unplaced_node = CladeNode(
            "unplaced:omitted",
            "Unplaced ASVs ($omitted_asvs omitted)",
            "unplaced",
            omitted_reads,
            omitted_reads,
            total_table_reads > 0.0 ? omitted_reads / total_table_reads : 0.0,
            omitted_reads,
            Epistemic.cloud_size_by_residual(omitted_reads),
            0.0,
            nothing,
            0.0,
            nothing,
            nothing,
            nothing,
            :sans_fibre,
            Epistemic.epistemic_colour(:sans_fibre),
            CladeNode[],
        )
        rescaled_kids = CladeNode[rescale_frequencies(c, total_table_reads) for c in root_node.children]
        push!(rescaled_kids, unplaced_node)
        new_root_cum = root_node.cumulative_count + omitted_reads
        new_root_res = root_node.residual_count + omitted_reads
        root_node = CladeNode(
            root_node.id,
            root_node.name,
            root_node.rank,
            root_node.direct_count,
            new_root_cum,
            total_table_reads > 0.0 ? new_root_cum / total_table_reads : 0.0,
            new_root_res,
            Epistemic.cloud_size_by_residual(new_root_res),
            root_node.branch_length,
            root_node.support,
            root_node.subtree_pd,
            root_node.dominant_taxon,
            root_node.taxon_purity,
            root_node.monophyletic,
            root_node.epistemic_status,
            root_node.colour,
            rescaled_kids,
        )
    end

    CladeTreeResult(
        mode,
        root_node,
        case_obj,
        phylo_root,
        final_newick,
        did_midpoint,
        dispersed,
        discordant,
        warnings,
        tool_records,
        subsampled,
        total_in_asvs,
        retained_asvs,
        retained_frac,
    )
end

## Taxonomic hierarchy builder
mutable struct _TaxDraft
    id           :: String
    name         :: String
    rank         :: String
    direct_count :: Float64
    unresolved   :: Float64
    conf_sum     :: Float64
    conf_weight  :: Float64
    children     :: OrderedDict{String,_TaxDraft}
end

function _build_taxonomic_clade_tree(
    asv_reads::OrderedDict{String,Float64},
    asv_lineage::Dict{String,Vector{Union{String,Nothing}}},
    asv_tax_conf::Dict{String,Float64},
    query_lwr::Dict{String,Float64},
    unanchored_queries::Set{String},
    ranks::Vector{String};
    support_threshold::Float64 = 0.80,
    lwr_threshold::Float64 = 0.95,
)::Tuple{CladeNode,Epistemic.Case}
    root_draft = _TaxDraft("tax:Root", "Root", "Root", 0.0, 0.0, 0.0, 0.0, OrderedDict{String,_TaxDraft}())

    for (aid, cnt) in asv_reads
        lin = get(asv_lineage, aid, Union{String,Nothing}[])
        conf = get(asv_tax_conf, aid, 1.0)
        lwr = get(query_lwr, aid, 1.0)
        eff_conf = min(conf, lwr)
        cur = root_draft
        path_parts = String[]
        unresolved_here = false
        for (ri, rname) in enumerate(ranks)
            val = ri <= length(lin) ? lin[ri] : nothing
            if val === nothing
                unresolved_here = true
                break
            end
            push!(path_parts, string(rname, ":", val))
            nid = "tax:" * join(path_parts, "|")
            ch = get!(cur.children, nid) do
                _TaxDraft(nid, val, rname, 0.0, 0.0, 0.0, 0.0, OrderedDict{String,_TaxDraft}())
            end
            ch.conf_sum += eff_conf * max(cnt, 1.0)
            ch.conf_weight += max(cnt, 1.0)
            cur = ch
        end
        # Attach ASV leaf node under deepest resolved taxon without double-counting
        # unresolved residual on both leaf and parent.
        has_lwr = haskey(query_lwr, aid)
        low_evidence = (conf < support_threshold) || (has_lwr && lwr < lwr_threshold)
        leaf_res = if unresolved_here
            cnt * (1.0 - 0.5 * eff_conf)
        elseif low_evidence
            cnt * (1.0 - eff_conf)
        else
            0.0
        end
        leaf_id = "asv:" * aid
        leaf = _TaxDraft(leaf_id, aid, "ASV", cnt,
            leaf_res,
            conf * max(cnt, 1.0), max(cnt, 1.0), OrderedDict{String,_TaxDraft}())
        cur.children[leaf_id] = leaf
    end

    node_supports = Dict{String,Float64}("tax:Root" => 1.0)
    node_lwrs = Dict{String,Float64}()
    active_ids = Set{String}()
    unanchored = Set{String}()

    function collect_supports!(d::_TaxDraft)::Tuple{Float64,Union{Float64,Nothing}}
        cum = d.direct_count
        lwr_sum = 0.0
        lwr_w = 0.0
        if d.rank == "ASV" && haskey(query_lwr, d.name)
            w = max(d.direct_count, 1.0)
            lwr_sum += query_lwr[d.name] * w
            lwr_w += w
        end
        for ch in values(d.children)
            cc, clwr = collect_supports!(ch)
            cum += cc
            if clwr !== nothing
                w = max(cc, 1.0)
                lwr_sum += clwr * w
                lwr_w += w
            end
        end
        if cum > 0.0
            push!(active_ids, d.id)
        end
        if d.rank == "ASV" && (d.name in unanchored_queries)
            push!(unanchored, d.id)
        end
        node_supports[d.id] = d.conf_weight > 0.0 ? clamp(d.conf_sum / d.conf_weight, 0.0, 1.0) : 1.0
        avg_lwr = lwr_w > 0.0 ? clamp(lwr_sum / lwr_w, 0.0, 1.0) : nothing
        avg_lwr !== nothing && d.id != "tax:Root" && (node_lwrs[d.id] = avg_lwr)
        (cum, avg_lwr)
    end
    total_reads, _ = collect_supports!(root_draft)
    node_supports["tax:Root"] = 1.0
    total_reads > 0.0 && push!(active_ids, "tax:Root")

    case_obj = _build_independent_epistemic_case(
        "taxonomic_clade_cumulus",
        active_ids,
        unanchored,
        node_supports,
        node_lwrs;
        support_threshold = support_threshold,
        lwr_threshold = lwr_threshold,
    )

    function freeze(d::_TaxDraft)::Tuple{CladeNode,Float64,Float64}
        child_nodes = CladeNode[]
        cum = d.direct_count
        res = d.unresolved
        for ch in values(d.children)
            cn, cc, cr = freeze(ch)
            push!(child_nodes, cn)
            cum += cc
            res += cr
        end
        freq = total_reads > 0.0 ? cum / total_reads : 0.0
        st = Epistemic.epistemic_status(case_obj, d.id)
        col = Epistemic.epistemic_colour(st)
        sup = get(node_supports, d.id, 1.0)
        node = CladeNode(
            d.id, d.name, d.rank, d.direct_count, cum, freq, res,
            Epistemic.cloud_size_by_residual(res),
            0.0, sup, 0.0,
            d.rank == "ASV" ? nothing : d.name,
            d.rank == "ASV" ? nothing : 1.0,
            true,
            st, col, child_nodes,
        )
        (node, cum, res)
    end

    frozen_root, _, _ = freeze(root_draft)
    (frozen_root, case_obj)
end

## Phylogenetic & Combined dual-hierarchy builder + monophyly / dispersion detector
function _build_phylo_or_combined_tree(
    phylo_root::PhyloNode,
    mode::Symbol,
    asv_reads::OrderedDict{String,Float64},
    asv_deepest_taxon::Dict{String,Union{String,Nothing}},
    asv_tax_conf::Dict{String,Float64},
    query_lwr::Dict{String,Float64},
    unanchored_queries::Set{String};
    support_threshold::Float64 = 0.80,
    lwr_threshold::Float64 = 0.95,
)
    active_tips = Set{String}(k for (k, v) in asv_reads if v > 0.0)
    node_supports = Dict{String,Float64}()
    active_ids = Set{String}()
    unanchored = Set{String}()

    # Count total occurrences of each named taxon across all tips present in the tree.
    total_tips_per_taxon = Dict{String,Int}()
    function count_tree_taxa!(u::PhyloNode)
        if isempty(u.children)
            tx = get(asv_deepest_taxon, u.name, nothing)
            tx !== nothing && (total_tips_per_taxon[tx] = get(total_tips_per_taxon, tx, 0) + 1)
        else
            for ch in u.children
                count_tree_taxa!(ch)
            end
        end
    end
    count_tree_taxa!(phylo_root)

    node_lwrs = Dict{String,Float64}()

    function gather!(u::PhyloNode, is_root::Bool)::Float64
        if isempty(u.children)
            cnt = get(asv_reads, u.name, 0.0)
            cnt > 0.0 && push!(active_ids, u.id)
            (u.name in unanchored_queries || !haskey(asv_reads, u.name)) && push!(unanchored, u.id)
            tconf = get(asv_tax_conf, u.name, 1.0)
            node_supports[u.id] = tconf
            haskey(query_lwr, u.name) && (node_lwrs[u.id] = query_lwr[u.name])
            return cnt
        end
        cum = 0.0
        for ch in u.children
            cum += gather!(ch, false)
        end
        cum > 0.0 && push!(active_ids, u.id)
        node_supports[u.id] = is_root ? 1.0 : (u.support === nothing ? 1.0 : u.support)
        cum
    end
    total_tree_reads = gather!(phylo_root, true)

    case_obj = _build_independent_epistemic_case(
        string(mode, "_clade_cumulus"),
        active_ids,
        unanchored,
        node_supports,
        node_lwrs;
        support_threshold = support_threshold,
        lwr_threshold = lwr_threshold,
    )

    # Track whether each named taxon has at least one clade containing ALL of its tips purely.
    monophyletic_witness = Dict{String,Bool}(tx => false for tx in keys(total_tips_per_taxon))
    discordant_clades = OrderedDict{String,Any}[]

    function build_node(
        u::PhyloNode,
        is_root::Bool,
    )::Tuple{CladeNode,Float64,Float64,Dict{String,Int},Int}
        if isempty(u.children)
            cnt = get(asv_reads, u.name, 0.0)
            tx = get(asv_deepest_taxon, u.name, nothing)
            sup = min(get(node_supports, u.id, 1.0), get(node_lwrs, u.id, 1.0))
            # Residual on tip reflects placement LWR split uncertainty or unassigned taxon in combined mode.
            unassigned_penalty = (mode === :combined && tx === nothing) ? 0.5 : 0.0
            res = cnt * max(1.0 - sup, unassigned_penalty)
            freq = total_tree_reads > 0.0 ? cnt / total_tree_reads : 0.0
            st = Epistemic.epistemic_status(case_obj, u.id)
            col = Epistemic.epistemic_colour(st)
            tcounts = Dict{String,Int}()
            if tx !== nothing
                tcounts[tx] = 1
                total_tips_per_taxon[tx] == 1 && (monophyletic_witness[tx] = true)
            end
            lbl = (mode === :combined && tx !== nothing) ? "$(u.name) [$tx]" : u.name
            node = CladeNode(
                u.id,
                lbl,
                "tip",
                cnt,
                cnt,
                freq,
                res,
                Epistemic.cloud_size_by_residual(res),
                is_root ? 0.0 : max(0.0, u.branch_length),
                u.support === nothing ? sup : u.support,
                0.0,
                tx,
                tx === nothing ? nothing : 1.0,
                tx === nothing ? nothing : (total_tips_per_taxon[tx] == 1),
                st,
                col,
                CladeNode[],
            )
            return (node, cnt, res, tcounts, 1)
        end

        kids = CladeNode[]
        cum = 0.0
        child_res = 0.0
        merged_taxa = Dict{String,Int}()
        n_sub_tips = 0
        for ch in u.children
            cn, cc, cr, ct, nt = build_node(ch, false)
            push!(kids, cn)
            cum += cc
            child_res += cr
            n_sub_tips += nt
            for (k, v) in ct
                merged_taxa[k] = get(merged_taxa, k, 0) + v
            end
        end

        # Dominant taxon & cladistic concordance for this phylogenetic clade.
        dom_tx = nothing
        dom_n = 0
        for (tx, c) in merged_taxa
            if c > dom_n || (c == dom_n && (dom_tx === nothing || tx < dom_tx))
                dom_tx = tx
                dom_n = c
            end
        end
        purity = (dom_tx !== nothing && n_sub_tips > 0) ? dom_n / n_sub_tips : nothing
        is_mono = if dom_tx !== nothing && purity !== nothing
            pure_and_complete = (dom_n == n_sub_tips) && (dom_n == total_tips_per_taxon[dom_tx])
            pure_and_complete && (monophyletic_witness[dom_tx] = true)
            pure_and_complete
        else
            nothing
        end

        branch_sup = is_root ? 1.0 : (u.support === nothing ? 1.0 : u.support)
        branch_uncert = is_root ? 0.0 : cum * (1.0 - branch_sup)
        res = max(child_res, branch_uncert)
        freq = total_tree_reads > 0.0 ? cum / total_tree_reads : 0.0
        sub_pd = clade_faith_pd(u, active_tips; is_root = is_root)
        st = Epistemic.epistemic_status(case_obj, u.id)
        col = Epistemic.epistemic_colour(st)

        base_name = isempty(u.name) ? u.id : u.name
        display_name = (mode === :combined && dom_tx !== nothing && !is_root) ?
            "$base_name ($dom_tx $(round(Int, (purity::Float64) * 100))%)" : base_name

        if mode === :combined && !is_root && length(merged_taxa) > 1
            push!(discordant_clades, OrderedDict{String,Any}(
                "clade_id"        => u.id,
                "label"           => display_name,
                "support"         => u.support,
                "cumulative_reads"=> cum,
                "dominant_taxon"  => dom_tx,
                "taxon_purity"    => purity,
                "taxa_breakdown"  => OrderedDict{String,Int}(
                    k => merged_taxa[k] for k in sort!(collect(keys(merged_taxa)))
                ),
            ))
        end

        node = CladeNode(
            u.id,
            display_name,
            is_root ? "root" : "clade",
            0.0,
            cum,
            freq,
            res,
            Epistemic.cloud_size_by_residual(res),
            is_root ? 0.0 : max(0.0, u.branch_length),
            u.support,
            sub_pd,
            dom_tx,
            purity,
            is_mono,
            st,
            col,
            kids,
        )
        (node, cum, res, merged_taxa, n_sub_tips)
    end

    root_clade, _, _, _, _ = build_node(phylo_root, true)

    dispersed = OrderedDict{String,Any}[]
    if mode === :combined
        for tx in sort!(collect(keys(total_tips_per_taxon)))
            total_tips_per_taxon[tx] >= 2 || continue
            if !get(monophyletic_witness, tx, false)
                push!(dispersed, OrderedDict{String,Any}(
                    "taxon"      => tx,
                    "tip_count"  => total_tips_per_taxon[tx],
                    "monophyletic" => false,
                    "note"       => "Tips assigned to '$tx' do not form a single exclusive phylogenetic clade.",
                ))
            end
        end
    end

    (root_clade, case_obj, dispersed, discordant_clades)
end

## Non-destructive drag-and-drop clade reassignment validation
function _find_clade(node::CladeNode, target_id::AbstractString)::Union{CladeNode,Nothing}
    node.id == target_id && return node
    for ch in node.children
        found = _find_clade(ch, target_id)
        found !== nothing && return found
    end
    nothing
end

function _is_descendant(candidate_desc::AbstractString, ancestor::CladeNode)::Bool
    for ch in ancestor.children
        (ch.id == candidate_desc || _is_descendant(candidate_desc, ch)) && return true
    end
    false
end

function _reaggregate_after_move(
    root::CladeNode,
    moving::CladeNode,
    target_id::AbstractString,
    case_obj::Epistemic.Case,
    total_reads::Float64,
)::CladeNode
    # First structurally graft `moving` under `target_id` while detaching its old attachment.
    function graft(u::CladeNode)::Union{CladeNode,Nothing}
        u.id == moving.id && return nothing
        new_kids = CladeNode[]
        for ch in u.children
            rc = graft(ch)
            rc !== nothing && push!(new_kids, rc)
        end
        if u.id == target_id
            push!(new_kids, moving)
        end
        CladeNode(
            u.id, u.name, u.rank, u.direct_count, u.cumulative_count, u.cumulative_frequency,
            u.residual_count, u.cloud_size, u.branch_length, u.support, u.subtree_pd,
            u.dominant_taxon, u.taxon_purity, u.monophyletic, u.epistemic_status, u.colour, new_kids,
        )
    end
    grafted = graft(root)
    grafted === nothing && error("Cannot detach root node during drag-and-drop reassignment")

    # Count global occurrences of each leaf taxon across the new topology so monophyly
    # and purity are exact everywhere on the proposed tree.
    total_tips_per_taxon = Dict{String,Int}()
    function count_leaf_taxa!(u::CladeNode)
        if isempty(u.children)
            u.dominant_taxon !== nothing &&
                (total_tips_per_taxon[u.dominant_taxon] = get(total_tips_per_taxon, u.dominant_taxon, 0) + 1)
        else
            for ch in u.children
                count_leaf_taxa!(ch)
            end
        end
    end
    count_leaf_taxa!(grafted)

    function recompute(u::CladeNode, is_root::Bool)::Tuple{CladeNode,Dict{String,Int},Int,Bool}
        if isempty(u.children)
            freq = total_reads > 0.0 ? u.cumulative_count / total_reads : 0.0
            tmap = Dict{String,Int}()
            mono = u.monophyletic
            if u.dominant_taxon !== nothing
                tmap[u.dominant_taxon] = 1
                mono = get(total_tips_per_taxon, u.dominant_taxon, 0) == 1
            end
            active_here = u.cumulative_count > 0.0
            sub_pd = active_here && !is_root ? max(0.0, u.branch_length) : 0.0
            st = Epistemic.epistemic_status(case_obj, u.id)
            leaf_node = CladeNode(
                u.id, u.name, u.rank, u.direct_count, u.cumulative_count, freq,
                u.residual_count, Epistemic.cloud_size_by_residual(u.residual_count),
                u.branch_length, u.support, sub_pd, u.dominant_taxon, u.taxon_purity, mono,
                st, Epistemic.epistemic_colour(st), CladeNode[],
            )
            return (leaf_node, tmap, 1, active_here)
        end

        rebuilt_kids = CladeNode[]
        merged_taxa = Dict{String,Int}()
        n_sub_tips = 0
        any_active = u.direct_count > 0.0
        sub_pd = 0.0
        child_res = 0.0
        cum = u.direct_count

        for ch in u.children
            rk, ct, nt, ch_active = recompute(ch, false)
            push!(rebuilt_kids, rk)
            cum += rk.cumulative_count
            child_res += rk.residual_count
            n_sub_tips += nt
            if ch_active
                any_active = true
                sub_pd += rk.subtree_pd
            end
            for (k, v) in ct
                merged_taxa[k] = get(merged_taxa, k, 0) + v
            end
        end

        !is_root && any_active && (sub_pd += max(0.0, u.branch_length))

        dom_tx = nothing
        dom_n = 0
        for (tx, c) in merged_taxa
            if c > dom_n || (c == dom_n && (dom_tx === nothing || tx < dom_tx))
                dom_tx = tx
                dom_n = c
            end
        end
        purity = if u.rank in ("tip", "ASV")
            u.taxon_purity
        elseif dom_tx !== nothing && n_sub_tips > 0
            dom_n / n_sub_tips
        elseif isempty(merged_taxa) && u.dominant_taxon !== nothing
            1.0
        else
            nothing
        end
        mono = if dom_tx !== nothing && n_sub_tips > 0
            (dom_n == n_sub_tips) && (dom_n == get(total_tips_per_taxon, dom_tx, 0))
        else
            u.monophyletic
        end
        eff_dom = dom_tx !== nothing ? dom_tx : u.dominant_taxon
        branch_sup = is_root ? 1.0 : (u.support === nothing ? 1.0 : u.support)
        branch_uncert = is_root ? 0.0 : cum * (1.0 - branch_sup)
        res = max(child_res, branch_uncert)
        freq = total_reads > 0.0 ? cum / total_reads : 0.0
        st = Epistemic.epistemic_status(case_obj, u.id)
        node = CladeNode(
            u.id, u.name, u.rank, u.direct_count, cum, freq, res,
            Epistemic.cloud_size_by_residual(res),
            u.branch_length, u.support, sub_pd,
            eff_dom, purity, mono,
            st, Epistemic.epistemic_colour(st), rebuilt_kids,
        )
        (node, merged_taxa, n_sub_tips, any_active)
    end

    updated_root, _, _, _ = recompute(grafted, true)
    updated_root
end

"""
    validate_drag_drop(tree_result::CladeTreeResult, source_id::AbstractString, target_id::AbstractString)

Validate moving clade/tip `source_id` beneath `target_id` against structural
acyclic invariants and `Epistemic.present_in_every_admissible_world(case, target_id)`.
Never mutates `tree_result.root` or canonical upstream tables; returns a new
counterfactual `proposed_root` dict when accepted.
"""
function validate_drag_drop(
    tree_result::CladeTreeResult,
    source_id::AbstractString,
    target_id::AbstractString,
)::OrderedDict{String,Any}
    src = String(source_id)
    dst = String(target_id)
    src == tree_result.root.id && return OrderedDict{String,Any}(
        "allowed"       => false,
        "source_id"     => src,
        "target_id"     => dst,
        "target_status" => "invalid",
        "target_colour" => "#c62828",
        "reason"        => "The root clade cannot be moved.",
        "proposed_root" => nothing,
    )
    src == dst && return OrderedDict{String,Any}(
        "allowed"       => false,
        "source_id"     => src,
        "target_id"     => dst,
        "target_status" => String(Epistemic.epistemic_status(tree_result.case, dst)),
        "target_colour" => Epistemic.epistemic_colour(Epistemic.epistemic_status(tree_result.case, dst)),
        "reason"        => "A clade cannot be moved onto itself.",
        "proposed_root" => nothing,
    )

    src_node = _find_clade(tree_result.root, src)
    dst_node = _find_clade(tree_result.root, dst)
    if src_node === nothing || dst_node === nothing
        missing_which = src_node === nothing ? src : dst
        return OrderedDict{String,Any}(
            "allowed"       => false,
            "source_id"     => src,
            "target_id"     => dst,
            "target_status" => "missing",
            "target_colour" => "#c62828",
            "reason"        => "Clade '$missing_which' does not exist in the current tree.",
            "proposed_root" => nothing,
        )
    end

    if dst_node.rank in ("tip", "ASV") || isempty(dst_node.children)
        st = Epistemic.epistemic_status(tree_result.case, dst)
        return OrderedDict{String,Any}(
            "allowed"       => false,
            "source_id"     => src,
            "target_id"     => dst,
            "target_status" => String(st),
            "target_colour" => Epistemic.epistemic_colour(st),
            "reason"        => "Target '$dst' is a terminal sequence leaf ('$(dst_node.rank)'); select an internal clade target.",
            "proposed_root" => nothing,
        )
    end

    if _is_descendant(dst, src_node)
        st = Epistemic.epistemic_status(tree_result.case, dst)
        return OrderedDict{String,Any}(
            "allowed"       => false,
            "source_id"     => src,
            "target_id"     => dst,
            "target_status" => String(st),
            "target_colour" => Epistemic.epistemic_colour(st),
            "reason"        => "Cannot move clade '$src' beneath its own descendant '$dst' (cycle forbidden).",
            "proposed_root" => nothing,
        )
    end

    st = Epistemic.epistemic_status(tree_result.case, dst)
    col = Epistemic.epistemic_colour(st)
    if !Epistemic.present_in_every_admissible_world(tree_result.case, dst)
        return OrderedDict{String,Any}(
            "allowed"       => false,
            "source_id"     => src,
            "target_id"     => dst,
            "target_status" => String(st),
            "target_colour" => col,
            "reason"        => "Target clade '$dst' has epistemic status '$(String(st))' ($col); clade reassignment requires 'present_in_every' warrant across all admissible worlds.",
            "proposed_root" => nothing,
        )
    end

    proposed = _reaggregate_after_move(
        tree_result.root,
        src_node,
        dst,
        tree_result.case,
        tree_result.root.cumulative_count,
    )
    OrderedDict{String,Any}(
        "allowed"       => true,
        "source_id"     => src,
        "target_id"     => dst,
        "target_status" => String(st),
        "target_colour" => col,
        "reason"        => "Target clade '$dst' holds in every admissible world; counterfactual clade sums updated without modifying canonical run tables.",
        "proposed_root" => clade_node_to_dict(proposed),
    )
end

## Serialization & Plotly figure builder
function clade_node_to_dict(u::CladeNode)::OrderedDict{String,Any}
    OrderedDict{String,Any}(
        "id"                   => u.id,
        "name"                 => u.name,
        "rank"                 => u.rank,
        "direct_count"         => u.direct_count,
        "cumulative_count"     => u.cumulative_count,
        "cumulative_frequency" => u.cumulative_frequency,
        "residual_count"       => u.residual_count,
        "cloud_size"           => u.cloud_size,
        "branch_length"        => u.branch_length,
        "support"              => u.support,
        "subtree_pd"           => u.subtree_pd,
        "dominant_taxon"       => u.dominant_taxon,
        "taxon_purity"         => u.taxon_purity,
        "monophyletic"         => u.monophyletic,
        "epistemic_status"     => String(u.epistemic_status),
        "colour"               => u.colour,
        "children"             => OrderedDict{String,Any}[clade_node_to_dict(c) for c in u.children],
    )
end

"""
    to_plotly_figure(root::CladeNode; title="CladeCumulus Explorer") -> OrderedDict{String,Any}

Render `root` as a rectangular cladogram/phylogram scatter + edge figure in
Plotly JSON format with marker size `cloud_size = log(1 + residual_count) * 10 + 5`
and marker colour determined by `epistemic_status`.
"""
function to_plotly_figure(
    root::CladeNode;
    title::AbstractString = "CladeCumulus Explorer",
)::OrderedDict{String,Any}
    edge_x = Union{Float64,Nothing}[]
    edge_y = Union{Float64,Nothing}[]

    # Bucket nodes by epistemic status so the Plotly legend names every epistemic state cleanly.
    status_order = [
        (:present_in_every, "Present in every admissible world (#2e7d32)", "circle"),
        (:present_in_some,  "Present in some admissible worlds (#f9a825)", "diamond"),
        (:absent,           "Absent in every admissible world (#9e9e9e)",  "square-open"),
        (:sans_fibre,       "Unanchored / sans fibre (#c62828)",           "x"),
    ]
    buckets = Dict{Symbol,NamedTuple}(
        st => (
            xs = Float64[],
            ys = Float64[],
            sizes = Float64[],
            labels = String[],
            hovers = String[],
            ids = String[],
            colour = Epistemic.epistemic_colour(st),
            title = lbl,
            symbol = sym,
        )
        for (st, lbl, sym) in status_order
    )

    leaf_slot = Ref(0.0)
    use_branch_x = any(c -> c.branch_length > 0.0, root.children)

    function layout_walk(u::CladeNode, depth_x::Float64)::Float64
        x_here = use_branch_x ? depth_x + u.branch_length : depth_x
        y_here = if isempty(u.children)
            leaf_slot[] += 1.0
            leaf_slot[]
        else
            child_ys = Float64[layout_walk(ch, use_branch_x ? x_here : depth_x + 1.0) for ch in u.children]
            for (ch, cy) in zip(u.children, child_ys)
                ch_x = use_branch_x ? x_here + ch.branch_length : depth_x + 1.0
                # Rectangular L-shaped cladogram elbow: vertical segment at x_here, horizontal branch to ch_x
                append!(edge_x, [x_here, x_here, ch_x, nothing])
                append!(edge_y, [cy, cy, cy, nothing])
            end
            if length(child_ys) >= 2
                append!(edge_x, [x_here, x_here, nothing])
                append!(edge_y, [minimum(child_ys), maximum(child_ys), nothing])
            end
            0.5 * (minimum(child_ys) + maximum(child_ys))
        end

        b = buckets[u.epistemic_status]
        push!(b.xs, x_here)
        push!(b.ys, y_here)
        push!(b.sizes, u.cloud_size)
        push!(b.labels, u.name)
        push!(b.ids, u.id)
        sup_txt = u.support === nothing ? "n/a" : string(round(u.support; digits=3))
        push!(b.hovers,
            "<b>$(u.name)</b><br>" *
            "ID: $(u.id)<br>" *
            "Cumulative reads: $(round(u.cumulative_count; digits=1)) ($(round(u.cumulative_frequency * 100; digits=2))%)<br>" *
            "Residual uncertainty: $(round(u.residual_count; digits=2)) (cloud size $(round(u.cloud_size; digits=2)))<br>" *
            "Subtree Faith's PD: $(round(u.subtree_pd; digits=4))<br>" *
            "Support: $sup_txt | Epistemic: $(String(u.epistemic_status))")
        y_here
    end

    layout_walk(root, 0.0)

    traces = OrderedDict{String,Any}[
        OrderedDict{String,Any}(
            "type"      => "scatter",
            "mode"      => "lines",
            "name"      => "Clade branches",
            "x"         => edge_x,
            "y"         => edge_y,
            "hoverinfo" => "skip",
            "showlegend"=> false,
            "line"      => OrderedDict{String,Any}("color" => "#607d8b", "width" => 1.5),
        ),
    ]

    for (st, _, _) in status_order
        b = buckets[st]
        isempty(b.xs) && continue
        push!(traces, OrderedDict{String,Any}(
            "type"          => "scatter",
            "mode"          => "markers+text",
            "name"          => b.title,
            "x"             => b.xs,
            "y"             => b.ys,
            "text"          => b.labels,
            "textposition"  => "middle right",
            "hovertext"     => b.hovers,
            "hoverinfo"     => "text",
            "customdata"    => b.ids,
            "marker"        => OrderedDict{String,Any}(
                "size"   => b.sizes,
                "color"  => b.colour,
                "symbol" => b.symbol,
                "opacity"=> 0.85,
                "line"   => OrderedDict{String,Any}("color" => "#263238", "width" => 1.0),
            ),
        ))
    end

    OrderedDict{String,Any}(
        "data"   => traces,
        "layout" => OrderedDict{String,Any}(
            "title"      => OrderedDict{String,Any}("text" => String(title)),
            "hovermode"  => "closest",
            "xaxis"      => OrderedDict{String,Any}(
                "title"    => OrderedDict{String,Any}(
                    "text" => use_branch_x ? "Patristic branch distance (substitutions / site)" : "Cladistic rank depth",
                ),
                "zeroline" => false,
            ),
            "yaxis"      => OrderedDict{String,Any}(
                "visible"  => false,
                "zeroline" => false,
            ),
            "margin"     => OrderedDict{String,Any}("l" => 40, "r" => 180, "t" => 50, "b" => 50),
            "legend"     => OrderedDict{String,Any}("orientation" => "h", "y" => -0.15),
        ),
    )
end

end # module CladeCumulus
