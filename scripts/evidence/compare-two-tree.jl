#!/usr/bin/env julia
# SPDX-License-Identifier: MPL-2.0
# Structural comparison, not a semantic-equivalence proof. Julia parsing is
# parse-only; R and TypeScript adapters are sibling scripts. No project code is
# evaluated. Call edges are syntactic and may be unresolved.
using JSON3, SHA, TOML

const NORMALIZE_VERSION = "evidence-ast-v1"
sha(data) = bytes2hex(sha256(data))
json_write(path, value) = open(path, "w") do io
    JSON3.pretty(io, value)
    write(io, "\n")
end

function normalize(ex)
    ex isa LineNumberNode && return nothing
    ex isa Expr && return ["expr", String(ex.head), Any[normalize(a) for a in ex.args if !(a isa LineNumberNode)]]
    ex isa QuoteNode && return ["quote", normalize(ex.value)]
    ex isa Symbol && return ["symbol", String(ex)]
    ex isa String && return ["string", ex]
    ex isa Number && return [string(typeof(ex)), string(ex)]
    ex isa Bool && return ["bool", ex]
    ex === nothing && return ["nothing"]
    return [string(typeof(ex)), repr(ex)]
end
function walk!(f, ex)
    f(ex)
    if ex isa Expr
        for a in ex.args
            walk!(f, a)
        end
    end
    ex isa QuoteNode && walk!(f, ex.value)
    nothing
end
function call_name(ex)
    ex isa Symbol && return String(ex)
    ex isa Expr && return sprint(show, ex)
    return string(ex)
end
function julia_structure(root)
    records = Any[]
    raw = read(`git -C $root ls-files -z -- *.jl`)
    for path in sort(filter(!isempty, split(String(raw), '\0')))
        source = read(joinpath(root, path), String)
        parsed = Meta.parseall(source; filename=path)
        errors = Any[]
        walk!(parsed) do ex
            if ex isa Expr && ex.head in (:error, :incomplete)
                push!(errors, sprint(show, ex))
            end
        end
        isempty(errors) || error("Julia parse failure in $path: $(join(errors, "; "))")
        functions = Any[]; calls = Any[]; imports = Any[]
        function visit(ex, caller)
            if ex isa Expr
                if ex.head in (:function, :macro)
                    name = call_name(ex.args[1]); start = nothing
                    # Locate the definition by its normalized body, not text similarity.
                    push!(functions, Dict("name" => name, "ast_sha256" => sha(repr(normalize(ex)))))
                    for a in ex.args[2:end]; visit(a, name); end
                    return
                elseif ex.head == :call
                    push!(calls, Dict("caller" => caller, "callee" => call_name(ex.args[1]), "resolved" => false))
                    if !isempty(ex.args) && call_name(ex.args[1]) == "include" && length(ex.args) == 2 && ex.args[2] isa String
                        push!(imports, "include:" * ex.args[2])
                    end
                elseif ex.head in (:using, :import)
                    push!(imports, sprint(show, ex))
                end
                for a in ex.args; visit(a, caller); end
            elseif ex isa QuoteNode
                visit(ex.value, caller)
            end
        end
        visit(parsed, "<top-level>")
        push!(records, Dict("path" => path, "language" => "julia",
            "ast_sha256" => sha(repr(normalize(parsed))), "functions" => functions,
            "calls" => calls, "imports" => sort(unique(imports)),
            "limitations" => ["parse-only", "syntactic call names; no dispatch resolution", "no Julia dataflow analysis"]))
    end
    return records
end

