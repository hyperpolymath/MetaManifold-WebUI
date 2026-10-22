# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

# Routes: the optional exact-arithmetic statistics layer (issue #1).
#
# These endpoints are additive. They read the same results database as the other
# analysis routes but write only their own immutable records under
# `projects/.../run/analysis/statistics/`, so a request here cannot change a
# pipeline output or an existing analysis.
#
#   GET  /api/v1/studies/{study}/analysis/statistics/catalogue
#   POST /api/v1/studies/{study}/runs/{run}/analysis/statistics
#   GET  /api/v1/studies/{study}/runs/{run}/analysis/statistics
#   GET  /api/v1/studies/{study}/runs/{run}/analysis/statistics/{analysis_id}
#
# The POST answers 200 with the stored record even when the record's `status` is
# "partial" or "unsuccessful": the request succeeded, and the analysis's own
# outcome (with its codes and messages) is what the record is for. A client must
# read `status`, which is why every failure path also carries a machine-readable
# `code`. Only a malformed request, an unknown method or option, or an
# unrepresentable numeric policy is an HTTP error.

using JSON3
using ..ExactNumeric: NUMERIC_MODES, DEFAULT_PRECISION_BITS, DEFAULT_MAX_DIGITS,
                      NumericError, error_code, policy_from_config, policy_dict
using ..ExactStatistics: analyse, write_record, read_record, list_records,
                         method_catalogue, RecordConflict
using ..Analysis: sample_columns, filtered_df, sequence_column_name

## Which column identifies a feature row, for the names stored with a record.
const _FEATURE_ID_COLUMNS = ("ASV", "OTU", "SeqName")

function _statistics_feature_column(columns::Vector{String})
    for name in _FEATURE_ID_COLUMNS
        name in columns && return name
    end
    return sequence_column_name(columns)
end

"""
    _statistics_matrix(con, table, scols, columns, where_clause, where_params)
        -> (Matrix{Float64}, Vector{String})

The count matrix and its feature names, from one read of the filtered table.

`filtered_counts` cannot serve here because the feature *names* must line up with
the matrix's columns: the name and the counts come from the same rows, in the
same identity order, so a record's feature list cannot describe a different
ordering than the analysis used. `missing` counts count as zero, as they do in
`filtered_counts`.
"""
function _statistics_matrix(con, table::String, scols::Vector{String},
                            columns::Vector{String}, where_clause::String, where_params::Vector)
    df = filtered_df(con, table, where_clause, where_params)
    n = nrow(df)
    features = if n == 0
        String[]
    else
        idcol = _statistics_feature_column(columns)
        if isnothing(idcol)
            [string(j) for j in 1:n]
        else
            [string(df[!, Symbol(idcol)][j]) for j in 1:n]
        end
    end
    mat = Matrix{Float64}(undef, length(scols), n)
    for (i, c) in enumerate(scols)
        column = df[!, Symbol(c)]
        for j in 1:n
            v = column[j]
            mat[i, j] = ismissing(v) ? 0.0 : Float64(v)
        end
    end
    return mat, features
end

"""
    _statistics_numeric_section(study) -> Dict{String,Any}

The study's `analysis.statistics.numeric` settings, resolved through the config
cascade. A missing or `nothing` value falls back to the factory default; an
unknown or invalid value raises `ArgumentError` from the policy constructor
rather than being ignored.
"""
function _statistics_numeric_section(study::String)
    resolved = _resolved_run_config(study, nothing, nothing, nothing)
    val(k, d) = something(get(get(resolved, k, (; value=d)), :value, d), d)
    return Dict{String,Any}(
        "mode"           => val("analysis.statistics.numeric.mode", "float64"),
        "precision_bits" => val("analysis.statistics.numeric.precision_bits", DEFAULT_PRECISION_BITS),
        "max_digits"     => val("analysis.statistics.numeric.max_digits", DEFAULT_MAX_DIGITS),
        "display_digits" => val("analysis.statistics.numeric.display_digits", 6),
    )
end

"""
    _statistics_numeric_override(raw) -> Dict{String,Any}

The optional per-request `numeric` object. Only the four policy keys are
accepted, and only as plain scalars; `policy_from_config` validates the values
and their ranges, so an out-of-range precision is a 400 and never a silently
clamped setting.
"""
function _statistics_numeric_override(raw)
    isnothing(raw) && return Dict{String,Any}()
    (raw isa AbstractDict || raw isa JSON3.Object) || throw(ArgumentError(
        "numeric must be a JSON object with mode, precision_bits, max_digits or display_digits"))
    out = Dict{String,Any}()
    for (k, v) in raw
        out[string(k)] = v
    end
    return out
end

"""
    _statistics_options(raw) -> Dict{String,Any}

The optional per-request `options` object for the chosen method. Values are
passed through unchanged: `ExactStatistics.analyse` owns validation, so a nested
object or a wrong type is reported once, by the layer that defines what the
option means.
"""
function _statistics_options(raw)
    isnothing(raw) && return Dict{String,Any}()
    (raw isa AbstractDict || raw isa JSON3.Object) || throw(ArgumentError(
        "options must be a JSON object"))
    out = Dict{String,Any}()
    for (k, v) in raw
        out[string(k)] = v
    end
    return out
end

