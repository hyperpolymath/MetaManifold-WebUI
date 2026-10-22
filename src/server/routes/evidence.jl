# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: Evidence Mode for one run.
#
#   GET    /api/v1/studies/{study}/runs/{run}/evidence
#   GET    /api/v1/studies/{study}/runs/{run}/evidence/claims.yml
#   POST   /api/v1/studies/{study}/runs/{run}/evidence/claims
#   DELETE /api/v1/studies/{study}/runs/{run}/evidence/claims/{id}
#   POST   /api/v1/studies/{study}/runs/{run}/evidence/fiber
#   POST   /api/v1/studies/{study}/runs/{run}/evidence/residuals
#
# Evidence Mode is additive: it reads the run's existing results database and
# provenance attestation, and writes only into its own `evidence/` directory.
# Nothing here rewrites a scientific object.
#
# The mathematical content - what a fibre is, the two nulls the residual
# explorer offers, and the anti-cherry-pick rule on claim status - lives in
# `src/core/evidence.jl` and `docs/evidence-mode.md`. This file owns the SQL.
#
# Performance note. The tables here reach 1M rows and hundreds of sample
# columns. Every aggregate below is a single pass over the table with
# conditional sums; the only row-level output is a member list capped at
# `MAX_MEMBERS`. Nothing materialises the whole fibre in memory, and no query is
# issued per sample.
using JSON3, DataFrames, OrderedCollections, DuckDB, DBInterface, YAML

const Evidence = MetaManifold.Evidence
# `Provenance` is already bound at the top of pipeline.jl; reading the
# attestation here reuses that binding rather than shadowing it.

# One writer at a time: a claims file is small but must never be interleaved.
const _evidence_lock = ReentrantLock()

# The member list is a drill-down, not an export. The count is always exact; the
# list says how much of it is shown.
const MAX_MEMBERS = 50

_ev_blank(x) = isnothing(x) || (x isa AbstractString && isempty(strip(x)))
_ev_num(x)   = ismissing(x) || isnothing(x) ? 0.0 : Float64(x)
_ev_int(x)   = ismissing(x) || isnothing(x) ? 0    : Int(round(Float64(x)))

"Where a run's evidence record lives: `projects/<study>[/<group>]/<run>/evidence`."
_evidence_dir(study::String, run::String; group::Union{String,Nothing}=nothing) =
    joinpath(_run_project_dir(study, run; group), Evidence.EVIDENCE_DIRNAME)

_evidence_path(study::String, run::String; group::Union{String,Nothing}=nothing) =
    joinpath(_evidence_dir(study, run; group), Evidence.CLAIMS_FILENAME)

function _load_evidence(study::String, run::String; group::Union{String,Nothing}=nothing)
    lock(_evidence_lock) do
        Evidence.load_document(_evidence_path(study, run; group); study, run)
    end
end

## Provenance summary
# A compact projection of attestation.yml. The file itself is served by the
# pipeline, which owns it; here it is reduced to what a reader needs in order to
# judge how far the claims may be trusted: whether the run is degraded, whether
# its stages agree about their environment, and which tools, databases and
# stages are recorded.
function _evidence_provenance(study::String, run::String; group::Union{String,Nothing}=nothing)
    path = joinpath(_run_project_dir(study, run; group), "attestation.yml")
    isfile(path) || return (; present = false, file = "attestation.yml")

    att = try
        Provenance.read_attestation(path)
    catch
        return (; present = true, readable = false, file = "attestation.yml")
    end
    doc = att.doc

    # Entries that are not mappings are skipped rather than throwing: a partially
    # written attestation must still yield a readable summary.
    tools = [(; name      = string(k),
                version   = string(get(v, "version", "")),
                sha256    = first(string(get(v, "sha256", "")), 12))
             for (k, v) in get(doc, "tools", ()) if v isa AbstractDict]
    databases = [(; name = string(k), release = string(get(v, "release", "")))
                 for (k, v) in get(doc, "databases", ()) if v isa AbstractDict]
    stages = [(; name     = string(get(s, "name", "")),
                 status   = string(get(s, "status", "")),
                 finished = string(get(s, "finished", "")))
              for s in get(doc, "stages", ()) if s isa AbstractDict]
    runtimes = [(; name = string(k), version = string(get(v, "version", "")))
                for (k, v) in get(doc, "runtimes", ()) if v isa AbstractDict]
    mm_raw = get(doc, "metamanifold", nothing)
    mm = mm_raw isa AbstractDict ? mm_raw : Dict{String,Any}()

    (; present        = true,
       readable       = true,
       file           = "attestation.yml",
       schema_version = Evidence.as_int(get(doc, "schema_version", 0)),
       generated      = string(get(doc, "generated", "")),
       uniform        = get(doc, "uniform", true) === true,
       degraded       = get(doc, "degraded", false) === true,
       degraded_components = String[string(x) for x in get(doc, "degraded_components", ())],
       divergent      = String[string(x) for x in get(doc, "divergent", ())],
       metamanifold   = (; git_sha = string(get(mm, "git_sha", "")),
                           git_dirty = get(mm, "git_dirty", false) === true),
       runtimes, tools, databases, stages)
