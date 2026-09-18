# SPDX-License-Identifier: AGPL-3.0-only
"""
    CladeCumulus — Cumulative Cladistic Explorer

Implements the second feature: tree with cumulative frequencies, epistemic colour coding,
cloud sizing by residual count, drag-and-drop with live present_in_every_admissible_world validation,
Evidence Mode toggle, clean non-cluttered UI.

Backend part: cumulative frequencies over cladistic tree, epistemic colour coding, cloud sizing.

Frontend part will be in `frontend/src/components/CladeCumulus.tsx`.

This file is scaffolded on feat/analysis-config-v1 branch but will be fully implemented
on feat/clade-cumulus branch (sequential task). For now, it provides the data structures
and validation logic that AnalysisConfig can already use.

Rules:
- Keep UI clean. Advanced options and cladistic visuals only appear when Evidence Mode enabled.
- Drag-and-drop with live present_in_every_admissible_world validation
- Evidence Mode toggle
"""
module CladeCumulus

using OrderedCollections
using ..Epistemic: EchoFiber, avec_fibre, present_in_every_admissible_world,
                   epistemic_colour, cloud_size_by_residual,
                   AVEC_FIBRE_COLUMN, EPISTEMIC_STATUSES

export CladeNode, CladeTree, CumulativeFrequency,
       build_clade_tree, cumulative_frequencies,
       validate_drag_drop, epistemic_colour_for_node, cloud_size_for_node,
       to_plotly_tree, to_json

# --------------------------------------------------------------------------
# Data structures
# --------------------------------------------------------------------------

"""
    CladeNode — node in cladistic tree

- `id`: unique id (e.g., taxon name or rank:value)
- `label`: display label
- `rank`: taxonomic rank (Domain, Phylum, etc.)
- `parent_id`: parent node id, nothing for root
- `children_ids`: child node ids
- `count`: raw count (sum of sequences)
- `cumulative_count`: cumulative count including children (computed)
- `cumulative_frequency`: cumulative frequency (count / total)
- `residual_count`: number of residual evidence candidates (for cloud sizing)
- `avec_fibre`: bool
- `epistemic_status`: one of EPISTEMIC_STATUSES
- `metadata`: extra dict
"""
struct CladeNode
    id::String
    label::String
    rank::String
    parent_id::Union{String,Nothing}
    children_ids::Vector{String}
    count::Float64
    cumulative_count::Float64
    cumulative_frequency::Float64
    residual_count::Int
    avec_fibre::Bool
    epistemic_status::String
    metadata::OrderedDict{String,Any}

    function CladeNode(; id::String,
                         label::String=id,
                         rank::String="unknown",
                         parent_id::Union{String,Nothing}=nothing,
                         children_ids::Vector{String}=String[],
                         count::Float64=0.0,
                         cumulative_count::Float64=count,
                         cumulative_frequency::Float64=0.0,
                         residual_count::Int=0,
                         avec_fibre::Bool=false,
                         epistemic_status::String="unknown",
                         metadata::OrderedDict{String,Any}=OrderedDict{String,Any}())

        epistemic_status in EPISTEMIC_STATUSES ||
            throw(ArgumentError("epistemic_status must be one of $(join(EPISTEMIC_STATUSES, ", ")) (got '$epistemic_status')"))

        new(id, label, rank, parent_id, children_ids, count, cumulative_count, cumulative_frequency, residual_count, avec_fibre, epistemic_status, metadata)
    end
end

"""
    CladeTree — whole tree

- `nodes`: id -> CladeNode
- `root_id`: root node id
- `total_count`: total sequences
"""
struct CladeTree
    nodes::OrderedDict{String,CladeNode}
    root_id::String
    total_count::Float64

    function CladeTree(nodes::OrderedDict{String,CladeNode}, root_id::String)
        haskey(nodes, root_id) || throw(ArgumentError("root_id '$root_id' not in nodes"))
        total = sum(n.count for n in values(nodes) if isnothing(n.parent_id) || n.parent_id == root_id || true; init=0.0)
        # Actually total should be root's cumulative count
        root = nodes[root_id]
        total_count = root.cumulative_count > 0 ? root.cumulative_count : sum(n.count for n in values(nodes); init=0.0)
        new(nodes, root_id, total_count)
    end
end

struct CumulativeFrequency
    node_id::String
    cumulative_count::Float64
    cumulative_frequency::Float64
    depth::Int
end

# --------------------------------------------------------------------------
# Tree building
# --------------------------------------------------------------------------

