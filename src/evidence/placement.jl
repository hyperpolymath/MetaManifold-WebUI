# SPDX-License-Identifier: MPL-2.0
module PlacementEvidence
using JSON3, SHA

const CHECKER = "raw-best-lwr-v1"
const TOLERANCE = 1e-6
finite(x) = x isa Real && !(x isa Bool) && isfinite(x)
integer(x) = finite(x) && x >= 0 && x <= typemax(Int32) && isinteger(x)
utf16less(a, b) = isless(transcode(UInt16, a), transcode(UInt16, b))

function tiphash(name)
    a, b = UInt32(0x811c9dc5), UInt32(0x01000193 ⊻ 0x5bd1e995)
    for c in transcode(UInt16, name)
        a = (a ⊻ UInt32(c)) * UInt32(0x01000193)
        b = (b ⊻ UInt32(c)) * UInt32(0x5bd1e995)
        b ⊻= b >> 15
    end
    a ⊻= a >> 13; a *= UInt32(0x85ebca6b); a ⊻= a >> 16
    b ⊻= b >> 13; b *= UInt32(0xc2b2ae35); b ⊻= b >> 16
    (a, b)
end
hexhash(h) = string(h[1]; base=16, pad=8) * string(h[2]; base=16, pad=8)

# Parse topology and edge numbers without modifying the viewer's version-1 IDs.
# The evidence boundary is deliberately stricter than the display parser.
function treeindex(text::AbstractString)
    s = collect(text); i = 1; nodes = NamedTuple[]
    peek() = i <= length(s) ? s[i] : '\0'
    function space()
        while isspace(peek()); i += 1; end
    end
    function comment()
        while peek() == '['
            while peek() != ']'
                peek() == '\0' && throw(ArgumentError("Unclosed Newick comment"))
                i += 1
            end
            i += 1; space()
        end
    end
    function label()
        space()
        if peek() in ('\'', '"')
            q = peek(); i += 1; out = IOBuffer()
            while peek() != '\0'
                c = peek(); i += 1
                if c == q
                    if peek() == q; print(out, q); i += 1
                    else; return String(take!(out)); end
                else; print(out, c); end
            end
            throw(ArgumentError("Unclosed Newick label"))
        end
        start = i
        while !(peek() in ('\0', '(', ')', ':', ',', ';', '[', '{')); i += 1; end
        strip(String(s[start:i-1]))
    end
    function subtree(depth)
        depth <= 512 || throw(ArgumentError("Evidence tree nesting exceeds 512"))
        space(); comment(); children = Int[]
        if peek() == '('
            i += 1; push!(children, subtree(depth+1)); space()
            while peek() == ','; i += 1; push!(children, subtree(depth+1)); space(); end
            peek() == ')' || throw(ArgumentError("Unbalanced Newick tree"))
            i += 1
        end
        name = label(); edge = nothing; length_seen = false
        while true
            space(); comment()
            if peek() == ':'
                length_seen && throw(ArgumentError("Repeated branch length"))
                length_seen = true; i += 1; space(); start = i
                while (isdigit(peek()) || peek() in ('+', '-', '.', 'e', 'E')); i += 1; end
                v = tryparse(Float64, String(s[start:i-1]))
                isnothing(v) || isfinite(v) || throw(ArgumentError("Invalid branch length"))
                isnothing(v) && throw(ArgumentError("Missing branch length"))
            elseif peek() == '{'
                isnothing(edge) || throw(ArgumentError("Repeated edge number"))
                i += 1; start = i
                while isdigit(peek()); i += 1; end
                edge = tryparse(Int, String(s[start:i-1]))
                !isnothing(edge) && integer(edge) && peek() == '}' || throw(ArgumentError("Invalid edge number"))
                i += 1
            else; break; end
        end
        isempty(children) && isempty(name) && throw(ArgumentError("Unnamed tip"))
        push!(nodes, (; name, edge, children)); length(nodes)
    end
    root = subtree(0); space()
    peek() == ';' || throw(ArgumentError("Missing Newick semicolon"))
    i += 1; space(); i > length(s) || throw(ArgumentError("Trailing Newick content"))
    # Match the viewer's right-to-left traversal and duplicate suffix order.
    order = Int[]; stack = [root]
    while !isempty(stack)
        v = pop!(stack); push!(order, v); append!(stack, nodes[v].children)
    end
    seen = Dict{String,Int}(); keys = fill("", length(nodes))
    for v in order
        isempty(nodes[v].children) || continue
        name = nodes[v].name; k = get(seen, name, 0)+1; seen[name] = k
        keys[v] = k == 1 ? name : "$name#$k"
    end
    tips = filter(!isempty, keys)
    length(unique(tips)) == length(tips) || throw(ArgumentError("Ambiguous duplicate tip keys"))
    all(==(1), values(seen)) || throw(ArgumentError("Duplicate tip names cannot be matched unambiguously"))
    universe = sort(tips; lt=utf16less); ref = first(universe)
    sides = Vector{Vector{String}}(undef, length(nodes))
    for v in reverse(order)
        sides[v] = isempty(nodes[v].children) ? [keys[v]] : reduce(vcat, (sides[c] for c in nodes[v].children))
    end
    edges = Dict{Int,NamedTuple}(); splits = Dict{String,Vector{String}}(); seenedges = Set{Int}()
    for (v,n) in enumerate(nodes)
        if !isnothing(n.edge)
            n.edge in seenedges && throw(ArgumentError("Duplicate edge number"))
            push!(seenedges, n.edge)
        end
        v == root && continue
        canonical = sort(ref in sides[v] ? setdiff(universe, sides[v]) : sides[v]; lt=utf16less)
        h = (UInt32(0),UInt32(0))
        for tip in canonical; x = tiphash(tip); h = (h[1] ⊻ x[1], h[2] ⊻ x[2]); end
        id = hexhash(h)
        haskey(splits,id) && splits[id] != canonical && throw(ArgumentError("Split hash collision"))
        splits[id] = canonical
        isnothing(n.edge) || (edges[n.edge] = (; split="split:$id", tips=canonical))
    end
    (; nodes, root, edges, universe, splits)
