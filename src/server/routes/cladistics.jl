# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Study-scoped de novo ASV phylogenies and their CladeCumulus analysis.
# Each build is an immutable directory under projects/{study}/cladistics/{id}:
# source document + FASTA + selected counts + the usual MAFFT/trimAl/IQ-TREE
# attestation + metrics pinned to the exact count and tree hashes. Rebuilding
# creates a new id instead of silently changing an earlier result.
using JSON3, SHA

const CC = MetaManifold.CladeCumulus
const _CC_MAX_ASVS = 2000

_clad_root(study::String) = joinpath(ServerState.projects_dir(), study, "cladistics")
_clad_dir(study::String, id::String) = joinpath(_clad_root(study), id)
_clad_doc_path(study::String, id::String) = joinpath(_clad_dir(study, id), "analysis.json")
_clad_counts_path(study::String, id::String) = joinpath(_clad_dir(study, id), "counts.json")
_clad_results_path(study::String, id::String) = joinpath(_clad_dir(study, id), "results.json")
_clad_files(study::String, id::String) = Phylo.reference_files(_clad_dir(study, id))

function _clad_request_error(study::String, id::Union{String,Nothing}=nothing)
    _study_exists(study) || return json_error(404, "study_not_found", "Study '$study' not found")
    isnothing(id) && return nothing
    _valid_phylo_id(id) || return json_error(400, "invalid_id", "Cladistics analysis ids are 8 hex characters")
    isfile(_clad_doc_path(study, id)) ||
        return json_error(404, "not_found", "No Cladistics analysis '$id'")
    nothing
end

function _clad_summary(study::String, id::String)
    doc = something(_read_doc(_clad_doc_path(study, id)), Dict{String,Any}())
    dir = _clad_dir(study, id)
    published = get(doc, "published", nothing)
    (; id,
       name = string(get(doc, "name", id)),
       created = string(get(doc, "created", "")),
       modified = string(get(doc, "modified", "")),
       asv_count = Int(get(doc, "asv_count", 0)),
       sample_count = Int(get(doc, "sample_count", 0)),
       state = _state(dir, "cc:$study/$id"),
       built = isfile(_clad_results_path(study, id)),
       published)
end

function _cc_integer(value, fallback::Int, label::String, lo::Int, hi::Int)::Int
    isnothing(value) && return fallback
    (value isa Real && !(value isa Bool) && isfinite(value) && isinteger(value)) ||
        error("$label must be an integer")
    number = Int(value)
    lo <= number <= hi || error("$label must be between $lo and $hi")
    number
end

function _cc_min_reads(value)::Float64
    isnothing(value) && return 1.0
    (value isa Real && !(value isa Bool) && isfinite(value) && value >= 1) ||
        error("min_reads must be a finite number of at least 1")
    Float64(value)
end

# Validate the run list before the generic cross-run collector, which is
# intentionally forgiving for chart UIs. A phylogeny must not silently omit one
# of the studies the user selected.
function _cc_check_runs(study::String, runs)
    runs isa AbstractVector || error("runs must be an array")
    isempty(runs) && error("Choose at least one run")
    seen = Set{Tuple{String,String}}()
    for spec in runs
        spec isa AbstractDict || error("each run must be an object")
        run = string(get(spec, :run, ""))
        group = _opt_string(spec, :group)
        key = (something(group, ""), run)
        key in seen && error("Run '$(isnothing(group) ? run : "$group/$run")' was selected more than once")
        push!(seen, key)
        resolved = _resolve_run_duckdb(study, spec)
        isnothing(resolved) && error("Run '$(isnothing(group) ? run : "$group/$run")' has no results")
    end
    nothing
end

function _cc_sample_labels(samples, run_labels)
    labels = ["$(run_labels[i]) / $(samples[i])" for i in eachindex(samples)]
    length(unique(labels)) == length(labels) ||
        error("Sample labels are not unique; check the selected runs")
    labels
end

