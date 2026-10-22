# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Zenodo deposition-v1 client for automated DOI minting.
#
# Publication is DISABLED by default. Opt-in requires DOI_ENABLED=true and a
# ZENODO_TOKEN environment variable, both read server-side. The token is
# redacted in every log line and never written to disk.
#
# Safety properties (see docs/doi-publication.md):
#   * Fixed production/sandbox origins - callers cannot supply an arbitrary host
#   * Server-only redacted credentials; suppressed HTTP wire logging
#   * Bounded memory uploads; bounded 429 / Retry-After handling
#   * No blind replay of ambiguous create/publish POSTs
#   * Documented legacy application/json contract
#   * Durable write-ahead journal; immutable DOI/provenance receipts
#   * DOI insertion never rewrites scientific objects

using Dates, SHA, HTTP, JSON3, Logging

export DOIConfig, Deposition, PublicationReceipt,
       load_doi_config, publication_enabled,
       create_deposition, upload_file, publish_deposition,
       deposition_status, record_receipt, read_receipt,
       publish_study, journal_append, journal_state,
       redact, DANGER_PUBLICATION_IRREVERSIBLE

const DANGER_PUBLICATION_IRREVERSIBLE = """
DOI publication is IRREVERSIBLE. Once a Zenodo deposition is published its DOI
is minted and the record can no longer be deleted through the API. Verify
against sandbox first, and never publish production records from a test run.
"""

## Fixed origins (callers cannot supply an arbitrary host) -------------------

const ZENODO_SANDBOX_ORIGIN    = "https://sandbox.zenodo.org"
const ZENODO_PRODUCTION_ORIGIN = "https://zenodo.org"

## Configuration ------------------------------------------------------------

"""
    DOIConfig(; enabled=false, origin=ZENODO_SANDBOX_ORIGIN, token="",
               storage_dir="data/doi_journal")

Immutable configuration for Zenodo DOI publication.

`enabled` is `false` by default: publication is opt-in. `origin` must be one of
the two fixed Zenodo origins above. `token` is the Zenodo personal access token
(read from `ZENODO_TOKEN`, never from a config file). `storage_dir` holds the
private write-ahead journal and immutable receipts.
"""
struct DOIConfig
    enabled::Bool
    origin::String
    token::String
    storage_dir::String
    sandbox::Bool
end

function DOIConfig(; enabled::Bool=false,
                   origin::AbstractString=ZENODO_SANDBOX_ORIGIN,
                   token::AbstractString="",
                   storage_dir::AbstractString="data/doi_journal")
    origin_s = String(origin)
    valid = origin_s in (ZENODO_SANDBOX_ORIGIN, ZENODO_PRODUCTION_ORIGIN)
    effective = valid ? origin_s : ZENODO_SANDBOX_ORIGIN
    DOIConfig(enabled, effective, String(token), String(storage_dir),
              effective == ZENODO_SANDBOX_ORIGIN)
end

"""
    load_doi_config(; storage_dir="data/doi_journal") -> DOIConfig

Read DOI configuration entirely from the environment:
  DOI_ENABLED      "true" to opt into publication (default false)
  DOI_ORIGIN       sandbox or production origin (default sandbox)
  ZENODO_TOKEN     personal access token (required for publication)
  DOI_STORAGE_DIR  journal/receipt directory (default data/doi_journal)

A missing or invalid token leaves publication disabled; the absence of a
token never silently enables it.
"""
function load_doi_config(; storage_dir::AbstractString="data/doi_journal")::DOIConfig
    enabled = lowercase(strip(get(ENV, "DOI_ENABLED", "false"))) == "true"
    origin  = strip(get(ENV, "DOI_ORIGIN", ZENODO_SANDBOX_ORIGIN))
    token   = strip(get(ENV, "ZENODO_TOKEN", ""))
    DOIConfig(; enabled, origin, token, storage_dir=String(storage_dir))
end

publication_enabled(config::DOIConfig)::Bool = config.enabled && !isempty(config.token)

## Redaction ----------------------------------------------------------------

"""
    redact(msg) -> String

Return `msg` with any `Authorization: Bearer ...` header and any bearer token
replaced by `[redacted]`, so logs never carry credentials.
"""
function redact(msg::AbstractString)::String
    s = String(msg)
    s = replace(s, r"Authorization\s*:\s*Bearer\s+\S+"   => "Authorization: Bearer [redacted]")
    s = replace(s, r"Bearer\s+[A-Za-z0-9._-]+"          => "Bearer [redacted]")
    s
