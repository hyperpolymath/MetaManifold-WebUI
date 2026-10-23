# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

"""
Epistemic admissibility, residual cloud sizing, and cryptographic receipts for
cladistic and placement evidence (`CladeCumulus`).

This module implements the runtime counterpart of `proofs/agda/MetaManifold/CladeCumulus.agda`:
- Candidate admissible worlds (`WorldCandidate`) and world collections (`Case`)
- Admissibility predicates (`present_in_every_admissible_world`,
  `present_in_some_admissible_world`, `absent_in_every_admissible_world`)
- Canonical epistemic colour encoding (`#2e7d32`, `#f9a825`, `#9e9e9e`, `#c62828`)
- Residual cloud sizing (`cloud_size_by_residual(r) = log(1 + r) * 10 + 5`)
- Tamper-evident SHA-256 provenance receipts (`Receipt`)
"""
module Epistemic

using Dates
using JSON3
using OrderedCollections
using SHA

export WorldCandidate, Case, Receipt,
       present_in_every_admissible_world,
       present_in_some_admissible_world,
       absent_in_every_admissible_world,
       epistemic_status, epistemic_colour, cloud_size_by_residual,
       build_epistemic_case, create_receipt, receipt_dict, verify_receipt

const EPISTEMIC_COLOURS = OrderedDict{Symbol,String}(
    :present_in_every => "#2e7d32",
    :present_in_some  => "#f9a825",
    :absent           => "#9e9e9e",
    :sans_fibre       => "#c62828",
)

const RECEIPT_SCHEMA_VERSION = 1

"""
    WorldCandidate(id; parameters, present_ids, weights, log_likelihood)

One admissible parameter world (for example, a support threshold, a placement
likelihood-weight candidate configuration, or a taxonomic assignment model)
recording the set of clade or taxon identifiers warranted in that world.
"""
struct WorldCandidate
    id             :: String
    parameters     :: OrderedDict{String,Any}
    present_ids    :: Set{String}
    weights        :: Dict{String,Float64}
    log_likelihood :: Union{Float64,Nothing}
end

function WorldCandidate(
    id::AbstractString;
    parameters::AbstractDict = OrderedDict{String,Any}(),
    present_ids::AbstractSet = Set{String}(),
    weights::AbstractDict = Dict{String,Float64}(),
    log_likelihood::Union{Real,Nothing} = nothing,
)
    params = OrderedDict{String,Any}(String(k) => v for (k, v) in pairs(parameters))
    pids = Set{String}(String(x) for x in present_ids)
    wts = Dict{String,Float64}(String(k) => Float64(v) for (k, v) in pairs(weights))
    ll = log_likelihood === nothing ? nothing : Float64(log_likelihood)
    WorldCandidate(String(id), params, pids, wts, ll)
end

"""
    Case(label, worlds; unanchored_ids, threshold, metadata)

A finite fibre of admissible `WorldCandidate` instances against which clade
membership and reassignment proposals are tested.
"""
struct Case
    label          :: String
    worlds         :: Vector{WorldCandidate}
    unanchored_ids :: Set{String}
    threshold      :: Float64
    metadata       :: OrderedDict{String,Any}
end

function Case(
    label::AbstractString,
    worlds::AbstractVector{WorldCandidate};
    unanchored_ids::AbstractSet = Set{String}(),
    threshold::Real = 0.80,
    metadata::AbstractDict = OrderedDict{String,Any}(),
)
    t = Float64(threshold)
    (isfinite(t) && 0.0 <= t <= 1.0) ||
        throw(ArgumentError("Epistemic threshold must be finite in [0, 1], got $threshold"))
    unanchored = Set{String}(String(x) for x in unanchored_ids)
    meta = OrderedDict{String,Any}(String(k) => v for (k, v) in pairs(metadata))
    Case(String(label), collect(WorldCandidate, worlds), unanchored, t, meta)
end

"""
    present_in_every_admissible_world(c::Case, id::AbstractString) -> Bool

True iff `c.worlds` is non-empty, `id` is not unanchored (`sans_fibre`), and `id`
is present in every world in `c.worlds`. Matches `presentInEvery` in
`proofs/agda/MetaManifold/CladeCumulus.agda`.
"""
function present_in_every_admissible_world(c::Case, id::AbstractString)::Bool
    isempty(c.worlds) && return false
    key = String(id)
    key in c.unanchored_ids && return false
    all(w -> key in w.present_ids, c.worlds)
