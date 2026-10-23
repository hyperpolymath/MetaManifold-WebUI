# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Opt-in validated descriptive statistics. These routes deliberately do not use
# Analysis.filtered_counts (Float64) or SQL SUM (fixed-width overflow).
using JSON3, DataFrames, DuckDB, DBInterface
using ..NumericPolicy
using ..ExactSummaries
using ..HighPrecision
using ..DerivedAnalyses

const _STATISTICS_REQUEST_LIMIT = 16 * 1024 * 1024
const _EXACT_JSON_INTEGER_MAX = 2^53 - 1
const _DUCKDB_INTEGER_TYPES = Set([
    "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT",
])

function _statistics_json(payload; status::Int=200)
    HTTP.Response(status, ["Content-Type" => "application/json"], body=JSON3.write(payload))
end

function _statistics_guard(f::Function)
    try
        f()
    catch err
        err isa InterruptException && rethrow()
        err isa ResourceLimitError && return json_error(
            413, "numeric_resource_limit", sprint(showerror, err))
        err isa UnsupportedRepresentationError && return json_error(
            422, "invalid_numeric_input", sprint(showerror, err))
        err isa DerivedAnalysisError && return json_error(
            err.code == "not_found" ? 404 : err.code == "conflict" ? 409 :
            err.code == "resource_limit" ? 413 : 500,
            "derived_analysis_$(err.code)", err.reason)
        err isa ArgumentError && return json_error(
            400, "invalid_statistics_request", sprint(showerror, err))
        rethrow()
    end
end

function _statistics_body(req)
    length(req.body) <= _STATISTICS_REQUEST_LIMIT || throw(ResourceLimitError(
        "request bytes", _STATISTICS_REQUEST_LIMIT, length(req.body)))
    parsed = try
        JSON3.read(String(req.body))
    catch
        throw(ArgumentError("request body is not valid JSON"))
    end
    parsed isa JSON3.Object || throw(ArgumentError("request body must be a JSON object"))
    parsed
end

function _policy_integer(raw, key::Symbol, default)
    value = get(raw, key, default)
    (value isa Integer && !(value isa Bool)) || throw(ArgumentError(
        "numeric_policy.$key must be an integer, not $(repr(value))"))
    typemin(Int) <= value <= typemax(Int) || throw(ArgumentError(
        "numeric_policy.$key is outside the configuration integer range"))
    Int(value)
end

function _statistics_policy(body)
    raw = get(body, :numeric_policy, nothing)
    isnothing(raw) && throw(ArgumentError("numeric_policy is required; ordinary mode is not implicit"))
    (raw isa JSON3.Object || raw isa AbstractDict) || throw(ArgumentError(
        "numeric_policy must be an object"))
    mode_value = get(raw, :mode, nothing)
    mode_value isa AbstractString || throw(ArgumentError("numeric_policy.mode must be a string"))
    mode_value in ("exact_counts", "high_precision") || throw(ArgumentError(
        "validated statistics supports only exact_counts or high_precision; use the existing ordinary endpoints otherwise"))
    allowed = Set(["mode", "precision_bits", "max_denominator_bits", "round_digits"])
    for key in keys(raw)
        string(key) in allowed || throw(ArgumentError("unknown numeric_policy field '$key'"))
    end
    precision = haskey(raw, :precision_bits) ?
                _policy_integer(raw, :precision_bits, 0) : nothing
    numeric_policy(; mode=Symbol(mode_value), precision_bits=precision,
        max_denominator_bits=_policy_integer(raw, :max_denominator_bits, DEFAULT_MAX_DENOMINATOR_BITS),
        round_digits=_policy_integer(raw, :round_digits, 6))
end