function external_structure(root, language)
    out = tempname()
    try
        if language == "r"
            script = joinpath(@__DIR__, "r-structure.R")
            run(pipeline(`Rscript --vanilla $script $root`, stdout=out))
            records = Any[]
            for line in eachline(out)
                isempty(line) && continue
                r = Dict{String,Any}(string(k) => v for (k, v) in pairs(JSON3.read(line)))
                r["ast_sha256"] = sha(r["normalized"])
                delete!(r, "normalized")
                r["functions"] = Any[Dict("name" => f.name, "ast_sha256" => sha(f.normalized)) for f in r["functions"]]
                push!(records, r)
            end
            return records
        else
            bun = get(ENV, "BUN", "bun")
            script = joinpath(@__DIR__, "ts-structure.ts")
            run(pipeline(`$bun $script $root`, stdout=out))
            return Vector{Any}(JSON3.read(read(out, String)))
        end
    finally
        isfile(out) && rm(out)
    end
end

function provenance(owner, base, up, fork, path, ublob, fblob)
    bblob = let result = read(`git -C $owner ls-tree -z $base -- $path`, String)
        isempty(result) ? nothing : split(split(result, '\t')[1], ' ')[3]
    end
    isnothing(ublob) && return isnothing(bblob) ? "fork-added" : "fork-deleted"
    isnothing(fblob) && return isnothing(bblob) ? "upstream-added" : "upstream-deleted"
    if ublob == fblob
        return isnothing(bblob) ? "both-added-identical-bytes" :
            ublob == bblob ? "shared-unchanged-since-base" : "both-changed-identical-bytes"
    elseif ublob == bblob
        return "fork-changed"
    elseif fblob == bblob
        return "upstream-changed"
    else
        return isnothing(bblob) ? "both-added-different-bytes" : "both-changed-different-bytes"
    end
end

