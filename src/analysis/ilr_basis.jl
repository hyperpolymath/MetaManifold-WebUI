# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# ILR bases beyond the Helmert default: phylogenetic (PhILR), sequential binary partition
# (SBP) and balance dendrogram. Issue #20.
#
# The conditions this code is held to were published before it existed
# (docs/statistics/method-conditions/ilr-bases.md). Where this file and that document
# disagree, the document is right and this file is the bug.
#
# Every basis is reduced to one object, a validated rooted binary tree over the retained
# taxa (`BalanceTree`). Balances are then computed from clade sums in one post-order pass
# per sample -- O(D) time and memory per sample -- so no dense D x (D-1) basis matrix is
# ever built. For 10 000 taxa a dense basis is ~800 MB; this needs a few hundred kB.
#
# The exact-arithmetic facts the engine relies on are machine-checked in Agda
# (proofs/agda/MetaManifold/ILR/*.agda, plan in docs/formal/verification-plan.md):
#   internal-count          a tree over D tips has D-1 internal nodes, so D-1 balances
#   contrast-sum-zero       each balance is p-centred: CLR centring does not matter
#   contrast-orthogonal,    with c = sqrt(r*s/(r+s)) the basis is orthonormal
#   contrast-norm
#   balance-scale-invariant multiplying a sample by a positive factor changes nothing, so
#                           counts and proportions give identical balances
#   kernel-needs-hypothesis non-positive part weights break injectivity: refused here
#   comb-is-helmert         the comb tree reproduces the Helmert default exactly
# The Julia tests that check this floating-point code against those facts carry the
# theorem names (test/unit/test_ilr_basis.jl).
#
# What this module does NOT do, on purpose:
#   - root, resolve or otherwise edit a tree (refuses unrooted trees and polytomies);
#   - drop or add taxa to make an SBP fit (refuses, naming the taxa);
#   - substitute any basis for another;
#   - call R. `philr`, `compositions` and `robCompositions` are not in renv.lock.
module ILRBasis

using Statistics
using SHA
using OrderedCollections

export BalanceTree, ILROutcome,
       parse_newick, phylo_balance_tree,
       parse_sbp, sbp_balance_tree, sbp_matrix,
       variation_condensed, hclust_r, dendrogram_balance_tree,
       comb_tree, part_weights, balance_weights, tree_balances, ilr_transform,
       VALID_BASES, VALID_PART_WEIGHTS, VALID_BALANCE_WEIGHTS, VALID_DENDROGRAM_METHODS,
       SBP_ATTEMPT_DANGER_THRESHOLD, DENDROGRAM_WARN_BYTES, DENDROGRAM_REFUSE_BYTES

"The three bases implemented here. `default` (Helmert) stays in Execution, unchanged."
const VALID_BASES = ["phylogenetic", "sequential_binary_partition", "balance_dendrogram"]

"`philr`'s `part.weights`, with `.` written `_`."
const VALID_PART_WEIGHTS = ["uniform", "gm_counts", "anorm", "enorm", "anorm_x_gm_counts", "enorm_x_gm_counts"]

"`philr`'s `ilr.weights`, with `.` written `_`. Phylogenetic basis only."
const VALID_BALANCE_WEIGHTS = ["uniform", "blw", "blw_sqrt", "mean_descendants"]

"`ward` is R's `ward.D2`."
const VALID_DENDROGRAM_METHODS = ["ward", "complete", "average"]

"More distinct SBP matrices than this in one project raises the DANGER flag."
const SBP_ATTEMPT_DANGER_THRESHOLD = 3

"Condensed variation matrix size above which a warning is recorded (1 GiB)."
const DENDROGRAM_WARN_BYTES = Int64(1) << 30

"Condensed variation matrix size above which the dendrogram basis is refused (2 GiB)."
const DENDROGRAM_REFUSE_BYTES = Int64(2) << 30

const CONDITIONS_DOC = "docs/statistics/method-conditions/ilr-bases.md"

_refuse(msg::AbstractString) = throw(ArgumentError("ILR basis refused: " * msg * " See " * CONDITIONS_DOC * "."))

function _name_list(names, limit::Int=10)
    v = collect(names)
    shown = join(("'" * string(x) * "'" for x in first(v, limit)), ", ")
    return length(v) > limit ? shown * ", ... ($(length(v)) in total)" : shown
end

# ==========================================================================================
# The balance tree
# ==========================================================================================

"""
    BalanceTree

A rooted, strictly bifurcating tree over `taxa`, stored as arrays with nodes numbered in
preorder (node 1 is the root, and every child has a larger number than its parent, so
iterating `N:-1:1` is a valid post-order).

- `left[k]`, `right[k]`: children of internal node `k` (0 for a tip). The left child is the
  numerator group, the right child the denominator group.
- `tip[k]`: for a tip, the index of its taxon in `taxa` (= its row in the count table);
  0 for an internal node.
- `edge_length[k]`: length of the edge above `k` (`NaN` when absent; the root's is unused).
- `node_label[k]`: label from the source (Newick label, merge id, ...), possibly empty.
- `balance_row[k]`: for an internal node, the output row of its balance; 0 for a tip.
- `balance_ids[row]`: the id of the balance in output row `row`.
"""
struct BalanceTree
    taxa::Vector{String}
    left::Vector{Int}
    right::Vector{Int}
    tip::Vector{Int}
    edge_length::Vector{Float64}
    node_label::Vector{String}
    balance_row::Vector{Int}
    balance_ids::Vector{String}

    function BalanceTree(taxa, left, right, tip, edge_length, node_label, balance_row, balance_ids)
        D = length(taxa)
        N = length(left)
        D >= 2 || throw(ArgumentError("INTERNAL: a balance tree needs at least 2 taxa, got $D"))
        N == 2D - 1 || throw(ArgumentError("INTERNAL: a binary tree over $D tips has $(2D - 1) nodes, got $N"))
        all(length(v) == N for v in (right, tip, edge_length, node_label, balance_row)) ||
            throw(ArgumentError("INTERNAL: balance tree arrays have inconsistent lengths"))
        length(balance_ids) == D - 1 || throw(ArgumentError("INTERNAL: $(D - 1) balance ids expected, got $(length(balance_ids))"))
        seen_tip = falses(D)
        seen_row = falses(D - 1)
        for k in 1:N
            if tip[k] > 0
                (left[k] == 0 && right[k] == 0) || throw(ArgumentError("INTERNAL: tip node $k has children"))
                seen_tip[tip[k]] && throw(ArgumentError("INTERNAL: taxon $(taxa[tip[k]]) appears twice as a tip"))
                seen_tip[tip[k]] = true
                balance_row[k] == 0 || throw(ArgumentError("INTERNAL: tip node $k has a balance row"))
            else
                (k < left[k] <= N && k < right[k] <= N) || throw(ArgumentError("INTERNAL: node $k is not in preorder"))
                seen_row[balance_row[k]] && throw(ArgumentError("INTERNAL: balance row $(balance_row[k]) used twice"))
                seen_row[balance_row[k]] = true
            end
        end
        all(seen_tip) || throw(ArgumentError("INTERNAL: not every taxon is a tip of the balance tree"))
        return new(taxa, left, right, tip, edge_length, node_label, balance_row, balance_ids)
    end
end

n_nodes(bt::BalanceTree) = length(bt.left)
n_balances(bt::BalanceTree) = length(bt.balance_ids)
is_tip(bt::BalanceTree, k::Int) = bt.tip[k] > 0

