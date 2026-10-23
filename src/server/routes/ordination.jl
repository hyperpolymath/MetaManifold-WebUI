# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Routes:
#   GET  /api/v1/ordination/contract
#   POST /api/v1/studies/{study}/analysis/ordination
#   GET  /api/v1/studies/{study}/analysis/ordination/{id}

using JSON3, DataFrames, OrderedCollections
using ..CladeCumulus
using ..DerivedAnalyses
using ..RRuntime: RBusyError

const _ORDINATION_REQUEST_LIMIT = 16 * 1024 * 1024

_ordination_derived_dir(study::String) =
    joinpath(ServerState.projects_dir(), study, "derived_analyses", "ordination")

function _unique_ordination_sample_ids(samples::Vector{String}, run_labels::Vector{String})::Vector{String}
    length(unique(samples)) == length(samples) && return copy(samples)
    combined = ["$(run_labels[i]) / $(samples[i])" for i in eachindex(samples)]
    length(unique(combined)) == length(combined) && return combined
    ["$(combined[i]) #$i" for i in eachindex(combined)]
end

function _read_ordination_ijson(req::HTTP.Request)
    body_bytes = req.body isa AbstractString ? ncodeunits(req.body) : length(req.body)
    body_bytes <= _ORDINATION_REQUEST_LIMIT || return json_error(
        413, "request_too_large",
        "Ordination request exceeds the $(_ORDINATION_REQUEST_LIMIT)-byte limit")
    raw = req.body isa AbstractString ? String(req.body) : String(copy(req.body))
    parsed = try
        ijson_read(raw)
    catch e
        return json_error(400, "invalid_json",
            "Request body is not valid RFC 7493 I-JSON: $(sprint(showerror, e))")
    end
    parsed isa JSON3.Object || return json_error(400, "invalid_json",
        "Request body must be a JSON object")
    parsed
end

function _study_ordination_dict(study::String)::Dict{String,Any}
    resolved = _resolve_config(study)
    val(k, d) = begin
        entry = get(resolved, k, (; value=d, source="default"))
        entry isa NamedTuple ? entry.value : entry
    end
    Dict{String,Any}(
        "seed" => val("seed", 42),
        "analysis" => Dict{String,Any}(
            "ordination" => Dict{String,Any}(
                "method" => val("analysis.ordination.method", "none"),
                "formula" => val("analysis.ordination.formula", nothing),
                "distance" => val("analysis.ordination.distance", "bray"),
                "scaling" => val("analysis.ordination.scaling", 2),
                "permutations" => val("analysis.ordination.permutations", 999),
                "variance_partitioning" => val("analysis.ordination.variance_partitioning", false),
                "replacement_method" => val("analysis.ordination.replacement_method", "bayesian_multiplicative"),
                "replacement_delta" => val("analysis.ordination.replacement_delta", 0.65),
            ),
        ),
    )
end

function _extract_ordination_overrides(body::JSON3.Object)::Dict{String,Any}
    overrides = Dict{String,Any}()
    for key in ("method", "formula", "distance", "scaling", "permutations",
                "variance_partitioning", "replacement_method", "replacement_delta", "seed")
        sym = Symbol(key)
        if haskey(body, sym)
            v = body[sym]
            # Validate integer-typed fields against float tokens with fractional parts or Bool
            if key in ("scaling", "permutations", "seed") && !isnothing(v)
                (v isa Integer && !(v isa Bool)) || throw(ArgumentError(
                    "'$key' must be an integer, not $(typeof(v))"))
            elseif key == "variance_partitioning" && !isnothing(v)
                v isa Bool || throw(ArgumentError("'variance_partitioning' must be true or false"))
            end
            overrides[key] = _to_plain(v)
        end
    end
    overrides
end

