# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

# Routes:
#   GET  /api/v1/studies/{study}/runs/{run}/clade-cumulus/sources
#   POST /api/v1/studies/{study}/runs/{run}/clade-cumulus
#   POST /api/v1/studies/{study}/runs/{run}/clade-cumulus/validate-move
#
# Non-destructive cladistic explorer and phylogenetic diversity endpoints.
# Canonical run DuckDB tables are read-only here; staged reassignment proposals
# write only study-local sidecars under `projects/{study}/trees/.clade_cumulus/`.

using DataFrames, OrderedCollections, SHA, Dates, JSON3

const _CC_SIDECAR_MAX_BYTES = 5 * 1024 * 1024

_clade_cumulus_sidecar_dir(study::String) =
    joinpath(_trees_dir(study), ".clade_cumulus")

function _probe_optional_phylo_tool(tool_key::String, fallbacks::Vector{String})::OrderedDict{String,Any}
    configured = Tools.tool_bin(tool_key)
    resolved = nothing
    for cand in vcat([configured], fallbacks)
        isempty(cand) && continue
        if isfile(cand)
            resolved = abspath(cand)
            break
        end
        w = Sys.which(cand)
        if w !== nothing
            resolved = w
            break
        end
    end
    if resolved === nothing
        return OrderedDict{String,Any}(
            "key"       => tool_key,
            "available" => false,
            "version"   => nothing,
            "path"      => nothing,
            "sha256"    => nothing,
        )
    end
    try
        rec = MetaManifold.Provenance.probe_tool(
            MetaManifold.Provenance.TOOL_PROBES[tool_key];
            bin_resolver = _ -> resolved,
        )
        return OrderedDict{String,Any}(
            "key"       => tool_key,
            "available" => true,
            "version"   => rec.version,
            "path"      => rec.path,
            "sha256"    => rec.sha256,
        )
    catch
        return OrderedDict{String,Any}(
            "key"       => tool_key,
            "available" => true,
            "version"   => "unknown",
            "path"      => resolved,
            "sha256"    => isfile(resolved) ? bytes2hex(open(sha256, resolved)) : nothing,
        )
    end
end

function _load_run_table_df(study::AbstractString, run::AbstractString, table::AbstractString; group::Union{AbstractString,Nothing}=nothing)
    # JSON3 hands request fields back as SubStrings; the DuckDB helpers are
    # String-typed, so normalise once at this boundary.
    study = String(study); run = String(run); table = String(table)
    group = isnothing(group) ? nothing : String(group)
    dir = _require_duckdb(study, run; group)
    isnothing(dir) && return (nothing, nothing, json_error(404, "no_results",
        "No results for run '$run' - run the pipeline first"))
    db_path = joinpath(dir, "results.duckdb")
    isfile(db_path) || return (nothing, nothing, json_error(404, "no_results",
        "No results database for run '$run'"))
    with_results_db(dir) do con
        cols = _duckdb_columns(con, table)
        isempty(cols) && return (nothing, nothing, json_error(404, "table_not_found",
            "Table '$table' not found in run '$run'"))
        scols = _sample_count_columns(con, table)
        order = _stable_order_clause(cols)
        df = DataFrame(DBInterface.execute(con, "SELECT * FROM \"$table\" $order"))
        return (df, (db_path = db_path, sample_cols = scols, columns = cols), nothing)
    end
end