"""
    build_clade_tree(taxa_table; rank_hierarchy, count_column="total") -> CladeTree

Builds a cladistic tree from a taxa table (DataFrame or vector of dicts).
Each row should have rank columns (Domain, Phylum, ..., Species) and a count column.

Cumulative frequencies are computed bottom-up: each node's cumulative_count = its own count + sum(children cumulative_counts)

Epistemic colour coding: based on avec_fibre and present_in_every_admissible_world
Cloud sizing: by residual_count (number of candidate worlds or residual evidence)
"""
function build_clade_tree(taxa_rows::Vector{Dict{String,Any}};
                          rank_hierarchy::Vector{String}=["Domain", "Phylum", "Class", "Order", "Family", "Genus", "Species"],
                          count_column::String="total",
                          avec_fibre_column::String=AVEC_FIBRE_COLUMN)::CladeTree

    nodes = OrderedDict{String,CladeNode}()
    # Root node
    root_id = "root"
    nodes[root_id] = CladeNode(id=root_id, label="Root", rank="root", parent_id=nothing, count=0.0)

    # Build nodes for each taxon path
    for row in taxa_rows
        count = Float64(get(row, count_column, 0.0))
        avec = Bool(get(row, avec_fibre_column, false))
        residual = Int(get(row, "residual_count", get(row, "residual", 0)))
        epistemic_status = String(get(row, "epistemic_status", avec ? "present_in_some_admissible_world" : "unknown"))

        # Build path from root through ranks
        parent_id = root_id
        for (depth, rank) in enumerate(rank_hierarchy)
            rank_value = get(row, rank, nothing)
            isnothing(rank_value) && continue
            rank_value_str = String(rank_value)
            isempty(strip(rank_value_str)) && continue
            rank_value_str in ("Unclassified", "unknown", "") && continue

            node_id = "$(parent_id)|$(rank):$(rank_value_str)"
            if !haskey(nodes, node_id)
                nodes[node_id] = CladeNode(
                    id=node_id,
                    label=rank_value_str,
                    rank=rank,
                    parent_id=parent_id,
                    count=0.0,  # internal nodes get count from children, not direct
                    residual_count=residual,
                    avec_fibre=avec,
                    epistemic_status=epistemic_status,
                )
                # Add to parent's children
                parent_node = nodes[parent_id]
                if !(node_id in parent_node.children_ids)
                    # Need to update parent (immutable struct, so recreate)
                    new_children = vcat(parent_node.children_ids, [node_id])
                    nodes[parent_id] = CladeNode(
                        id=parent_node.id,
                        label=parent_node.label,
                        rank=parent_node.rank,
                        parent_id=parent_node.parent_id,
                        children_ids=new_children,
                        count=parent_node.count,
                        cumulative_count=parent_node.cumulative_count,
                        cumulative_frequency=parent_node.cumulative_frequency,
                        residual_count=parent_node.residual_count,
                        avec_fibre=parent_node.avec_fibre,
                        epistemic_status=parent_node.epistemic_status,
                        metadata=parent_node.metadata,
                    )
                end
            end
            parent_id = node_id
        end

        # Leaf node (species or finest rank) gets the count
        # If parent_id is still root, create a direct leaf under root
        leaf_id = parent_id == root_id ? "$(root_id)|leaf:$(get(row, "SeqName", string(hash(row))))" : parent_id
        if haskey(nodes, leaf_id)
            old = nodes[leaf_id]
            nodes[leaf_id] = CladeNode(
                id=old.id,
                label=old.label,
                rank=old.rank,
                parent_id=old.parent_id,
                children_ids=old.children_ids,
                count=old.count + count,
                cumulative_count=old.cumulative_count + count,
                cumulative_frequency=old.cumulative_frequency,
                residual_count=max(old.residual_count, residual),
                avec_fibre=old.avec_fibre || avec,
                epistemic_status=epistemic_status, # last wins, could be more sophisticated
                metadata=old.metadata,
            )
        else
            nodes[leaf_id] = CladeNode(
                id=leaf_id,
                label=String(get(row, "Genus", get(row, "Species", "Unknown"))),
                rank="leaf",
                parent_id=root_id,
                count=count,
                cumulative_count=count,
                residual_count=residual,
                avec_fibre=avec,
                epistemic_status=epistemic_status,
            )
            # Add to root children
            root_node = nodes[root_id]
            new_children = vcat(root_node.children_ids, [leaf_id])
            nodes[root_id] = CladeNode(
                id=root_node.id,
                label=root_node.label,
                rank=root_node.rank,
                parent_id=root_node.parent_id,
                children_ids=new_children,
                count=root_node.count,
                cumulative_count=root_node.cumulative_count,
                cumulative_frequency=root_node.cumulative_frequency,
                residual_count=root_node.residual_count,
                avec_fibre=root_node.avec_fibre,
                epistemic_status=root_node.epistemic_status,
                metadata=root_node.metadata,
            )
        end
    end

    # Compute cumulative counts bottom-up
    nodes = _compute_cumulative(nodes, root_id)

    return CladeTree(nodes, root_id)
