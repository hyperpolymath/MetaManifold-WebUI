# © 2026 Joshua Benjamin Jewell. All rights reserved.
#
# This module is licensed under the GNU Affero General Public License version 3 (AGPLv3).

module Evidence

# Evidence Mode: the epistemic record of a run.
#
# A run's outputs become *evidence* only when three things travel together: what
# was computed (Provenance), what is being claimed about it, and the part of the
# data the claim is about. This module owns the middle and the arithmetic of the
# third; the routes own the SQL.
#
# Vocabulary, used consistently here, in the frontend and in docs/evidence-mode.md:
#
#   claim      A sentence a reader could disagree with, plus the projection
#              (scope) that fixes what it is about and the warrant that says why
#              it follows.
#   fibre      The preimage of a claim's scope: the rows whose value under the
#              claim's projection (a rank or a category set) is one of the
#              scope's values. "avec fibre" means a claim is never stated free of
#              the sub-population it is about.
#   echo       The same fibre seen through a second projection. Agreement bounds
#              how strongly a claim may be stated; disagreement is reported, not
#              averaged away.
#   residual   Observed minus expected reads per sample under an explicitly
#              named null. The residual explorer's whole value is that the null
#              is declared rather than assumed.
#
# Two rules are enforced here rather than in the UI, because a claim that cannot
# be exported is worth nothing and a claim the UI may state loosely is a claim
# the record may overstate:
#
#   No unsupported support. A claim may not carry status "supported" without at
#   least one warrant of an evidential kind (measurement, citation or inference).
#   A bare definition - "we call this a bloom" - cannot support an empirical
#   statement.
#
#   No unwarranted precision. A scope names exactly one projection and a bounded
#   list of values. There is no way to express "everything" as a claim, so
#   cherry-picking cannot be performed by omission inside the document; the
#   reader sees the fibre.

using Dates, YAML, OrderedCollections
using ..Validation

export SCHEMA_VERSION, CLAIM_STATUSES, WARRANT_KINDS, PROJECTION_TAGS,
       EVIDENCE_DIRNAME, CLAIMS_FILENAME, MAX_CLAIMS,
       as_int, slugify, next_claim_id, blank_document, load_document, save_document,
       document_errors, claim_errors, normalise_claim, upsert_claim, remove_claim,
       find_claim, claim_projection, render_claims_yaml,
       pearson_residual, log2_ratio, ResidualRow, residual_rows, residual_summary,
       echo_verdict, share_of

const SCHEMA_VERSION = 1
const EVIDENCE_DIRNAME = "evidence"
const CLAIMS_FILENAME = "claims.yml"

const CLAIM_STATUSES = ("draft", "supported", "contested", "refuted")
const WARRANT_KINDS  = ("definition", "measurement", "citation", "inference")
# Warrants whose kind can carry an empirical claim. "definition" fixes the words
# of a claim; it does not support it.
const EVIDENTIAL_WARRANTS = ("measurement", "citation", "inference")

const PROJECTION_TAGS = ("rank", "category")

const MAX_CLAIMS     = 200
const MAX_VALUES     = 50
const MAX_WARRANTS   = 5
const MAX_CAVEATS    = 20
const MAX_TEXT       = 2000
const MAX_LABEL      = 200
const MAX_ID         = 64

## Small helpers

timestamp() = Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SSZ")

_blank(x) = isnothing(x) || (x isa AbstractString && isempty(strip(x)))

_as_string(x) = x isa AbstractString ? String(x) : ""

_as_int(x) = x isa Integer ? Int(x) :
             x isa Real    ? Int(round(x)) : 0

"`x` as an `Int`, with anything that is not a real number reading as 0."
as_int(x) = _as_int(x)

"Whether `x` is a vector, treating `nothing` as an empty one."
_as_vector(x) = x isa AbstractVector ? collect(x) : Any[]

"Whether `x` is an abstract dict."
_as_dict(x) = x isa AbstractDict ? x : nothing

"""
    share_of(part, whole) -> Float64

`part / whole`, or 0.0 when `whole` is zero. A guarded ratio so callers cannot
divide a fibre's reads by an empty table and publish NaN.
"""
share_of(part, whole) = whole > 0 ? part / whole : 0.0

## Identifiers

"""
    slugify(text) -> String

A lowercase, hyphenated, ASCII-safe stem for a claim identifier: runs of
everything outside `[a-z0-9]` collapse to a single hyphen, and the result is cut
to 48 characters. Returns `""` when nothing survives, which callers must treat
as "derive an identifier from elsewhere" rather than as a valid id.
"""
function slugify(text::AbstractString)
    s = lowercase(strip(String(text)))
    s = replace(s, r"[^a-z0-9]+" => "-")
    s = strip(s, '-')
    isempty(s) && return ""
    first(s, 48) |> strip |> String