"Preorder rows 1..D-1 for the internal nodes of a preorder-numbered tree."
function _preorder_rows(tip::Vector{Int})
    rows = zeros(Int, length(tip))
    r = 0
    for k in eachindex(tip)
        if tip[k] == 0
            r += 1
            rows[k] = r
        end
    end
    return rows
end

"""
    comb_tree(taxa) -> BalanceTree

The comb (caterpillar) tree whose balances are the Helmert default used by Execution:
balance `i` (row `i`) contrasts taxa `1..i` (numerator) with taxon `i+1` (denominator).
Agda: `comb-is-helmert`, `comb-masses`. Used by the tests to show the engine reproduces the
default basis, not by the default path itself (which is left byte-for-byte unchanged).
"""
function comb_tree(taxa::Vector{String})
    D = length(taxa)
    D >= 2 || _refuse("ILR needs at least 2 taxa, got $D.")
    left = Int[]; right = Int[]; tip = Int[]; row = Int[]
    # Stack items: (m, parent, side). m > 0 is the group {1..m}; m < 0 is the tip -m.
    stack = Tuple{Int,Int,Int}[(D, 0, 0)]
    while !isempty(stack)
        (m, parent, side) = pop!(stack)
        push!(left, 0); push!(right, 0)
        id = length(left)
        if parent > 0
            side == 1 ? (left[parent] = id) : (right[parent] = id)
        end
        if m < 0 || m == 1
            push!(tip, m < 0 ? -m : 1); push!(row, 0)
        else
            push!(tip, 0); push!(row, m - 1)           # group {1..m} is Helmert balance m-1
            push!(stack, (-m, id, 2))                   # denominator: taxon m
            push!(stack, (m - 1, id, 1))                # numerator: taxa 1..m-1 (popped first)
        end
    end
    N = length(left)
    return BalanceTree(copy(taxa), left, right, tip, fill(NaN, N), fill("", N), row,
                       ["balance_$i" for i in 1:(D - 1)])
end

"""
    sbp_matrix(bt) -> Matrix{Int8}

The SBP of a balance tree: `D x (D-1)`, rows in `bt.taxa` order, columns in balance-row
order, entries `1` (numerator), `-1` (denominator), `0`. Dense, so O(D^2): for export and
tests, never used to compute balances.
"""
function sbp_matrix(bt::BalanceTree)
    D = length(bt.taxa)
    W = zeros(Int8, D, D - 1)
    N = n_nodes(bt)
    # Tips below each node, collected post-order.
    below = Vector{Vector{Int}}(undef, N)
    for k in N:-1:1
        if is_tip(bt, k)
            below[k] = [bt.tip[k]]
        else
            l, r = bt.left[k], bt.right[k]
            row = bt.balance_row[k]
            for t in below[l]; W[t, row] = 1; end
            for t in below[r]; W[t, row] = -1; end
            below[k] = vcat(below[l], below[r])
        end
    end
    return W
end

# ==========================================================================================
# Newick (phylogenetic basis)
# ==========================================================================================

mutable struct NewickNode
    label::String
    length::Float64
    children::Vector{NewickNode}
    has_label::Bool
    has_length::Bool
end
NewickNode() = NewickNode("", NaN, NewickNode[], false, false)

const _NEWICK_DELIMS = ('(', ')', ',', ':', ';', '[', '\'')

_newick_error(msg) = _refuse("the phylogenetic tree is not valid Newick: " * msg * ".")

function _set_label!(nd::NewickNode, label::String, at::Int)
    nd.has_label && _newick_error("a second label '$label' at character $at for a node that already has label '$(nd.label)' (labels containing spaces must be quoted)")
    nd.label = label
    nd.has_label = true
    return nd
end

"""
    parse_newick(text) -> NewickNode

Parses one Newick tree. Quoted labels (`'...'`, with `''` for a quote) and bracketed
comments are supported; labels are kept exactly as written -- underscores are not turned
into spaces and case is not folded, because tips are matched to taxon ids exactly.
Iterative, so a 10 000-taxon caterpillar does not exhaust the stack.
"""
function parse_newick(text::AbstractString)
    chars = collect(text)
    if !isempty(chars) && chars[1] == '\ufeff'
        chars = chars[2:end]
    end
    n = length(chars)
    root = NewickNode()
    cur = root
    stack = NewickNode[]
    finished = false
    i = 1
    while i <= n
        c = chars[i]
        if isspace(c)
            i += 1
        elseif c == '['
            j = findnext(==(']'), chars, i)
            j === nothing && _newick_error("unterminated comment '[' at character $i")
            i = j + 1
        elseif c == '('
            child = NewickNode()
            push!(cur.children, child)
            push!(stack, cur)
            cur = child
            i += 1
        elseif c == ','
            isempty(stack) && _newick_error("',' outside any parentheses at character $i")
            child = NewickNode()
            push!(stack[end].children, child)
            cur = child
            i += 1
        elseif c == ')'
            isempty(stack) && _newick_error("unbalanced ')' at character $i")
            cur = pop!(stack)
            i += 1
        elseif c == ':'
            cur.has_length && _newick_error("a second branch length at character $i")
            j = i + 1
            while j <= n && isspace(chars[j]); j += 1; end
            k = j
            while k <= n && !(chars[k] in _NEWICK_DELIMS) && !isspace(chars[k]); k += 1; end
            tok = String(chars[j:(k - 1)])
            v = tryparse(Float64, tok)
            (v === nothing || !isfinite(v)) && _newick_error("branch length '$tok' at character $i is not a finite number")
            cur.length = v
            cur.has_length = true
            i = k
        elseif c == ';'
            isempty(stack) || _newick_error("$(length(stack)) '(' not closed before ';'")
            rest = strip(String(chars[(i + 1):end]))
            isempty(rest) || _newick_error("text after the terminating ';' (one tree per file)")
            finished = true
            break
        elseif c == '\''
            buf = IOBuffer()
            j = i + 1
            closed = false
            while j <= n
                if chars[j] == '\''
                    if j < n && chars[j + 1] == '\''
                        write(buf, '\'')
                        j += 2
                    else
                        closed = true
                        j += 1
                        break
                    end
                else
                    write(buf, chars[j])
                    j += 1
                end
            end
            closed || _newick_error("unterminated quoted label starting at character $i")
            _set_label!(cur, String(take!(buf)), i)
            i = j
        else
            j = i
            while j <= n && !(chars[j] in _NEWICK_DELIMS) && !isspace(chars[j]); j += 1; end
            _set_label!(cur, String(chars[i:(j - 1)]), i)
            i = j
        end
    end
    finished || _newick_error("no terminating ';'")
    return root
end

"All nodes in preorder (children in Newick order). Iterative."
function _newick_preorder(root::NewickNode)
    out = NewickNode[]
    stack = NewickNode[root]
    while !isempty(stack)
        nd = pop!(stack)
        push!(out, nd)
        for c in Iterators.reverse(nd.children)
            push!(stack, c)
        end
    end
    return out
end

function _clade_description(nd::NewickNode)
    nd.has_label && !isempty(nd.label) && return "node '$(nd.label)'"
    tips = [x.label for x in _newick_preorder(nd) if isempty(x.children)]
    return "the node whose clade contains " * _name_list(tips, 5)
end