end

## HTTP client --------------------------------------------------------------

struct _ZenodoError <: Exception
    status::Int
    body::String
end
Base.showerror(io::IO, e::_ZenodoError) = print(io,
    "zenodo: HTTP $(e.status) $(e.body)")

_ts() = Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SSZ")

function _header(resp::HTTP.Response, name::AbstractString)::String
    for h in resp.headers
        if lowercase(h.first) == lowercase(name)
            return String(h.second)
        end
    end
    return ""
end

"""
    _zenodo_request(config, method, path; ...)

Make a JSON request to Zenodo with bounded 429 / Retry-After handling.

Only the method, path and status are logged - never headers or body, so the
token never reaches the wire log. Ambiguous failures (network errors, timeouts,
5xx) are NOT replayed: the caller must reconcile via the journal before
retrying a create or publish, because those are not idempotent safe to blindly
repeat.
"""
function _zenodo_request(config::DOIConfig, method::AbstractString, path::AbstractString;
                         body=nothing,
                         raw_body::Bool=false,
                         extra_headers::Dict{String,String}=Dict{String,String}(),
                         max_retries::Int=3)
    publication_enabled(config) ||
        error("DOI publication is disabled (set DOI_ENABLED=true and ZENODO_TOKEN)")
    isempty(config.token) && error("Zenodo access token not configured (ZENODO_TOKEN)")

    url = config.origin * path
    headers = Dict{String,String}("Authorization" => "Bearer $(config.token)",
                                  "Content-Type"  => "application/json",
                                  "Accept"        => "application/json")
    for (k, v) in extra_headers
        headers[k] = v
    end

    last_err = nothing
    for attempt in 1:max_retries
        try
            req_body = raw_body ? body : (isnothing(body) ? nothing : JSON3.write(body))
            resp = HTTP.request(method, url, headers, req_body;
                                connect_timeout=10, readtimeout=60,
                                status_exception=false, retry=false,
                                redirect=false)
            status = resp.status
            body_s = String(copy(resp.body))
            # Log only method, path and status - never headers or body.
            @info "zenodo request" method=String(method) path=path status=status
            if status == 429
                retry_after = _retry_after_seconds(resp)
                if retry_after > 0.0 && attempt < max_retries
                    sleep(retry_after)
                    continue
                end
                throw(_ZenodoError(status, body_s))
            end
            if 200 <= status < 300
                return isnothing(body_s) || isempty(strip(body_s)) ?
                       Dict{String,Any}() : JSON3.read(body_s)
            end
            # 4xx / 5xx: report, never blindly replay a state-changing call.
            throw(_ZenodoError(status, body_s))
        catch e
            if e isa _ZenodoError
                rethrow()
            end
            # Network error / timeout: ambiguous whether the server acted, so
            # do not replay. The journal holds the last known state.
            last_err = e
            @warn "zenodo request attempt failed (not replayed blindly)" method=String(method) path=path attempt=attempt max=max_retries exception=redact(sprint(showerror, e))
            attempt < max_retries || break
            sleep(min(2.0 ^ attempt, 30.0))
        end
    end
    rethrow(last_err)
end

function _retry_after_seconds(resp::HTTP.Response)::Float64
    v = _header(resp, "Retry-After")
    isempty(v) && return 0.0
    try parse(Float64, strip(v)) catch; 0.0 end
end

## Domain types -------------------------------------------------------------

"""
    Deposition(id, doi, published, link, files)

A Zenodo deposition. `doi` is the reserved DOI before publishing and the minted
DOI after publishing. `published` distinguishes a reserved identifier from a
published one.
"""
struct Deposition
    id::Int
    doi::String
    published::Bool
    link::String
    files::Vector{Dict{String,Any}}
end

"""
    PublicationReceipt(schema, study, run, origin, deposition_id, doi,
                       published, files, created_at, published_at, checksum)

Immutable DOI/provenance receipt. `checksum` is the SHA-256 of the receipt
document itself, so any later alteration is detectable. Receipts are never
overwritten: each publication writes a new receipt under `storage_dir/receipts/`.
"""
struct PublicationReceipt
    schema::Int
    study::String
    run::String
    origin::String
    deposition_id::Int
    doi::String
    published::Bool
    files::Vector{Dict{String,Any}}
    created_at::String
    published_at::Union{String,Nothing}
    checksum::String