end

## Results-database survey
# The projections a claim may name, as the database actually offers them. Ranks
# are listed per classifier rather than as one union, because a claim that names
# DADA2 and a rank DADA2 does not carry is a claim about the wrong column.
function _evidence_survey(con)
    present = try
        Set(String[string(r.name) for r in eachrow(DataFrame(DBInterface.execute(con, "SHOW TABLES")))])
    catch
        Set{String}()
    end

    tables = NamedTuple[]
    for t in sort(collect(present))
        t == "cluster_membership" && continue
        Validation.is_safe_name(t) || continue
        n = try
            _ev_int(only(DataFrame(DBInterface.execute(con, "SELECT COUNT(*) AS n FROM \"$t\"")).n))
        catch
            0
        end
        push!(tables, (; id = t, rows = n))
    end

    merged = "merged" in present ? "merged" : (isempty(tables) ? "" : first(tables).id)
    columns = isempty(merged) ? String[] :
              try _duckdb_columns(con, merged) catch; String[] end
    colset = Set(columns)

    sources = MetaManifold.Categories.available_sources(colset)
    ranks = NamedTuple[]
    for src in sources
        names = String[]
        columns = String[]
        for r in (Analysis.taxonomy_levels(con, merged))
            col = MetaManifold.Categories.rank_col(r, src, colset)
            isnothing(col) && continue
            push!(names, r)
            push!(columns, col)
        end
        # The column travels with the rank so the editor can offer that
        # projection's actual labels rather than guessing at a name.
        push!(ranks, (; source = src, names, columns))
    end

    (; tables, sources, ranks, merged_table = merged, taxonomy_columns = columns)
end

## Request parsing

"`(; table, tag, value, values, source, share, null)` from an evidence request body."
function _evidence_request(body)
    table = string(get(body, :table, "merged"))
    tag   = string(get(body, :tag, "rank"))
    value = string(get(body, :value, ""))

    values = String[]
    raw = get(body, :values, nothing)
    if raw isa AbstractVector
        for v in raw
            _ev_blank(v) || push!(values, string(v))
        end
    end
    single = get(body, :value_label, nothing)
    if isempty(values) && !_ev_blank(single)
        push!(values, string(single))
    end
    unique!(values)

    source = let s = get(body, :source, nothing)
        _ev_blank(s) ? nothing : uppercase(string(s))
    end

    null = let n = get(body, :null, nothing)
        _ev_blank(n) ? "proportional" : string(n)
    end
    share = let s = get(body, :share, nothing)
        _ev_blank(s) ? nothing : try Float64(s) catch; nothing end
    end

    (; table, tag, value, values, source, null, share)
end

# Sample read-count bounds travel as `sampleReads`, as on the table endpoints.
function _evidence_sample_params(body)
    params = Dict{String,String}()
    sr = get(body, :sampleReads, nothing)
    isnothing(sr) && return params
    for (field, key) in ((:min, "sample_min_reads"), (:max, "sample_max_reads"), (:basis, "sample_reads_basis"))
        v = get(sr, field, nothing)
        isnothing(v) || (params[key] = string(v))
    end
    params
end