## The catalogue: what this layer claims, published as data.
@get "/api/v1/studies/{study}/analysis/statistics/catalogue" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                "Study '$study' not found")
    policy = try
        policy_from_config(_statistics_numeric_section(study))
    catch e
        e isa ArgumentError || rethrow()
        return json_error(400, "invalid_numeric_policy", sprint(showerror, e))
    end
    body = Dict{String,Any}(
        "methods" => method_catalogue(),
        "numeric_modes" => collect(NUMERIC_MODES),
        "default_numeric_policy" => policy_dict(policy),
        "record_schema" => "metamanifold.statistics/1",
    )
    HTTP.Response(200, ["Content-Type" => "application/json"], body = JSON3.write(body))
end

## Run one method and store the record.
@post "/api/v1/studies/{study}/runs/{run}/analysis/statistics" function(req,
                                                                        study::String,
                                                                        run::String)
    group = _req_group(req)
    dir, err = _require_run_results(study, run; group)
    !isnothing(err) && return err

    body   = JSON3.read(String(req.body))
    table  = string(get(body, :table, "merged"))
    method = string(get(body, :method, "summarise.counts"))
    prefix = let p = get(body, :prefix, nothing); isnothing(p) ? nothing : string(p) end
    params = _body_filter_params(body)

    policy = try
        policy_from_config(_statistics_numeric_section(study);
                           overrides = _statistics_numeric_override(get(body, :numeric, nothing)))
    catch e
        e isa ArgumentError || rethrow()
        return json_error(400, "invalid_numeric_policy", sprint(showerror, e))
    end
    options = try
        _statistics_options(get(body, :options, nothing))
    catch e
        e isa ArgumentError || rethrow()
        return json_error(400, "invalid_options", sprint(showerror, e))
    end

    cfg_cache = Dict{Tuple{String,String,String}, Any}()
    response = _with_analysis_results_table(study, run, table; group) do con, columns
        scols = _filter_by_prefix(sample_columns(con, table), prefix)
        isempty(scols) && return json_error(400, "no_samples",
                                            "No sample columns found in table '$table'")
        # The statistics surface obeys the same category exclusions as the other
        # analysis surfaces, but only when a config names it: the factory default
        # lists its surfaces explicitly, so statistics sees the whole table until
        # an exclusion says otherwise.
        exclude_conditions = _exclusion_conditions(study, run, group, columns;
                                                   surface = "statistics",
                                                   config_cache = cfg_cache)
        where_clause, where_params = _analysis_where_clause(params, columns;
                                                            exclude_conditions)
        scols = _retain_sample_columns(con, table, scols, params, where_clause, where_params)
        isempty(scols) && return json_error(400, "no_samples",
                                            "No samples pass the sample read-count filter")

        mat, feature_names = _statistics_matrix(con, table, scols, columns,
                                                where_clause, where_params)
        isempty(feature_names) && return json_error(400, "no_features",
            "No rows remain in table '$table' after filtering")

        record = try
            analyse(mat, scols, feature_names;
                    method  = method,
                    policy  = policy,
                    options = options,
                    seed    = _study_seed(study),
                    source  = Dict{String,Any}(
                        "study" => study,
                        "run"   => run,
                        "group" => isnothing(group) ? nothing : group,
                        "table" => table,
                    ))
        catch e
            e isa ArgumentError && return json_error(400, "invalid_request", sprint(showerror, e))
            e isa NumericError && return json_error(422, error_code(e), sprint(showerror, e))
            rethrow()
        end

        written = try
            write_record(_run_project_dir(study, run; group), record)
        catch e
            e isa RecordConflict && return json_error(409, "record_conflict", sprint(showerror, e))
            e isa ArgumentError && return json_error(500, "record_not_serialisable",
                                                     sprint(showerror, e))
            rethrow()
        end

        out = Dict{String,Any}(record)
        out["analysis_id"]   = written.id
        out["record_path"]   = written.path
        out["record_created"] = written.created
        HTTP.Response(200, ["Content-Type" => "application/json"], body = JSON3.write(out))
    end
    return response
end

## List a run's records: what was analysed, when, under which policy.
@get "/api/v1/studies/{study}/runs/{run}/analysis/statistics" function(req,
                                                                      study::String,
                                                                      run::String)
    group = _req_group(req)
    err = _validate_run_request(study, run)
    !isnothing(err) && return err
    records = list_records(_run_project_dir(study, run; group))
    body = Dict{String,Any}(
        "records" => records,
        "note" => "Records are immutable and content-addressed. An unreadable record is " *
                  "reported rather than hidden, because a missing record and a damaged " *
                  "one are different facts.",
    )
    HTTP.Response(200, ["Content-Type" => "application/json"], body = JSON3.write(body))
end

## One stored record, by content address.
@get "/api/v1/studies/{study}/runs/{run}/analysis/statistics/{analysis_id}" function(req,
                                                                                     study::String,
                                                                                     run::String,
                                                                                     analysis_id::String)
    group = _req_group(req)
    err = _validate_run_request(study, run)
    !isnothing(err) && return err
    record = try
        read_record(_run_project_dir(study, run; group), analysis_id)
    catch e
        e isa ArgumentError || rethrow()
        return json_error(400, "invalid_analysis_id", sprint(showerror, e))
    end
    isnothing(record) && return json_error(404, "analysis_not_found",
        "No statistics record '$analysis_id' for run '$run'")
    HTTP.Response(200, ["Content-Type" => "application/json"], body = JSON3.write(record))
end