end

"""
    next_claim_id(document, seed) -> String

An identifier not already used by `document`'s claims: `slugify(seed)` when that
is free, else `-2`, `-3`, … appended. Falls back to `claim` when the seed has no
slug at all, so an id is always a safe name.
"""
function next_claim_id(document, seed::AbstractString)
    taken = Set(String(get(c, "id", "")) for c in _as_vector(get(document, "claims", Any[]))
                if c isa AbstractDict)
    base = slugify(seed)
    isempty(base) && (base = "claim")
    candidate = base
    n = 1
    while candidate in taken
        n += 1
        candidate = "$base-$n"
    end
    candidate
end

## Claim normalisation and validation

"""
    normalise_claim(claim; id=nothing) -> OrderedDict{String,Any}

A claim document with every optional field present and every scalar at its
declared type. Unknown fields are dropped: the exported record is a schema, not
a scratchpad. `id` supplies an identifier when the incoming claim has none.
"""
function normalise_claim(claim::AbstractDict; id::Union{String,Nothing}=nothing)
    scope_in = _as_dict(get(claim, "scope", nothing))
    # A missing scope normalises to an empty one, which `claim_errors` then
    # rejects with a message that points at the missing projection.
    isnothing(scope_in) && (scope_in = Dict{String,Any}())
    scope = OrderedDict{String,Any}(
        "table"  => string(get(scope_in, "table", "merged")),
        "tag"    => string(get(scope_in, "tag", "rank")),
        "value"  => string(get(scope_in, "value", "")),
        "source" => let s = get(scope_in, "source", nothing)
            _blank(s) ? nothing : string(s)
        end,
        "values" => String[string(v) for v in _as_vector(get(scope_in, "values", Any[]))
                           if !_blank(v)],
    )

    warrants = Any[]
    for w in _as_vector(get(claim, "warrant", Any[]))
        wd = _as_dict(w)
        isnothing(wd) && continue
        entry = OrderedDict{String,Any}(
            "kind" => string(get(wd, "kind", "")),
            "text" => string(get(wd, "text", "")),
        )
        ref = get(wd, "ref", nothing)
        _blank(ref) || (entry["ref"] = string(ref))
        push!(warrants, entry)
    end

    claim_id = _blank(get(claim, "id", nothing)) ? (id === nothing ? "" : id) :
               string(get(claim, "id"))
    # A JSON null for an optional field means "not supplied", not the string
    # "nothing": such a claim must not be rejected for a status a client never set.
    status = get(claim, "status", nothing)
    doc = OrderedDict{String,Any}(
        "id"      => claim_id,
        "text"    => string(get(claim, "text", "")),
        "status"  => _blank(status) ? "draft" : string(status),
        "scope"   => scope,
        "warrant" => warrants,
        "caveats" => String[string(c) for c in _as_vector(get(claim, "caveats", Any[]))
                            if !_blank(c)],
    )
    created = get(claim, "created", nothing)
    _blank(created) || (doc["created"] = string(created))
    modified = get(claim, "modified", nothing)
    _blank(modified) || (doc["modified"] = string(modified))
    doc
end

const _RANK_NAME_RE = r"^[A-Za-z][A-Za-z0-9_]*$"