function _resolve_tree_inputs_from_request(
    study::String,
    body,
    source_digests::OrderedDict{String,String},
)
    tree_source = lowercase(strip(string(get(body, :treeSource, "auto"))))
    tree_file = String(strip(string(get(body, :treeFile, ""))))
    inline_newick = String(strip(string(get(body, :newick, ""))))

    if tree_source == "study_tree" || (!isempty(tree_file) && tree_source == "auto")
        _valid_tree_file(tree_file) || return (nothing, nothing, :auto,
            json_error(400, "invalid_tree_file", "Invalid study tree filename '$tree_file'"))
        full_path = joinpath(_trees_dir(study), tree_file)
        isfile(full_path) || return (nothing, nothing, :auto,
            json_error(404, "tree_not_found", "Study tree '$tree_file' not found"))
        filesize(full_path) > _TREE_MAX_BYTES && return (nothing, nothing, :auto,
            json_error(413, "tree_too_large", "Tree file '$tree_file' exceeds size limit"))
        raw = read(full_path, String)
        source_digests["study_tree:$tree_file"] = bytes2hex(sha256(raw))
        if _tree_format(tree_file) == "jplace"
            return (nothing, raw, :auto, nothing)
        else
            return (raw, nothing, :auto, nothing)
        end
    elseif tree_source == "inline_newick" || !isempty(inline_newick)
        ncodeunits(inline_newick) > _TREE_MAX_BYTES && return (nothing, nothing, :auto,
            json_error(413, "tree_too_large", "Inline Newick string exceeds size limit"))
        source_digests["inline_newick"] = bytes2hex(sha256(inline_newick))
        return (inline_newick, nothing, :auto, nothing)
    elseif tree_source in ("build_fasttree", "fasttree")
        return (nothing, nothing, :fasttree, nothing)
    elseif tree_source in ("build_iqtree", "iqtree")
        return (nothing, nothing, :iqtree, nothing)
    elseif tree_source in ("build_nj", "nj")
        return (nothing, nothing, :nj, nothing)
    elseif tree_source in ("auto", "none", "")
        return (nothing, nothing, :auto, nothing)
    else
        return (nothing, nothing, :auto,
            json_error(400, "invalid_tree_source", "Unsupported treeSource '$tree_source'"))
    end
end

@get "/api/v1/studies/{study}/runs/{run}/clade-cumulus/sources" function(req::HTTP.Request, study::String, run::String)
    group = _req_group(req)
    err = _validate_run_request(study, run)
    !isnothing(err) && return err

    dir = _require_duckdb(study, run; group)
    db_path = isnothing(dir) ? nothing : joinpath(dir, "results.duckdb")
    tables_info = OrderedDict{String,Any}[]
    if !isnothing(dir) && !isnothing(db_path) && isfile(db_path)
        tables_info = with_results_db(dir) do con
            available = OrderedDict{String,Any}[]
            # Real tables only: SHOW TABLES also lists views, and a view backed
            # by a session-registered DataFrame cannot be bound (let alone
            # counted) from this fresh connection.
            names_df = DataFrame(DBInterface.execute(con,
                "SELECT table_name AS name FROM duckdb_tables() WHERE NOT internal"))
            tlist = sort(String[string(r.name) for r in eachrow(names_df)])
            for t in tlist
                cols = _duckdb_columns(con, t)
                scols = _sample_count_columns(con, t)
                isempty(scols) && continue
                nrows = Int(only(DataFrame(DBInterface.execute(con, "SELECT COUNT(*) AS n FROM \"$t\""))).n)
                has_seq = any(c -> c in ("Sequence", "sequence", "seq", "DNA"), cols)
                ranks = [r for r in MetaManifold.CladeCumulus.DEFAULT_TAXONOMIC_RANKS if r in cols]
                push!(available, OrderedDict{String,Any}(
                    "table"        => t,
                    "row_count"    => nrows,
                    "sample_count" => length(scols),
                    "has_sequence" => has_seq,
                    "ranks"        => ranks,
                ))
            end
            available
        end
    end

    tools = OrderedDict{String,Any}[
        _probe_optional_phylo_tool("fasttree", ["FastTree", "fasttree"]),
        _probe_optional_phylo_tool("iqtree", ["iqtree3", "iqtree"]),
        _probe_optional_phylo_tool("mafft", ["mafft"]),
    ]

    sidecar_dir = _clade_cumulus_sidecar_dir(study)
    proposals = String[]
    if isdir(sidecar_dir)
        for f in sort(readdir(sidecar_dir))
            endswith(f, ".json") && isfile(joinpath(sidecar_dir, f)) && push!(proposals, f)
        end
    end

    json(OrderedDict{String,Any}(
        "study"     => study,
        "run"       => run,
        "tables"    => tables_info,
        "trees"     => _tree_listing(study),
        "tools"     => tools,
        "proposals" => proposals,
    ))