# Select, normalize and persist the exact count matrix that the later tree and
# metrics use. Ties in top-N selection are broken by sequence, so a rebuild with
# the same inputs never depends on DuckDB or Dict iteration order.
function _cc_prepare!(study::String, id::String, body)
    runs = get(body, :runs, nothing)
    _cc_check_runs(study, runs)
    table = strip(string(get(body, :table, "merged")))
    isempty(table) && error("Choose a results table")
    max_asvs = _cc_integer(get(body, :max_asvs, nothing), 500, "max_asvs", 4, _CC_MAX_ASVS)
    min_reads = _cc_min_reads(get(body, :min_reads, nothing))
    depth = _cc_integer(get(body, :depth, nothing), 0, "depth", 0, 1_000_000_000)
    method = string(get(body, :normalisation, "none"))
    method in NORMALISATION_METHODS || error("Unknown normalisation '$method'")
    seed = Int(get(body, :seed, _study_seed(study)))

    params = _body_filter_params(body)
    run_data, _, _, _, missing_seq = _collect_cross_run_asvs(
        study, runs, table, params; aggregate=true)
    missing_seq && error("Table '$table' needs a DNA sequence column (Sequence or sequence)")
    expected = length(_expand_comparison_run_specs(study, runs; aggregate=true))
    length(run_data) == expected ||
        error("Every selected run needs table '$table' and at least one sample")
    isempty(run_data) && error("No ASV counts were found")

    raw, samples, sequences, run_labels = combined_asv_counts_across_runs(run_data)
    all(v -> isfinite(v) && v >= 0, raw) || error("ASV counts must be finite and non-negative")
    totals = vec(sum(raw; dims=1))
    candidates = findall(v -> v >= min_reads, totals)
    sort!(candidates; by = j -> (-totals[j], sequences[j]))
    available = length(candidates)
    chosen = first(candidates, min(max_asvs, available))
    length(chosen) >= 4 || error(
        "A phylogeny needs at least 4 ASVs after filtering; found $(length(chosen))")

    selected_sequences = sequences[chosen]
    tips = CC.asv_tip_name.(selected_sequences)
    length(unique(tips)) == length(tips) || error(
        "ASV sequences that differ only by case or gaps need to be de-duplicated first")
    selected = raw[:, chosen]

    # Name samples by run as well as table column: equal sample names in two runs
    # remain distinct observations in the UniFrac matrix.
    labels = _cc_sample_labels(samples, run_labels)
    norm = normalise_counts(selected; method, depth, seed)
    normalised_labels = labels[norm.kept]
    nonempty = findall(v -> v > 0, vec(sum(norm.mat; dims=2)))
    isempty(nonempty) && error("All samples are empty after ASV selection and normalisation")
    kept = norm.kept[nonempty]
    excluded = labels[setdiff(1:length(labels), kept)]
    counts = norm.mat[nonempty, :]
    kept_labels = normalised_labels[nonempty]

    records = Phylo.parse_fasta(join((">$(tips[i])\n$(selected_sequences[i])" for i in eachindex(tips)), "\n");
                                what="ASV phylogeny")
    files = _clad_files(study, id)
    Phylo.write_fasta(files["references.fasta"], records)

    resolved_depth = method == "none" ? 0 :
                     (depth == 0 ? auto_min_depth(vec(sum(selected; dims=2))) : depth)
    counts_doc = Dict{String,Any}(
        "version" => 1,
        "samples" => kept_labels,
        "tips" => tips,
        "counts" => [collect(row) for row in eachrow(counts)],
        "excluded_samples" => excluded,
        "normalisation" => Dict{String,Any}(
            "method" => method, "depth" => resolved_depth, "seed" => seed),
    )
    counts_json = JSON3.write(counts_doc)
    counts_sha256 = bytes2hex(sha256(counts_json))
    _write_atomic(_clad_counts_path(study, id), counts_json)

    name = strip(string(get(body, :name, "ASV phylogeny")))
    isempty(name) && error("The analysis needs a name")
    length(name) <= 100 || error("The analysis name is limited to 100 characters")
    overrides = get(body, :overrides, Dict{String,Any}())
    problem = _check_overrides(_study_config(study), overrides, "reference")
    isnothing(problem) || error(problem)

    doc = Dict{String,Any}(
        "id" => id,
        "name" => name,
        "created" => _stamp(),
        "source" => Dict{String,Any}(
            "runs" => runs,
            "table" => table,
            "filters" => params,
            "min_reads" => min_reads,
            "max_asvs" => max_asvs,
            "available_asvs" => available,
            "selection" => "highest total reads; ties broken by sequence"),
        "overrides" => overrides,
        "asv_count" => length(tips),
        "sample_count" => length(kept_labels),
        "counts_sha256" => counts_sha256,
        "warning" => "A tree inferred from short amplicon ASVs is approximate; interpret deep branches cautiously.",
    )
    _write_doc(_clad_doc_path(study, id), doc)
    nothing
end

function _cc_read_counts(study::String, id::String)
    doc = JSON3.read(read(_clad_counts_path(study, id), String))
    samples = string.(collect(doc.samples))
    tips = string.(collect(doc.tips))
    rows = collect(doc.counts)
    counts = zeros(Float64, length(rows), length(tips))
    for (i, row) in enumerate(rows)
        values = Float64.(collect(row))
        length(values) == length(tips) || error("Saved counts row $i has the wrong ASV count")
        counts[i, :] = values
    end
    counts, tips, samples, doc
end

function _cc_compute(study::String, id::String)
    doc = _read_doc(_clad_doc_path(study, id))
    isnothing(doc) && error("The Cladistics source document is unreadable")
    counts, tips, samples, counts_doc = _cc_read_counts(study, id)
    tree_text = read(_clad_files(study, id)["reference.treefile"], String)
    tree = CC.parse_newick(tree_text)
    analysed = CC.analyse_phylogeny(tree, counts, tips, samples)

    result = Dict{String,Any}(string(k) => v for (k, v) in pairs(analysed))
    # JSON arrays are explicitly row-major; do not rely on a serializer's
    # treatment of Julia's column-major Matrix.
    for key in ("unweighted_unifrac", "weighted_unifrac")
        result[key] = [collect(row) for row in eachrow(result[key])]
    end
    result["version"] = 1
    result["generated"] = _stamp()
    result["tree_sha256"] = bytes2hex(sha256(tree_text))
    result["counts_sha256"] = doc["counts_sha256"]
    result["normalisation"] = counts_doc.normalisation
    result["excluded_samples"] = counts_doc.excluded_samples
    result["weighted_unifrac_definition"] =
        "sum(branch * abs(a-b)) / sum(branch * (a+b)); clade relative abundances"
    result
