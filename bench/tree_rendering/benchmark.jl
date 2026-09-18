# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""
Benchmark for tree rendering pathways (CladeCumulus)

Measures (future CladeCumulus, currently mocked):
- CladeTree building bottom-up cumulative frequencies
- Epistemic colour coding for nodes
- Cloud sizing by residual count
- validate_drag_drop with present_in_every check
- to_plotly_tree conversion (sunburst)
- to_json serialization
- Frontend SVG tree rendering (mocked as string building)
"""

using Random

# Mock CladeNode and CladeTree (mirrors src/analysis/clade_cumulus.jl)
struct MockCladeNode
    id::String
    label::String
    rank::String
    parent_id::Union{String, Nothing}
    children_ids::Vector{String}
    count::Int
    cumulative_count::Int
    cumulative_frequency::Float64
    residual_count::Int
    avec_fibre::Bool
    epistemic_status::String
    colour::String
    cloud_size::Float64
end

struct MockCladeTree
    nodes::Dict{String, MockCladeNode}
    root_id::String
    total_count::Int
end

function build_mock_tree(n_nodes::Int=100)
    nodes = Dict{String, MockCladeNode}()
    # Root
    nodes["root"] = MockCladeNode("root", "Root", "Domain", nothing, ["node1", "node2"], 0, 0, 0.0, 0, true, "present_in_every", "#2e7d32", 10.0)
    for i in 1:n_nodes
        id = "node$i"
        parent = i <= 2 ? "root" : "node$(rand(1:i-1))"
        count = rand(0:1000)
        residual = rand(0:100)
        avec = rand(Bool)
        status = rand(["present_in_every", "present_in_some", "absent", "sans_fibre"])
        colour = if status == "present_in_every"
            "#2e7d32"
        elseif status == "present_in_some"
            "#f9a825"
        elseif status == "absent"
            "#9e9e9e"
        else
            "#c62828"
        end
        cloud = log(1+residual)*10+5
        # Update parent children
        if haskey(nodes, parent)
            push!(nodes[parent].children_ids, id)
        end
        nodes[id] = MockCladeNode(id, "Taxon $i", rand(["Phylum", "Class", "Order", "Family", "Genus"]), parent, String[], count, 0, 0.0, residual, avec, status, colour, cloud)
    end
    # Bottom-up cumulative
    total = 0
    # Simple post-order via reverse id order (mock)
    for i in n_nodes:-1:1
        id = "node$i"
        node = nodes[id]
        cum = node.count + sum(nodes[child].cumulative_count for child in node.children_ids if haskey(nodes, child); init=0)
        nodes[id] = MockCladeNode(node.id, node.label, node.rank, node.parent_id, node.children_ids, node.count, cum, 0.0, node.residual_count, node.avec_fibre, node.epistemic_status, node.colour, node.cloud_size)
        if node.parent_id === nothing || node.parent_id == "root"
            total += cum
        end
    end
    # Root cumulative
    root = nodes["root"]
    root_cum = sum(nodes[child].cumulative_count for child in root.children_ids if haskey(nodes, child); init=0)
    nodes["root"] = MockCladeNode(root.id, root.label, root.rank, root.parent_id, root.children_ids, root.count, root_cum, 1.0, root.residual_count, root.avec_fibre, root.epistemic_status, root.colour, root.cloud_size)
    for (id, node) in nodes
        if root_cum > 0
            nodes[id] = MockCladeNode(node.id, node.label, node.rank, node.parent_id, node.children_ids, node.count, node.cumulative_count, node.cumulative_count / root_cum, node.residual_count, node.avec_fibre, node.epistemic_status, node.colour, node.cloud_size)
        end
    end
    return MockCladeTree(nodes, "root", root_cum)
end

function bench_build_tree(n::Int=100)
    @elapsed build_mock_tree(n)
end

function bench_epistemic_colour(n::Int=1000)
    statuses = rand(["present_in_every", "present_in_some", "absent", "sans_fibre"], n)
    @elapsed for s in statuses
        if s == "present_in_every"
            "#2e7d32"
        elseif s == "present_in_some"
            "#f9a825"
        elseif s == "absent"
            "#9e9e9e"
        else
            "#c62828"
        end
    end
end

function bench_cloud_size(n::Int=1000)
    residuals = rand(0:1000, n)
    @elapsed for r in residuals
        log(1+r)*10+5
    end
end

function bench_validate_drag_drop(tree::MockCladeTree, n::Int=100)
    @elapsed for _ in 1:n
        dragged = "node$(rand(1:length(tree.nodes)-1))"
        target = "node$(rand(1:length(tree.nodes)-1))"
        # Mock present_in_every check + cycle prevention
        dragged != target && !occursin(dragged, target)  # simplified cycle check
    end
end

function bench_to_plotly_tree(tree::MockCladeTree)
    @elapsed begin
        # Mock conversion to Plotly sunburst format
        ids = String[]
        labels = String[]
        parents = String[]
        values = Int[]
        colours = String[]
        for (id, node) in tree.nodes
            push!(ids, id)
            push!(labels, node.label)
            push!(parents, node.parent_id === nothing ? "" : node.parent_id)
            push!(values, node.cumulative_count)
            push!(colours, node.colour)
        end
        Dict("ids" => ids, "labels" => labels, "parents" => parents, "values" => values, "colours" => colours)
    end
end

function bench_to_json(tree::MockCladeTree)
    using JSON3
    @elapsed JSON3.write(tree.nodes)
end

function bench_svg_rendering(n::Int=100)
    @elapsed begin
        # Mock SVG tree rendering: string building for g/circle/text
        buf = IOBuffer()
        for i in 1:n
            println(buf, """<g transform="translate($(rand()*100),$(rand()*100))"><circle r="$(rand()*5+2)" fill="#2e7d32"/><text>Taxon $i</text></g>""")
        end
        String(take!(buf))
    end
end

function run_benchmarks(; reps=5)
    println("=== Tree Rendering (CladeCumulus) Benchmark ===")
    results = Dict{String, Vector{Float64}}()

    for name in ["build_tree", "epistemic_colour", "cloud_size", "validate_drag_drop", "to_plotly_tree", "to_json", "svg_rendering"]
        results[name] = Float64[]
    end

    tree = build_mock_tree(100)

    for _ in 1:reps
        push!(results["build_tree"], bench_build_tree(100))
        push!(results["epistemic_colour"], bench_epistemic_colour())
        push!(results["cloud_size"], bench_cloud_size())
        push!(results["validate_drag_drop"], bench_validate_drag_drop(tree, 100))
        push!(results["to_plotly_tree"], bench_to_plotly_tree(tree))
        push!(results["to_json"], bench_to_json(tree))
        push!(results["svg_rendering"], bench_svg_rendering(100))
    end

    for (name, times) in results
        med = median(times)
        println("$name: median $(round(med*1000, digits=2)) ms over $reps reps")
    end

    baseline_path = joinpath(@__DIR__, "baseline.json")
    if isfile(baseline_path)
        using JSON3
        baseline = JSON3.read(read(baseline_path, String))
        println("\nBaseline comparison (fail on >10% regression):")
        for (name, times) in results
            med = median(times)
            if haskey(baseline, name)
                base_med = baseline[name]
                delta = (med - base_med) / base_med * 100
                status = abs(delta) > 10 ? "FAIL" : "PASS"
                println("$status $name: $(round(delta, digits=1))% vs baseline $(round(base_med*1000, digits=2)) ms")
                if abs(delta) > 10 && get(ENV, "CI", "false") == "true"
                    @error "Regression >10% for $name" delta
                    exit(1)
                end
            end
        end
    else
        println("\nNo baseline.json — saving current as baseline")
        using JSON3
        baseline = Dict(name => median(times) for (name, times) in results)
        open(baseline_path, "w") do io
            JSON3.write(io, baseline)
        end
    end

    return results
end

if abspath(PROGRAM_FILE) == @__FILE__
    run_benchmarks()
end