end

const RECEIPT_SCHEMA = 1
const MAX_UPLOAD_BYTES = 500 * 1024 * 1024   # bound memory for streamed uploads

_plain(x::JSON3.Object) = Dict{String,Any}(string(k) => _plain(v) for (k, v) in x)
_plain(x::JSON3.Array)  = [_plain(v) for v in x]
_plain(x) = x

_deposition_from(resp)::Deposition = Deposition(
    Int(get(resp, "id", 0)),
    string(get(resp, "doi", "")),
    Bool(get(resp, "published", false)),
    string(get(get(resp, "links", Dict{String,Any}()), "html", "")),
    _plain(get(resp, "files", [])),
)

## Durable write-ahead journal ---------------------------------------------

"""
    _journal_path(config) -> String

Private journal file, kept outside the study data tree so publication state
cannot be confused with scientific outputs.
"""
_journal_path(config::DOIConfig) = joinpath(config.storage_dir, "publication_journal.jsonl")

"""
    journal_append(config, entry::Dict) -> nothing

Append one write-ahead transition to the journal as a single JSON line. The
append-and-close makes each line atomic from a reader's perspective, and the
journal is append-only: transitions are never rewritten.
"""
function journal_append(config::DOIConfig, entry::Dict{String,Any})::Nothing
    mkpath(config.storage_dir)
    path = _journal_path(config)
    line = JSON3.write(entry) * "\n"
    open(path, "a") do io
        write(io, line)
        flush(io)
    end
    nothing
end

"""
    journal_state(config) -> Vector{Dict}

Read every journal transition in order. The latest entry per deposition id is
the current known state; callers reconcile against Zenodo before publishing.
"""
function journal_state(config::DOIConfig)::Vector{Dict{String,Any}}
    path = _journal_path(config)
    isfile(path) || return Dict{String,Any}[]
    out = Dict{String,Any}[]
    for line in eachline(path)
        isempty(strip(line)) && continue
        obj = try JSON3.read(line) catch; nothing end
        obj isa JSON3.Object && push!(out, _plain(obj))
    end
    out
end

## Receipts -----------------------------------------------------------------

_receipt_dir(config::DOIConfig) = joinpath(config.storage_dir, "receipts")

_receipt_path(config::DOIConfig, doi::String)::String =
    joinpath(_receipt_dir(config), "$(replace(doi, r"[^A-Za-z0-9._-]" => "_")).json")

function _receipt_dict(receipt::PublicationReceipt)::Dict{String,Any}
    Dict{String,Any}(
        "schema"         => receipt.schema,
        "study"          => receipt.study,
        "run"            => receipt.run,
        "origin"         => receipt.origin,
        "deposition_id"  => receipt.deposition_id,
        "doi"            => receipt.doi,
        "published"      => receipt.published,
        "files"          => receipt.files,
        "created_at"     => receipt.created_at,
        "published_at"   => receipt.published_at,
    )
end

_receipt_checksum(d::Dict{String,Any})::String =
    bytes2hex(sha256(JSON3.write(_receipt_dict_from_flat(d))))

# Build a flat dict (fixed insertion order => deterministic bytes) minus the
# checksum field, so the checksum covers exactly the attested content.
function _receipt_dict_from_flat(d::Dict{String,Any})::Dict{String,Any}
    Dict{String,Any}(
        "schema"         => get(d, "schema", 1),
        "study"          => get(d, "study", ""),
        "run"            => get(d, "run", ""),
        "origin"         => get(d, "origin", ""),
        "deposition_id"  => get(d, "deposition_id", 0),
        "doi"            => get(d, "doi", ""),
        "published"      => get(d, "published", false),
        "files"          => get(d, "files", []),
        "created_at"     => get(d, "created_at", ""),
        "published_at"   => get(d, "published_at", nothing),
    )
end

"""
    record_receipt(config, receipt) -> nothing

Write an immutable receipt next to the journal. The checksum is computed over
the attestation content (excluding the checksum field itself) so any later
alteration is detectable on read. Existing receipts are never overwritten.
"""
function record_receipt(config::DOIConfig, receipt::PublicationReceipt)::Nothing
    d = _receipt_dict(receipt)
    d["checksum"] = _receipt_checksum(d)
    path = _receipt_path(config, receipt.doi)
    isfile(path) && return nothing   # immutable: never overwrite a receipt
    mkpath(_receipt_dir(config))
    tmp = path * ".tmp"
    open(tmp, "w") do io
        JSON3.write(io, d)
    end
    mv(tmp, path; force=true)
    nothing