"""
    claim_errors(claim) -> Vector{String}

Every reason `claim` cannot enter the record, in the order a reader would fix
them. Empty means the claim is valid. The same rules are mirrored in
`frontend/src/evidence/claims.ts` so the editor can explain a disabled Save
before the request is made - but this function is the authority.
"""
function claim_errors(claim::AbstractDict)
    errors = String[]
    id = _as_string(get(claim, "id", ""))
    if isempty(id)
        push!(errors, "a claim needs an id")
    elseif !Validation.is_safe_name(id) || startswith(id, ".")
        push!(errors, "claim id '$(id)' must be letters, digits, dots, hyphens or underscores, not starting with a dot")
    elseif ncodeunits(id) > MAX_ID
        push!(errors, "claim id '$(id)' is longer than $MAX_ID characters")
    end

    text = strip(_as_string(get(claim, "text", "")))
    if isempty(text)
        push!(errors, "a claim needs text")
    elseif length(text) > MAX_TEXT
        push!(errors, "claim text is longer than $MAX_TEXT characters")
    end

    status = _as_string(get(claim, "status", "draft"))
    status in CLAIM_STATUSES ||
        push!(errors, "status '$(status)' must be one of $(join(CLAIM_STATUSES, ", "))")

    scope = _as_dict(get(claim, "scope", nothing))
    if isnothing(scope)
        push!(errors, "a claim needs a scope naming the projection it is about")
    else
        table = _as_string(get(scope, "table", "merged"))
        if !Validation.is_safe_name(table)
            push!(errors, "scope.table '$(table)' must be letters, digits, dots, hyphens or underscores")
        end

        tag = _as_string(get(scope, "tag", ""))
        tag in PROJECTION_TAGS ||
            push!(errors, "scope.tag '$(tag)' must be one of $(join(PROJECTION_TAGS, ", "))")

        value = _as_string(get(scope, "value", ""))
        if isempty(value)
            push!(errors, "scope.value must name a rank (tag 'rank') or a category set (tag 'category')")
        elseif tag == "rank" && !occursin(_RANK_NAME_RE, value)
            push!(errors, "scope.value '$(value)' is not a rank name")
        elseif tag == "category" && !Validation.is_safe_name(value)
            push!(errors, "scope.value '$(value)' is not a category set name")
        end

        source = get(scope, "source", nothing)
        if !_blank(source) && !(string(source) in ("VSEARCH", "DADA2"))
            push!(errors, "scope.source must be VSEARCH, DADA2 or empty")
        end

        values = _as_vector(get(scope, "values", Any[]))
        if isempty(values)
            push!(errors, "scope.values must list at least one value: the fibre a claim is about is never everything")
        elseif length(values) > MAX_VALUES
            push!(errors, "scope.values holds $(length(values)) values; the limit is $MAX_VALUES")
        else
            for v in values
                _blank(v) && push!(errors, "scope.values contains an empty value")
                s = _as_string(v)
                length(s) > MAX_LABEL &&
                    push!(errors, "scope.values entry is longer than $MAX_LABEL characters")
            end
        end
    end

    warrants = _as_vector(get(claim, "warrant", Any[]))
    length(warrants) > MAX_WARRANTS &&
        push!(errors, "a claim may carry at most $MAX_WARRANTS warrants")
    evidential = 0
    for (i, w) in enumerate(warrants)
        wd = _as_dict(w)
        if isnothing(wd)
            push!(errors, "warrant $i must be an object with kind and text")
            continue
        end
        kind = _as_string(get(wd, "kind", ""))
        if !(kind in WARRANT_KINDS)
            push!(errors, "warrant $i kind '$(kind)' must be one of $(join(WARRANT_KINDS, ", "))")
        elseif kind in EVIDENTIAL_WARRANTS
            evidential += 1
        end
        wtext = strip(_as_string(get(wd, "text", "")))
        isempty(wtext) && push!(errors, "warrant $i needs text")
        length(wtext) > MAX_TEXT &&
            push!(errors, "warrant $i text is longer than $MAX_TEXT characters")
    end

    # The anti-cherry-pick rule: the record may not say a claim is supported
    # without saying what supports it.
    if status == "supported" && evidential == 0
        push!(errors,
            "status 'supported' needs at least one warrant of kind " *
            join(EVIDENTIAL_WARRANTS, ", ") * " - a definition alone supports nothing")
    end

    caveats = _as_vector(get(claim, "caveats", Any[]))
    length(caveats) > MAX_CAVEATS &&
        push!(errors, "a claim may carry at most $MAX_CAVEATS caveats")
    for c in caveats
        _blank(c) && push!(errors, "caveats contains an empty entry")
        length(_as_string(c)) > MAX_TEXT &&
            push!(errors, "a caveat is longer than $MAX_TEXT characters")
    end

    errors
end

"Whether every claim in `document` is valid and every id is used once."
function document_errors(document::AbstractDict)
    errors = String[]

    version = get(document, "schema_version", nothing)
    _as_int(version) == SCHEMA_VERSION ||
        push!(errors, "schema_version must be $SCHEMA_VERSION")

    study = _as_string(get(document, "study", ""))
    run   = _as_string(get(document, "run", ""))
    Validation.is_safe_name(study) || push!(errors, "study must be a safe name")
    Validation.is_safe_name(run)   || push!(errors, "run must be a safe name")

    claims = _as_vector(get(document, "claims", Any[]))
    length(claims) > MAX_CLAIMS &&
        push!(errors, "the record holds $(length(claims)) claims; the limit is $MAX_CLAIMS")

    seen = Set{String}()
    for (i, c) in enumerate(claims)
        cd = _as_dict(c)
        if isnothing(cd)
            push!(errors, "claim $i is not an object")
            continue
        end
        for e in claim_errors(cd)
            push!(errors, "claim $i: $(e)")
        end
        id = _as_string(get(cd, "id", ""))
        if id in seen
            push!(errors, "claim $i: duplicate claim id '$(id)'")
        end
        push!(seen, id)
    end

    errors