# The labels a fibre is taken over. Category values are category names within the
# named set; rank values are labels of that rank. Either way, at least one value
# must be named: there is no "all" scope.
function _evidence_labels(con, table::String, columns::Vector{String},
                          tag::String, value::String, values::Vector{String},
                          library::Dict, tag_source::String)
    if tag == "category"
        Validation.is_safe_name(value) || return nothing,
            json_error(400, "invalid_name",
                "Category set name must contain only letters, numbers, dots, hyphens, and underscores")
        haskey(library["sets"], value) || return nothing, json_error(404, "category_set_not_found",
            "Category set '$value' not found")
        # The tag source is the request's classifier when one was named, else the
        # run's configured tagging source; `_tagging_source` resolves both.
        Categories.ensure_columns!(con, table, tag_source, [value];
                                   library=library, suffixed=_suffixed())
        col = _category_column(value)
        col in _duckdb_columns(con, table) || return nothing, json_error(404,
            "category_set_not_found", "Category set '$value' is not present in table '$table'")
        (; expr = "\"$col\"", column = col, label = value), nothing
    elseif tag == "rank"
        col = _rank_column(columns, value)
        isnothing(col) && return nothing, json_error(400, "bad_rank",
            "Unknown rank '$value' in table '$table'" *
            (isnothing(_analysis_source()) ? "" : " for $(_analysis_source()) taxonomy"))
        # Blank ranks count as Unclassified, as they do in the chart and
        # composition paths, so a claim never silently ignores unclassified rows.
        (; expr = "COALESCE(NULLIF(TRIM(\"$col\"), ''), 'Unclassified')",
           column = col, label = value), nothing
    else
        nothing, json_error(400, "bad_tag", "tag must be 'rank' or 'category'")
    end
end

## Fibre arithmetic

_ev_read_sum(samples::Vector{String}) =
    isempty(samples) ? "0" :
    join(["COALESCE(\"$s\", 0)" for s in samples], " + ")

_ev_in_list(n::Int) = join(fill("?", n), ", ")

_ev_labelled(table::String, label_expr::String) =
    "WITH labelled AS (SELECT *, $label_expr AS __label FROM \"$table\")"

_ev_identity_column(columns::Vector{String}) = begin
    found = nothing
    for c in _IDENTITY_COLUMNS
        if c in columns
            found = c
            break
        end
    end
    found
end

"""
    _fibre_profile(con, table, label, values, samples) -> NamedTuple

One pass over the table for everything the fibre and residual views need:
table totals, the fibre's row and read counts, and per-sample fibre reads
alongside each sample's own total. `label` is a NamedTuple carrying the label
expression.
"""
function _fibre_profile(con, table::String, label, values::Vector{String},
                        samples::Vector{String})
    row_sum = _ev_read_sum(samples)
    in_list = _ev_in_list(length(values))

    # Two passes rather than one wide query: the fibre condition is written once
    # per pass, so the parameter list stays exactly the named values. Folding the
    # per-sample fibre sums into the totals query instead would repeat that IN
    # list once per sample, and a table with hundreds of sample columns would
    # carry tens of thousands of bound parameters.
    totals_sql = _ev_labelled(table, label.expr) * """
        SELECT
            COUNT(*) AS total_rows,
            COALESCE(SUM($row_sum), 0) AS total_reads,
            COUNT(CASE WHEN __label IN ($in_list) AND ($row_sum) > 0 THEN 1 END) AS fibre_rows,
            COALESCE(SUM(CASE WHEN __label IN ($in_list) THEN ($row_sum) ELSE 0 END), 0) AS fibre_reads,
            $(join(["COALESCE(SUM(\"$s\"), 0) AS \"t$i\""
                    for (i, s) in enumerate(samples)], ", "))
        FROM labelled
    """
    row = only(DataFrame(DBInterface.execute(con, totals_sql, vcat(values, values))))

    observed_sql = _ev_labelled(table, label.expr) * """
        SELECT $(join(["COALESCE(SUM(\"$s\"), 0) AS \"s$i\""
                       for (i, s) in enumerate(samples)], ", "))
        FROM labelled
        WHERE __label IN ($in_list)
    """
    obs_row = only(DataFrame(DBInterface.execute(con, observed_sql, values)))

    obs = [_ev_num(obs_row[Symbol("s$i")]) for i in eachindex(samples)]
    tot = [_ev_num(row[Symbol("t$i")]) for i in eachindex(samples)]
    (; total_rows   = _ev_int(row.total_rows),
       total_reads  = _ev_num(row.total_reads),
       fibre_rows   = _ev_int(row.fibre_rows),
       fibre_reads  = _ev_num(row.fibre_reads),
       samples, observed = obs, totals = tot)
end