"""
    phylo_balance_tree(root, taxa) -> (BalanceTree, info)

Validates a parsed tree against the retained `taxa` (in count-table row order), prunes the
tips that are not retained exactly as `ape::keep.tip` does (collapsing unary nodes and
summing branch lengths), and returns the balance tree plus a record of what was done.

Refused, with the reason named: duplicate or empty tip labels; a single-tip tree; an
unrooted tree (basal trifurcation, checked *before* pruning, because pruning one basal
branch of an unrooted tree would silently invent a root); retained taxa missing from the
tree; and any multifurcation that survives pruning to the retained taxa.
"""
function phylo_balance_tree(root::NewickNode, taxa::Vector{String})
    D = length(taxa)
    D >= 2 || _refuse("ILR needs at least 2 taxa, got $D.")
    all_nodes = _newick_preorder(root)
    tips = [nd for nd in all_nodes if isempty(nd.children)]
    tip_labels = [nd.label for nd in tips]
    any(isempty, tip_labels) && _refuse("the phylogenetic tree has $(count(isempty, tip_labels)) tip(s) without a label; every tip must be named by a taxon id.")
    if !allunique(tip_labels)
        seen = Set{String}(); dups = String[]
        for l in tip_labels
            (l in seen && !(l in dups)) ? push!(dups, l) : push!(seen, l)
        end
        _refuse("the phylogenetic tree has duplicate tip labels: $(_name_list(dups)). Tips are matched to taxon ids exactly, so each id may appear once.")
    end
    length(tips) >= 2 || _refuse("the phylogenetic tree has a single tip.")

    # Unary nodes above the root carry no split: step down to the first real node.
    input_unary = count(nd -> length(nd.children) == 1, all_nodes)
    top = root
    while length(top.children) == 1
        top = top.children[1]
    end
    nbasal = length(top.children)
    if nbasal == 3
        _refuse("the phylogenetic tree is unrooted: its root has 3 children (a basal trifurcation, which is how FastTree, IQ-TREE and RAxML write unrooted trees). The root decides every balance, so MetaManifold does not choose one: root the tree in a phylogenetics tool (outgroup or midpoint) and record that decision there.")
    elseif nbasal > 3
        _refuse("the root of the phylogenetic tree has $nbasal children: the tree is unrooted or its root is unresolved. Supply a rooted, strictly bifurcating tree.")
    end

    tip_set = Set(tip_labels)
    missing_taxa = [t for t in taxa if !(t in tip_set)]
    isempty(missing_taxa) || _refuse("$(length(missing_taxa)) retained taxa are not tips of the phylogenetic tree: $(_name_list(missing_taxa)). Tips are matched to taxon ids exactly (no case folding, no underscore/space rewriting).")

    # Prune (ape::keep.tip): children before parents, i.e. reverse preorder.
    keep = Set(taxa)
    kept = IdDict{NewickNode,Union{Nothing,NewickNode}}()
    collapsed = 0
    for nd in Iterators.reverse(all_nodes)
        if isempty(nd.children)
            kept[nd] = nd.label in keep ? NewickNode(nd.label, nd.length, NewickNode[], true, nd.has_length) : nothing
            continue
        end
        kids = NewickNode[]
        for c in nd.children
            k = kept[c]
            k === nothing || push!(kids, k)
        end
        if isempty(kids)
            kept[nd] = nothing
        elseif length(kids) == 1
            k = kids[1]
            collapsed += 1
            kept[nd] = NewickNode(k.label, k.length + nd.length, k.children, k.has_label, k.has_length && nd.has_length)
        else
            kept[nd] = NewickNode(nd.label, nd.length, kids, nd.has_label, nd.has_length)
        end
    end
    pruned_root = kept[root]
    pruned_root === nothing && _refuse("INTERNAL: pruning removed every tip.")
    pruned_tips = [l for l in tip_labels if !(l in keep)]

    for nd in _newick_preorder(pruned_root)
        nc = length(nd.children)
        if nc > 2
            _refuse("the phylogenetic tree has a multifurcation (polytomy) with $nc retained children at $(_clade_description(nd)). Resolving it arbitrarily (as ape::multi2di does, randomly) would invent balances no data supports; supply a strictly bifurcating tree.")
        end
    end

    # Preorder numbering, left child = first Newick child = numerator (philr's convention).
    taxon_index = Dict(t => i for (i, t) in enumerate(taxa))
    left = Int[]; right = Int[]; tip = Int[]; len = Float64[]; lab = String[]
    stack = Tuple{NewickNode,Int,Int}[(pruned_root, 0, 0)]
    while !isempty(stack)
        (nd, parent, side) = pop!(stack)
        push!(left, 0); push!(right, 0)
        push!(len, nd.has_length ? nd.length : NaN)
        push!(lab, nd.label)
        id = length(left)
        if parent > 0
            side == 1 ? (left[parent] = id) : (right[parent] = id)
        end
        if isempty(nd.children)
            push!(tip, taxon_index[nd.label])
        else
            push!(tip, 0)
            push!(stack, (nd.children[2], id, 2))
            push!(stack, (nd.children[1], id, 1))
        end
    end
    rows = _preorder_rows(tip)
    internal_labels = [lab[k] for k in eachindex(tip) if tip[k] == 0]
    use_labels = all(!isempty, internal_labels) && allunique(internal_labels) &&
                 all(l -> tryparse(Float64, l) === nothing, internal_labels) &&
                 !any(l -> haskey(taxon_index, l), internal_labels)
    ids = use_labels ? internal_labels : ["n$i" for i in 1:(D - 1)]
    rule = use_labels ? "internal node labels (all unique, non-empty and non-numeric)" :
                        "n1..n$(D - 1) in preorder (internal node labels missing, repeated, numeric support values, or equal to a taxon id)"
    bt = BalanceTree(copy(taxa), left, right, tip, len, lab, rows, ids)
    info = OrderedDict{String,Any}(
        "tree_tips" => length(tips),
        "retained_taxa" => D,
        "pruned_tips_count" => length(pruned_tips),
        "pruned_tips_sample" => first(pruned_tips, 20),
        "unary_nodes_collapsed" => collapsed,
        "unary_nodes_in_input" => input_unary,
        "balance_id_rule" => rule,
        "order" => "preorder of the pruned tree, children in Newick order (philr column order)"
    )
    return bt, info
end

phylo_balance_tree(text::AbstractString, taxa::Vector{String}) = phylo_balance_tree(parse_newick(text), taxa)

# ==========================================================================================
# Sequential binary partition
# ==========================================================================================

"""
    _csv_foreach_row(f, text)

Minimal RFC 4180 reader: quoted fields, doubled quotes, CRLF, BOM, blank lines skipped.
Calls `f(row)` once per non-blank row, in order. The reader never holds more than one row:
an SBP over 10,000 taxa is 10^8 cells, and materialising them all (as the first version of
this reader did, with `collect(text)` plus one `String` per cell) costs several GB for a
matrix that is 100 MB as `Int8`. `row` is reused for the next row, so `f` copies what it keeps.
"""
function _csv_foreach_row(f, text::AbstractString)
    row = String[]
    field = IOBuffer()
    inq = false
    started = false
    first_char = true
    prev_quote = false            # the previous character closed a quote (for doubled quotes)
    emit() = (length(row) == 1 && isempty(strip(row[1]))) || f(row)
    for c in text
        if first_char
            first_char = false
            c == '\ufeff' && continue
        end
        if inq
            if c == '"'
                inq = false
                prev_quote = true
                continue
            end
            write(field, c)
        elseif c == '"'
            if prev_quote
                # `""` inside a quoted field: a literal quote, and the field stays quoted
                write(field, '"')
                inq = true
            else
                inq = true
                started = true
            end
        elseif c == ','
            push!(row, String(take!(field)))
            started = true
        elseif c == '\r'
            # part of CRLF; ignored
        elseif c == '\n'
            push!(row, String(take!(field)))
            emit()
            empty!(row)
            started = false
        else
            write(field, c)
            started = true
        end
        prev_quote = false
    end
    inq && _refuse("the SBP file has an unterminated quoted field.")
    if started
        push!(row, String(take!(field)))
        emit()
    end
    return nothing