# JSON3 collapses an integral float token (1.0, 1e0) to an integer when it
# parses, so the token form of `counts` entries can only be checked on the
# raw request text. This scanner walks the top-level object to the `counts`
# member and rejects any numeric token there that is not a plain integer
# token. Strings are skipped properly; their contents are validated by
# _json_exact_count after parsing.
function _reject_float_count_tokens(raw::AbstractString)
    text = String(raw)
    bytes = codeunits(text)
    n = length(bytes)
    pos = Ref(1)
    at_end() = pos[] > n
    peek() = at_end() ? 0x00 : bytes[pos[]]
    function skip_ws()
        while !at_end() && bytes[pos[]] in (0x20, 0x09, 0x0a, 0x0d)
            pos[] += 1
        end
    end
    function parse_string()
        # At the opening quote; returns the decoded string.
        pos[] += 1
        out = IOBuffer()
        while !at_end()
            byte = bytes[pos[]]
            pos[] += 1
            if byte == 0x22 # "
                return String(take!(out))
            elseif byte == 0x5c # backslash
                at_end() && break
                esc = bytes[pos[]]
                pos[] += 1
                if esc == 0x75 && pos[] + 3 <= n # \uXXXX
                    hex = text[pos[]:pos[] + 3]
                    code = tryparse(UInt32, hex; base=16)
                    isnothing(code) || print(out, Char(code))
                    pos[] += 4
                else
                    print(out, Char(esc))
                end
            else
                write(out, byte)
            end
        end
        String(take!(out))
    end
    function skip_value()
        skip_ws()
        byte = peek()
        if byte == 0x22
            parse_string()
        elseif byte in (0x7b, 0x5b) # { [
            depth = 0
            while !at_end()
                current = peek()
                if current == 0x22
                    parse_string()
                    continue
                end
                pos[] += 1
                if current in (0x7b, 0x5b)
                    depth += 1
                elseif current in (0x7d, 0x5d) # } ]
                    depth -= 1
                    depth == 0 && break
                end
            end
        else
            while !at_end() && !(bytes[pos[]] in (0x2c, 0x7d, 0x5d, 0x20, 0x09, 0x0a, 0x0d))
                pos[] += 1
            end
        end
    end
    function scan_counts_value()
        # At the first byte of the counts value: check every numeric token
        # until the value ends, skipping strings and nesting.
        depth = 0
        while !at_end()
            byte = peek()
            if byte == 0x22
                parse_string()
                continue
            elseif byte in (0x7b, 0x5b)
                depth += 1
                pos[] += 1
            elseif byte in (0x7d, 0x5d)
                depth -= 1
                pos[] += 1
                depth <= 0 && break
            elseif byte == 0x2d || (0x30 <= byte <= 0x39) # - or digit
                start = pos[]
                while !at_end() && (bytes[pos[]] in (0x2d, 0x2b, 0x2e, 0x65, 0x45) ||
                                     0x30 <= bytes[pos[]] <= 0x39)
                    pos[] += 1
                end
                token = text[start:pos[] - 1]
                occursin(r"^-?[0-9]+$", token) || throw(UnsupportedRepresentationError(
                    "integer JSON tokens in counts", token,
                    "counts; floating-point JSON tokens are not exact input, " *
                    "even when their value is integral"))
                depth == 0 && break
            else
                pos[] += 1
                byte == 0x2c && depth == 0 && break # comma ends a scalar value
            end
        end
    end

    skip_ws()
    peek() == 0x7b || return nothing # not an object; _statistics_body refuses it
    pos[] += 1
    while true
        skip_ws()
        peek() == 0x22 || return nothing
        key = parse_string()
        skip_ws()
        peek() == 0x3a || return nothing # :
        pos[] += 1
        skip_ws()
        if key == "counts"
            scan_counts_value()
            return nothing
        end
        skip_value()
        skip_ws()
        peek() == 0x2c || return nothing
        pos[] += 1
    end
end

function _statistics_labels(raw, name::String)
    raw isa AbstractVector || throw(ArgumentError("$name must be an array of strings"))
    all(x -> x isa AbstractString, raw) || throw(ArgumentError("$name must contain only strings"))
    String[String(x) for x in raw]
end

function _json_exact_count(value, feature::String, sample::String)
    if value isa AbstractString
        try
            return BigInt(parse_exact_count(value))
        catch err
            err isa UnsupportedRepresentationError || rethrow()
            throw(UnsupportedRepresentationError("an integer count", string(value),
                "feature '$feature', sample '$sample'; use a canonical whole-number string"))
        end
    end
    # A non-integral float token (1.5) reaches here as a float and is refused.
    # Integral float tokens (1.0, 1e0) are collapsed to integers by JSON3, so
    # _reject_float_count_tokens refuses those on the raw text before parsing.
    (value isa Integer && !(value isa Bool)) || throw(UnsupportedRepresentationError(
        "an integer JSON token or whole-number string", repr(value),
        "feature '$feature', sample '$sample'; floating-point JSON is not exact input"))
    0 <= value <= _EXACT_JSON_INTEGER_MAX || throw(UnsupportedRepresentationError(
        "a JSON-safe integer", repr(value),
        "feature '$feature', sample '$sample'; counts above 2^53-1 must be strings"))
    BigInt(value)
end

function _validated_filter_params(body)
    try
        _body_filter_params(body)
    catch err
        err isa InterruptException && rethrow()
        throw(ArgumentError("invalid filter parameters: $(sprint(showerror, err))"))
    end
end