end

function readjplace(text)
    d = JSON3.read(text, Dict{String,Any})
    d isa AbstractDict || throw(ArgumentError("Expected a jplace object"))
    get(d,"tree",nothing) isa String || throw(ArgumentError("Missing tree string"))
    get(d,"fields",nothing) isa AbstractVector || throw(ArgumentError("Missing fields array"))
    all(x->x isa String,d["fields"]) || throw(ArgumentError("Field names must be strings"))
    get(d,"placements",nothing) isa AbstractVector || throw(ArgumentError("Missing placements array"))
    (; doc=d, index=treeindex(d["tree"]))
end

function aliases(q)
    q isa AbstractDict || return nothing
    haskey(q,"n") == haskey(q,"nm") && return nothing
    if haskey(q,"n")
        ns = q["n"]
        ns isa AbstractVector && !isempty(ns) && all(x->x isa String && !isempty(x),ns) || return nothing
        length(unique(ns)) == length(ns) || return nothing
        return [(; name=n, multiplicity=1) for n in ns]
    end
    ns = q["nm"]
    ns isa AbstractVector && !isempty(ns) || return nothing
    all(x->x isa AbstractVector && length(x)==2 && x[1] isa String && !isempty(x[1]) && finite(x[2]) && x[2]>0, ns) || return nothing
    length(unique(first.(ns))) == length(ns) || return nothing
    [(; name=x[1], multiplicity=x[2]) for x in ns]
end

