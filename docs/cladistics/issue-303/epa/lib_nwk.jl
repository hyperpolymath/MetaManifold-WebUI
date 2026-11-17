# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Experiment E8 (issue 303): evidence verdicts on placements made by the application's own
# placement step (RAxML EPA).  See ../README.md, section 8.
# Minimal Newick + jplace reading; standard library only. Data is read as data only.
# Graph = Vector{Dict{Int,Float64}} adjacency; names[i] = leaf name or "".
mutable struct NG; names::Vector{String}; adj::Vector{Dict{Int,Float64}}; lab::Vector{Dict{Int,Int}}; end
# lab[u][v] = jplace edge number of edge u-v (only filled by parse with {n})
function parse_nwk(s::AbstractString)
    names = String[]; adj = Dict{Int,Float64}[]; lab = Dict{Int,Int}[]
    newnode!(n) = (push!(names, n); push!(adj, Dict{Int,Float64}()); push!(lab, Dict{Int,Int}()); length(names))
    s = strip(s); pos = 1; n = lastindex(s)
    # returns (node, branchlength, edgenum)
    function rd()
        if s[pos] == '('
            pos += 1; kids = Tuple{Int,Float64,Int}[]
            while true
                push!(kids, rd()); c = s[pos]; pos += 1
                c == ',' && continue; c == ')' && break; error("bad newick at $pos")
            end
            lbl = ""
            while s[pos] ∉ (':', ',', ')', ';', '{'); lbl *= s[pos]; pos += 1; end
            u = newnode!("")
            for (k, l, e) in kids; adj[u][k] = l; adj[k][u] = l; e >= 0 && (lab[u][k] = e; lab[k][u] = e); end
        else
            st = pos; while s[pos] ∉ (':', ',', ')', ';', '{'); pos += 1; end
            u = newnode!(String(s[st:pos-1]))
        end
        bl = 0.0; en = -1
        if s[pos] == ':'; pos += 1; st = pos; while s[pos] ∉ (',', ')', ';', '{'); pos += 1; end; bl = parse(Float64, s[st:pos-1]); end
        if s[pos] == '{'; pos += 1; st = pos; while s[pos] != '}'; pos += 1; end; en = parse(Int, s[st:pos-1]); pos += 1; end
        (u, bl, en)
    end
    (root, _, _) = rd()
    g = NG(names, adj, lab)
    # suppress a degree-2 root
    if length(adj[root]) == 2 && names[root] == ""
        (a, la), (b, lb) = collect(adj[root])
        delete!(adj[a], root); delete!(adj[b], root); delete!(adj[root], a); delete!(adj[root], b)
        adj[a][b] = la + lb; adj[b][a] = la + lb
        if haskey(lab[root], a) && haskey(lab[root], b); lab[a][b] = lab[root][a]; lab[b][a] = lab[root][a]; end
    end
    g
end
isleaf(g::NG, u) = g.names[u] != ""
alive(g::NG, u) = !isempty(g.adj[u])
# Root at leaf `rl`; returns parent, children, below (BitSet of leaf *indices in leafidx*), order (preorder)
function root_at(g::NG, rl::Int, leafidx::Dict{String,Int})
    n = length(g.names); parent = zeros(Int, n); order = Int[]; st = [rl]; seen = falses(n); seen[rl] = true
    kids = [Int[] for _ in 1:n]
    while !isempty(st)
        u = pop!(st); push!(order, u)
        for v in keys(g.adj[u]); if !seen[v]; seen[v] = true; parent[v] = u; push!(kids[u], v); push!(st, v); end; end
    end
    below = Vector{BitSet}(undef, n)
    for u in reverse(order)
        if isleaf(g, u); below[u] = BitSet([leafidx[g.names[u]]])
        else b = BitSet(); for c in kids[u]; union!(b, below[c]); end; below[u] = b; end
    end
    parent, kids, below, order
end
function parse_jplace(path)
    txt = read(path, String)
    m = match(r"\"tree\"\s*:\s*\"([^\"]*)\"", txt); tree = m.captures[1]
    fm = match(r"\"fields\"\s*:\s*\[([^\]]*)\]", txt)
    fields = [strip(replace(x, "\"" => "")) for x in split(fm.captures[1], ",")]
    pm = match(r"\"p\"\s*:\s*\[(.*?)\]\s*,\s*\"n\""s, txt)
    rows = Vector{Vector{Float64}}()
    for rm in eachmatch(r"\[([^\[\]]+)\]", pm.captures[1] * "]")
        push!(rows, parse.(Float64, split(rm.captures[1], ",")))
    end
    tree, fields, rows
end