function _direct_count_input(body)
    sample_raw = get(body, :sample_labels, nothing)
    feature_raw = get(body, :feature_labels, nothing)
    rows = get(body, :counts, nothing)
    isnothing(sample_raw) && throw(ArgumentError("sample_labels is required"))
    isnothing(feature_raw) && throw(ArgumentError("feature_labels is required"))
    rows isa AbstractVector || throw(ArgumentError("counts must be a features-by-samples array"))
    labels = _statistics_labels(sample_raw, "sample_labels")
    features = _statistics_labels(feature_raw, "feature_labels")
    isempty(labels) && throw(ArgumentError("at least one sample is required"))
    isempty(features) && throw(ArgumentError("at least one feature is required"))
    length(rows) == length(features) || throw(ArgumentError(
        "counts has $(length(rows)) rows but feature_labels has $(length(features))"))
    length(rows) * length(labels) <= MAX_CELLS || throw(ResourceLimitError(
        "table cells", MAX_CELLS, length(rows) * length(labels)))
    counts = Matrix{BigInt}(undef, length(features), length(labels))
    for i in eachindex(features)
        row = rows[i]
        row isa AbstractVector || throw(ArgumentError("counts row $i must be an array"))
        length(row) == length(labels) || throw(ArgumentError(
            "counts row $i has $(length(row)) cells; expected $(length(labels))"))
        for j in eachindex(labels)
            counts[i, j] = _json_exact_count(row[j], features[i], labels[j])
        end
    end
    groups_raw = get(body, :groups, nothing)
    groups = isnothing(groups_raw) ? nothing : _statistics_labels(groups_raw, "groups")
    !isnothing(groups) && length(groups) != length(labels) && throw(ArgumentError(
        "groups has $(length(groups)) labels; expected $(length(labels))"))
    # Shared checks cover blank/duplicate labels before any analysis is claimed.
    ExactSummaries.validate_coordinates(counts, labels, features)
    counts, labels, features, groups
end

function _run_statistics(counts, labels, features, groups, policy)
    if policy.mode === :exact_counts
        summary = exact_summary(counts; sample_labels=labels, feature_labels=features,
            groups, policy, allow_approximate=false)
        return summary_to_storage(summary)
    end
    isnothing(groups) || throw(ArgumentError(
        "groups are supported for exact_counts only; high_precision is per-sample"))
    summary = high_precision_summary(counts; sample_labels=labels,
        feature_labels=features, policy)
    high_precision_to_storage(summary)
end

_sql_identifier(name::AbstractString) = "\"" * replace(name, "\"" => "\"\"") * "\""

function _validated_integer_sample_columns(con, table::String, columns::Vector{String})
    schema = DataFrame(DBInterface.execute(con,
        "SELECT column_name, data_type FROM information_schema.columns WHERE table_name = ?",
        [table]))
    types = Dict(string(row.column_name) => uppercase(string(row.data_type)) for row in eachrow(schema))
    samples = Analysis.sample_columns(con, table)
    isempty(samples) && throw(ArgumentError("no sample count columns were found"))
    for sample in samples
        type = get(types, sample, "")
        type in _DUCKDB_INTEGER_TYPES || throw(UnsupportedRepresentationError(
            "an integer DuckDB count column", "$sample has type $type",
            "validated run statistics; FLOAT/DOUBLE/DECIMAL storage is never upgraded"))
    end
    samples
end

function _reject_float_count_filters(sample_columns::Vector{String}, params::Dict{String,String})
    for sample in sample_columns, prefix in ("col_min.", "col_max.")
        key = prefix * sample
        haskey(params, key) && throw(UnsupportedRepresentationError(
            "an exact integer count-filter predicate", "$key=$(params[key])",
            "validated run statistics; legacy col_min/col_max predicates use Float64"))
    end
    nothing
end