end

@post "/api/v1/studies/{study}/runs/{run}/clade-cumulus" function(req::HTTP.Request, study::String, run::String)
    try
        return _clade_cumulus_post_impl(req, study, run)
    catch e
        @error "clade-cumulus request failed" exception = (e, catch_backtrace())
        return json_error(500, "clade_cumulus_failed", sprint(showerror, e))
    end
end

function _clade_cumulus_post_impl(req::HTTP.Request, study::String, run::String)
    group = _req_group(req)
    err = _validate_run_request(study, run)
    !isnothing(err) && return err

    body = try
        isempty(req.body) ? Dict{Symbol,Any}() : JSON3.read(String(req.body))
    catch
        return json_error(400, "invalid_json", "Request body must be valid JSON")
    end

    table = String(strip(string(get(body, :table, "merged"))))
    _valid_name(table) || return json_error(400, "invalid_table", "Invalid table name '$table'")

    mode_str = lowercase(strip(string(get(body, :mode, "combined"))))
    mode_str in ("phylogenetic", "taxonomic", "combined") ||
        return json_error(400, "invalid_mode", "mode must be 'phylogenetic', 'taxonomic', or 'combined'")
    mode_sym = Symbol(mode_str)

    max_asvs = Int(get(body, :maxAsvs, 500))
    (3 <= max_asvs <= 50_000) ||
        return json_error(400, "invalid_max_asvs", "maxAsvs must be between 3 and 50000")

    support_threshold = Float64(get(body, :supportThreshold, 0.80))
    (isfinite(support_threshold) && 0.0 <= support_threshold <= 1.0) ||
        return json_error(400, "invalid_support_threshold", "supportThreshold must lie in [0, 1]")

    lwr_threshold = Float64(get(body, :lwrThreshold, 0.95))
    (isfinite(lwr_threshold) && 0.0 < lwr_threshold <= 1.0) ||
        return json_error(400, "invalid_lwr_threshold", "lwrThreshold must lie in (0, 1]")

    seed = Int(get(body, :seed, 42))

    df, meta, load_err = _load_run_table_df(study, run, table; group)
    !isnothing(load_err) && return load_err

    source_digests = OrderedDict{String,String}(
        "duckdb:$table" => bytes2hex(open(sha256, meta.db_path)),
    )
    nwk_str, jplace_str, tree_method, tree_err =
        _resolve_tree_inputs_from_request(study, body, source_digests)
    !isnothing(tree_err) && return tree_err

    cc_res = try
        MetaManifold.CladeCumulus.build_clade_tree(
            df;
            mode = mode_sym,
            newick = nwk_str,
            jplace_json = jplace_str,
            sample_cols = meta.sample_cols,
            support_threshold = support_threshold,
            lwr_threshold = lwr_threshold,
            tree_method = tree_method,
            max_asvs = max_asvs,
            seed = seed,
        )
    catch e
        msg = e isa ArgumentError ? e.msg : sprint(showerror, e)
        return json_error(400, "clade_cumulus_failed", msg)
    end

    # Compute Faith's PD + Unweighted & Weighted UniFrac when a phylogenetic tree is present,
    # including split `.jplace` query placements (`<qname>@edge<N>#<k>`).
    diversity_payload = nothing
    if cc_res.phylo_root !== nothing && !isempty(meta.sample_cols)
        tip_list = sort!(collect(MetaManifold.CladeCumulus._collect_tree_tips!(Set{String}(), cc_res.phylo_root)))
        id_col = MetaManifold.CladeCumulus._detect_id_col(df)
        scols = meta.sample_cols
        row_by_id = Dict{String,Int}()
        for (ri, r) in enumerate(eachrow(df))
            tid = String(strip(string(r[id_col])))
            !haskey(row_by_id, tid) && (row_by_id[tid] = ri)
        end
        # Weight each placed `.jplace` tip by its raw like-weight ratio so any
        # unplaced mass remains off the tree rather than renormalised onto the
        # kept edge(s).
        tip_weights = Dict{String,Float64}()
        if jplace_str !== nothing && !isempty(strip(jplace_str))
            jd_div = MetaManifold.CladeCumulus.parse_jplace(jplace_str)
            for q in jd_div.queries
                q.status === :valid && !isempty(q.candidates) || continue
                multi = length(q.candidates) > 1
                for (qname, _) in q.names
                    for (ci, cand) in enumerate(q.candidates)
                        tid = multi ? string(qname, "@edge", cand.edge_num, "#", ci) : qname
                        tip_weights[tid] = cand.like_weight
                    end
                end
            end
        end
        taxa_vec = String[]
        taxa_rows = Tuple{Int,Float64}[]
        for tid in tip_list
            base_id = occursin("@edge", tid) ? first(split(tid, "@edge"; limit = 2)) : tid
            if haskey(row_by_id, base_id)
                push!(taxa_vec, tid)
                push!(taxa_rows, (row_by_id[base_id], get(tip_weights, tid, 1.0)))
            end
        end
        if !isempty(taxa_vec)
            mat = zeros(Float64, length(taxa_vec), length(scols))
            for (ci, sc) in enumerate(scols)
                col_vals = df[!, sc]
                for (mi, (ri, w)) in enumerate(taxa_rows)
                    v = col_vals[ri]
                    mat[mi, ci] = ismissing(v) ? 0.0 : max(0.0, Float64(v)) * w
                end
            end
            row_weight = Dict{Int,Float64}()
            for (ri, w) in taxa_rows
                row_weight[ri] = get(row_weight, ri, 0.0) + w
            end
            # `unplaced_reads` reports how much of each row's abundance never
            # reached the tree, so its floor is floating-point noise, not the
            # *validity* tolerance. `PLACEMENT_WEIGHT_SUM_TOL` (0.05) exists so
            # that a candidate list truncated by the placement tool stays
            # `:valid`; reusing it here reported 0 unplaced reads for a
            # placement at LWR 0.99 whose remaining 1% really is off the tree.
            noise_floor = MetaManifold.CladeCumulus.PLACEMENT_WEIGHT_OVER_TOL
            short_rows = [(ri, 1.0 - wsum) for (ri, wsum) in row_weight
                          if 1.0 - wsum > noise_floor]
            unplaced_reads = OrderedDict{String,Float64}()
            for sc in scols
                col_vals = df[!, sc]
                tot = 0.0
                for (ri, lost_share) in short_rows
                    v = col_vals[ri]
                    ismissing(v) && continue
                    tot += max(0.0, Float64(v)) * lost_share
                end
                unplaced_reads[sc] = tot
            end
            pd_by_sample = OrderedDict{String,Float64}(
                sc => MetaManifold.CladeCumulus.faith_pd(@view(mat[:, ci]), taxa_vec, cc_res.phylo_root)
                for (ci, sc) in enumerate(scols)
            )
            uw = MetaManifold.CladeCumulus.unifrac_matrix(
                mat, taxa_vec, scols, cc_res.phylo_root; metric = :unweighted
            )
            w_raw = MetaManifold.CladeCumulus.unifrac_matrix(
                mat, taxa_vec, scols, cc_res.phylo_root; metric = :weighted, normalized = false
            )
            w_norm = MetaManifold.CladeCumulus.unifrac_matrix(
                mat, taxa_vec, scols, cc_res.phylo_root; metric = :weighted, normalized = true
            )
            top_branches = if length(scols) >= 2
                first_n = MetaManifold.CladeCumulus.branch_unifrac_contributions(
                    @view(mat[:, 1]), @view(mat[:, 2]), taxa_vec, cc_res.phylo_root
                )
                first_n[1:min(length(first_n), 15)]
            else
                OrderedDict{String,Any}[]
            end
            diversity_payload = OrderedDict{String,Any}(
                "samples"                     => scols,
                "mapped_tips"                 => length(taxa_vec),
                "unplaced_reads"              => unplaced_reads,
                "faith_pd"                    => pd_by_sample,
                "unweighted_unifrac"          => [uw[i, :] for i in 1:size(uw, 1)],
                "weighted_unifrac"            => [w_raw[i, :] for i in 1:size(w_raw, 1)],
                "normalized_weighted_unifrac" => [w_norm[i, :] for i in 1:size(w_norm, 1)],
                "top_branch_contributions"    => top_branches,
            )
        end
    end

    receipt = MetaManifold.Epistemic.create_receipt(;
        study = study,
        run = run,
        source_digests = source_digests,
        tool_records = cc_res.tool_records,
        parameters = OrderedDict{String,Any}(
            "group"             => group,
            "table"             => table,
            "mode"              => mode_str,
            "max_asvs"          => max_asvs,
            "support_threshold" => support_threshold,
            "lwr_threshold"     => lwr_threshold,
            "seed"              => seed,
        ),
        warnings = cc_res.warnings,
    )

    json(OrderedDict{String,Any}(
        "study"       => study,
        "run"         => run,
        "table"       => table,
        "mode"        => mode_str,
        "root"        => MetaManifold.CladeCumulus.clade_node_to_dict(cc_res.root),
        "plotly"      => MetaManifold.CladeCumulus.to_plotly_figure(
            cc_res.root;
            title = "CladeCumulus ($mode_str) — $study / $run ($table)",
        ),
        "phylogeny"   => OrderedDict{String,Any}(
            "newick"                 => cc_res.newick,
            "midpoint_rooted"        => cc_res.midpoint_rooted,
            "subsampled"             => cc_res.subsampled,
            "total_input_asvs"       => cc_res.total_input_asvs,
            "retained_asvs"          => cc_res.retained_asvs,
            "retained_read_fraction" => cc_res.retained_fraction,
        ),
        "concordance" => OrderedDict{String,Any}(
            "dispersed_taxa"    => cc_res.dispersed_taxa,
            "discordant_clades" => cc_res.discordant_clades,
        ),
        "diversity"   => diversity_payload,
        "warnings"    => cc_res.warnings,
        "receipt"     => MetaManifold.Epistemic.receipt_dict(receipt),
    ))