function _attach_custom_covariates!(metadata::DataFrame, raw_covs, sample_ids::Vector{String})
    isnothing(raw_covs) && return String[]
    (raw_covs isa JSON3.Object || raw_covs isa AbstractDict) || throw(ArgumentError(
        "'covariates' must be a JSON object mapping covariate names to per-sample arrays or sample->value maps"))
    n = length(sample_ids)
    added = String[]
    reserved_cols = Set(["sample", "group", "run", "individual", "library_size", "log_library_size"])
    for (k_raw, v_raw) in pairs(raw_covs)
        col_name = String(k_raw)
        col_name in reserved_cols && throw(ArgumentError(
            "Custom covariate '$col_name' collides with built-in sample metadata column"))
        Ordination.validate_formula_syntax("~ $col_name")
        vals = if v_raw isa AbstractVector
            length(v_raw) == n || throw(ArgumentError(
                "Custom covariate '$col_name' has length $(length(v_raw)), expected $n"))
            collect(v_raw)
        elseif v_raw isa JSON3.Object || v_raw isa AbstractDict
            [haskey(v_raw, s) ? v_raw[s] :
             haskey(v_raw, Symbol(s)) ? v_raw[Symbol(s)] :
             throw(ArgumentError("Custom covariate '$col_name' is missing value for sample '$s'"))
             for s in sample_ids]
        else
            throw(ArgumentError("Custom covariate '$col_name' must be an array or sample->value object"))
        end
        if all(x -> x isa Real && !(x isa Bool), vals)
            num_vec = Float64[]
            for x in vals
                fx = Float64(x)
                isfinite(fx) || throw(ArgumentError("Custom covariate '$col_name' contains non-finite value"))
                push!(num_vec, fx)
            end
            metadata[!, col_name] = num_vec
        else
            str_vec = String[]
            for x in vals
                (isnothing(x) || ismissing(x)) && throw(ArgumentError(
                    "Custom covariate '$col_name' contains null/missing value"))
                sx = String(strip(string(x)))
                isempty(sx) && throw(ArgumentError(
                    "Custom covariate '$col_name' contains empty string value"))
                push!(str_vec, sx)
            end
            metadata[!, col_name] = str_vec
        end
        push!(added, col_name)
    end
    sort!(added)
    added
end

function _resolve_study_unifrac_tree(study::String, body::JSON3.Object)
    if haskey(body, :tree_newick) && !isnothing(body[:tree_newick])
        nwk = String(strip(string(body[:tree_newick])))
        isempty(nwk) && throw(ArgumentError("'tree_newick' cannot be empty"))
        idx_tree = CladeCumulus.parse_phylogenetic_tree(nwk)
        return (CladeCumulus.parse_newick(nwk), idx_tree.tips, "inline_newick")
    end
    req_id = haskey(body, :cladistics_id) && !isnothing(body[:cladistics_id]) ?
             strip(string(body[:cladistics_id])) : nothing
    if !isnothing(req_id) && !isempty(req_id)
        _valid_phylo_id(req_id) || throw(ArgumentError(
            "cladistics_id must be an 8-character lowercase hex identifier"))
        tree_file = _clad_files(study, req_id)["reference.treefile"]
        isfile(tree_file) || throw(ArgumentError(
            "Cladistics analysis '$req_id' has no completed ASV tree yet"))
        nwk = read(tree_file, String)
        idx_tree = CladeCumulus.parse_phylogenetic_tree(nwk)
        return (CladeCumulus.parse_newick(nwk), idx_tree.tips, "cladistics:$req_id")
    end
    root = _clad_root(study)
    if isdir(root)
        candidates = String[]
        for id in readdir(root)
            _valid_phylo_id(id) || continue
            isfile(_clad_files(study, id)["reference.treefile"]) && push!(candidates, id)
        end
        if !isempty(candidates)
            sort!(candidates; by = id -> _clad_summary(study, id).created, rev=true)
            best_id = first(candidates)
            tree_file = _clad_files(study, best_id)["reference.treefile"]
            nwk = read(tree_file, String)
            idx_tree = CladeCumulus.parse_phylogenetic_tree(nwk)
            return (CladeCumulus.parse_newick(nwk), idx_tree.tips, "cladistics:$best_id")
        end
    end
    throw(ArgumentError(
        "UniFrac constrained ordination requires an ASV phylogenetic tree; build one in the study's Cladistics tab first or pass 'cladistics_id' / 'tree_newick'"))
end