# The fibre's largest members by reads. The count of distinct members is exact;
# the list is capped and says so.
function _fibre_members(con, table::String, label, values::Vector{String},
                        samples::Vector{String}, columns::Vector{String})
    id_col = _ev_identity_column(columns)
    isnothing(id_col) && return (; members = NamedTuple[], member_count = 0, truncated = false)
    row_sum = _ev_read_sum(samples)
    in_list = _ev_in_list(length(values))
    where = "WHERE __label IN ($in_list) AND ($row_sum) > 0"

    count_sql = _ev_labelled(table, label.expr) *
        " SELECT COUNT(DISTINCT \"$id_col\") AS n FROM labelled $where"
    count_row = only(DataFrame(DBInterface.execute(con, count_sql, values)))
    member_count = _ev_int(count_row.n)

    list_sql = _ev_labelled(table, label.expr) * """
        SELECT "$id_col" AS member, CAST(($row_sum) AS BIGINT) AS reads
        FROM labelled $where
        ORDER BY reads DESC, member ASC
        LIMIT $(MAX_MEMBERS)
    """
    df = DataFrame(DBInterface.execute(con, list_sql, values))
    members = [(; member = string(r.member), reads = _ev_int(r.reads)) for r in eachrow(df)]
    (; members, member_count, truncated = member_count > length(members))
end

# Fibre profile as the frontend consumes it, including each sample's share.
function _fibre_view(profile)
    samples = [(; sample   = s,
                  observed = profile.observed[i],
                  total    = profile.totals[i],
                  percent  = round(100 * Evidence.share_of(profile.observed[i], profile.totals[i]); digits = 4))
               for (i, s) in enumerate(profile.samples)]
    (; rows       = profile.fibre_rows,
       reads      = profile.fibre_reads,
       row_share  = round(Evidence.share_of(profile.fibre_rows, profile.total_rows); digits = 6),
       read_share = round(Evidence.share_of(profile.fibre_reads, profile.total_reads); digits = 6),
       samples)
end

## Echoes
# Two ways of seeing the same fibre from elsewhere:
#
#   source  The other classifier's labels at the same rank, over the same rows.
#           Agreement measures how far the claim's scope survives a change of
#           method; disagreement is exactly what the dual-classifier consensus
#           exists to expose.
#   rank    The coarser fibre of the parent rank. A taxonomy's own nesting
#           requires the child fibre to sit inside it; when it does not, the
#           finding is an integrity problem in the labelling, reported as such.

function _echo_source(con, table::String, label, rank::String, values::Vector{String},
                      other::String, columns::Vector{String}, samples::Vector{String},
                      fibre_rows::Int, fibre_reads::Float64)
    col = MetaManifold.Categories.rank_col(rank, other, Set(columns))
    isnothing(col) && return nothing
    echo_expr = "COALESCE(NULLIF(TRIM(\"$col\"), ''), 'Unclassified')"
    row_sum = _ev_read_sum(samples)
    in_list = _ev_in_list(length(values))
    missing_marker = "'Unclassified', 'NA', 'Unassigned'"

    sql = _ev_labelled(table, label.expr) * """
        SELECT
            COUNT(CASE WHEN $echo_expr IN ($in_list) THEN 1 END) AS agree_rows,
            COUNT(CASE WHEN $echo_expr IN ($missing_marker) THEN 1 END) AS missing_rows,
            COALESCE(SUM(CASE WHEN $echo_expr IN ($in_list) THEN ($row_sum) ELSE 0 END), 0) AS agree_reads,
            COALESCE(SUM(CASE WHEN $echo_expr IN ($missing_marker) THEN ($row_sum) ELSE 0 END), 0) AS missing_reads
        FROM labelled
        WHERE __label IN ($in_list)
    """
    row = only(DataFrame(DBInterface.execute(con, sql, vcat(values, values, values))))

    agree_rows    = _ev_int(row.agree_rows)
    missing_rows  = _ev_int(row.missing_rows)
    agree_reads   = _ev_num(row.agree_reads)
    missing_reads = _ev_num(row.missing_reads)
    # Everything else is a genuine disagreement about this rank's label. Derived
    # rather than counted so the three buckets always sum to the fibre.
    conflict_rows = max(fibre_rows - agree_rows - missing_rows, 0)
    conflict_reads = max(fibre_reads - agree_reads - missing_reads, 0.0)

    (; kind          = "source",
       label         = other,
       projection    = (; tag = "rank", value = rank, source = other, values),
       fibre_rows,
       fibre_reads,
       agree_rows, agree_reads,
       missing_rows, missing_reads,
       conflict_rows, conflict_reads,
       agree_fraction   = round(Evidence.share_of(agree_rows, fibre_rows); digits = 4),
       conflict_fraction = round(Evidence.share_of(conflict_rows, fibre_rows); digits = 4),
       verdict = Evidence.echo_verdict(agree_rows, conflict_rows, missing_rows))