end

"All non-blank rows of a small CSV (tests and error paths; `parse_sbp` streams instead)."
function _csv_rows(text::AbstractString)
    rows = Vector{String}[]
    _csv_foreach_row(r -> push!(rows, copy(r)), text)
    return rows
end

const _SBP_VALUE = r"^[+-]?[01](\.0+)?$"

function _sbp_value(s::AbstractString)
    # the three canonical spellings first: no regex, no Float64 parse (10^8 calls at 10,000 taxa)
    s == "0" && return Int8(0)
    s == "1" && return Int8(1)
    s == "-1" && return Int8(-1)
    occursin(_SBP_VALUE, s) || return nothing
    v = parse(Float64, s)
    return v == 1.0 ? Int8(1) : v == -1.0 ? Int8(-1) : Int8(0)
end

"""
    parse_sbp(text) -> (taxa, balance_ids, W::Matrix{Int8})

Reads an SBP CSV: first column taxon ids, every other column a balance whose header is its
id; entries `1`, `-1`, `0` (also written `+1`, `1.0`, `-1.0`). Shape and entries only --
validity is decided by `sbp_balance_tree`.
"""
function parse_sbp(text::AbstractString)
    # Pass 1: shape only (header, row count, first ragged row). Refusals come in the order
    # they always have -- too few rows, too few columns, a ragged row, then entries -- so a
    # file with several problems reports the same one whichever reader version reads it.
    # (Counters are Refs: a variable reassigned inside a closure is boxed and untyped, and
    # the entry loop below runs 10^8 times at 10,000 taxa.)
    header = String[]
    rows_seen = Ref(0)
    ragged = Ref{Union{Nothing,Tuple{Int,Int}}}(nothing)
    _csv_foreach_row(text) do row
        rows_seen[] += 1
        if rows_seen[] == 1
            append!(header, String(strip(h)) for h in row)
        elseif ragged[] === nothing && length(row) != length(header)
            ragged[] = (rows_seen[], length(row))
        end
    end
    nrows = rows_seen[]
    nrows >= 3 || _refuse("the SBP file needs a header row and at least 2 taxon rows; it has $nrows non-blank row(s).")
    ncol = length(header)
    ncol >= 2 || _refuse("the SBP header has $ncol column(s); it needs a taxon-id column and at least one balance column.")
    bad = ragged[]
    bad === nothing || _refuse("SBP row $(bad[1]) has $(bad[2]) fields; the header has $ncol.")
    ids = header[2:end]
    # Pass 2: taxa and entries, straight into the Int8 matrix.
    D = nrows - 1
    taxa = Vector{String}(undef, D)
    W = Matrix{Int8}(undef, D, ncol - 1)
    seen = Ref(0)
    _csv_foreach_row(text) do row
        seen[] += 1
        seen[] == 1 && return
        i = seen[] - 1
        taxa[i] = String(strip(row[1]))
        for j in 1:(ncol - 1)
            cell = strip(row[j + 1])
            v = _sbp_value(cell)
            v === nothing && _refuse("the SBP entry for taxon '$(taxa[i])' in balance column '$(ids[j])' is '$cell'; entries must be 1 (numerator), -1 (denominator) or 0 (not involved).")
            W[i, j] = v
        end
    end
    return taxa, ids, W
end

function _group_text(names::Vector{String}, G::Vector{Int})
    shown = join((names[g] for g in first(G, 6)), ", ")
    return length(G) > 6 ? "{" * shown * ", ... ($(length(G)) taxa)}" : "{" * shown * "}"
end

"""
    sbp_balance_tree(sbp_taxa, ids, W, taxa; removed_by_filtering=String[]) -> BalanceTree

Validates an SBP by Egozcue & Pawlowsky-Glahn's (2005) definition -- decided by
reconstructing the tree it encodes -- and returns that tree with balance rows in the SBP's
column order and ids from its header. `taxa` are the retained taxa in count-table order;
the SBP must be over exactly those (see the conditions document for why an extra taxon is
refused rather than dropped). `removed_by_filtering` lets the message say which extra taxa
were removed by prevalence/abundance filtering.
"""
function sbp_balance_tree(sbp_taxa::Vector{String}, ids::Vector{String}, W::AbstractMatrix{<:Integer},
                          taxa::Vector{String}; removed_by_filtering::Vector{String}=String[])
    D = length(sbp_taxa)
    D >= 2 || _refuse("an SBP needs at least 2 taxa, got $D.")
    size(W) == (D, length(ids)) || _refuse("INTERNAL: SBP matrix shape $(size(W)) does not match $D taxa and $(length(ids)) ids.")
    any(isempty, sbp_taxa) && _refuse("the SBP has a row with an empty taxon id.")
    allunique(sbp_taxa) || _refuse("the SBP lists a taxon more than once: $(_name_list(unique(t for t in sbp_taxa if count(==(t), sbp_taxa) > 1))).")
    length(ids) == D - 1 || _refuse("an SBP over $D taxa has exactly $(D - 1) balance columns (Egozcue & Pawlowsky-Glahn 2005); this one has $(length(ids)).")
    any(isempty, ids) && _refuse("the SBP has a balance column with an empty header; every balance needs an id.")
    allunique(ids) || _refuse("the SBP has repeated balance ids: $(_name_list(unique(x for x in ids if count(==(x), ids) > 1))).")

    sbp_set = Set(sbp_taxa)
    retained_set = Set(taxa)
    missing_taxa = [t for t in taxa if !(t in sbp_set)]
    isempty(missing_taxa) || _refuse("$(length(missing_taxa)) retained taxa are not rows of the SBP: $(_name_list(missing_taxa)). Every retained taxon must be assigned in every partition.")
    extra = [t for t in sbp_taxa if !(t in retained_set)]
    if !isempty(extra)
        filtered = [t for t in extra if t in removed_by_filtering]
        absent = [t for t in extra if !(t in removed_by_filtering)]
        parts = String[]
        isempty(filtered) || push!(parts, "$(length(filtered)) removed by prevalence/abundance filtering ($(_name_list(filtered)); lower advanced.min_prevalence / advanced.min_abundance to keep them)")
        isempty(absent) || push!(parts, "$(length(absent)) not in the count table ($(_name_list(absent)))")
        _refuse("the SBP has rows for taxa that are not in the analysis: " * join(parts, "; ") * ". Removing a taxon always removes a balance that isolates it, so a partition you wrote down would silently disappear; delete those rows and re-balance the SBP, or keep the taxa.")
    end

    # Columns must be genuine splits.
    for j in eachindex(ids)
        col = view(W, :, j)
        any(==(1), col) || _refuse("SBP column '$(ids[j])' has no +1 entry: every partition needs a numerator group.")
        any(==(-1), col) || _refuse("SBP column '$(ids[j])' has no -1 entry: every partition needs a denominator group.")
    end

    # Support set of each column -> column, rejecting repeats. Keyed by (size, hash of the
    # ascending row indices) rather than by the index vector itself: a comb-shaped SBP over
    # 10 000 taxa has supports totalling ~5e7 indices (~400 MB), while the keys are O(D).
    # A key match is only a candidate; it is confirmed exactly before it is trusted.
    support_of(j) = [i for i in 1:D if W[i, j] != 0]
    function support_key(j)
        h = zero(UInt)
        c = 0
        @inbounds for i in 1:D
            if W[i, j] != 0
                h = hash(i, h)
                c += 1
            end
        end
        return (c, h)
    end
    same_support(j, k) = all(i -> (W[i, j] != 0) == (W[i, k] != 0), 1:D)
    support = Dict{Tuple{Int,UInt},Vector{Int}}()
    for j in eachindex(ids)
        bucket = get!(() -> Int[], support, support_key(j))
        for k in bucket
            same_support(k, j) && _refuse("SBP columns '$(ids[k])' and '$(ids[j])' involve the same taxa $(_group_text(sbp_taxa, support_of(j))); each group is split exactly once.")
        end
        push!(bucket, j)
    end
    # The column whose support is exactly `G` (ascending), or 0. The key fixes |support| = |G|,
    # so support ⊇ G means support == G.
    function column_splitting(G::Vector{Int})
        h = zero(UInt)
        for i in G
            h = hash(i, h)
        end
        for k in get(support, (length(G), h), Int[])
            all(i -> W[i, k] != 0, G) && return k
        end
        return 0
    end

    # Reconstruct the tree top-down in preorder (numerator first).
    taxon_index = Dict(t => i for (i, t) in enumerate(taxa))
    used = falses(length(ids))
    unsplit = String[]
    left = Int[]; right = Int[]; tip = Int[]; lab = String[]; row = Int[]
    # (group of SBP rows, parent node, side, description of where the group came from)
    stack = Tuple{Vector{Int},Int,Int,String}[(collect(1:D), 0, 0, "all taxa")]
    while !isempty(stack)
        (G, parent, side, origin) = pop!(stack)
        push!(left, 0); push!(right, 0)
        id = length(left)
        if parent > 0
            side == 1 ? (left[parent] = id) : (right[parent] = id)
        end
        if length(G) == 1
            push!(tip, taxon_index[sbp_taxa[G[1]]]); push!(lab, sbp_taxa[G[1]]); push!(row, 0)
            continue
        end
        j = column_splitting(G)
        if j == 0
            push!(unsplit, origin == "all taxa" ?
                "no column involves every taxon: the first partition of an SBP must split all $D parts" :
                "the group $(_group_text(sbp_taxa, G)) ($origin) is never split")
            push!(tip, 0); push!(lab, ""); push!(row, 0)
            continue
        end
        used[j] = true
        push!(tip, 0); push!(lab, ids[j]); push!(row, j)
        P = [i for i in G if W[i, j] == 1]
        M = [i for i in G if W[i, j] == -1]
        push!(stack, (M, id, 2, "the denominator of '$(ids[j])'"))
        push!(stack, (P, id, 1, "the numerator of '$(ids[j])'"))
    end
    if !isempty(unsplit) || !all(used)
        problems = copy(unsplit)
        for j in eachindex(ids)
            if !used[j]
                push!(problems, "column '$(ids[j])' involves $(_group_text(sbp_taxa, support_of(j))), which is not one side of any earlier partition")
            end
        end
        _refuse("the matrix is not a sequential binary partition (Egozcue & Pawlowsky-Glahn 2005: each partition splits one group produced by an earlier partition, and every group of two or more parts is split exactly once): " * join(problems, "; ") * ".")
    end
    N = length(left)
    return BalanceTree(copy(taxa), left, right, tip, fill(NaN, N), lab, row, copy(ids))
