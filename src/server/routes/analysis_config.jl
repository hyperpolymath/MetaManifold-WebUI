# SPDX-License-Identifier: AGPL-3.0-only
# Routes for AnalysisConfig layer — safe, explicit, versioned
# Implements: NB GLM, CLR/ILR+Gaussian LM, logistic in v1; BH mandatory; DANGER banner; DOI-ready bundles

using OrderedCollections
# `:` form — the dotted form binds the exported `struct AnalysisConfig`,
# not the same-named submodule, so every `AnalysisConfig.x` below would FieldError.
using MetaManifold: AnalysisConfig
using MetaManifold.Epistemic
using MetaManifold.CladeCumulus

# Durable per-study records; publication journals retain independent snapshots.
using MetaManifold: AnalysisStore, DOIBundles, DOIStorage
function _analysis_store_dir(study::String)
    _valid_name(study) || throw(DOIStorage.PublicationError(400, "invalid_study", "Invalid study name."))
    project = joinpath(ServerState.projects_dir(), study)
    islink(project) && throw(DOIStorage.PublicationError(403, "unsafe_storage", "Analysis storage must not be a symlink."))
    joinpath(project, ".analysis")
end
_get_study_configs(study::String) = AnalysisStore.configs(_analysis_store_dir(study))
_get_study_results(study::String) = AnalysisStore.results(_analysis_store_dir(study))

# List available metadata columns for a study (from first run's merged table or from study config)
function _available_metadata_columns(study::String)::Vector{String}
    # Try to get from study's runs — for now return a default set plus any custom from config
    # In real implementation, would read from sample metadata CSV or DuckDB
    default_cols = ["group", "batch", "age", "sex", "disease", "sample_id", "tissue", "location"]
    try
        resolved = _resolve_config(study)
        # If analysis.metadata_columns is configured, use that as available?
        # For now just return default + any configured
        return default_cols
    catch
        return default_cols
    end
end

# --------------------------------------------------------------------------
# AnalysisConfig CRUD
# --------------------------------------------------------------------------