end

## Document IO

"""
    blank_document(study, run) -> OrderedDict

An empty evidence record. Nothing is written until a claim is saved, so a run
that is inspected but not commented on leaves no file behind.
"""
function blank_document(study::AbstractString, run::AbstractString)
    OrderedDict{String,Any}(
        "schema_version" => SCHEMA_VERSION,
        "study"          => String(study),
        "run"            => String(run),
        "updated"        => nothing,
        "claims"         => Any[],
    )
end

"""
    load_document(path; study, run) -> OrderedDict

The record at `path`, or `blank_document(study, run)` when there is none.
`claims` is always a mutable vector: YAML narrows a homogeneous sequence, and a
later claim must not be refused because the first ones happened to share a
shape.
"""
function load_document(path::AbstractString; study::AbstractString, run::AbstractString)
    isfile(path) || return blank_document(study, run)
    # A record that exists but cannot be parsed is an error, not an empty record:
    # returning blank claims here would let the next save overwrite a record this
    # code simply failed to read.
    doc = YAML.load_file(path; dicttype=OrderedDict{String,Any})
    doc["schema_version"] = _as_int(get(doc, "schema_version", SCHEMA_VERSION))
    doc["study"] = string(get(doc, "study", study))
    doc["run"]   = string(get(doc, "run", run))
    doc["claims"] = Any[OrderedDict{String,Any}(string(k) => v for (k, v) in c)
                        for c in _as_vector(get(doc, "claims", Any[]))
                        if c isa AbstractDict]
    doc
end

"""
    save_document(path, document) -> String

Write `document` to `path` atomically: a partially written claims file would
lose the whole record, and this record is the reason the run was examined.
Returns the path.
"""
function save_document(path::AbstractString, document::AbstractDict)
    mkpath(dirname(abspath(path)))
    tmp = string(path) * ".tmp"
    open(tmp, "w") do io
        YAML.write(io, document)
    end
    mv(tmp, path; force=true)
    String(path)
end

## Document mutation

"Replace the claim with the same id, or append it. Returns a new document."
function upsert_claim(document::AbstractDict, claim::AbstractDict)
    doc = OrderedDict{String,Any}(string(k) => v for (k, v) in document)
    claims = Any[c for c in _as_vector(get(doc, "claims", Any[]))]
    id = string(get(claim, "id", ""))
    index = findfirst(c -> c isa AbstractDict && string(get(c, "id", "")) == id, claims)
    if isnothing(index)
        push!(claims, claim)
    else
        claims[index] = claim
    end
    doc["claims"] = claims
    doc["schema_version"] = SCHEMA_VERSION
    doc["updated"] = timestamp()
    doc
end

"Remove the claim with `id`. Returns `(document, removed)`."
function remove_claim(document::AbstractDict, id::AbstractString)
    doc = OrderedDict{String,Any}(string(k) => v for (k, v) in document)
    claims = Any[c for c in _as_vector(get(doc, "claims", Any[]))]
    before = length(claims)
    filter!(c -> !(c isa AbstractDict && string(get(c, "id", "")) == id), claims)
    doc["claims"] = claims
    length(claims) == before && return (doc, false)
    doc["updated"] = timestamp()
    (doc, true)
end

function find_claim(document::AbstractDict, id::AbstractString)
    for c in _as_vector(get(document, "claims", Any[]))
        c isa AbstractDict || continue
        string(get(c, "id", "")) == id && return c
    end
    nothing
end

"`(; table, tag, value, source, values)` for a claim's scope."
function claim_projection(claim::AbstractDict)
    scope = _as_dict(get(claim, "scope", nothing))
    isnothing(scope) && return nothing
    source = get(scope, "source", nothing)
    (; table  = string(get(scope, "table", "merged")),
       tag    = string(get(scope, "tag", "rank")),
       value  = string(get(scope, "value", "")),
       source = _blank(source) ? nothing : string(source),
       values = String[string(v) for v in _as_vector(get(scope, "values", Any[]))])
end