end

"""
    present_in_some_admissible_world(c::Case, id::AbstractString) -> Bool

True iff `id` is not unanchored and is present in at least one world of `c.worlds`.
"""
function present_in_some_admissible_world(c::Case, id::AbstractString)::Bool
    isempty(c.worlds) && return false
    key = String(id)
    key in c.unanchored_ids && return false
    any(w -> key in w.present_ids, c.worlds)
end

"""
    absent_in_every_admissible_world(c::Case, id::AbstractString) -> Bool

True iff `c.worlds` is non-empty, `id` is not unanchored, and `id` is absent
from every world in `c.worlds`.
"""
function absent_in_every_admissible_world(c::Case, id::AbstractString)::Bool
    isempty(c.worlds) && return false
    key = String(id)
    key in c.unanchored_ids && return false
    all(w -> !(key in w.present_ids), c.worlds)
end

"""
    epistemic_status(c::Case, id::AbstractString) -> Symbol

Classify `id` into one of `:present_in_every`, `:present_in_some`, `:absent`,
or `:sans_fibre`.
"""
function epistemic_status(c::Case, id::AbstractString)::Symbol
    key = String(id)
    (isempty(c.worlds) || key in c.unanchored_ids) && return :sans_fibre
    present_in_every_admissible_world(c, key) && return :present_in_every
    absent_in_every_admissible_world(c, key) && return :absent
    return :present_in_some
end

"""
    epistemic_colour(status::Symbol) -> String

Map an epistemic status symbol to its fixed accessible hex colour:
- `:present_in_every` => `"#2e7d32"`
- `:present_in_some`  => `"#f9a825"`
- `:absent`           => `"#9e9e9e"`
- `:sans_fibre`       => `"#c62828"`
"""
function epistemic_colour(status::Symbol)::String
    haskey(EPISTEMIC_COLOURS, status) ||
        throw(ArgumentError("Unknown epistemic status: $(repr(status))"))
    EPISTEMIC_COLOURS[status]
end

"""
    cloud_size_by_residual(residual_count::Real) -> Float64

Marker diameter `log(1 + residual_count) * 10 + 5` encoding unresolved read
mass (unassigned taxonomy, split placement likelihood weight, or low-support
branch uncertainty). Rejects negative or non-finite values.
"""
function cloud_size_by_residual(residual_count::Real)::Float64
    r = Float64(residual_count)
    (isfinite(r) && r >= 0.0) ||
        throw(ArgumentError("residual_count must be finite and non-negative, got $residual_count"))
    log(1.0 + r) * 10.0 + 5.0
end

"""
    build_epistemic_case(label, node_supports, active_ids; unanchored_ids, support_threshold, permissive_threshold, metadata)

Construct a concrete multi-world `Case` across strict (`support_threshold`),
moderate (`0.5 * (support_threshold + permissive_threshold)`), and permissive
(`permissive_threshold`) support worlds for nodes carrying active read support.
Nodes whose active reads are zero are absent in every world; nodes listed in
`unanchored_ids` receive status `:sans_fibre`.
"""
function build_epistemic_case(
    label::AbstractString,
    node_supports::AbstractDict{String,Float64},
    active_ids::AbstractSet{String};
    unanchored_ids::AbstractSet{String} = Set{String}(),
    support_threshold::Real = 0.80,
    permissive_threshold::Real = 0.50,
    metadata::AbstractDict = OrderedDict{String,Any}(),
)::Case
    strict_t = clamp(Float64(support_threshold), 0.0, 1.0)
    perm_t = clamp(min(Float64(permissive_threshold), strict_t), 0.0, 1.0)
    mid_t = 0.5 * (strict_t + perm_t)

    thresholds = [("strict", strict_t), ("moderate", mid_t), ("permissive", perm_t)]
    worlds = WorldCandidate[]
    for (wname, th) in thresholds
        present = Set{String}()
        wts = Dict{String,Float64}()
        for id in active_ids
            s = get(node_supports, id, 1.0)
            wts[id] = s
            if s >= th
                push!(present, id)
            end
        end
        push!(worlds, WorldCandidate(
            wname;
            parameters = OrderedDict{String,Any}("min_support" => th),
            present_ids = present,
            weights = wts,
        ))
    end
    Case(
        label,
        worlds;
        unanchored_ids = unanchored_ids,
        threshold = strict_t,
        metadata = metadata,
    )