@post "/api/v1/studies/{study}/analysis-config" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found", "Study '$study' not found")

    body = JSON3.read(String(req.body), Dict{String,Any})

    # Explicit parsing — no silent defaults
    method = get(body, "method", nothing)
    isnothing(method) && return json_error(400, "missing_method", "method is required (nb_glm, clr_lm, ilr_lm, logistic)")

    formula = get(body, "formula", nothing)
    isnothing(formula) && return json_error(400, "missing_formula", "formula is required, e.g. '~ group'")

    metadata_columns = get(body, "metadata_columns", nothing)
    isnothing(metadata_columns) && return json_error(400, "missing_metadata_columns", "metadata_columns is required, explicit list")

    # Normalization
    norm_body = get(body, "normalization", Dict{String,Any}())
    norm_method = get(norm_body, "method", "none")

    # Build config via Julia types for heavy validation
    try
        normalization = AnalysisConfig.NormalizationConfig(
            method=String(norm_method),
            pseudocount=Float64(get(norm_body, "pseudocount", 0.5)),
            epsilon=Float64(get(norm_body, "epsilon", 1e-6)),
            zero_policy=String(get(norm_body, "zero_policy", "pseudocount")),
            ilr_basis=get(norm_body, "ilr_basis", nothing) isa Nothing ? nothing : String(get(norm_body, "ilr_basis", nothing)),
            multiplicative_replacement_delta=get(norm_body, "multiplicative_replacement_delta", nothing) isa Nothing ? nothing : Float64(get(norm_body, "multiplicative_replacement_delta", nothing)),
            # The declared scaling parameters travel with the request, are validated by the
            # same constructor the rest of the configuration uses, and end up in the config
            # hash — a run that asked for a different CSS quantile is a different run.
            css_quantile=Float64(get(norm_body, "css_quantile", 0.75)),
            tmm_ref_column=get(norm_body, "tmm_ref_column", nothing) isa Nothing ? nothing : String(get(norm_body, "tmm_ref_column", nothing)),
            tmm_log_ratio_trim=Float64(get(norm_body, "tmm_log_ratio_trim", 0.3)),
            tmm_sum_trim=Float64(get(norm_body, "tmm_sum_trim", 0.05)),
        )

        corr_body = get(body, "correction", Dict{String,Any}())
        correction = AnalysisConfig.CorrectionConfig(
            method=String(get(corr_body, "method", "BH")),
            alpha=Float64(get(corr_body, "alpha", 0.05)),
            allow_no_correction=Bool(get(corr_body, "allow_no_correction", false)),
            acknowledgment_token=get(corr_body, "acknowledgment_token", nothing) isa Nothing ? nothing : String(get(corr_body, "acknowledgment_token", nothing)),
        )

        adv_body = get(body, "advanced", Dict{String,Any}())
        advanced = AnalysisConfig.AdvancedOverrides(
            dispersion_method=String(get(adv_body, "dispersion_method", "parametric")),
            zero_handling=String(get(adv_body, "zero_handling", "pseudocount")),
            zero_policy=String(get(adv_body, "zero_policy", get(adv_body, "zero_handling", "pseudocount"))),
            pseudocount=Float64(get(adv_body, "pseudocount", 0.5)),
            epsilon=Float64(get(adv_body, "epsilon", 1e-6)),
            min_prevalence=Float64(get(adv_body, "min_prevalence", 0.1)),
            min_abundance=Float64(get(adv_body, "min_abundance", 0.0)),
            max_features=get(adv_body, "max_features", nothing) isa Nothing ? nothing : Int(get(adv_body, "max_features", nothing)),
            min_samples_per_group=Int(get(adv_body, "min_samples_per_group", 3)),
            robust=Bool(get(adv_body, "robust", false)),
            acknowledgment_token=get(adv_body, "acknowledgment_token", nothing) isa Nothing ? nothing : String(get(adv_body, "acknowledgment_token", nothing)),
            # ILR basis inputs (issue #20). Validated, and cross-checked against
            # normalization.ilr_basis, by the same constructors as everything else.
            ilr_phylo_tree_path=get(adv_body, "ilr_phylo_tree_path", nothing) isa Nothing ? nothing : String(get(adv_body, "ilr_phylo_tree_path", nothing)),
            ilr_sbp_matrix_path=get(adv_body, "ilr_sbp_matrix_path", nothing) isa Nothing ? nothing : String(get(adv_body, "ilr_sbp_matrix_path", nothing)),
            ilr_balance_dendrogram_method=get(adv_body, "ilr_balance_dendrogram_method", nothing) isa Nothing ? nothing : String(get(adv_body, "ilr_balance_dendrogram_method", nothing)),
            ilr_part_weights=String(get(adv_body, "ilr_part_weights", "uniform")),
            ilr_balance_weights=String(get(adv_body, "ilr_balance_weights", "uniform")),
            ilr_sbp_history=String[String(h) for h in get(adv_body, "ilr_sbp_history", String[])],
        )

        cfg = AnalysisConfig.AnalysisConfigStruct(
            method=String(method),
            formula=String(formula),
            outcome_column=get(body, "outcome_column", nothing) isa Nothing ? nothing : String(get(body, "outcome_column", nothing)),
            metadata_columns=Vector{String}(String.(metadata_columns)),
            normalization=normalization,
            correction=correction,
            advanced=advanced,
            created_by=String(get(body, "created_by", "anonymous")),
        )

        # Context-sensitive validation with available columns
        available_cols = _available_metadata_columns(study)
        errors = AnalysisConfig.validate_config(cfg, available_cols; strict=false)
        if !isempty(errors)
            return json_error(400, "validation_failed", "AnalysisConfig validation failed"; detail=join(errors, "\n"))
        end

        # Check DANGER
        danger = AnalysisConfig.danger_banner(cfg)
        if !isnothing(danger) && !cfg.correction.allow_no_correction && cfg.advanced.zero_handling != "refuse"
            # If dangerous but no acknowledgment, we still allow creation but flag
            @warn "DANGEROUS config created" study id=cfg.id method=cfg.method danger=danger
        end

        # Store
        AnalysisStore.save_config!(_analysis_store_dir(study), cfg)

        # Return with danger banner if any
        resp = OrderedDict{String,Any}(
            "config" => JSON3.read(AnalysisConfig.to_json(cfg)),
            "danger_banner" => danger,
            "is_dangerous" => AnalysisConfig.is_dangerous(cfg),
            "help" => Dict(
                "method" => AnalysisConfig.context_help("method"),
                "formula" => AnalysisConfig.context_help("formula"),
            ),
        )

        HTTP.Response(200, ["Content-Type" => "application/json"], body=JSON3.write(resp))

    catch e
        if e isa ArgumentError
            return json_error(400, "invalid_config", "Invalid AnalysisConfig: $(e.msg)"; detail=sprint(showerror, e))
        else
            @error "Failed to create AnalysisConfig" exception=(e, catch_backtrace())
            return json_error(500, "internal_error", "Failed to create AnalysisConfig: $(sprint(showerror, e))")
        end
    end