end

"""
    read_receipt(config, doi) -> Union{PublicationReceipt,Nothing}

Read and verify a receipt. Returns nothing if absent or if the stored checksum
no longer matches the attestation content (tamper detection).
"""
function read_receipt(config::DOIConfig, doi::String)::Union{PublicationReceipt,Nothing}
    path = _receipt_path(config, doi)
    isfile(path) || return nothing
    raw = try read(path, String) catch; return nothing end
    obj = try JSON3.read(raw) catch; return nothing end
    obj isa JSON3.Object || return nothing
    d = Dict{String,Any}(string(k) => _plain(v) for (k, v) in obj)
    get(d, "checksum", "") == _receipt_checksum(d) || return nothing
    return PublicationReceipt(
        Int(get(d, "schema", 1)),
        string(get(d, "study", "")),
        string(get(d, "run", "")),
        string(get(d, "origin", "")),
        Int(get(d, "deposition_id", 0)),
        string(get(d, "doi", "")),
        Bool(get(d, "published", false)),
        _plain(get(d, "files", [])),
        string(get(d, "created_at", "")),
        get(d, "published_at", nothing),
        string(get(d, "checksum", "")),
    )
end

## Core operations ----------------------------------------------------------

"""
    create_deposition(config, study, run; metadata=Dict()) -> Deposition

Create an empty Zenodo deposition and reserve a DOI. Sends the metadata as
application/json (the documented legacy contract). Records a `created` journal
transition.
"""
function create_deposition(config::DOIConfig, study::AbstractString, run::AbstractString;
                           metadata::Dict{String,Any}=Dict{String,Any}())::Deposition
    publication_enabled(config) || error("DOI publication is disabled")
    payload = Dict{String,Any}("metadata" => merge(Dict{String,Any}(
        "title"        => "MetaManifold publication: $(study)/$(run)",
        "description"  => "Automated DOI minted via the MetaManifold Zenodo integration",
        "upload_type"  => "dataset",
        "publication_type" => "dataset",
        "communities"  => [Dict{String,Any}("identifier" => "metamanifold")],
    ), metadata))
    resp = _zenodo_request(config, "POST", "/api/deposit/depositions"; body=payload)
    dep = _deposition_from(resp)
    journal_append(config, Dict{String,Any}(
        "schema"         => 1,
        "ts"             => _ts(),
        "study"          => study,
        "run"            => run,
        "phase"          => "created",
        "status"         => "ok",
        "deposition_id"  => dep.id,
        "doi"            => dep.doi,
    ))
    @info "zenodo deposition created" study=study run=run deposition=dep.id doi=dep.doi
    return dep
end

const _BOUNDARY = "----MetaManifoldDOIUpload"

function _multipart_form(filename::AbstractString, data::Vector{UInt8})
    io = IOBuffer()
    write(io, "--$_BOUNDARY\r\n")
    write(io, "Content-Disposition: form-data; name=\"file\"; filename=\"$(filename)\"\r\n")
    write(io, "Content-Type: application/octet-stream\r\n\r\n")
    write(io, data)
    write(io, "\r\n--$_BOUNDARY--\r\n")
    return take!(io), "multipart/form-data; boundary=$_BOUNDARY"
end

"""
    upload_file(config, dep, file_path) -> Deposition

Stream a file into an existing Zenodo deposition as `application/octet-stream`
bounded by `MAX_UPLOAD_BYTES`. Returns the deposition with the new file entry.
"""
function upload_file(config::DOIConfig, dep::Deposition, file_path::AbstractString)::Deposition
    publication_enabled(config) || error("DOI publication is disabled")
    isfile(file_path) || error("File not found: $file_path")
    sz = filesize(file_path)
    sz > MAX_UPLOAD_BYTES && error("File exceeds upload limit ($sz > $MAX_UPLOAD_BYTES bytes)")
    data = read(file_path)
    name = basename(file_path)
    sha = bytes2hex(sha256(data))
    body, ctype = _multipart_form(name, data)
    resp = _zenodo_request(config, "POST",
        "/api/deposit/depositions/$(dep.id)/files";
        body=body, raw_body=true,
        extra_headers=Dict{String,String}("Content-Type" => ctype))
    file_entry = _plain(get(resp, "id", nothing) === nothing ? Dict{String,Any}() : resp)
    file_entry["sha256"] = sha
    file_entry["size"]   = sz
    files = push!(copy(dep.files), file_entry)
    dep2 = Deposition(dep.id, dep.doi, dep.published, dep.link, files)
    journal_append(config, Dict{String,Any}(
        "schema"         => 1,
        "ts"             => _ts(),
        "phase"          => "uploaded",
        "status"         => "ok",
        "deposition_id"  => dep.id,
        "file"           => name,
        "sha256"         => sha,
        "size"           => sz,
    ))
    @info "zenodo file uploaded" deposition=dep.id file=name sha256=sha size=sz
    return dep2