end

## Cryptographic provenance receipt
struct Receipt
    schema_version :: Int
    study          :: String
    run            :: String
    source_digests :: OrderedDict{String,String}
    tool_records   :: Vector{OrderedDict{String,Any}}
    parameters     :: OrderedDict{String,Any}
    warnings       :: Vector{String}
    created_at     :: String
    checksum       :: String
end

_canonical_json_value(x::AbstractDict) =
    OrderedDict{String,Any}(String(k) => _canonical_json_value(x[k])
                            for k in sort!(collect(keys(x)); by=string))
_canonical_json_value(x::AbstractVector) = Any[_canonical_json_value(v) for v in x]
_canonical_json_value(x::Symbol) = String(x)
_canonical_json_value(x) = x

function _receipt_payload(
    schema_version::Int,
    study::AbstractString,
    run::AbstractString,
    source_digests::AbstractDict,
    tool_records::AbstractVector,
    parameters::AbstractDict,
    warnings::AbstractVector,
    created_at::AbstractString,
)::OrderedDict{String,Any}
    OrderedDict{String,Any}(
        "created_at"     => String(created_at),
        "parameters"     => _canonical_json_value(parameters),
        "run"            => String(run),
        "schema_version" => schema_version,
        "source_digests" => _canonical_json_value(source_digests),
        "study"          => String(study),
        "tool_records"   => Any[_canonical_json_value(r) for r in tool_records],
        "warnings"       => String[String(w) for w in warnings],
    )
end

function _compute_receipt_checksum(payload::OrderedDict{String,Any})::String
    bytes2hex(sha256(JSON3.write(payload)))
end

function create_receipt(;
    study::AbstractString,
    run::AbstractString,
    source_digests::AbstractDict = OrderedDict{String,String}(),
    tool_records::AbstractVector = OrderedDict{String,Any}[],
    parameters::AbstractDict = OrderedDict{String,Any}(),
    warnings::AbstractVector{<:AbstractString} = String[],
    created_at::AbstractString = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS") * "Z",
)::Receipt
    digests = OrderedDict{String,String}()
    for k in sort!(collect(keys(source_digests)); by=string)
        digests[String(k)] = string(source_digests[k])
    end
    tools = OrderedDict{String,Any}[_canonical_json_value(t) for t in tool_records]
    params = _canonical_json_value(parameters)
    warns = String[String(w) for w in warnings]
    payload = _receipt_payload(
        RECEIPT_SCHEMA_VERSION, study, run, digests, tools, params, warns, created_at
    )
    checksum = _compute_receipt_checksum(payload)
    Receipt(
        RECEIPT_SCHEMA_VERSION,
        String(study),
        String(run),
        digests,
        tools,
        params,
        warns,
        String(created_at),
        checksum,
    )
end

function receipt_dict(r::Receipt)::OrderedDict{String,Any}
    d = _receipt_payload(
        r.schema_version,
        r.study,
        r.run,
        r.source_digests,
        r.tool_records,
        r.parameters,
        r.warnings,
        r.created_at,
    )
    d["checksum"] = r.checksum
    d
end

function verify_receipt(d::AbstractDict)::Bool
    claimed = get(d, "checksum", get(d, :checksum, nothing))
    claimed isa AbstractString || return false
    payload = _receipt_payload(
        Int(get(d, "schema_version", get(d, :schema_version, 0))),
        string(get(d, "study", get(d, :study, ""))),
        string(get(d, "run", get(d, :run, ""))),
        get(d, "source_digests", get(d, :source_digests, OrderedDict{String,String}())),
        get(d, "tool_records", get(d, :tool_records, Any[])),
        get(d, "parameters", get(d, :parameters, OrderedDict{String,Any}())),
        get(d, "warnings", get(d, :warnings, String[])),
        string(get(d, "created_at", get(d, :created_at, ""))),
    )
    _compute_receipt_checksum(payload) == lowercase(strip(claimed))
end

verify_receipt(r::Receipt)::Bool = verify_receipt(receipt_dict(r))

end # module Epistemic