end

# ==========================================================================================
# Balance dendrogram
# ==========================================================================================

"Condensed index of (i, j), i < j, as R's hclust.f IOFFST."
@inline _ioffst(n::Int, i::Int, j::Int) = j + (i - 1) * n - (i * (i + 1)) ÷ 2

"""
    variation_condensed(X) -> Vector{Float64}

The variation matrix `tau_ij = Var(log(x_i / x_j))` across samples (denominator `n - 1`) of
a positive taxa x samples table, condensed in R's `dist` order (upper triangle by rows).
This is `robCompositions::variation(x, method = "Pairwise")`.
"""
function variation_condensed(X::AbstractMatrix{<:Real})
    D, n = size(X)
    n >= 2 || _refuse("the balance dendrogram needs at least 2 samples to estimate a variance of log-ratios; got $n.")
    C = Matrix{Float64}(undef, n, D)
    for i in 1:D
        m = 0.0
        for s in 1:n
            C[s, i] = log(Float64(X[i, s]))
            m += C[s, i]
        end
        m /= n
        for s in 1:n
            C[s, i] -= m
        end
    end
    tau = Vector{Float64}(undef, (D * (D - 1)) ÷ 2)
    idx = 0
    for i in 1:(D - 1), j in (i + 1):D
        acc = 0.0
        @inbounds for s in 1:n
            d = C[s, i] - C[s, j]
            acc += d * d
        end
        idx += 1
        tau[idx] = acc / (n - 1)
    end
    return tau
end

"""
    hclust_r(diss, n, method) -> (merge::Matrix{Int}, height::Vector{Float64})

R's `hclust` for `method` in `ward` (R's `ward.D2`), `complete`, `average`: a line-by-line
port of Murtagh's nearest-neighbour-list algorithm in R's `src/library/stats/src/hclust.f`
(subroutines HCLUST and HCASS2), including its tie-breaking and its `INF = 1e300`. `diss` is
condensed in `dist` order and is not modified. `merge` follows R's convention: singletons
negative, clusters by the step that formed them.
"""
function hclust_r(diss_in::AbstractVector{<:Real}, n::Int, method::AbstractString)
    method in VALID_DENDROGRAM_METHODS || _refuse("balance dendrogram method must be one of $(join(VALID_DENDROGRAM_METHODS, ", ")); got '$method'.")
    n >= 2 || _refuse("clustering needs at least 2 parts; got $n.")
    length(diss_in) == (n * (n - 1)) ÷ 2 || throw(ArgumentError("INTERNAL: condensed dissimilarity has $(length(diss_in)) entries, expected $((n * (n - 1)) ÷ 2)"))
    iopt = method == "ward" ? 8 : method == "complete" ? 3 : 4
    is_ward = iopt == 8
    INF = 1.0e300
    diss = Float64.(diss_in)
    if is_ward
        diss .= diss .* diss
    end
    membr = ones(Float64, n)
    flag = trues(n)
    nn = zeros(Int, n)
    disnn = zeros(Float64, n)
    ia = zeros(Int, n)
    ib = zeros(Int, n)
    crit = zeros(Float64, n)
    im = 0; jj = 0; jm = 0
    for i in 1:(n - 1)
        dmin = INF
        for j in (i + 1):n
            ind = _ioffst(n, i, j)
            if dmin > diss[ind]
                dmin = diss[ind]
                jm = j
            end
        end
        nn[i] = jm
        disnn[i] = dmin
    end
    ncl = n
    while ncl > 1
        dmin = INF
        for i in 1:(n - 1)
            if flag[i] && disnn[i] < dmin
                dmin = disnn[i]
                im = i
                jm = nn[i]
            end
        end
        ncl -= 1
        i2 = min(im, jm)
        j2 = max(im, jm)
        ia[n - ncl] = i2
        ib[n - ncl] = j2
        if iopt == 8
            dmin = sqrt(dmin)
        end
        crit[n - ncl] = dmin
        flag[j2] = false
        dmin = INF
        for k in 1:n
            if flag[k] && k != i2
                ind1 = i2 < k ? _ioffst(n, i2, k) : _ioffst(n, k, i2)
                ind2 = j2 < k ? _ioffst(n, j2, k) : _ioffst(n, k, j2)
                d12 = diss[_ioffst(n, i2, j2)]
                if is_ward
                    diss[ind1] = (membr[i2] + membr[k]) * diss[ind1] +
                                 (membr[j2] + membr[k]) * diss[ind2] - membr[k] * d12
                    diss[ind1] = diss[ind1] / (membr[i2] + membr[j2] + membr[k])
                elseif iopt == 3
                    diss[ind1] = max(diss[ind1], diss[ind2])
                else # iopt == 4, average
                    diss[ind1] = (membr[i2] * diss[ind1] + membr[j2] * diss[ind2]) /
                                 (membr[i2] + membr[j2])
                end
                if i2 < k
                    if diss[ind1] < dmin
                        dmin = diss[ind1]
                        jj = k
                    end
                else
                    if diss[ind1] < disnn[k]
                        disnn[k] = diss[ind1]
                        nn[k] = i2
                    end
                end
            end
        end
        membr[i2] = membr[i2] + membr[j2]
        disnn[i2] = dmin
        nn[i2] = jj
        for i in 1:(n - 1)
            if flag[i] && (nn[i] == i2 || nn[i] == j2)
                dmin = INF
                for j in (i + 1):n
                    if flag[j]
                        ind = _ioffst(n, i, j)
                        if diss[ind] < dmin
                            dmin = diss[ind]
                            jj = j
                        end
                    end
                end
                nn[i] = jj
                disnn[i] = dmin
            end
        end
    end
    # HCASS2: convert to R's merge convention.
    iia = copy(ia)
    iib = copy(ib)
    for i in 1:(n - 2)
        k = min(ia[i], ib[i])
        for j in (i + 1):(n - 1)
            ia[j] == k && (iia[j] = -i)
            ib[j] == k && (iib[j] = -i)
        end
    end
    for i in 1:(n - 1)
        iia[i] = -iia[i]
        iib[i] = -iib[i]
    end
    for i in 1:(n - 1)
        if iia[i] > 0 && iib[i] < 0
            k = iia[i]; iia[i] = iib[i]; iib[i] = k
        end
        if iia[i] > 0 && iib[i] > 0
            k1 = min(iia[i], iib[i]); k2 = max(iia[i], iib[i])
            iia[i] = k1; iib[i] = k2
        end
    end
    merge = Matrix{Int}(undef, n - 1, 2)
    for i in 1:(n - 1)
        merge[i, 1] = iia[i]
        merge[i, 2] = iib[i]
    end
    return merge, crit[1:(n - 1)]