function _serializable_ordination_payload(res, available_covariates::Vector{String},
                                          runtime_estimate)
    Dict{String,Any}(
        "method" => res.method,
        "distance" => res.distance,
        "scaling" => res.scaling,
        "formula" => res.formula,
        "constrained_terms" => res.constrained_terms,
        "condition_terms" => res.condition_terms,
        "available_covariates" => available_covariates,
        "n_samples" => res.n_samples,
        "n_features" => res.n_features,
        "total_inertia" => res.total_inertia,
        "conditioned_inertia" => res.conditioned_inertia,
        "constrained_inertia" => res.constrained_inertia,
        "unconstrained_inertia" => res.unconstrained_inertia,
        "imaginary_inertia" => res.imaginary_inertia,
        "conditioned_proportion" => res.conditioned_proportion,
        "constrained_proportion" => res.constrained_proportion,
        "unconstrained_proportion" => res.unconstrained_proportion,
        "r2" => res.r2,
        "adj_r2" => res.adj_r2,
        "axis_names" => res.axis_names,
        "axis_labels" => res.axis_labels,
        "constrained_eigenvalues" => res.constrained_eigenvalues,
        "unconstrained_eigenvalues" => res.unconstrained_eigenvalues,
        "sites" => res.sites,
        "biplot_arrows" => res.biplot_arrows,
        "centroids" => res.centroids,
        "top_feature_scores" => res.top_feature_scores,
        "omnibus_test" => res.omnibus_test,
        "term_tests" => res.term_tests,
        "marginal_tests" => res.marginal_tests,
        "axis_tests" => res.axis_tests,
        "variance_partitioning" => res.variance_partitioning,
        "cautions" => res.cautions,
        "runtime_estimate" => runtime_estimate,
        "provenance" => res.provenance,
    )
end

function _opt_ordination_bool(body::JSON3.Object, key::Symbol, default::Bool)::Bool
    (!haskey(body, key) || isnothing(body[key])) && return default
    v = body[key]
    v isa Bool || throw(ArgumentError("'$key' must be true or false"))
    v
end

@get "/api/v1/ordination/contract" function(req)
    jcs_json(Ordination.load_ordination_contract())
end

@get "/api/v1/studies/{study}/analysis/ordination/{id}" function(req, study::String, id::String)
    _study_exists(study) || return json_error(404, "study_not_found", "Study '$study' not found")
    try
        rec = DerivedAnalyses.load_derived_analysis(_ordination_derived_dir(study), id)
        return jcs_json(rec)
    catch err
        err isa DerivedAnalyses.DerivedAnalysisError && return json_error(
            err.code == "not_found" ? 404 : err.code == "conflict" ? 409 : 400,
            "derived_analysis_$(err.code)", err.reason)
        rethrow()
    end
end