function check(text; threshold=0.95)
    finite(threshold) && 0 < threshold <= 1 || throw(ArgumentError("Threshold must be finite and in (0,1]"))
    parsed = readjplace(text); d, ix = parsed.doc, parsed.index
    fields = d["fields"]; ie = findfirst(==("edge_num"),fields); iw = findfirst(==("like_weight_ratio"),fields)
    field_error = length(unique(fields)) != length(fields) || isnothing(ie) || isnothing(iw)
    digest = bytes2hex(sha256(text)); results = NamedTuple[]
    for (qi,q) in enumerate(d["placements"])
        names = aliases(q); rows = q isa AbstractDict ? get(q,"p",nothing) : nothing
        reason = isnothing(names) ? "Invalid or contradictory query names/multiplicities" :
                 field_error ? "Missing or duplicate edge_num/like_weight_ratio field" : ""
        candidates = NamedTuple[]
        if isempty(reason)
            if !(rows isa AbstractVector) || isempty(rows)
                reason = "No placement candidates"
            else
                used = Set{Int}()
                for (ci,row) in enumerate(rows)
                    if !(row isa AbstractVector) || length(row) != length(fields) ||
                       !integer(row[ie]) || !haskey(ix.edges,Int(row[ie])) ||
                       !finite(row[iw]) || !(0 <= row[iw] <= 1) || Int(row[ie]) in used
                        reason = "Invalid candidate weight, edge number or row width"; break
                    end
                    edge = Int(row[ie]); push!(used,edge)
                    push!(candidates,(; ordinal=ci-1, edge_num=edge, split=ix.edges[edge].split, lwr=row[iw]))
                end
                isempty(reason) && abs(sum(c.lwr for c in candidates)-1)>TOLERANCE && (reason="Candidate LWRs do not sum to 1 within tolerance")
            end
        end
        value = isempty(reason) ? maximum(c.lwr for c in candidates) : nothing
        verdict = isempty(reason) ? (value >= threshold ? "holds" : "fails") : "undecided"
        best = isnothing(value) ? Int[] : [c.ordinal for c in candidates if c.lwr == value]
        push!(results,(; key="$digest:$(qi-1)", ordinal=qi-1, aliases=something(names,NamedTuple[]), verdict,
                        reason, value, best, candidates=isempty(reason) ? candidates : NamedTuple[]))
    end
    (; version=1, checker=CHECKER, predicate="raw_best_lwr_gte", threshold, tolerance=TOLERANCE,
       assurance="computed; regression-tested", source_sha256=digest, queries=results)
end

# Compare actual rooted topology for accumulation, not merely matching split hashes.
function rootedkey(ix,v=ix.root)
    n=ix.nodes[v]
    isempty(n.children) && return ("tip", n.name)
    ("node", sort([repr(rootedkey(ix,c)) for c in n.children]))
end
function mapping(rawtext,targettext)
    raw, target = readjplace(rawtext), readjplace(targettext)
    raw.index.universe == target.index.universe && rootedkey(raw.index)==rootedkey(target.index) ||
        throw(ArgumentError("Accumulated tree has different tips or rooted topology"))
    signature(q) = let a=aliases(q)
        isnothing(a) ? nothing : sort([(x.name,x.multiplicity) for x in a])
    end
    rs = signature.(raw.doc["placements"]); ts = signature.(target.doc["placements"])
    ie = findall(==("edge_num"),target.doc["fields"])
    map(enumerate(rs)) do (i,s)
        matches = isnothing(s) ? Int[] : findall(==(s),ts)
        reason = isnothing(s) || count(==(s),rs)!=1 ? "Ambiguous raw query identity" :
                 isempty(matches) ? "Query absent from accumulated file" :
                 length(matches)!=1 ? "Ambiguous accumulated query identity" : ""
        dest = nothing
        if isempty(reason)
            j=only(matches); q=target.doc["placements"][j]; rows=get(q,"p",nothing)
            if length(ie)!=1 || !(rows isa AbstractVector) || length(rows)!=1 ||
               !(rows[1] isa AbstractVector) || length(rows[1])!=length(target.doc["fields"]) ||
               !integer(rows[1][only(ie)]) || !haskey(target.index.edges,Int(rows[1][only(ie)]))
                reason="Accumulated query has no unique valid target edge"
            else
                edge=Int(rows[1][only(ie)])
                dest=(; ordinal=j-1, edge_num=edge, split=target.index.edges[edge].split)
            end
        end
        (; raw_ordinal=i-1, target=dest, reason)
    end
end
end