end

"""
    dendrogram_balance_tree(merge, taxa) -> BalanceTree

The balance tree of an R-convention merge matrix, as `compositions::gsi.merge2signary`
reads it: merge step `k` is balance `m<k>`, its second cluster the numerator and its first
the denominator. Balances are emitted in preorder from the root (the last merge).
"""
function dendrogram_balance_tree(merge::AbstractMatrix{<:Integer}, taxa::Vector{String})
    D = length(taxa)
    size(merge) == (D - 1, 2) || throw(ArgumentError("INTERNAL: merge matrix for $D taxa must be $(D - 1) x 2, got $(size(merge))"))
    left = Int[]; right = Int[]; tip = Int[]; lab = String[]
    # code < 0: singleton taxon -code; code > 0: the cluster formed at merge step `code`.
    stack = Tuple{Int,Int,Int}[(D - 1, 0, 0)]
    while !isempty(stack)
        (code, parent, side) = pop!(stack)
        push!(left, 0); push!(right, 0)
        id = length(left)
        if parent > 0
            side == 1 ? (left[parent] = id) : (right[parent] = id)
        end
        if code < 0
            push!(tip, -code); push!(lab, taxa[-code])
        else
            push!(tip, 0); push!(lab, "m$code")
            push!(stack, (Int(merge[code, 1]), id, 2))   # denominator: first cluster
            push!(stack, (Int(merge[code, 2]), id, 1))   # numerator: second cluster
        end
    end
    rows = _preorder_rows(tip)
    ids = Vector{String}(undef, D - 1)
    for k in eachindex(tip)
        tip[k] == 0 && (ids[rows[k]] = lab[k])
    end
    return BalanceTree(copy(taxa), left, right, tip, fill(NaN, length(left)), lab, rows, ids)
end

# ==========================================================================================
# Weights
# ==========================================================================================

"""
    part_weights(X, kind) -> Vector{Float64}

`philr`'s part weights computed on the zero-handled taxa x samples table `X`:
`gm_counts` is each taxon's geometric mean across samples, `anorm` the Aitchison norm of its
profile across samples, `enorm` the Euclidean norm of its closed profile; `*_x_gm_counts`
multiply by `gm_counts`. Weights must be finite and positive (Agda:
`kernel-needs-hypothesis` -- with a non-positive weight balances stop being injective).
"""
function part_weights(X::AbstractMatrix{<:Real}, kind::AbstractString)
    D, n = size(X)
    kind in VALID_PART_WEIGHTS || _refuse("part weights must be one of $(join(VALID_PART_WEIGHTS, ", ")); got '$kind'.")
    kind == "uniform" && return ones(Float64, D)
    gm = Vector{Float64}(undef, D)
    an = Vector{Float64}(undef, D)
    en = Vector{Float64}(undef, D)
    for i in 1:D
        row = Float64.(view(X, i, :))
        L = log.(row)
        mL = mean(L)
        gm[i] = exp(mL)
        an[i] = sqrt(sum(abs2, L .- mL))
        t = sum(row)
        en[i] = sqrt(sum(abs2, row ./ t))
    end
    p = kind == "gm_counts" ? gm :
        kind == "anorm" ? an :
        kind == "enorm" ? en :
        kind == "anorm_x_gm_counts" ? gm .* an :
        gm .* en
    for i in 1:D
        (isfinite(p[i]) && p[i] > 0) || _refuse("part weight '$kind' is $(p[i]) for taxon $i; part weights must be finite and positive (with one sample, or a taxon that is constant across samples, 'anorm' is 0).")
    end
    return p
end

"""
    balance_weights(bt, kind) -> (weights by balance row, info)

`philr`'s `ilr.weights`. Needs branch lengths on every non-root edge. As in `philr`,
zero-length tip edges are first replaced by the smallest non-zero edge length of the tree.
"""
function balance_weights(bt::BalanceTree, kind::AbstractString)
    nb = n_balances(bt)
    kind in VALID_BALANCE_WEIGHTS || _refuse("balance weights must be one of $(join(VALID_BALANCE_WEIGHTS, ", ")); got '$kind'.")
    info = OrderedDict{String,Any}("balance_weights" => kind)
    kind == "uniform" && return ones(Float64, nb), info
    N = n_nodes(bt)
    len = copy(bt.edge_length)
    for k in 2:N
        isnan(len[k]) && _refuse("balance weights '$kind' need a branch length on every edge; $(is_tip(bt, k) ? "tip '$(bt.taxa[bt.tip[k]])'" : "an internal node") has none.")
        len[k] < 0 && _refuse("balance weights '$kind' need non-negative branch lengths; $(is_tip(bt, k) ? "tip '$(bt.taxa[bt.tip[k]])'" : "an internal node") has length $(len[k]).")
    end
    positive = [len[k] for k in 2:N if len[k] > 0]
    isempty(positive) && _refuse("balance weights '$kind' need at least one non-zero branch length.")
    min_nonzero = minimum(positive)
    replaced = 0
    for k in 2:N
        if is_tip(bt, k) && len[k] == 0
            len[k] = min_nonzero
            replaced += 1
        end
    end
    w = zeros(Float64, nb)
    if kind == "blw" || kind == "blw_sqrt"
        for k in 1:N
            is_tip(bt, k) && continue
            w[bt.balance_row[k]] = len[bt.left[k]] + len[bt.right[k]]
        end
        kind == "blw_sqrt" && (w .= sqrt.(w))
    else # mean_descendants
        ntips = zeros(Int, N)
        sumd = zeros(Float64, N)   # sum over descendant tips of the path length from the node
        for k in N:-1:1
            if is_tip(bt, k)
                ntips[k] = 1
            else
                l, r = bt.left[k], bt.right[k]
                ntips[k] = ntips[l] + ntips[r]
                sumd[k] = sumd[l] + ntips[l] * len[l] + sumd[r] + ntips[r] * len[r]
            end
        end
        for k in 1:N
            is_tip(bt, k) && continue
            l, r = bt.left[k], bt.right[k]
            w[bt.balance_row[k]] = (len[l] + sumd[l] / ntips[l]) + (len[r] + sumd[r] / ntips[r])
        end
    end
    for row in 1:nb
        w[row] > 0 || _refuse("balance weight '$kind' is $(w[row]) for balance '$(bt.balance_ids[row])' (both child edges have length 0), which would erase that balance.")
    end
    info["zero_length_tip_edges_replaced"] = replaced
    info["min_nonzero_edge_length"] = min_nonzero
    info["isometric"] = false
    return w, info