end

function _compute_cumulative(nodes::OrderedDict{String,CladeNode}, root_id::String)::OrderedDict{String,CladeNode}
    # Post-order traversal: children first
    # For simplicity, iterate in reverse topological order (leaves first)
    # We need to compute cumulative_count = own count + sum(children cumulative_counts)

    # Build depth map
    depth_map = Dict{String,Int}()
    function compute_depth(id::String, depth::Int)
        depth_map[id] = depth
        node = nodes[id]
        for child_id in node.children_ids
            if haskey(nodes, child_id)
                compute_depth(child_id, depth+1)
            end
        end
    end
    compute_depth(root_id, 0)

    # Sort nodes by depth descending (deepest first)
    sorted_ids = sort(collect(keys(nodes)), by=id->get(depth_map, id, 0), rev=true)

    new_nodes = copy(nodes)
    for id in sorted_ids
        node = new_nodes[id]
        # Sum children cumulative counts
        children_cum = 0.0
        for child_id in node.children_ids
            if haskey(new_nodes, child_id)
                children_cum += new_nodes[child_id].cumulative_count
            end
        end
        cum_count = node.count + children_cum
        # Update node with cumulative_count
        new_nodes[id] = CladeNode(
            id=node.id,
            label=node.label,
            rank=node.rank,
            parent_id=node.parent_id,
            children_ids=node.children_ids,
            count=node.count,
            cumulative_count=cum_count,
            cumulative_frequency=0.0, # will be set after total known
            residual_count=node.residual_count,
            avec_fibre=node.avec_fibre,
            epistemic_status=node.epistemic_status,
            metadata=node.metadata,
        )
    end

    # Now set cumulative_frequency = cumulative_count / total
    total = new_nodes[root_id].cumulative_count
    total = total == 0 ? 1.0 : total
    for id in keys(new_nodes)
        node = new_nodes[id]
        freq = node.cumulative_count / total
        new_nodes[id] = CladeNode(
            id=node.id,
            label=node.label,
            rank=node.rank,
            parent_id=node.parent_id,
            children_ids=node.children_ids,
            count=node.count,
            cumulative_count=node.cumulative_count,
            cumulative_frequency=freq,
            residual_count=node.residual_count,
            avec_fibre=node.avec_fibre,
            epistemic_status=node.epistemic_status,
            metadata=node.metadata,
        )
    end

    return new_nodes
end

function cumulative_frequencies(tree::CladeTree)::Vector{CumulativeFrequency}
    freqs = CumulativeFrequency[]
    for (id, node) in tree.nodes
        depth = _depth_of(tree, id)
        push!(freqs, CumulativeFrequency(id, node.cumulative_count, node.cumulative_frequency, depth))
    end
    sort!(freqs, by=f->f.depth)
    return freqs
end

function _depth_of(tree::CladeTree, node_id::String)::Int
    depth = 0
    current_id = node_id
    while true
        node = get(tree.nodes, current_id, nothing)
        isnothing(node) && break
        isnothing(node.parent_id) && break
        current_id = node.parent_id
        depth += 1
        depth > 100 && break # prevent infinite loop
    end
    return depth
end

# --------------------------------------------------------------------------
# Validation: drag-and-drop with live present_in_every_admissible_world
# --------------------------------------------------------------------------