end

@get "/api/v1/studies/{study}/analysis-config" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found", "Study '$study' not found")

    study_configs = _get_study_configs(study)
    configs = [JSON3.read(AnalysisConfig.to_json(c)) for c in values(study_configs)]

    json(OrderedDict(
        "study" => study,
        "count" => length(configs),
        "configs" => configs,
    ))
end

@get "/api/v1/studies/{study}/analysis-config/{id}" function(req, study::String, id::String)
    study in _study_names() || return json_error(404, "study_not_found", "Study '$study' not found")

    study_configs = _get_study_configs(study)
    haskey(study_configs, id) || return json_error(404, "config_not_found", "AnalysisConfig '$id' not found in study '$study'")

    cfg = study_configs[id]

    format = get(HTTP.queryparams(req), "format", "json") # json, nickel, deed

    if format == "nickel"
        HTTP.Response(200, ["Content-Type" => "text/plain"], body=AnalysisConfig.to_nickel(cfg))
    elseif format == "deed"
        HTTP.Response(200, ["Content-Type" => "text/plain"], body=AnalysisConfig.to_deed(cfg))
    else
        json(OrderedDict(
            "config" => JSON3.read(AnalysisConfig.to_json(cfg)),
            "nickel" => AnalysisConfig.to_nickel(cfg),
            "deed" => AnalysisConfig.to_deed(cfg),
            "danger_banner" => AnalysisConfig.danger_banner(cfg),
            "is_dangerous" => AnalysisConfig.is_dangerous(cfg),
        ))
    end
end

@delete "/api/v1/studies/{study}/analysis-config/{id}" function(req, study::String, id::String)
    study in _study_names() || return json_error(404, "study_not_found", "Study '$study' not found")

    haskey(_get_study_configs(study), id) || return json_error(404, "config_not_found", "AnalysisConfig '$id' not found")
    # Keep reviewed config identities addressable for both drafts and citations.
    any(p -> p["binding"]["config_id"] == id, MetaManifold.DOIPublications.publications(_doi_store_dir(study))) &&
        return json_error(409, "config_has_publication", "This configuration has a DOI publication journal and cannot be deleted")
    AnalysisStore.delete_config!(_analysis_store_dir(study), id)

    json(OrderedDict("deleted" => id))
end

@post "/api/v1/studies/{study}/analysis-config/{id}/validate" function(req, study::String, id::String)
    study in _study_names() || return json_error(404, "study_not_found", "Study '$study' not found")

    study_configs = _get_study_configs(study)
    haskey(study_configs, id) || return json_error(404, "config_not_found", "AnalysisConfig '$id' not found")

    cfg = study_configs[id]
    available_cols = _available_metadata_columns(study)

    errors = AnalysisConfig.validate_config(cfg, available_cols; strict=false)

    json(OrderedDict(
        "id" => id,
        "valid" => isempty(errors),
        "errors" => errors,
        "is_dangerous" => AnalysisConfig.is_dangerous(cfg),
        "danger_banner" => AnalysisConfig.danger_banner(cfg),
    ))