"""Read and aggregate an integer-safe run table without SQL arithmetic.

SQL only projects rows; every count is added in Julia `BigInt`. A `SUM` of
`BIGINT`/`HUGEINT` columns is evaluated in `Int64`/`Int128` and can overflow
before the exact total is known - two sample columns of `2^126` already sum to
`2^127`, one past `typemax(Int128)` - so no `SUM` and no `Float64` matrix is
used. Rows that share a feature label are therefore summed here, after SQL has
ordered them by label.
"""
function _validated_duckdb_counts(con, table::String, columns::Vector{String};
                                  prefix=nothing, taxonomic_level=nothing,
                                  where_clause::String="", where_params=Any[])
    samples = _validated_integer_sample_columns(con, table, columns)
    if !isnothing(prefix)
        samples = filter(c -> startswith(c, prefix), samples)
    end
    isempty(samples) && throw(ArgumentError("no sample columns remain after the prefix filter"))

    feature_expression = if isnothing(taxonomic_level)
        identity = Analysis.sequence_column_name(columns)
        if isnothing(identity) && "SeqName" in columns
            identity = "SeqName"
        end
        isnothing(identity) && throw(ArgumentError(
            "taxonomic_level is required because this table has no sequence identifier column"))
        _sql_identifier(identity)
    else
        taxon = Analysis.taxon_column(columns, taxonomic_level)
        isnothing(taxon) && throw(ArgumentError(
            "taxonomic level '$taxonomic_level' is not present in table '$table'"))
        # Missing/blank taxonomy is an explicit biological category, not a count
        # missing value. Count NULLs below are always rejected.
        "COALESCE(NULLIF(CAST($(_sql_identifier(taxon)) AS VARCHAR), ''), 'Unassigned')"
    end
    count_columns = join([_sql_identifier(c) for c in samples], ", ")
    # Project the rows and let SQL sort them by feature; no addition happens
    # here. `GROUP BY feature` alone is a DuckDB binder error, because the count
    # columns are neither grouped nor aggregated, and `SUM` cannot take their
    # place without overflowing. Sorting by label makes equal labels adjacent
    # and leaves the accumulator independent of row order.
    sql = "SELECT $feature_expression AS feature, $count_columns FROM $(_sql_identifier(table)) " *
          "$where_clause ORDER BY feature LIMIT $(MAX_CELLS + 1)"
    frame = DataFrame(DBInterface.execute(con, sql, where_params))
    nrow(frame) > 0 || throw(ArgumentError("no rows remain after filtering"))
    nrow(frame) <= MAX_CELLS || throw(ResourceLimitError("table rows", MAX_CELLS, nrow(frame)))

    features = String[]
    totals = Dict{String,Vector{BigInt}}()
    for (i, row) in enumerate(eachrow(frame))
        ismissing(row.feature) && throw(UnsupportedRepresentationError(
            "a non-missing feature label", "missing", "validated run statistics row $i"))
        label = string(row.feature)
        sums = get(totals, label, nothing)
        if isnothing(sums)
            length(features) + 1 <= MAX_CELLS ÷ max(length(samples), 1) ||
                throw(ResourceLimitError("table cells", MAX_CELLS,
                                         (length(features) + 1) * length(samples)))
            sums = zeros(BigInt, length(samples))
            totals[label] = sums
            push!(features, label)
        end
        for (j, sample) in enumerate(samples)
            value = row[Symbol(sample)]
            ismissing(value) && throw(UnsupportedRepresentationError(
                "a non-missing integer count", "NULL", "feature '$label', sample '$sample'"))
            (value isa Integer && !(value isa Bool)) || throw(UnsupportedRepresentationError(
                "an integer count", repr(value), "feature '$label', sample '$sample'"))
            value >= 0 || throw(ArgumentError(
                "negative count $value at feature '$label', sample '$sample'"))
            sums[j] += BigInt(value) # every addition is exact, so no overflow
        end
    end
    counts = Matrix{BigInt}(undef, length(features), length(samples))
    for (i, label) in enumerate(features)
        counts[i, :] = totals[label]
    end
    ExactSummaries.validate_coordinates(counts, samples, features)
    counts, samples, features
end

function _direct_source(result, labels, features, groups, counts)
    # Persisted direct analyses are self-contained: the original exact input can
    # be reconstructed without trusting a browser number or an external file.
    Dict{String,Any}(
        "schema" => "metamanifold.direct-count-input.v1",
        "source_format" => "direct-json",
        "input_sha256" => result["input_sha256"],
        "input" => Dict{String,Any}(
            "orientation" => "features_by_samples",
            "sample_labels" => labels,
            "feature_labels" => features,
            "groups" => groups,
            "counts" => [[string(counts[i, j]) for j in eachindex(labels)]
                         for i in eachindex(features)],
        ),
    )
end

function _derived_run_directory(study::String, run::String; group=nothing)
    joinpath(_run_project_dir(study, run; group), "derived", "validated-statistics")
end

function _persisted_statistics_response(directory, source, config, result)
    saved = persist_derived_analysis(directory; source, config, result)
    response = copy(result)
    response["analysis_id"] = saved.id
    response["derived_analysis"] = Dict{String,Any}(
        "id" => saved.id, "created" => saved.created, "immutable" => true)
    _statistics_json(response)
end