function compare(config_path, workspace, out)
    config = JSON3.read(read(config_path, String))
    owner = joinpath(workspace, "owner")
    inventories = Dict(side => JSON3.read(read(joinpath(out, string(side), "git-inventory.json"), String))
                       for side in (:upstream, :fork))
    blobs = Dict(side => Dict(String(x.path) => String(x.blob) for x in inventories[side])
                 for side in (:upstream, :fork))
    paths = sort(union(collect(keys(blobs[:upstream])), collect(keys(blobs[:fork]))))
    structures = Dict{Tuple{Symbol,String},Any}()
    for side in (:upstream, :fork)
        root = joinpath(workspace, string(side))
        records = julia_structure(root)
        append!(records, external_structure(root, "r"))
        append!(records, external_structure(root, "typescript"))
        json_write(joinpath(out, string(side), "structure.json"), records)
        for r in records; structures[(side, String(r["path"]))] = r; end
    end
    inventory = Any[]
    for path in paths
        u = get(blobs[:upstream], path, nothing); f = get(blobs[:fork], path, nothing)
        us = get(structures, (:upstream, path), nothing); fs = get(structures, (:fork, path), nothing)
        ast_equal = u == f ? true : (isnothing(us) || isnothing(fs) ? nothing : us["ast_sha256"] == fs["ast_sha256"])
        push!(inventory, Dict("path" => path, "upstream_blob" => u, "fork_blob" => f,
            "provenance" => provenance(owner, config.merge_base, config.trees.upstream.revision,
                                          config.trees.fork.revision, path, u, f),
            "upstream_ast_sha256" => isnothing(us) ? nothing : us["ast_sha256"],
            "fork_ast_sha256" => isnothing(fs) ? nothing : fs["ast_sha256"],
            "ast_equal" => ast_equal,
            "call_edges_equal" => isnothing(us) || isnothing(fs) ? nothing : us["calls"] == fs["calls"],
            "import_edges_equal" => isnothing(us) || isnothing(fs) ? nothing : us["imports"] == fs["imports"]))
    end
    json_write(joinpath(out, "path-provenance.json"), inventory)

    findings = Any[]
    for side in (:upstream, :fork)
        pons = JSON3.read(read(joinpath(out, string(side), "pons.json"), String))
        panic = JSON3.read(read(joinpath(out, string(side), "panic-attack.json"), String))
        for f in pons.findings
            path = relpath(String(f.location.file), ".")
            push!(findings, Dict("tool" => "pons", "side" => string(side), "path" => path,
                "rule" => f.rule_id, "severity" => f.severity, "evidence" => f.evidence,
                "message" => f.message, "line" => f.location.line_start,
                "fingerprint" => f.semantic_fingerprint, "blob" => get(blobs[side], path, nothing)))
        end
        for f in panic.weak_points
            raw_file = get(f, :file, nothing)
            file = raw_file === nothing ? String(get(f, :location, "")) : String(raw_file)
            path = startswith(file, "./") ? file[3:end] : file
            push!(findings, Dict("tool" => "panic-attack", "side" => string(side), "path" => path,
                "rule" => f.category, "severity" => f.severity, "evidence" => "HEURISTIC",
                "message" => f.description, "line" => get(f, :line, nothing),
                "suppressed" => Bool(get(f, :suppressed, false)), "blob" => get(blobs[side], path, nothing)))
        end
    end
    groups = Dict{String,Vector{Any}}()
    for f in findings
        # Message equality is a correlation key, never a claim of equivalent
        # changed semantics. Occurrence ordinals distinguish repeated findings.
        key = join([f["tool"], f["path"], string(f["rule"]), string(f["message"])], "\0")
        push!(get!(groups, key, Any[]), f)
    end
    joined = Any[]
    for key in sort(collect(keys(groups)))
        items = groups[key]; u = filter(x -> x["side"] == "upstream", items); f = filter(x -> x["side"] == "fork", items)
        for i in 1:max(length(u), length(f))
            a = i <= length(u) ? u[i] : nothing; b = i <= length(f) ? f[i] : nothing
            same_blob = !isnothing(a) && !isnothing(b) && a["blob"] == b["blob"]
            classification = isnothing(a) ? "fork-only-occurrence" : isnothing(b) ? "upstream-only-occurrence" :
                same_blob ? "both-identical-blob" : "both-changed-blob-review-required"
            push!(joined, Dict("correlation_sha256" => sha(key), "occurrence" => i,
                "classification" => classification, "upstream" => a, "fork" => b,
                "review_status" => "unreviewed scanner output; not an observed defect"))
        end
    end
    json_write(joinpath(out, "finding-provenance.json"), joined)
    coverage = Dict{String,Any}()
    for side in (:upstream, :fork)
        p = JSON3.read(read(joinpath(out, string(side), "pons.json"), String))
        a = JSON3.read(read(joinpath(out, string(side), "panic-attack.json"), String))
        count_kind(items, field) = Dict(k => count(x -> String(get(x, field, "")) == k, items)
                                         for k in unique(String(get(x, field, "")) for x in items))
        coverage[string(side)] = Dict("pons_status" => p.scanned.coverage_status,
            "pons_files" => p.scanned.files, "pons_languages" => p.scanned.languages,
            "pons_by_language" => count_kind(p.scanned.inventory, :language),
            "pons_by_outcome" => count_kind(p.scanned.inventory, :outcome),
            "panic_status" => a.coverage.status, "panic_analyzed" => a.coverage.analyzed_files,
            "panic_candidates" => a.coverage.candidate_files,
            "panic_by_status" => count_kind(a.coverage.inputs, :status))
    end
    json_write(joinpath(out, "coverage.json"), coverage)
    json_write(joinpath(out, "comparison.json"), Dict("normalization" => NORMALIZE_VERSION,
        "paths" => length(paths), "finding_occurrences" => length(joined),
        "limitations" => ["AST equality does not prove semantic equivalence",
            "No cross-language taint proof", "Pons dataflow rules at this pin are Python-only",
            "Julia/R calls are syntactic and unresolved", "Missing AST coverage is null, not equal"]))
    println("Structural comparison complete: $(length(paths)) paths, $(length(joined)) finding occurrences; not a verdict.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 3 || error("Usage: compare-two-tree.jl CONFIG WORKSPACE OUTPUT")
    compare(ARGS...)
end