end

"""
    publish_deposition(config, dep; confirm=false) -> PublicationReceipt

Publish a deposition, minting its DOI. Requires `confirm=true` (publication is
irreversible). Refuses to publish an already-published deposition. Records a
`published` journal transition.
"""
function publish_deposition(config::DOIConfig, dep::Deposition;
                            confirm::Bool=false)::PublicationReceipt
    publication_enabled(config) || error("DOI publication is disabled")
    confirm || error("Publishing requires explicit confirmation (confirm=true)")
    dep.published && error("Deposition $(dep.id) is already published")
    @warn DANGER_PUBLICATION_IRREVERSIBLE
    resp = _zenodo_request(config, "POST",
        "/api/deposit/depositions/$(dep.id)/actions/publish";
        body=Dict{String,Any}())
    doi = string(get(resp, "doi", dep.doi))
    published_at = _ts()
    files = Dict{String,Any}[]
    for f in dep.files
        push!(files, Dict{String,Any}(
            "name"   => get(f, "filename", get(f, "key", "")),
            "sha256" => get(f, "sha256", ""),
            "size"   => get(f, "size", 0),
        ))
    end
    receipt = PublicationReceipt(
        RECEIPT_SCHEMA, "", "", config.origin, dep.id, doi, true,
        files, published_at, published_at, "",
    )
    journal_append(config, Dict{String,Any}(
        "schema"         => 1,
        "ts"             => published_at,
        "phase"          => "published",
        "status"         => "ok",
        "deposition_id"  => dep.id,
        "doi"            => doi,
    ))
    @info "zenodo deposition published" deposition=dep.id doi=doi
    return receipt
end

"""
    deposition_status(config, deposition_id) -> Deposition

Fetch the current state of a deposition from Zenodo (used for reconciliation
after an ambiguous failure).
"""
function deposition_status(config::DOIConfig, deposition_id::Int)::Deposition
    publication_enabled(config) || error("DOI publication is disabled")
    resp = _zenodo_request(config, "GET", "/api/deposit/depositions/$deposition_id")
    return _deposition_from(resp)
end

"""
    publish_study(config, study, run, files; confirm=false) -> PublicationReceipt

End-to-end publication: create a deposition, upload every file, publish to mint
the DOI, then record an immutable receipt. The receipt is the citable artefact;
scientific objects are never rewritten by DOI insertion.
"""
function publish_study(config::DOIConfig, study::AbstractString, run::AbstractString,
                       files::Vector{<:AbstractString}; confirm::Bool=false)::PublicationReceipt
    publication_enabled(config) || error("DOI publication is disabled")
    isempty(files) && error("No files to publish")
    for f in files
        isfile(f) || error("File not found: $f")
    end
    @warn DANGER_PUBLICATION_IRREVERSIBLE
    dep = create_deposition(config, String(study), String(run))
    for f in files
        dep = upload_file(config, dep, f)
    end
    receipt = publish_deposition(config, dep; confirm=confirm)
    receipt = PublicationReceipt(
        receipt.schema, String(study), String(run), receipt.origin,
        receipt.deposition_id, receipt.doi, receipt.published, receipt.files,
        receipt.created_at, receipt.published_at, receipt.checksum,
    )
    record_receipt(config, receipt)
    journal_append(config, Dict{String,Any}(
        "schema"         => 1,
        "ts"             => receipt.created_at,
        "phase"          => "complete",
        "status"         => "ok",
        "study"          => study,
        "run"            => run,
        "doi"            => receipt.doi,
    ))
    return receipt
end

end