end

@post "/api/v1/studies/{study}/analysis-config/{id}/run" function(req, study::String, id::String)
    study in _study_names() || return json_error(404, "study_not_found", "Study '$study' not found")

    study_configs = _get_study_configs(study)
    haskey(study_configs, id) || return json_error(404, "config_not_found", "AnalysisConfig '$id' not found")

    cfg = study_configs[id]

    # For v1, we implement a mock run that returns fake results but with proper provenance
    # Real implementation would call R via RCall for NB GLM etc.

    body = JSON3.read(String(req.body), Dict{String,Any})
    table = get(body, "table", "merged")

    # Simulate analysis — in real, would:
    # - Load counts from DuckDB
    # - Apply normalization (size_factors, CLR, ILR)
    # - Run method via R (DESeq2, lm, glm)
    # - BH correction mandatory
    # - Return results with hash chain

    # For now, return mock results with proper structure
    mock_results = OrderedDict{String,Any}()
    # Would be populated from real analysis

    result = AnalysisConfig.AnalysisResult(
        config_id=cfg.id,
        config_hash=cfg.hash,
        method=cfg.method,
        results=mock_results,
        provenance=OrderedDict{String,Any}(
            "study" => study,
            "table" => table,
            "config_id" => cfg.id,
            "config_hash" => cfg.hash,
            "method" => AnalysisConfig.METHOD_TO_STRING[cfg.method],
            "mock" => true,
            "note" => "Mock result — real implementation requires R packages DESeq2, compositions, etc. This is v1 scaffold with provenance chain intact.",
        ),
    )

    AnalysisStore.save_result!(_analysis_store_dir(study), result)

    json(OrderedDict(
        "result" => OrderedDict(
            "id" => result.id,
            "config_id" => result.config_id,
            "config_hash" => result.config_hash,
            "method" => AnalysisConfig.METHOD_TO_STRING[result.method],
            "results" => result.results,
            "provenance" => result.provenance,
            "hash" => result.hash,
        ),
        "config" => JSON3.read(AnalysisConfig.to_json(cfg)),
        "danger_banner" => AnalysisConfig.danger_banner(cfg),
    ))
end

@post "/api/v1/studies/{study}/analysis-config/{id}/doi-bundle" function(req, study::String, id::String)
    study in _study_names() || return json_error(404, "study_not_found", "Study '$study' not found")

    study_configs = _get_study_configs(study)
    haskey(study_configs, id) || return json_error(404, "config_not_found", "AnalysisConfig '$id' not found")

    cfg = study_configs[id]

    body = JSON3.read(String(req.body), Dict{String,Any})
    authors = Vector{String}(String.(get(body, "authors", ["Anonymous"])))
    title = String(get(body, "title", "MetaManifold Analysis Bundle for $study"))
    license = String(get(body, "license", "CC-BY-4.0"))

    # Explicit selection only: never bind a publication to a moving "latest" result.
    result_id = get(body, "result_id", nothing)
    study_results = _get_study_results(study)
    !isnothing(result_id) && !haskey(study_results, result_id) &&
        return json_error(404, "result_not_found", "Selected analysis result was not found")
    selected_result = isnothing(result_id) ? nothing : study_results[result_id]
    try
        mktempdir() do tmpdir
            bundle_dir = joinpath(tmpdir, "bundle")
            AnalysisConfig.create_doi_bundle(cfg, selected_result, bundle_dir; authors, title, license,
                description=String(get(body, "description", "Analysis configuration export")))
            zip_path = joinpath(tmpdir, "bundle.zip")
            DOIBundles.archive_bundle(bundle_dir, zip_path)
            HTTP.Response(200, ["Content-Type" => "application/zip", "Cache-Control" => "no-store",
                "Content-Disposition" => "attachment; filename=\"metamanifold-doi-bundle.zip\""]; body=read(zip_path))
        end
    catch e
        if e isa DOIStorage.PublicationError
            return json_error(e.status, e.code, e.message)
        elseif e isa ArgumentError
            return json_error(422, "invalid_bundle", "The result does not belong to this exact configuration or the bundle is invalid")
        end
        return json_error(500, "bundle_failed", "Could not create the DOI bundle; no temporary path is returned")
    end