end

function _cc_publish(study::String, id::String, name::String)
    source = _clad_files(study, id)["reference.treefile"]
    file = "$(_phylo_slug(name))-$id.treefile"
    destination = joinpath(_trees_dir(study), file)
    mkpath(dirname(destination))
    cp(source, destination * ".tmp"; force=true)
    mv(destination * ".tmp", destination; force=true)
    file
end

@get "/api/v1/studies/{study}/cladistics" function(req, study::String)
    err = _clad_request_error(study)
    isnothing(err) || return err
    root = _clad_root(study)
    isdir(root) || return json([])
    ids = filter(id -> _valid_phylo_id(id) && isfile(_clad_doc_path(study, id)), readdir(root))
    json(sort([_clad_summary(study, id) for id in ids]; by = a -> a.created, rev=true))
end

@post "/api/v1/studies/{study}/cladistics" function(req, study::String)
    err = _clad_request_error(study)
    isnothing(err) || return err
    body = try JSON3.read(String(req.body)) catch
        return json_error(400, "invalid_body", "Expected a JSON object")
    end
    body isa JSON3.Object || return json_error(400, "invalid_body", "Expected a JSON object")
    id = _new_phylo_id()
    try
        _cc_prepare!(study, id, body)
    catch e
        rm(_clad_dir(study, id); recursive=true, force=true)
        return json_error(400, "invalid_analysis", sprint(showerror, e))
    end

    doc = _read_doc(_clad_doc_path(study, id))
    name = string(doc["name"])
    overrides = get(doc, "overrides", nothing)
    job = _submit_phylo("cc:$study/$id"; study) do
        dir = _clad_dir(study, id)
        files = _clad_files(study, id)
        try
            Phylo.check_reference(files)
        catch e
            _fail_status!(dir, e)
            rethrow()
        end
        Phylo.run_workflow(Phylo.REFERENCE_STEPS, dir, files, _study_config(study);
            overrides,
            run = Dict{String,Any}("study" => study, "cladistics" => id, "name" => name,
                                   "counts_sha256" => doc["counts_sha256"]))
        try
            result = _cc_compute(study, id)
            _write_atomic(_clad_results_path(study, id), JSON3.write(result))
            latest = _read_doc(_clad_doc_path(study, id))
            latest["published"] = _cc_publish(study, id, name)
            latest["tree_sha256"] = result["tree_sha256"]
            _write_doc(_clad_doc_path(study, id), latest)
        catch e
            _fail_status!(dir, e)
            rethrow()
        end
    end
    json((; id, job = _job_to_namedtuple(job)))
end

@get "/api/v1/studies/{study}/cladistics/{id}" function(req, study::String, id::String)
    err = _clad_request_error(study, id)
    isnothing(err) || return err
    doc = _read_doc(_clad_doc_path(study, id))
    d = _workflow_detail(Phylo.REFERENCE_STEPS, _clad_dir(study, id), _clad_files(study, id),
                         _study_config(study), get(doc, "overrides", nothing), "cc:$study/$id")
    result = isfile(_clad_results_path(study, id)) ? _read_doc(_clad_results_path(study, id)) : nothing
    json((; doc, summary = _clad_summary(study, id), d..., result))
end

@get "/api/v1/studies/{study}/cladistics/{id}/log/{step}" function(req, study::String, id::String, step::String)
    err = _clad_request_error(study, id)
    isnothing(err) || return err
    _log_response(Phylo.REFERENCE_STEPS, _clad_dir(study, id), step)
end

@get "/api/v1/studies/{study}/cladistics/{id}/qc/{step}" function(req, study::String, id::String, step::String)
    err = _clad_request_error(study, id)
    isnothing(err) || return err
    _qc_response(Phylo.REFERENCE_STEPS, _clad_dir(study, id), step)
end

@delete "/api/v1/studies/{study}/cladistics/{id}" function(req, study::String, id::String)
    err = _clad_request_error(study, id)
    isnothing(err) || return err
    isnothing(_active_job("cc:$study/$id")) ||
        return json_error(409, "running", "The phylogeny is running; cancel its job first")
    doc = _read_doc(_clad_doc_path(study, id))
    published = get(doc, "published", nothing)
    if published isa AbstractString && _valid_tree_file(String(published))
        rm(joinpath(_trees_dir(study), String(published)); force=true)
        rm(_tree_view_path(study, String(published)); force=true)
    end
    rm(_clad_dir(study, id); recursive=true, force=true)
    json((; deleted = id))
end