end

function _echo_rank(con, table::String, label, parent::String, values::Vector{String},
                    columns::Vector{String}, samples::Vector{String},
                    fibre_rows::Int, fibre_reads::Float64)
    col = _rank_column(columns, parent)
    isnothing(col) && return nothing
    parent_expr = "COALESCE(NULLIF(TRIM(\"$col\"), ''), 'Unclassified')"
    row_sum = _ev_read_sum(samples)
    in_list = _ev_in_list(length(values))

    # The parent label the fibre mostly sits under. Containment is measured
    # against it, so a polyphyletic child label shows up as rows outside the
    # parent rather than being averaged away.
    modal_sql = _ev_labelled(table, label.expr) * """
        SELECT $parent_expr AS parent, COUNT(*) AS n
        FROM labelled
        WHERE __label IN ($in_list)
        GROUP BY parent
        ORDER BY n DESC, parent ASC
        LIMIT 1
    """
    df = DataFrame(DBInterface.execute(con, modal_sql, values))
    isempty(df) && return nothing
    parent_label = string(df.parent[1])

    containment_sql = _ev_labelled(table, label.expr) * """
        SELECT
            COUNT(CASE WHEN $parent_expr = ? THEN 1 END) AS inside_rows,
            COALESCE(SUM(CASE WHEN $parent_expr = ? THEN ($row_sum) ELSE 0 END), 0) AS inside_reads
        FROM labelled
        WHERE __label IN ($in_list)
    """
    crow = only(DataFrame(DBInterface.execute(con, containment_sql, vcat([parent_label, parent_label], values))))
    inside_rows  = _ev_int(crow.inside_rows)
    inside_reads = _ev_num(crow.inside_reads)

    parent_fibre_sql = _ev_labelled(table, label.expr) * """
        SELECT COUNT(*) AS rows, COALESCE(SUM($row_sum), 0) AS reads
        FROM labelled WHERE $parent_expr = ?
    """
    prow = only(DataFrame(DBInterface.execute(con, parent_fibre_sql, [parent_label])))

    contained = inside_rows == fibre_rows
    (; kind        = "rank",
       label       = parent,
       projection  = (; tag = "rank", value = parent, source = _analysis_source(),
                       values = [parent_label]),
       fibre_rows,
       fibre_reads,
       echo_rows   = _ev_int(prow.rows),
       echo_reads  = _ev_num(prow.reads),
       inside_rows, inside_reads,
       # Share of the fibre that the parent-rank fibre contains.
       agree_fraction    = round(Evidence.share_of(inside_rows, fibre_rows); digits = 4),
       contained_in_echo = contained,
       # A parent-rank fibre can be larger than the child; the meaningful claim
       # is nesting, so the verdict speaks about containment.
       verdict = contained ? "contained" :
                 (inside_rows == 0 ? "disjoint" : "inconsistent"),
       note = contained ? "" :
              "The parent-rank fibre does not contain the whole fibre: $(fibre_rows - inside_rows) " *
              "row(s) carry a '$(parent_label)' label that the table's own $(parent) column contradicts. " *
              "This is an integrity finding about the labelling, not about the claim.")
end

## Fibre endpoint core