end

# --------------------------------------------------------------------------
# CladeCumulus routes
# --------------------------------------------------------------------------

@post "/api/v1/studies/{study}/clade-cumulus/tree" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found", "Study '$study' not found")

    body = JSON3.read(String(req.body), Dict{String,Any})
    table = get(body, "table", "merged")
    runs_spec = get(body, "runs", [])

    # For now, build a mock tree from first run's merged table
    # Real implementation would query DuckDB for taxonomy + counts + avec_fibre + epistemic_status

    # Mock rows for demonstration
    mock_rows = [
        Dict{String,Any}("Domain" => "Bacteria", "Phylum" => "Firmicutes", "Class" => "Bacilli", "Order" => "Lactobacillales", "Family" => "Lactobacillaceae", "Genus" => "Lactobacillus", "Species" => "Lactobacillus crispatus", "total" => 150.0, "avec_fibre" => true, "epistemic_status" => "present_in_every_admissible_world", "residual_count" => 2),
        Dict{String,Any}("Domain" => "Bacteria", "Phylum" => "Firmicutes", "Class" => "Bacilli", "Order" => "Lactobacillales", "Family" => "Streptococcaceae", "Genus" => "Streptococcus", "Species" => "Streptococcus mitis", "total" => 80.0, "avec_fibre" => true, "epistemic_status" => "present_in_some_admissible_world", "residual_count" => 5),
        Dict{String,Any}("Domain" => "Bacteria", "Phylum" => "Bacteroidetes", "Class" => "Bacteroidia", "Order" => "Bacteroidales", "Family" => "Bacteroidaceae", "Genus" => "Bacteroides", "Species" => "Bacteroides vulgatus", "total" => 200.0, "avec_fibre" => false, "epistemic_status" => "unknown", "residual_count" => 0),
        Dict{String,Any}("Domain" => "Eukaryota", "Supergroup" => "TSAR", "Division" => "Alveolata", "Class" => "Aconoidasida", "Order" => "Piroplasmida", "Family" => "Babesiidae", "Genus" => "Babesia", "Species" => "Babesia microti", "total" => 30.0, "avec_fibre" => true, "epistemic_status" => "present_in_every_admissible_world", "residual_count" => 1),
    ]

    tree = CladeCumulus.build_clade_tree(mock_rows)

    json(OrderedDict(
        "study" => study,
        "table" => table,
        "tree" => JSON3.read(CladeCumulus.to_json(tree)),
        "plotly" => CladeCumulus.to_plotly_tree(tree),
        "note" => "Mock tree — real implementation queries DuckDB for taxonomy + avec_fibre + epistemic_status + residual_count, computes cumulative frequencies bottom-up",
    ))
end