"""
    render_claims_yaml(document) -> String

The record as YAML text, for download. This is the artefact a paper's methods
section can cite; it is deliberately the same bytes that sit on disk.
"""
function render_claims_yaml(document::AbstractDict)
    io = IOBuffer()
    YAML.write(io, document)
    String(take!(io))
end

## Residuals

"""
    ResidualRow(sample, observed, expected, residual, log2_ratio, total)

One sample's departure from the declared null. `residual` is the Pearson
residual `(observed - expected) / sqrt(expected)`; `log2_ratio` is
`log2((observed + 0.5) / (expected + 0.5))`, with the half-read pseudocount
stated so a zero cell is not reported as negative infinity.
"""
struct ResidualRow
    sample     :: String
    observed   :: Float64
    expected   :: Float64
    residual   :: Float64
    log2_ratio :: Float64
    total      :: Float64
end

"Pearson residual. Zero when `expected` is zero, where it is undefined."
pearson_residual(observed, expected) =
    expected > 0 ? (Float64(observed) - Float64(expected)) / sqrt(Float64(expected)) : 0.0

"""
    log2_ratio(observed, expected; pseudocount=0.5) -> Float64

Log2 fold change of observed over expected, with a pseudocount on both sides so
zero cells stay finite and symmetric.
"""
function log2_ratio(observed, expected; pseudocount::Float64=0.5)
    log2((Float64(observed) + pseudocount) / (Float64(expected) + pseudocount))
end

"""
    residual_rows(samples, observed, totals, fibre_total, grand_total;
                  share=nothing) -> Vector{ResidualRow}

Per-sample expected reads and residuals under one of two explicitly named nulls:

  `share=nothing`   the "proportional" null: the fibre's reads are distributed
                    across samples as the library's reads are, so
                    `expected = fibre_total * total / grand_total`.
  `share=x`         the "claim share" null: the fibre should hold `x` of every
                    sample's reads, so `expected = x * total`.

`observed`, `totals` and `samples` are positionally aligned. Rows come back
largest absolute residual first, ties broken by sample name, so the explorer's
default view is its own worst case rather than its first column.
"""
function residual_rows(samples::AbstractVector, observed::AbstractVector,
                       totals::AbstractVector, fibre_total, grand_total;
                       share::Union{Nothing,Real}=nothing)
    rows = ResidualRow[]
    for (i, sample) in enumerate(samples)
        obs = Float64(observed[i])
        tot = Float64(totals[i])
        exp = if isnothing(share)
            Float64(share_of(fibre_total, grand_total)) * tot
        else
            Float64(share) * tot
        end
        push!(rows, ResidualRow(String(sample), obs, exp,
                                pearson_residual(obs, exp),
                                log2_ratio(obs, exp), tot))
    end
    sort!(rows; by = r -> (-abs(r.residual), r.sample))
end

"""
    residual_summary(rows) -> NamedTuple

The residual explorer's headline: the Pearson chi-square statistic over the
samples whose expectation is positive, its degrees of freedom (`n - 1`), the
count of samples with `|residual| > 2` in each direction, and the largest
absolute residual. No p-value is claimed here - the statistic is reported as a
descriptive departure from a declared null, not as a significance test.
"""
function residual_summary(rows::AbstractVector{<:ResidualRow})
    usable = [r for r in rows if r.expected > 0]
    chi2 = sum(r.residual^2 for r in usable; init=0.0)
    (; chi2,
       df = max(length(usable) - 1, 0),
       n_samples = length(rows),
       n_usable = length(usable),
       n_excess = count(r -> r.residual > 2, usable),
       n_deficit = count(r -> r.residual < -2, usable),
       max_abs_residual = maximum((abs(r.residual) for r in usable); init=0.0))
end

## Echo

"""
    echo_verdict(agreeing, conflicting, missing) -> String

A word for how closely a second projection reproduces a fibre: `concordant`
(≥ 99% of rows agree), `minor divergence` (≥ 90%), `partial agreement` (≥ 50%),
`discordant` (below), or `empty` when the fibre has no rows. The thresholds are
stated in `docs/evidence-mode.md`; they describe set agreement, not truth, and
a discordant echo is a limit on how strongly a claim may be stated rather than
proof the claim is wrong.
"""
function echo_verdict(agreeing::Integer, conflicting::Integer, missing::Integer)
    total = agreeing + conflicting + missing
    total == 0 && return "empty"
    fraction = agreeing / total
    fraction >= 0.99 && return "concordant"
    fraction >= 0.90 && return "minor divergence"
    fraction >= 0.50 && return "partial agreement"
    return "discordant"
end

end # module Evidence