"""
    _evidence_fibre(study, run, body; group, with_members=true, with_echoes=true)

Resolve a request's projection, then compute the fibre and (optionally) its
echoes. Returns a NamedTuple, or an `HTTP.Response` error.
"""
function _evidence_fibre(study::String, run::String, body;
                         group::Union{String,Nothing}=nothing,
                         with_members::Bool=true, with_echoes::Bool=true)
    req = _evidence_request(body)
    Validation.is_safe_name(req.table) || return json_error(400, "invalid_table",
        "Table name must contain only letters, numbers, dots, hyphens, and underscores")
    req.tag in Evidence.PROJECTION_TAGS || return json_error(400, "bad_tag",
        "tag must be 'rank' or 'category'")
    isempty(req.values) && return json_error(400, "missing_values",
        "Body must name at least one value: a fibre is never everything")
    length(req.values) > Evidence.MAX_VALUES && return json_error(400, "too_many_values",
        "At most $(Evidence.MAX_VALUES) values may be named")
    any(v -> length(v) > Evidence.MAX_LABEL, req.values) && return json_error(400, "value_too_long",
        "A value may be at most $(Evidence.MAX_LABEL) characters")

    lib = _library()
    tag_source = _tagging_source(study, run; group)
    result = _with_analysis_results_table(study, run, req.table; group,
                                          readonly = req.tag != "category") do con, columns
        label, label_err = _evidence_labels(con, req.table, columns, req.tag, req.value,
                                            req.values, lib, tag_source)
        isnothing(label_err) || return label_err

        all_samples = Analysis.sample_columns(con, req.table)
        isempty(all_samples) && return json_error(400, "no_samples",
            "No sample columns found in table '$(req.table)'")
        samples = _retain_sample_columns(con, req.table, all_samples,
                                         _evidence_sample_params(body), "", Any[])
        isempty(samples) && return json_error(400, "no_samples",
            "No samples pass the sample read-count filter")

        profile = _fibre_profile(con, req.table, label, req.values, samples)

        members = nothing
        if with_members
            members = _fibre_members(con, req.table, label, req.values, samples, columns)
        end

        # The classifier this projection is read through. An explicit request
        # wins; otherwise a single present classifier names itself, and when both
        # ran the plain rank columns are VSEARCH's.
        sources = _taxonomy_sources(study, run; group)
        present_sources = isnothing(sources) ? String[] : sources
        effective = if !isnothing(req.source)
            req.source
        elseif length(present_sources) == 1
            first(present_sources)
        elseif !isempty(present_sources)
            "VSEARCH"
        else
            nothing
        end

        echoes = NamedTuple[]
        notes = String[]
        if with_echoes
            if req.tag == "rank"
                for other in present_sources
                    other == effective && continue
                    echo = try
                        _echo_source(con, req.table, label, req.value, req.values, other,
                                     columns, samples, profile.fibre_rows, profile.fibre_reads)
                    catch err
                        # An echo that cannot be computed is reported, never
                        # silently dropped: a reader must be able to tell
                        # "no disagreement" from "no comparison".
                        push!(notes, "The $other echo could not be computed: " *
                                     sprint(showerror, err))
                        nothing
                    end
                    isnothing(echo) && continue
                    push!(echoes, echo)
                end

                levels = Analysis.taxonomy_levels(con, req.table)
                index = findfirst(==(req.value), levels)
                if !isnothing(index) && index > 1
                    parent = levels[index - 1]
                    echo = try
                        _echo_rank(con, req.table, label, parent, req.values, columns,
                                   samples, profile.fibre_rows, profile.fibre_reads)
                    catch err
                        push!(notes, "The $parent echo could not be computed: " *
                                     sprint(showerror, err))
                        nothing
                    end
                    if isnothing(echo)
                        push!(notes, "The table carries no $(parent) column for this projection, so the parent-rank echo was not computed.")
                    else
                        push!(echoes, echo)
                    end
                end
            else
                push!(notes, "Category projections have no ranks above them, so only source echoes apply.")
            end
        end

        (; table      = req.table,
           tag        = req.tag,
           value      = req.value,
           values     = req.values,
           source     = effective,
           label      = label.label,
           column     = label.column,
           study, run, group,
           totals     = (; rows  = profile.total_rows,
                           reads = profile.total_reads),
           fibre      = _fibre_view(profile),
           members    = isnothing(members) ? NamedTuple[] : members.members,
           member_count = isnothing(members) ? 0 : members.member_count,
           members_truncated = isnothing(members) ? false : members.truncated,
           echoes,
           notes)
    end
    result
end

## Routes: context