"""
    validate_drag_drop(tree, dragged_node_id, target_parent_id, evidence) -> (Bool, String)

Validates whether dragged_node can be dropped under target_parent.

Uses present_in_every_admissible_world: a taxon can only be placed in a clade
if it is present in every admissible world consistent with evidence.

Returns (is_valid, message)
"""
function validate_drag_drop(tree::CladeTree,
                            dragged_node_id::String,
                            target_parent_id::String,
                            evidence::Dict{String,Any})::Tuple{Bool,String}

    !haskey(tree.nodes, dragged_node_id) && return (false, "Dragged node '$dragged_node_id' not found")
    !haskey(tree.nodes, target_parent_id) && return (false, "Target parent '$target_parent_id' not found")

    dragged = tree.nodes[dragged_node_id]
    target = tree.nodes[target_parent_id]

    # Cannot drop root
    dragged_node_id == tree.root_id && return (false, "Cannot move root")

    # Cannot drop onto itself or descendant (would create cycle)
    if _is_descendant(tree, target_parent_id, dragged_node_id)
        return (false, "Cannot drop a clade onto itself or its descendant (would create cycle)")
    end

    # Epistemic validation: present_in_every_admissible_world
    # For drag-and-drop to be valid, dragged taxon must be present in every admissible world
    # under the new parent's evidence context

    # Build evidence for this check
    check_evidence = Dict{String,Any}(evidence)
    check_evidence["avec_fibre"] = dragged.avec_fibre
    check_evidence["epistemic_status"] = dragged.epistemic_status
    check_evidence["residual_count"] = dragged.residual_count

    # If sans fibre, cannot validate presence in every world
    if !dragged.avec_fibre
        return (false, "Cannot move '$(dragged.label)': sans fibre (no semantic fibre). Artefact does not carry enough evidence to support placement. Needs avec_fibre=true.")
    end

    # Check epistemic status
    if dragged.epistemic_status == "absent_in_every_admissible_world"
        return (false, "Cannot move '$(dragged.label)': absent in every admissible world (epistemic status).")
    end

    if dragged.epistemic_status == "unknown"
        return (false, "Cannot move '$(dragged.label)': epistemic status unknown (sans fibre or insufficient evidence). Needs present_in_every_admissible_world.")
    end

    # For strict validation, require present_in_every, not just some
    if dragged.epistemic_status != "present_in_every_admissible_world"
        # Allow with warning if present_in_some, but require explicit acknowledgment?
        # For now, we allow present_in_some with warning, but not unknown/absent
        # The task says live present_in_every_admissible_world validation, so we should require every
        return (false, "Cannot move '$(dragged.label)': not present in every admissible world (status=$(dragged.epistemic_status)). Only taxa with status present_in_every_admissible_world can be placed. This is the residual-evidence validation.")
    end

    # Additional check: cumulative frequency must make sense
    # (e.g., cannot place a high-frequency clade under low-frequency parent if it would exceed 100%)
    # For now, we allow but warn

    return (true, "Valid: '$(dragged.label)' can be placed under '$(target.label)' (present_in_every_admissible_world, avec_fibre=true)")
end

function _is_descendant(tree::CladeTree, maybe_descendant_id::String, ancestor_id::String)::Bool
    current_id = maybe_descendant_id
    while true
        current_id == ancestor_id && return true
        node = get(tree.nodes, current_id, nothing)
        isnothing(node) && return false
        isnothing(node.parent_id) && return false
        current_id = node.parent_id
        # Prevent infinite loop
        if current_id == maybe_descendant_id
            return false
        end
    end
end

# --------------------------------------------------------------------------
# UI helpers: colour coding, cloud sizing
# --------------------------------------------------------------------------

function epistemic_colour_for_node(node::CladeNode)::String
    return epistemic_colour(node.epistemic_status)
end

function cloud_size_for_node(node::CladeNode)::Float64
    return cloud_size_by_residual(node.residual_count)
end

# --------------------------------------------------------------------------
# Plotly conversion (for frontend)
# --------------------------------------------------------------------------

function to_plotly_tree(tree::CladeTree)::Dict{String,Any}
    # Convert tree to Plotly sunburst or treemap format
    # For CladeCumulus: we want tree with cumulative frequencies, colour by epistemic, size by residual

    ids = String[]
    labels = String[]
    parents = String[]
    values = Float64[]
    colours = String[]
    sizes = Float64[]
    hover_texts = String[]

    for (id, node) in tree.nodes
        push!(ids, id)
        push!(labels, node.label)
        push!(parents, isnothing(node.parent_id) ? "" : node.parent_id)
        push!(values, node.cumulative_count)
        push!(colours, epistemic_colour_for_node(node))
        push!(sizes, cloud_size_for_node(node))
        push!(hover_texts, "Rank: $(node.rank)<br>Count: $(node.count)<br>Cumulative: $(node.cumulative_count) ($(round(node.cumulative_frequency*100, digits=2))%)<br>Residual: $(node.residual_count)<br>avec_fibre: $(node.avec_fibre)<br>Epistemic: $(node.epistemic_status)")
    end

    return Dict{String,Any}(
        "type" => "sunburst",
        "ids" => ids,
        "labels" => labels,
        "parents" => parents,
        "values" => values,
        "marker" => Dict("colors" => colours),
        "hovertext" => hover_texts,
        "branchvalues" => "total",
        "cloud_sizes" => sizes,
    )
end

function to_json(tree::CladeTree)::String
    dict = Dict{String,Any}(
        "root_id" => tree.root_id,
        "total_count" => tree.total_count,
        "nodes" => [Dict(
            "id" => n.id,
            "label" => n.label,
            "rank" => n.rank,
            "parent_id" => n.parent_id,
            "children_ids" => n.children_ids,
            "count" => n.count,
            "cumulative_count" => n.cumulative_count,
            "cumulative_frequency" => n.cumulative_frequency,
            "residual_count" => n.residual_count,
            "avec_fibre" => n.avec_fibre,
            "epistemic_status" => n.epistemic_status,
            "colour" => epistemic_colour_for_node(n),
            "cloud_size" => cloud_size_for_node(n),
        ) for n in values(tree.nodes)]
    )
    return JSON3.write(dict)
end

end # module CladeCumulus