end

# ==========================================================================================
# Balances
# ==========================================================================================

"""
    tree_balances(bt, X, p, bw) -> Matrix{Float64}

Balances `(D-1) x n` of the positive taxa x samples table `X` (rows of `X` indexed by
`bt.tip`), part weights `p`, balance weights `bw` (by balance row):

    b_n = bw_n * sqrt(r s / (r + s)) * (mean_p(log(x/p)) over numerator - over denominator)

computed from clade sums of `p * log(x/p)` and `p` in one post-order pass per sample.
"""
function tree_balances(bt::BalanceTree, X::AbstractMatrix{<:Real}, p::AbstractVector{<:Real},
                       bw::AbstractVector{<:Real})
    D, n = size(X)
    D == length(bt.taxa) || throw(ArgumentError("INTERNAL: table has $D taxa, balance tree $(length(bt.taxa))"))
    N = n_nodes(bt)
    nb = n_balances(bt)
    mass = zeros(Float64, N)
    for k in N:-1:1
        t = bt.tip[k]
        mass[k] = t > 0 ? Float64(p[t]) : mass[bt.left[k]] + mass[bt.right[k]]
    end
    coef = zeros(Float64, N)
    for k in 1:N
        if bt.tip[k] == 0
            r = mass[bt.left[k]]
            s = mass[bt.right[k]]
            coef[k] = sqrt(r * s / (r + s)) * Float64(bw[bt.balance_row[k]])
        end
    end
    logp = log.(Float64.(p))
    out = Matrix{Float64}(undef, nb, n)
    spy = zeros(Float64, N)
    @inbounds for j in 1:n
        for k in N:-1:1
            t = bt.tip[k]
            if t > 0
                spy[k] = p[t] * (log(Float64(X[t, j])) - logp[t])
            else
                l = bt.left[k]
                r = bt.right[k]
                spy[k] = spy[l] + spy[r]
                out[bt.balance_row[k], j] = coef[k] * (spy[l] / mass[l] - spy[r] / mass[r])
            end
        end
    end
    return out
end

# ==========================================================================================
# Orchestration
# ==========================================================================================

"""
    ILROutcome

- `balances`: `(D-1) x n`, rows in `balance_ids` order.
- `checks`: goes to `diagnostics.checks["ilr"]`.
- `provenance`: goes to the manifest's provenance under `"ilr"`.
- `warnings`: recorded, not fatal.
- `dangers`: reasons the run must carry a DANGER banner (the SBP p-hacking guard).
"""
struct ILROutcome
    balances::Matrix{Float64}
    balance_ids::Vector{String}
    checks::OrderedDict{String,Any}
    provenance::OrderedDict{String,Any}
    warnings::Vector{String}
    dangers::Vector{String}
end

function _read_source(path, what::AbstractString)
    path === nothing && _refuse("the $what is required for this basis and was not given.")
    p = String(path)
    isempty(strip(p)) && _refuse("the $what is required for this basis and is empty.")
    isfile(p) || _refuse("the $what '$p' does not exist or is not a file (relative paths resolve against the working directory, $(pwd())).")
    return read(p)
end

const _SHA256_HEX = r"^[0-9a-f]{64}$"

function _balance_records(bt::BalanceTree, p::AbstractVector{<:Real}, bw::AbstractVector{<:Real})
    N = n_nodes(bt)
    mass = zeros(Float64, N)
    for k in N:-1:1
        t = bt.tip[k]
        mass[k] = t > 0 ? Float64(p[t]) : mass[bt.left[k]] + mass[bt.right[k]]
    end
    name(c) = is_tip(bt, c) ? (bt.taxa[bt.tip[c]], "taxon") : (bt.balance_ids[bt.balance_row[c]], "balance")
    recs = Vector{OrderedDict{String,Any}}(undef, n_balances(bt))
    for k in 1:N
        is_tip(bt, k) && continue
        l, r = bt.left[k], bt.right[k]
        (nl, kl) = name(l)
        (nr, kr) = name(r)
        rr, ss = mass[l], mass[r]
        row = bt.balance_row[k]
        recs[row] = OrderedDict{String,Any}(
            "id" => bt.balance_ids[row],
            "numerator" => nl, "numerator_kind" => kl,
            "denominator" => nr, "denominator_kind" => kr,
            "r" => rr, "s" => ss,
            "coefficient" => sqrt(rr * ss / (rr + ss)),
            "balance_weight" => Float64(bw[row])
        )
    end
    return recs
end