@get "/api/v1/studies/{study}/runs/{run}/evidence" function(req, study::String, run::String)
    err = _validate_run_request(study, run)
    isnothing(err) || return err
    group = _req_group(req)

    document = _load_evidence(study, run; group)
    claims = Any[get(document, "claims", Any[])...]

    dir = _require_duckdb(study, run; group)
    if isnothing(dir)
        return json((; study, run, group,
            schema_version = Evidence.SCHEMA_VERSION,
            claim_statuses = collect(Evidence.CLAIM_STATUSES),
            warrant_kinds  = collect(Evidence.WARRANT_KINDS),
            claims,
            updated = get(document, "updated", nothing),
            file    = joinpath(Evidence.EVIDENCE_DIRNAME, Evidence.CLAIMS_FILENAME),
            provenance = _evidence_provenance(study, run; group),
            no_results = true,
            tables = NamedTuple[], sources = String[], ranks = NamedTuple[],
            category_sets = _list_category_sets()))
    end

    survey = try
        with_results_db(dir) do con
            _evidence_survey(con)
        end
    catch
        (; tables = NamedTuple[], sources = String[], ranks = NamedTuple[],
           merged_table = "merged", taxonomy_columns = String[])
    end

    json((; study, run, group,
        schema_version = Evidence.SCHEMA_VERSION,
        claim_statuses = collect(Evidence.CLAIM_STATUSES),
        warrant_kinds  = collect(Evidence.WARRANT_KINDS),
        claims,
        updated = get(document, "updated", nothing),
        file    = joinpath(Evidence.EVIDENCE_DIRNAME, Evidence.CLAIMS_FILENAME),
        provenance = _evidence_provenance(study, run; group),
        no_results = false,
        tables        = survey.tables,
        sources       = survey.sources,
        ranks         = survey.ranks,
        merged_table  = survey.merged_table,
        category_sets = _list_category_sets()))
end

## Routes: claims

# Download the record as YAML, byte-identical to what sits on disk. This is the
# artefact a methods section cites, so it is exportable without a JSON round trip.
@get "/api/v1/studies/{study}/runs/{run}/evidence/claims.yml" function(req, study::String,
                                                                       run::String)
    err = _validate_run_request(study, run)
    isnothing(err) || return err
    group = _req_group(req)
    document = _load_evidence(study, run; group)
    text = Evidence.render_claims_yaml(document)
    HTTP.Response(200,
        ["Content-Type"        => "application/yaml; charset=utf-8",
         "Content-Disposition" => "attachment; filename=\"$(study)-$(run)-claims.yml\""],
        body = text)
end

@post "/api/v1/studies/{study}/runs/{run}/evidence/claims" function(req, study::String,
                                                                   run::String)
    err = _validate_run_request(study, run)
    isnothing(err) || return err
    group = _req_group(req)

    body = try JSON3.read(String(req.body)) catch; nothing end
    body isa JSON3.Object || return json_error(400, "invalid_claim",
        "Body must be a JSON object with a 'claim' member")
    raw = get(body, :claim, nothing)
    raw isa JSON3.Object || return json_error(400, "invalid_claim",
        "Body must include a 'claim' object")

    incoming = _to_plain(raw)
    document = _load_evidence(study, run; group)

    id = _ev_blank(get(incoming, "id", nothing)) ?
         Evidence.next_claim_id(document, string(get(incoming, "text", ""))) :
         string(get(incoming, "id"))
    claim = Evidence.normalise_claim(incoming; id = id)

    # A claim keeps its creation time across edits; everything else is rewritten.
    previous = Evidence.find_claim(document, string(get(claim, "id", "")))
    created = isnothing(previous) ? nothing : get(previous, "created", nothing)
    claim["created"] = _ev_blank(created) ?
        string(something(get(claim, "created", nothing), Evidence.timestamp())) : string(created)
    claim["modified"] = Evidence.timestamp()

    errors = Evidence.claim_errors(claim)
    isempty(errors) || return json_error(400, "invalid_claim", join(errors, "; "))

    document = lock(_evidence_lock) do
        doc = Evidence.upsert_claim(document, claim)
        errs = Evidence.document_errors(doc)
        isempty(errs) || return errs
        Evidence.save_document(_evidence_path(study, run; group), doc)
        doc
    end
    document isa AbstractVector && return json_error(400, "invalid_document", join(document, "; "))

    json((; claim,
            claims  = get(document, "claims", Any[]),
            updated = get(document, "updated", nothing)))
end