@post "/api/v1/studies/{study}/analysis/ordination" function(req, study::String)
    _study_exists(study) || return json_error(404, "study_not_found", "Study '$study' not found")
    body = _read_ordination_ijson(req)
    body isa HTTP.Response && return body

    cfg = try
        overrides = _extract_ordination_overrides(body)
        Ordination.ordination_config_from_dict(_study_ordination_dict(study); overrides)
    catch err
        err isa ArgumentError && return json_error(400, "invalid_ordination_config", err.msg)
        rethrow()
    end

    if cfg.ordination_method === :none
        return json_error(400, "invalid_ordination_config",
            "Constrained ordination method is 'none'; choose 'rda', 'cca', 'cap', or 'dbrda'")
    end

    runs_spec = get(body, :runs, [])
    (runs_spec isa AbstractVector && !isempty(runs_spec)) ||
        return json_error(400, "no_runs", "Provide at least one run in 'runs'")

    table = String(strip(string(get(body, :table, "merged"))))
    isempty(table) && return json_error(400, "invalid_table", "Table name cannot be empty")
    (aggregate, test_axes, show_centroids, show_features, persist_record) = try
        (
            _opt_ordination_bool(body, :aggregate, false),
            _opt_ordination_bool(body, :test_axes, false),
            _opt_ordination_bool(body, :show_centroids, true),
            _opt_ordination_bool(body, :show_features, false),
            _opt_ordination_bool(body, :persist, false),
        )
    catch err
        err isa ArgumentError && return json_error(400, "invalid_request", err.msg)
        rethrow()
    end
    params = try
        _body_filter_params(body)
    catch err
        err isa BadRequest && return json_error(400, "bad_request", err.message)
        rethrow()
    end

    run_data, group_labels, run_labels, individual_ids, missing_seq = try
        _collect_cross_run_asvs(study, runs_spec, table, params; aggregate)
    catch err
        err isa BadRequest && return json_error(400, "bad_request", err.message)
        rethrow()
    end
    missing_seq && return json_error(400, "no_sequence_data",
        "Table '$table' does not contain a DNA sequence column required for cross-run ordination")
    isempty(run_data) && return json_error(400, "no_data", "No count data found for the selected runs")

    raw_mat, raw_samples, sequences, _ = combined_asv_counts_across_runs(run_data)
    (filtered, kept, _) = _drop_empty_samples(raw_mat, raw_samples, group_labels, run_labels, individual_ids)
    mat, raw_samples, group_labels, run_labels, individual_ids = filtered
    kept < 3 && return json_error(400, "too_few_samples",
        "Constrained ordination requires at least 3 non-empty samples (found $kept)")

    (norm_method, norm_depth, default_beta_transform) = _beta_normalisation(study)
    use_raw_counts = cfg.ordination_distance in (:aitchison, :unweighted_unifrac, :weighted_unifrac)
    if !use_raw_counts && norm_method != "none"
        eff_depth = _resolve_cross_run_depth(norm_method, norm_depth, (mat,))
        (filtered_norm, nkept) = _apply_normalisation(
            mat, norm_method, eff_depth, cfg.seed,
            raw_samples, group_labels, run_labels, individual_ids)
        mat, raw_samples, group_labels, run_labels, individual_ids = filtered_norm
        nkept < 3 && return json_error(400, "too_few_samples",
            "Constrained ordination requires at least 3 samples after '$norm_method' depth normalisation (found $nkept)")
    end

    beta_transform = if haskey(body, :beta_transform) && !isnothing(body[:beta_transform])
        String(strip(string(body[:beta_transform])))
    elseif cfg.ordination_distance in (:aitchison, :chisq, :unweighted_unifrac, :weighted_unifrac)
        "none"
    else
        default_beta_transform
    end

    sample_ids = _unique_ordination_sample_ids(raw_samples, run_labels)
    lib_sizes = Float64[sum(@view mat[i, :]) for i in axes(mat, 1)]
    log_lib_sizes = Float64[log10(max(v, 1.0)) for v in lib_sizes]

    metadata = DataFrame(
        sample           = sample_ids,
        group            = group_labels,
        run              = run_labels,
        individual       = individual_ids,
        library_size     = lib_sizes,
        log_library_size = log_lib_sizes,
    )
    custom_cols = try
        _attach_custom_covariates!(metadata, get(body, :covariates, nothing), sample_ids)
    catch err
        err isa ArgumentError && return json_error(400, "invalid_covariates", err.msg)
        rethrow()
    end

    # Determine explicit or sensible study default formula before invoking R
    effective_cfg = if !isnothing(cfg.ordination_formula)
        cfg
    else
        auto_rhs = if length(unique(group_labels)) >= 2
            "~ group"
        elseif length(unique(run_labels)) >= 2
            "~ run"
        elseif !isempty(custom_cols)
            "~ " * join(custom_cols, " + ")
        else
            nothing
        end
        isnothing(auto_rhs) ? cfg : Ordination.OrdinationConfig(;
            ordination_method     = cfg.ordination_method,
            ordination_formula    = auto_rhs,
            ordination_distance   = cfg.ordination_distance,
            ordination_scaling    = cfg.ordination_scaling,
            permutations          = cfg.permutations,
            variance_partitioning = cfg.variance_partitioning,
            replacement_method    = cfg.replacement_method,
            replacement_delta     = cfg.replacement_delta,
            seed                  = cfg.seed,
        )
    end

    # Pre-validate formula against metadata before touching R
    parsed_formula = try
        Ordination.parse_ordination_formula(effective_cfg.ordination_formula, metadata)
    catch err
        err isa ArgumentError && return json_error(400, "invalid_ordination_formula", err.msg)
        rethrow()
    end

    available_covariates = String[]
    for c in names(metadata)
        c == "sample" && continue
        length(unique(metadata[!, c])) >= 2 && push!(available_covariates, c)
    end

    # Resolve UniFrac distance matrix if requested
    dist_mat = nothing
    tree_source = nothing
    feature_ids = CladeCumulus.asv_tip_name.(sequences)
    if effective_cfg.ordination_distance in (:unweighted_unifrac, :weighted_unifrac)
        phylo_node, tip_map, tree_src = try
            _resolve_study_unifrac_tree(study, body)
        catch err
            err isa ArgumentError && return json_error(400, "missing_phylogeny", err.msg)
            rethrow()
        end
        tree_source = tree_src
        on_tree = [j for j in eachindex(feature_ids) if haskey(tip_map, feature_ids[j])]
        length(on_tree) >= 2 || return json_error(400, "insufficient_tree_overlap",
            "Fewer than 2 ASVs from table '$table' match tips on phylogeny '$tree_src' (matched $(length(on_tree)) of $(length(feature_ids)))")
        metric_sym = effective_cfg.ordination_distance === :unweighted_unifrac ? :unweighted : :weighted
        dist_mat = try
            CladeCumulus.unifrac_matrix(
                permutedims(mat[:, on_tree]),
                feature_ids[on_tree],
                sample_ids,
                phylo_node;
                metric = metric_sym,
                totals = lib_sizes,
            )
        catch err
            err isa ArgumentError && return json_error(400, "unifrac_failed", err.msg)
            rethrow()
        end
    end

    !r_available() && return json_error(503, "r_unavailable",
        "R/vegan is not available - install R and the pinned vegan package")

    runtime_est = Ordination.estimate_ordination_seconds(;
        method = effective_cfg.ordination_method,
        distance = effective_cfg.ordination_distance,
        n_samples = size(mat, 1),
        n_features = size(mat, 2),
        permutations = effective_cfg.permutations,
        n_terms = length(parsed_formula.constrained_terms),
        variance_partitioning = effective_cfg.variance_partitioning,
    )

    ord_res = try
        Ordination.run_constrained_ordination(
            mat,
            metadata,
            effective_cfg;
            sample_ids = sample_ids,
            feature_ids = feature_ids,
            beta_transform = beta_transform,
            distance_matrix = dist_mat,
            blocks = individual_ids,
            test_axes = test_axes,
        )
    catch err
        err isa Ordination.VeganUnavailable && return json_error(503, "vegan_unavailable", sprint(showerror, err))
        err isa Differential.ZCompositionsUnavailable && return json_error(503, "zcompositions_unavailable", sprint(showerror, err))
        err isa RBusyError && return json_error(503, "r_busy", "R runtime is busy; retry shortly")
        err isa ArgumentError && return json_error(400, "ordination_refused", err.msg)
        rethrow()
    end

    if !isnothing(tree_source)
        ord_res.provenance["phylogeny_source"] = tree_source
    end

    unique_groups = unique(group_labels)
    unique_runs = unique(run_labels)
    colour_by = length(unique_groups) >= 2 ? group_labels : run_labels
    shape_by  = (length(unique_groups) >= 2 && length(unique_runs) >= 2 && group_labels != run_labels) ?
                run_labels : nothing

    biplot = Ordination.ordination_biplot_chart(
        ord_res;
        colour_by = colour_by,
        shape_by = shape_by,
        show_centroids = show_centroids,
        show_features = show_features,
    )

    payload = _serializable_ordination_payload(ord_res, available_covariates, runtime_est)
    payload["biplot"] = biplot

    if persist_record
        src_doc = Dict{String,Any}(
            "study" => study,
            "table" => table,
            "aggregate" => aggregate,
            "n_samples" => ord_res.n_samples,
            "n_features" => ord_res.n_features,
        )
        cfg_doc = ord_res.provenance
        result_doc = copy(payload)
        saved = try
            DerivedAnalyses.persist_derived_analysis(
                _ordination_derived_dir(study);
                source = src_doc,
                config = cfg_doc,
                result = result_doc,
            )
        catch err
            err isa DerivedAnalyses.DerivedAnalysisError && return json_error(
                err.code == "conflict" ? 409 : err.code == "resource_limit" ? 413 : 500,
                "derived_analysis_$(err.code)", err.reason)
            rethrow()
        end
        payload["artifact"] = Dict{String,Any}(
            "analysis_id" => saved.id,
            "created" => saved.created,
        )
    end

    jcs_json(payload)
end