@post "/api/v1/statistics/summaries" function(req)
    _statistics_guard() do
        body = _statistics_body(req)
        _reject_float_count_tokens(String(req.body))
        policy = _statistics_policy(body)
        counts, labels, features, groups = _direct_count_input(body)
        result = _run_statistics(counts, labels, features, groups, policy)
        persist = get(body, :persist, false)
        persist isa Bool || throw(ArgumentError("persist must be a Boolean"))
        if persist
            source = _direct_source(result, labels, features, groups, counts)
            config = Dict{String,Any}("numeric_policy" => policy_to_storage(policy))
            directory = joinpath(ServerState.projects_dir(), "_derived", "direct")
            return _persisted_statistics_response(directory, source, config, result)
        end
        _statistics_json(result)
    end
end

@post "/api/v1/studies/{study}/runs/{run}/statistics/summaries" function(req, study::String, run::String)
    _statistics_guard() do
        err = _validate_run_request(study, run)
        !isnothing(err) && return err
        group = _req_group(req)
        body = _statistics_body(req)
        policy = _statistics_policy(body)
        haskey(body, :sampleReads) && throw(ArgumentError(
            "sampleReads filtering uses the legacy Float64/SQL-SUM path and is not supported for validated statistics"))
        table = string(get(body, :table, "merged"))
        occursin(r"^[A-Za-z][A-Za-z0-9_]*$", table) || throw(ArgumentError("invalid table name"))
        prefix_raw = get(body, :prefix, nothing)
        prefix = isnothing(prefix_raw) ? nothing : string(prefix_raw)
        level_raw = get(body, :taxonomic_level, get(body, :rank, nothing))
        level = isnothing(level_raw) ? nothing : string(level_raw)
        params = _validated_filter_params(body)
        groups_raw = get(body, :groups, nothing)
        groups = isnothing(groups_raw) ? nothing : _statistics_labels(groups_raw, "groups")

        outcome = _with_analysis_results_table(study, run, table; group, readonly=true) do con, columns
            candidate_samples = _validated_integer_sample_columns(con, table, columns)
            _reject_float_count_filters(candidate_samples, params)
            exclusions = _exclusion_conditions(study, run, group, columns;
                surface="diversity")
            where_clause, where_params = _analysis_where_clause(params, columns;
                exclude_conditions=exclusions)
            counts, labels, features = _validated_duckdb_counts(con, table, columns;
                prefix, taxonomic_level=level, where_clause, where_params)
            !isnothing(groups) && length(groups) != length(labels) && throw(ArgumentError(
                "groups has $(length(groups)) labels; expected $(length(labels)) after sample selection"))
            result = _run_statistics(counts, labels, features, groups, policy)
            source = Dict{String,Any}(
                "schema" => "metamanifold.run-count-input.v1",
                "source_format" => "duckdb-read-only-bigint-aggregation",
                "study_id" => study, "run_id" => run, "run_group" => group,
                "table" => table, "input_sha256" => result["input_sha256"],
            )
            config = Dict{String,Any}(
                "numeric_policy" => policy_to_storage(policy),
                "taxonomic_level" => level, "prefix" => prefix,
                "groups" => groups, "filters" => params,
                "inherited_exclusion_conditions" => exclusions,
                "sample_columns" => labels,
            )
            (; source, config, result)
        end
        outcome isa HTTP.Response && return outcome
        directory = _derived_run_directory(study, run; group)
        _persisted_statistics_response(directory, outcome.source, outcome.config, outcome.result)
    end
end

function _check_derived_source(record, key::String, expected)
    source = get(record, :source, nothing)
    isnothing(source) && throw(DerivedAnalysisError("invalid_record", "derived record has no source"))
    get(source, Symbol(key), nothing) == expected || throw(DerivedAnalysisError(
        "not_found", "derived analysis does not belong to the requested source"))
end

@get "/api/v1/statistics/derived/{id}" function(req, id::String)
    _statistics_guard() do
        directory = joinpath(ServerState.projects_dir(), "_derived", "direct")
        record = load_derived_analysis(directory, id)
        _check_derived_source(record, "source_format", "direct-json")
        _statistics_json(record)
    end
end

@get "/api/v1/studies/{study}/runs/{run}/statistics/derived/{id}" function(req, study::String, run::String, id::String)
    _statistics_guard() do
        err = _validate_run_request(study, run)
        !isnothing(err) && return err
        group = _req_group(req)
        directory = _derived_run_directory(study, run; group)
        record = load_derived_analysis(directory, id)
        _check_derived_source(record, "study_id", study)
        _check_derived_source(record, "run_id", run)
        _check_derived_source(record, "run_group", group)
        _statistics_json(record)
    end
end