@delete "/api/v1/studies/{study}/runs/{run}/evidence/claims/{id}" function(req, study::String,
                                                                          run::String,
                                                                          id::String)
    err = _validate_run_request(study, run)
    isnothing(err) || return err
    group = _req_group(req)
    Validation.is_safe_name(id) || return json_error(400, "invalid_id", "Invalid claim id")

    result = lock(_evidence_lock) do
        document = _load_evidence(study, run; group)
        doc, removed = Evidence.remove_claim(document, id)
        removed || return nothing
        Evidence.save_document(_evidence_path(study, run; group), doc)
        doc
    end
    isnothing(result) && return json_error(404, "claim_not_found", "Claim '$id' not found")

    json((; deleted = id, claims = get(result, "claims", Any[]),
            updated = get(result, "updated", nothing)))
end

## Routes: fibre and residuals

@post "/api/v1/studies/{study}/runs/{run}/evidence/fiber" function(req, study::String,
                                                                   run::String)
    err = _validate_run_request(study, run)
    isnothing(err) || return err
    group = _req_group(req)
    body = try JSON3.read(String(req.body)) catch; nothing end
    body isa JSON3.Object || return json_error(400, "bad_request", "Body must be a JSON object")

    result = _evidence_fibre(study, run, body; group)
    result isa HTTP.Response && return result
    json(result)
end

## Residual endpoint core

"""
    _evidence_residuals(study, run, body; group) -> NamedTuple

The residual explorer's data. Returns a NamedTuple, or an `HTTP.Response` error.
Factored out of the route so the arithmetic and the validation can be tested
against a fixture database without an HTTP listener.
"""
function _evidence_residuals(study::String, run::String, body;
                             group::Union{String,Nothing}=nothing)
    req_scope = _evidence_request(body)
    req_scope.null in ("proportional", "claim_share") || return json_error(400, "bad_null",
        "null must be 'proportional' or 'claim_share'")
    if req_scope.null == "claim_share"
        isnothing(req_scope.share) && return json_error(400, "missing_share",
            "null 'claim_share' requires a share between 0 and 1")
        (0 < req_scope.share <= 1) || return json_error(400, "bad_share",
            "share must be greater than 0 and at most 1")
    end

    # Residuals need only the profile: no member list, no echoes. Skipping them
    # keeps the explorer responsive on the evidence tab's default view.
    fibre = _evidence_fibre(study, run, body; group, with_members = false, with_echoes = false)
    fibre isa HTTP.Response && return fibre

    share = req_scope.null == "claim_share" ? req_scope.share : nothing
    sample_names = String[p.sample for p in fibre.fibre.samples]
    observed     = Float64[p.observed for p in fibre.fibre.samples]
    totals       = Float64[p.total for p in fibre.fibre.samples]
    rows = Evidence.residual_rows(sample_names, observed, totals,
                                  fibre.fibre.reads, fibre.totals.reads;
                                  share)
    summary = Evidence.residual_summary(rows)

    (; study, run, group,
       table  = fibre.table,
       tag    = fibre.tag,
       value  = fibre.value,
       values = fibre.values,
       source = fibre.source,
       null   = (; kind  = req_scope.null,
                   share = share,
                   note  = req_scope.null == "proportional" ?
                       "Expected reads distribute the fibre across samples as the whole library is distributed." :
                       "Expected reads are the stated share of each sample's reads."),
       fibre  = (; rows = fibre.fibre.rows, reads = fibre.fibre.reads,
                   read_share = fibre.fibre.read_share),
       grand  = (; rows = fibre.totals.rows, reads = fibre.totals.reads),
       samples = [(; sample     = r.sample,
                     observed   = r.observed,
                     expected   = round(r.expected; digits = 4),
                     residual   = round(r.residual; digits = 4),
                     log2_ratio = round(r.log2_ratio; digits = 4),
                     total      = r.total) for r in rows],
       summary = (; chi2             = round(summary.chi2; digits = 4),
                    df               = summary.df,
                    n_samples        = summary.n_samples,
                    n_usable         = summary.n_usable,
                    n_excess         = summary.n_excess,
                    n_deficit        = summary.n_deficit,
                    max_abs_residual = round(summary.max_abs_residual; digits = 4)))
end

@post "/api/v1/studies/{study}/runs/{run}/evidence/residuals" function(req, study::String,
                                                                       run::String)
    err = _validate_run_request(study, run)
    isnothing(err) || return err
    group = _req_group(req)
    body = try JSON3.read(String(req.body)) catch; nothing end
    body isa JSON3.Object || return json_error(400, "bad_request", "Body must be a JSON object")

    result = _evidence_residuals(study, run, body; group)
    result isa HTTP.Response && return result
    json(result)
end