end

@post "/api/v1/studies/{study}/runs/{run}/clade-cumulus/validate-move" function(req::HTTP.Request, study::String, run::String)
    group = _req_group(req)
    err = _validate_run_request(study, run)
    !isnothing(err) && return err

    body = try
        isempty(req.body) ? Dict{Symbol,Any}() : JSON3.read(String(req.body))
    catch
        return json_error(400, "invalid_json", "Request body must be valid JSON")
    end

    source_id = strip(string(get(body, :sourceId, "")))
    target_id = strip(string(get(body, :targetId, "")))
    (isempty(source_id) || isempty(target_id)) &&
        return json_error(400, "missing_clade_ids", "Both sourceId and targetId are required")

    table = String(strip(string(get(body, :table, "merged"))))
    _valid_name(table) || return json_error(400, "invalid_table", "Invalid table name '$table'")

    mode_str = lowercase(strip(string(get(body, :mode, "combined"))))
    mode_str in ("phylogenetic", "taxonomic", "combined") ||
        return json_error(400, "invalid_mode", "mode must be 'phylogenetic', 'taxonomic', or 'combined'")
    mode_sym = Symbol(mode_str)

    max_asvs = clamp(Int(get(body, :maxAsvs, 500)), 3, 50_000)
    support_threshold = clamp(Float64(get(body, :supportThreshold, 0.80)), 0.0, 1.0)
    lwr_threshold = clamp(Float64(get(body, :lwrThreshold, 0.95)), 1e-6, 1.0)
    seed = Int(get(body, :seed, 42))

    df, meta, load_err = _load_run_table_df(study, run, table; group)
    !isnothing(load_err) && return load_err

    source_digests = OrderedDict{String,String}(
        "duckdb:$table" => bytes2hex(open(sha256, meta.db_path)),
    )
    nwk_str, jplace_str, tree_method, tree_err =
        _resolve_tree_inputs_from_request(study, body, source_digests)
    !isnothing(tree_err) && return tree_err

    cc_res = try
        MetaManifold.CladeCumulus.build_clade_tree(
            df;
            mode = mode_sym,
            newick = nwk_str,
            jplace_json = jplace_str,
            sample_cols = meta.sample_cols,
            support_threshold = support_threshold,
            lwr_threshold = lwr_threshold,
            tree_method = tree_method,
            max_asvs = max_asvs,
            seed = seed,
        )
    catch e
        msg = e isa ArgumentError ? e.msg : sprint(showerror, e)
        return json_error(400, "clade_cumulus_failed", msg)
    end

    verdict = MetaManifold.CladeCumulus.validate_drag_drop(cc_res, source_id, target_id)
    save_proposal = Bool(get(body, :saveProposal, false))
    proposal_file = nothing
    proposal_params = OrderedDict{String,Any}(
        "group"             => group,
        "table"             => table,
        "mode"              => mode_str,
        "tree_method"       => String(tree_method),
        "max_asvs"          => max_asvs,
        "support_threshold" => support_threshold,
        "lwr_threshold"     => lwr_threshold,
        "seed"              => seed,
        "source_id"         => source_id,
        "target_id"         => target_id,
        "source_digests"    => source_digests,
    )
    if save_proposal && Bool(verdict["allowed"])
        proposal_key = JSON3.write(OrderedDict{String,Any}(
            "study" => study,
            "run"   => run,
            "params"=> proposal_params,
        ))
        proposal_name = string("proposal-", bytes2hex(sha256(proposal_key))[1:16], ".json")
        sidecar_path = joinpath(_clade_cumulus_sidecar_dir(study), proposal_name)
        payload = OrderedDict{String,Any}(
            "schema_version" => 1,
            "study"          => study,
            "run"            => run,
            "group"          => group,
            "table"          => table,
            "mode"           => mode_str,
            "parameters"     => proposal_params,
            "source_id"      => source_id,
            "target_id"      => target_id,
            "verdict"        => verdict,
            "source_digests" => source_digests,
            "created_at"     => Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS") * "Z",
        )
        encoded = JSON3.write(payload)
        ncodeunits(encoded) > _CC_SIDECAR_MAX_BYTES &&
            return json_error(413, "sidecar_too_large", "Proposal sidecar exceeds maximum size")
        _write_atomic(sidecar_path, encoded)
        proposal_file = proposal_name
    end
    verdict["proposal_file"] = proposal_file
    if verdict["proposed_root"] !== nothing
        verdict["proposed_plotly"] = MetaManifold.CladeCumulus.to_plotly_figure(
            MetaManifold.CladeCumulus._reaggregate_after_move(
                cc_res.root,
                MetaManifold.CladeCumulus._find_clade(cc_res.root, source_id)::MetaManifold.CladeCumulus.CladeNode,
                target_id,
                cc_res.case,
                cc_res.root.cumulative_count,
            );
            title = "Proposed CladeCumulus — $source_id → $target_id",
        )
    end

    json(verdict)
end