"""
    ilr_transform(X, taxa; basis, tree_path, sbp_path, dendrogram_method, part_weights_kind,
                  balance_weights_kind, sbp_history, removed_by_filtering) -> ILROutcome

Computes the balances of the zero-handled, filtered, strictly positive taxa x samples table
`X` (rows named by `taxa`) in one of the three bases of `VALID_BASES`. Refuses -- never
substitutes -- when a condition of the conditions document fails.
"""
function ilr_transform(X::AbstractMatrix{<:Real}, taxa::Vector{String};
                       basis::AbstractString,
                       tree_path::Union{AbstractString,Nothing}=nothing,
                       sbp_path::Union{AbstractString,Nothing}=nothing,
                       dendrogram_method::Union{AbstractString,Nothing}=nothing,
                       part_weights_kind::AbstractString="uniform",
                       balance_weights_kind::AbstractString="uniform",
                       sbp_history::Vector{String}=String[],
                       removed_by_filtering::Vector{String}=String[])
    D, n = size(X)
    basis in VALID_BASES || _refuse("basis '$basis' is not one of $(join(VALID_BASES, ", ")) (the Helmert 'default' basis is computed by Execution).")
    D == length(taxa) || throw(ArgumentError("INTERNAL: $(length(taxa)) taxon ids for a table with $D rows"))
    D >= 2 || _refuse("ILR needs at least 2 taxa; got $D.")
    n >= 1 || _refuse("ILR needs at least 1 sample; got $n.")
    allunique(taxa) || _refuse("taxon ids must be unique.")
    for j in 1:n, i in 1:D
        v = X[i, j]
        (isfinite(v) && v > 0) || _refuse("ILR needs a strictly positive, finite table after zero handling; taxon '$(taxa[i])' has $v in sample column $j. Zero handling (advanced.zero_policy, issue #21) must run first.")
    end
    part_weights_kind in VALID_PART_WEIGHTS || _refuse("advanced.ilr_part_weights must be one of $(join(VALID_PART_WEIGHTS, ", ")); got '$part_weights_kind'.")
    balance_weights_kind in VALID_BALANCE_WEIGHTS || _refuse("advanced.ilr_balance_weights must be one of $(join(VALID_BALANCE_WEIGHTS, ", ")); got '$balance_weights_kind'.")
    (balance_weights_kind != "uniform" && basis != "phylogenetic") &&
        _refuse("advanced.ilr_balance_weights = '$balance_weights_kind' needs branch lengths, which only the phylogenetic basis has.")

    warnings = String[]
    dangers = String[]
    basis_checks = OrderedDict{String,Any}()
    source_sha = nothing
    source_path = nothing
    sbp_attempts = nothing
    method = nothing
    rule = ""

    if basis == "phylogenetic"
        bytes = _read_source(tree_path, "phylogenetic tree (advanced.ilr_phylo_tree_path)")
        source_sha = bytes2hex(sha256(bytes))
        source_path = String(tree_path)
        bt, info = phylo_balance_tree(String(copy(bytes)), taxa)
        rule = info["balance_id_rule"]
        merge!(basis_checks, info)
        if info["pruned_tips_count"] > 0
            push!(warnings, "Phylogenetic ILR: $(info["pruned_tips_count"]) tree tips that are not retained taxa were pruned (ape::keep.tip semantics) before building the basis.")
        end
    elseif basis == "sequential_binary_partition"
        bytes = _read_source(sbp_path, "SBP matrix (advanced.ilr_sbp_matrix_path)")
        source_sha = bytes2hex(sha256(bytes))
        source_path = String(sbp_path)
        (sbp_taxa, ids, W) = parse_sbp(String(copy(bytes)))
        bt = sbp_balance_tree(sbp_taxa, ids, W, taxa; removed_by_filtering=removed_by_filtering)
        rule = "SBP column headers, in SBP column order"
        history = String[]
        for h in sbp_history
            hl = lowercase(strip(h))
            occursin(_SHA256_HEX, hl) || _refuse("advanced.ilr_sbp_history entries must be SHA-256 hex digests (64 hex characters); got '$h'.")
            push!(history, hl)
        end
        sbp_attempts = length(unique(vcat(history, [source_sha])))
        basis_checks["sbp_attempts"] = sbp_attempts
        basis_checks["sbp_attempt_threshold"] = SBP_ATTEMPT_DANGER_THRESHOLD
        basis_checks["sbp_history"] = unique(history)
        if sbp_attempts > SBP_ATTEMPT_DANGER_THRESHOLD
            push!(dangers, "SBP p-hacking guard: $sbp_attempts distinct SBP matrices have been tried in this project (more than $SBP_ATTEMPT_DANGER_THRESHOLD). Trying partitions until one 'works' inflates false discoveries that BH cannot correct; pre-register the SBP and report every partition tried.")
        end
    else # balance_dendrogram
        method = dendrogram_method === nothing ? "" : String(dendrogram_method)
        method in VALID_DENDROGRAM_METHODS || _refuse("advanced.ilr_balance_dendrogram_method must be one of $(join(VALID_DENDROGRAM_METHODS, ", ")); got '$(something(dendrogram_method, "nothing"))'.")
        need = Int64(8) * ((Int64(D) * (D - 1)) ÷ 2)
        need > DENDROGRAM_REFUSE_BYTES && _refuse("the balance dendrogram for $D taxa needs a $(round(need / 2^30, digits=2)) GiB variation matrix, above the $(DENDROGRAM_REFUSE_BYTES ÷ 2^30) GiB limit. Filter taxa or use a phylogenetic or SBP basis.")
        need > DENDROGRAM_WARN_BYTES && push!(warnings, "Balance dendrogram: the variation matrix for $D taxa takes $(round(need / 2^30, digits=2)) GiB.")
        tau = variation_condensed(X)
        all(isfinite, tau) || _refuse("the variation matrix has non-finite entries.")
        merge_m, height = hclust_r(tau, D, method)
        bt = dendrogram_balance_tree(merge_m, taxa)
        rule = "m<k> = the k-th merge (rows of the merge matrix R's hclust() returns), emitted in preorder from the root"
        basis_checks["method"] = method
        basis_checks["r_equivalent"] = method == "ward" ? "hclust(as.dist(variation(x, method = \"Pairwise\")), \"ward.D2\")" :
                                       "hclust(as.dist(variation(x, method = \"Pairwise\")), \"$method\")"
        basis_checks["dissimilarity"] = "variation matrix Var(log(x_i/x_j)), sample variance (n - 1)"
        basis_checks["variation_matrix_bytes"] = need
        basis_checks["merge"] = [[merge_m[k, 1], merge_m[k, 2]] for k in 1:(D - 1)]
        basis_checks["height"] = height
        basis_checks["data_derived"] = "the basis is chosen from the same table that is then tested; it uses no sample metadata, so it cannot see group labels, but it is not independent of the data"
    end

    p = part_weights(X, part_weights_kind)
    bw, bw_info = balance_weights(bt, balance_weights_kind)
    if get(bw_info, "zero_length_tip_edges_replaced", 0) > 0
        push!(warnings, "Phylogenetic ILR balance weights: $(bw_info["zero_length_tip_edges_replaced"]) zero-length tip edge(s) replaced by the smallest non-zero edge length $(bw_info["min_nonzero_edge_length"]), as philr does.")
    end
    B = tree_balances(bt, X, p, bw)
    all(isfinite, B) || _refuse("INTERNAL: non-finite balances from a positive table; please report this.")

    data_derived_weights = part_weights_kind != "uniform"
    checks = OrderedDict{String,Any}(
        "basis" => basis,
        "definition" => "b_n = sqrt(r*s/(r+s)) * (mean_p(log(x/p)) over the numerator group - over the denominator group); r, s = part-weight masses; see $CONDITIONS_DOC",
        "taxa_in" => D,
        "taxa_order" => copy(taxa),
        "n_balances" => D - 1,
        "balance_ids" => copy(bt.balance_ids),
        "balance_id_rule" => rule,
        "part_weights" => part_weights_kind,
        "part_weight_values" => data_derived_weights ? p : nothing,
        "balance_weights" => balance_weights_kind,
        "isometric" => balance_weights_kind == "uniform",
        "isometric_note" => balance_weights_kind == "uniform" ?
            (data_derived_weights ? "orthonormal in the p-weighted Aitchison geometry (weighted ILR, Silverman et al. 2017)" : "orthonormal ILR (Egozcue et al. 2003)") :
            "balance weights rescale each balance: effect sizes change, per-balance test statistics do not, and the coordinates are not isometric",
        "uses_data_twice" => data_derived_weights || basis == "balance_dendrogram",
        "source_path" => source_path,
        "source_sha256" => source_sha,
        "basis_details" => basis_checks,
        "balance_weight_details" => bw_info,
        "balances" => _balance_records(bt, p, bw),
        "multiple_testing" => "one test per balance; Benjamini-Hochberg across balances is mandatory"
    )
    provenance = OrderedDict{String,Any}(
        "basis" => basis,
        "source_path" => source_path,
        "source_sha256" => source_sha,
        "tree_sha256" => basis == "phylogenetic" ? source_sha : nothing,
        "sbp_sha256" => basis == "sequential_binary_partition" ? source_sha : nothing,
        "dendrogram_method" => method,
        "part_weights" => part_weights_kind,
        "balance_weights" => balance_weights_kind,
        "sbp_attempts" => sbp_attempts,
        "pruned_tips_count" => basis == "phylogenetic" ? basis_checks["pruned_tips_count"] : nothing,
        "balance_id_rule" => rule,
        "engine" => "MetaManifold.ILRBasis (clade-sum post-order, no dense basis)",
        "conditions" => CONDITIONS_DOC
    )
    return ILROutcome(B, copy(bt.balance_ids), checks, provenance, warnings, dangers)
end

end # module ILRBasis