@post "/api/v1/studies/{study}/clade-cumulus/validate-drag" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found", "Study '$study' not found")

    body = JSON3.read(String(req.body), Dict{String,Any})
    dragged_id = get(body, "dragged_id", nothing)
    target_parent_id = get(body, "target_parent_id", nothing)
    evidence = get(body, "evidence", Dict{String,Any}())

    isnothing(dragged_id) && return json_error(400, "missing_dragged_id", "dragged_id required")
    isnothing(target_parent_id) && return json_error(400, "missing_target", "target_parent_id required")

    # For demo, build mock tree and validate
    mock_rows = [
        Dict{String,Any}("Domain" => "Bacteria", "Genus" => "Lactobacillus", "total" => 100.0, "avec_fibre" => true, "epistemic_status" => "present_in_every_admissible_world", "residual_count" => 1),
        Dict{String,Any}("Domain" => "Bacteria", "Genus" => "Bacteroides", "total" => 200.0, "avec_fibre" => false, "epistemic_status" => "unknown", "residual_count" => 0),
    ]
    tree = CladeCumulus.build_clade_tree(mock_rows)

    # Find actual ids — in mock, ids are like "root|Domain:Bacteria|Genus:Lactobacillus"
    # For simplicity, if dragged_id is label, find by label
    dragged_node_id = String(dragged_id)
    target_id = String(target_parent_id)

    # Try to resolve label to id if needed
    if !haskey(tree.nodes, dragged_node_id)
        for (id, node) in tree.nodes
            if node.label == dragged_node_id
                dragged_node_id = id
                break
            end
        end
    end
    if !haskey(tree.nodes, target_id)
        for (id, node) in tree.nodes
            if node.label == target_id
                target_id = id
                break
            end
        end
    end

    if !haskey(tree.nodes, dragged_node_id) || !haskey(tree.nodes, target_id)
        # If not in mock tree, try generic validation based on evidence
        # For live validation, we need avec_fibre and epistemic_status from evidence
        avec = get(evidence, "avec_fibre", false) == true
        status = get(evidence, "epistemic_status", "unknown")

        if !avec
            return json(OrderedDict("valid" => false, "message" => "Cannot move: sans fibre (no semantic fibre). Needs avec_fibre=true."))
        end
        if status != "present_in_every_admissible_world"
            return json(OrderedDict("valid" => false, "message" => "Cannot move: not present_in_every_admissible_world (status=$status). Only taxa present in every admissible world can be placed. This is residual-evidence validation."))
        end
        return json(OrderedDict("valid" => true, "message" => "Valid (generic check): avec_fibre=true and present_in_every_admissible_world"))
    end

    (valid, message) = CladeCumulus.validate_drag_drop(tree, dragged_node_id, target_id, Dict{String,Any}(evidence))

    json(OrderedDict("valid" => valid, "message" => message))
end

@get "/api/v1/studies/{study}/analysis/methods" function(req, study::String)
    # List available analysis methods with help
    json(OrderedDict(
        "methods" => [
            OrderedDict("id" => "nb_glm", "label" => "Negative Binomial GLM", "description" => "For raw counts with overdispersion, DESeq2-style", "normalization" => ["none", "size_factors", "relative", "rarefy"], "requires" => "At least 3 samples per group", "help" => AnalysisConfig.context_help("method")),
            OrderedDict("id" => "clr_lm", "label" => "CLR + Gaussian LM", "description" => "Centered Log-Ratio + LM, compositional (Aitchison)", "normalization" => ["clr"], "requires" => "Pseudocount >0, e.g. 0.5", "help" => AnalysisConfig.context_help("normalization.method")),
            OrderedDict("id" => "ilr_lm", "label" => "ILR + Gaussian LM", "description" => "Isometric Log-Ratio + LM, balances", "normalization" => ["ilr"], "requires" => "Pseudocount + ilr_basis", "help" => AnalysisConfig.context_help("normalization.pseudocount")),
            OrderedDict("id" => "logistic", "label" => "Logistic Regression", "description" => "For presence/absence or binary outcome", "normalization" => ["presence_absence", "none", "relative"], "requires" => "Binary outcome_column", "help" => "Logistic regression for binary outcomes"),
        ],
        "correction" => OrderedDict("mandatory" => "BH", "danger_token" => AnalysisConfig.DANGER_ACK_TOKEN, "help" => AnalysisConfig.context_help("correction.method")),
        "schemas" => OrderedDict(
            "json" => "/config/schemas/analysis_config.schema.json",
            "nickel" => "/config/schemas/analysis_config.ncl",
            "deed" => "/config/templates/analysis_config_chora.deed",
        ),
        "epistemic" => OrderedDict(
            "avec_fibre_column" => AnalysisConfig.AVEC_FIBRE_COLUMN,
            "epistemic_statuses" => AnalysisConfig.EPISTEMIC_STATUS_VALUES,
            "present_in_every_admissible_world" => "Holds Present across all admissible worlds (residual-evidence-types)",
        ),
    ))
end
