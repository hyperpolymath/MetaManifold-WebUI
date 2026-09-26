# SPDX-License-Identifier: MPL-2.0
# A durable, recoverable two-phase publication journal. No tokens in state or bundles.
module DOIPublications

using JSON3, SHA, Dates
using ..DOIStorage
using ..DOIBundles
import ..Zenodo

export prepare!, resume!, publish!, refresh!, recover_creation!, status, publications,
       publication_path, confirmation_phrase, receipt, download_path

const SCHEMA_VERSION = "1.0.0"
const MAX_ARCHIVE_BYTES = 50_000_000_000
const STATES = Set(["preparing", "creating", "creation_uncertain", "draft", "ready", "publishing", "publication_uncertain", "published"])

function publication_path(root::AbstractString, id::AbstractString)
    occursin(r"^[0-9a-f]{64}$", id) || throw(PublicationError(404, "publication_not_found", "Publication not found."))
    joinpath(root, id)
end
_state_path(root, id) = joinpath(publication_path(root, id), "state.json")
_archive_name(id) = "metamanifold-" * id * ".zip"
_archive(root, s) = joinpath(publication_path(root, s["id"]), _archive_name(s["id"]))

function _read(root, id)
    path = _state_path(root, id)
    isfile(path) && !islink(path) || throw(PublicationError(404, "publication_not_found", "Publication not found."))
    s = try read_json(path) catch; throw(PublicationError(409, "corrupt_publication", "Publication state cannot be read. Restore its journal from backup; do not create a replacement.")) end
    get(s, "schema_version", nothing) == SCHEMA_VERSION && get(s, "id", nothing) == id && get(s, "state", "") in STATES ||
        throw(PublicationError(409, "corrupt_publication", "Unsupported or inconsistent publication journal."))
    return s
end

function _save(root, s, event)
    s["updated_at"] = string(now(UTC)) * "Z"
    push!(s["events"], Dict("at" => s["updated_at"], "event" => event, "state" => s["state"]))
    atomic_json(_state_path(root, s["id"]), s)
    return s
end

function _client_matches(s, client)
    s["environment"] == client.environment || throw(PublicationError(409, "environment_mismatch", "This publication belongs to a different Zenodo environment. Ask the operator to select its original environment."))
end

confirmation_phrase(s) = "PUBLISH " * s["environment"] * " " * something(s["deposition_id"], "unprepared")

function _public(s)
    # Deliberate allowlist: internal paths, raw remote responses and credentials
    # cannot accidentally become a future public API field.
    fields = ("schema_version", "id", "state", "environment", "binding", "metadata", "deposition_id",
              "reserved_doi", "doi", "record_url", "bundle_sha256", "bundle_md5", "bundle_size",
              "created_at", "updated_at", "published_at", "last_error")
    result = Dict{String,Any}(key => get(s, key, nothing) for key in fields)
    result["confirmation_phrase"] = confirmation_phrase(s)
    result["citation"] = s["state"] == "published" ? citation_text(s["metadata"], s["doi"]) : nothing
    result["doi_url"] = s["state"] == "published" ? "https://doi.org/" * s["doi"] : nothing
    result["draft_url"] = isnothing(s["deposition_id"]) ? nothing : Zenodo.ORIGINS[s["environment"]] * "/deposit/" * s["deposition_id"]
    result["test_record"] = s["environment"] == "sandbox"
    return result
end
status(root, id) = _public(_read(root, id))

function publications(root)
    isdir(root) || return Dict{String,Any}[]
    [_public(_read(root, id)) for id in sort!(readdir(root)) if occursin(r"^[0-9a-f]{64}$", id) && isfile(_state_path(root, id))]
end

function _local_integrity(root, s)
    archive = _archive(root, s)
    isfile(archive) && !islink(archive) && file_sha256(archive) == s["bundle_sha256"] && filesize(archive) == s["bundle_size"] ||
        throw(PublicationError(409, "bundle_changed", "The frozen archive is missing or changed. Restore its exact bytes; do not publish a replacement under this confirmation."))
    return archive
end

# Zenodo adds fields to creators/related identifiers; compare the fields we sent,
# not whole response dictionaries. Arrays remain order-sensitive for authorship.
_subset(expected::AbstractDict, actual::AbstractDict) = all(haskey(actual, k) && _subset(v, actual[k]) for (k, v) in expected)
_subset(expected::AbstractVector, actual::AbstractVector) = length(expected) == length(actual) && all(_subset(a, b) for (a, b) in zip(expected, actual))
_subset(expected, actual) = expected == actual

function _remote_metadata(s, deposit, client)
    Zenodo.checked_id(get(deposit, "id", nothing)) == s["deposition_id"] ||
        throw(PublicationError(409, "deposition_mismatch", "Zenodo returned a different deposition. Refusing to continue."))
    expected = zenodo_metadata(s["metadata"], s["binding"], s["id"])
    delete!(expected, "prereserve_doi")
    actual = get(deposit, "metadata", nothing)
    actual isa AbstractDict && _subset(expected, actual) ||
        throw(PublicationError(409, "remote_metadata_changed", "Zenodo metadata differs from the frozen publication request. Review the existing draft; it was not overwritten or published."))
    doi = get(deposit, "submitted", false) === true ?
        Zenodo.checked_doi(client, get(deposit, "doi", get(actual, "doi", nothing))) : Zenodo.reserved_doi(client, deposit)
    if !isnothing(s["reserved_doi"])
        doi == s["reserved_doi"] || throw(PublicationError(409, "doi_changed", "The Zenodo DOI differs from the reserved identifier."))
    end
    return doi
end

function _file_matches(file, s)
    file isa AbstractDict || return false
    name = get(file, "filename", get(file, "name", get(file, "key", nothing)))
    name == _archive_name(s["id"]) || return false
    checksum = get(file, "checksum", nothing)
    checksum isa AbstractString || return false
    replace(lowercase(checksum), r"^md5:" => "") == s["bundle_md5"] || return false
    rawsize = get(file, "filesize", get(file, "size", nothing))
    size = rawsize isa AbstractString ? tryparse(Int, rawsize) : rawsize
    size isa Integer && !(size isa Bool) && size == s["bundle_size"]
end

function _remote_files(s, deposit)
    files = get(deposit, "files", nothing)
    files isa AbstractVector && length(files) == 1 && _file_matches(only(files), s) ||
        throw(PublicationError(409, "remote_files_changed", "Zenodo must contain exactly the reviewed archive with the matching size and MD5 checksum. No publication was attempted."))
    return true
end

function _make_archive!(root, s)
    directory = publication_path(root, s["id"])
    archive = _archive(root, s)
    if !isnothing(s["bundle_sha256"])
        _local_integrity(root, s)
        return
    end
    payload = joinpath(directory, "payload")
    # Before an archive hash is journalled no upload can have started. Interrupted
    # local builds may be restarted, but a journalled archive is never regenerated.
    isdir(payload) && rm(payload; recursive=true)
    isfile(archive) && rm(archive)
    cp(joinpath(directory, "source"), payload)
    decorate_bundle!(payload, s["metadata"], s["binding"], s["id"], s["environment"], s["deposition_id"], s["reserved_doi"])
    archive_bundle(payload, archive)
    chmod(archive, 0o600)
    filesize(archive) <= MAX_ARCHIVE_BYTES || throw(PublicationError(422, "bundle_too_large", "The archive exceeds Zenodo's 50 GB record limit."))
    s["bundle_sha256"] = file_sha256(archive)
    s["bundle_md5"] = file_md5(archive) # Protocol integrity only; SHA-256 is the provenance identity.
    s["bundle_size"] = filesize(archive)
    _save(root, s, "archive_frozen")
end

function _remember_error!(root, s, e)
    # Only our sanitised exceptions may reach the journal. Never persist raw HTTP
    # errors, arbitrary exception strings, remote metadata, or token-bearing URLs.
    s["last_error"] = e isa Zenodo.RemoteError || e isa PublicationError ? Dict("code" => e.code, "message" => e.message) :
        Dict("code" => "publication_failed", "message" => "Publication operation failed locally. Review the journal and retry the same operation.")
    _save(root, s, "operation_failed")
end

function _finish!(root, s, deposit, client)
    _remote_metadata(s, deposit, client)
    _remote_files(s, deposit)
    _local_integrity(root, s)
    get(deposit, "submitted", false) === true && get(deposit, "state", "") == "done" || return false
    doi = Zenodo.checked_doi(client, get(deposit, "doi", get(deposit["metadata"], "doi", nothing)))
    doi == s["reserved_doi"] || throw(PublicationError(409, "doi_changed", "Published DOI differs from the reviewed DOI."))
    s["doi"] = doi
    # Do not trust remote URLs (or render javascript: links). Construct known origins.
    s["record_url"] = Zenodo.origin(client) * "/records/" * Zenodo.checked_id(get(deposit, "record_id", s["deposition_id"]))
    receipt_path = joinpath(publication_path(root, s["id"]), "publication-receipt.json")
    if isfile(receipt_path)
        previous = read_json(receipt_path)
        previous["doi"] == doi && previous["bundle_sha256"] == s["bundle_sha256"] ||
            throw(PublicationError(409, "receipt_conflict", "An immutable publication receipt already exists with different content."))
        s["published_at"] = previous["published_at"]
    else
        s["published_at"] = string(now(UTC)) * "Z"
        # The sidecar is written BEFORE the terminal journal state. A crash here
        # is recoverable by GET/reconciliation, without a second publish POST.
        value = _public(merge(copy(s), Dict("state" => "published")))
        value["api_version"] = Zenodo.API_VERSION
        value["events"] = vcat(s["events"], [Dict("at" => s["published_at"], "event" => "publication_verified", "state" => "published")])
        atomic_json(receipt_path, value)
    end
    s["state"] = "published"
    s["last_error"] = nothing
    _save(root, s, "publication_verified")
    return true
end

function _prepare_locked!(root, s, client)
    _client_matches(s, client)
    if s["state"] in ("ready", "published", "publishing", "publication_uncertain")
        _local_integrity(root, s)
        return _public(s)
    end
    if s["state"] in ("creating", "creation_uncertain")
        throw(PublicationError(409, "creation_uncertain", "A draft creation may already have succeeded. Find its deposition ID on Zenodo and use recovery; creation will not be replayed."))
    end
    try
        if isnothing(s["deposition_id"])
            s["state"] = "creating"
            _save(root, s, "creation_started") # write-ahead, before the non-idempotent POST
            deposit = try
                Zenodo.create_deposition(client, zenodo_metadata(s["metadata"], s["binding"], s["id"]))
            catch e
                s["state"] = e isa Zenodo.RemoteError && !e.ambiguous ? "preparing" : "creation_uncertain"
                rethrow()
            end
            # If the response is malformed, creation remains uncertain, never retried.
            s["deposition_id"] = Zenodo.checked_id(get(deposit, "id", nothing))
            s["state"] = "draft"
            _save(root, s, "deposition_created")
        end
        deposit = Zenodo.get_deposition(client, s["deposition_id"])
        doi = _remote_metadata(s, deposit, client)
        s["reserved_doi"] = doi
        _save(root, s, "doi_reserved")
        _make_archive!(root, s)
        if get(deposit, "submitted", false) === true
            _finish!(root, s, deposit, client) || throw(PublicationError(409, "zenodo_pending", "Zenodo is still processing this deposition. Refresh its status."))
            return _public(s)
        end
        files = get(deposit, "files", nothing)
        files isa AbstractVector || throw(PublicationError(502, "invalid_files", "Zenodo returned an invalid file list."))
        # No extra files can hitch a ride into a publication. An interrupted PUT
        # to our one filename is safe to repeat with the same frozen bytes.
        all(f -> get(f, "filename", get(f, "name", get(f, "key", nothing))) == _archive_name(s["id"]), files) ||
            throw(PublicationError(409, "unexpected_remote_files", "The draft contains unexpected files. Review it on Zenodo before continuing."))
        if !(length(files) == 1 && _file_matches(only(files), s))
            _save(root, s, "upload_started")
            uploaded = Zenodo.upload_file(client, deposit, _local_integrity(root, s), _archive_name(s["id"]))
            _file_matches(uploaded, s) || throw(PublicationError(502, "upload_integrity_failed", "Zenodo's uploaded file checksum or size does not match the archive. Publishing is blocked."))
        end
        verified = Zenodo.get_deposition(client, s["deposition_id"])
        _remote_metadata(s, verified, client)
        _remote_files(s, verified)
        get(verified, "submitted", false) === true && throw(PublicationError(409, "remote_state_changed", "The draft was submitted outside this operation. Refresh to reconcile it."))
        s["state"] = "ready"
        s["last_error"] = nothing
        _save(root, s, "draft_verified")
        return _public(s)
    catch e
        s["state"] == "creating" && (s["state"] = "creation_uncertain")
        _remember_error!(root, s, e)
        rethrow()
    end
end

"""Freeze a local bundle, create a draft, reserve its DOI and verify its upload. Never publish."""
function prepare!(root::String, bundle::String, input::AbstractDict, client::Zenodo.Client)
    metadata = validate_metadata(input)
    binding = snapshot(bundle) # all local validation BEFORE network side effects
    isnothing(Sys.which("zip")) && throw(PublicationError(503, "zip_unavailable", "Install zip before preparing a Zenodo draft."))
    sum(filesize(joinpath(bundle, f)) for f in readdir(bundle)) <= MAX_ARCHIVE_BYTES ||
        throw(PublicationError(422, "bundle_too_large", "Bundle exceeds the supported 50 GB limit."))
    id = bytes2hex(sha256(canonical_json(Dict("environment" => client.environment, "binding" => binding))))
    directory = publication_path(root, id)
    return with_publication_lock(directory) do
        if isfile(_state_path(root, id))
            s = _read(root, id)
            canonical_json(s["metadata"]) == canonical_json(metadata) ||
                throw(PublicationError(409, "metadata_frozen", "This exact config/result already has a publication with different metadata. Resume that record; do not mint a duplicate."))
        else
            source = joinpath(directory, "source")
            isdir(source) && rm(source; recursive=true)
            cp(bundle, source)
            # Verify the copied snapshot too: a caller must not race the freeze.
            snapshot(source) == binding || throw(PublicationError(409, "bundle_changed", "The source bundle changed while it was being frozen."))
            timestamp = string(now(UTC)) * "Z"
            s = Dict{String,Any}("schema_version" => SCHEMA_VERSION, "id" => id, "state" => "preparing",
                "environment" => client.environment, "binding" => binding, "metadata" => metadata,
                "deposition_id" => nothing, "reserved_doi" => nothing, "doi" => nothing, "record_url" => nothing,
                "bundle_sha256" => nothing, "bundle_md5" => nothing, "bundle_size" => nothing,
                "created_at" => timestamp, "updated_at" => timestamp, "published_at" => nothing,
                "last_error" => nothing, "events" => Any[])
            _save(root, s, "bundle_snapshot_saved")
        end
        return _prepare_locked!(root, s, client)
    end
end

function resume!(root, id, client)
    with_publication_lock(publication_path(root, id)) do
        _prepare_locked!(root, _read(root, id), client)
    end
end

function recover_creation!(root, id, deposition_id, client)
    with_publication_lock(publication_path(root, id)) do
        s = _read(root, id)
        _client_matches(s, client)
        s["state"] in ("creating", "creation_uncertain") && isnothing(s["deposition_id"]) ||
            throw(PublicationError(409, "recovery_not_needed", "Only an uncertain draft creation can be attached to an existing deposition."))
        candidate = Zenodo.checked_id(deposition_id)
        deposit = Zenodo.get_deposition(client, candidate)
        # Validate the publication-specific metadata marker BEFORE persisting any ID.
        proposed = merge(copy(s), Dict("deposition_id" => candidate))
        _remote_metadata(proposed, deposit, client)
        isempty(get(deposit, "files", [])) && get(deposit, "submitted", false) === false ||
            throw(PublicationError(409, "unsafe_recovery", "Creation recovery requires the matching unsubmitted, empty draft."))
        s["deposition_id"] = candidate
        s["state"] = "draft"
        _save(root, s, "creation_recovered")
        _prepare_locked!(root, s, client)
    end
end

function refresh!(root, id, client)
    with_publication_lock(publication_path(root, id)) do
        s = _read(root, id)
        _client_matches(s, client)
        s["state"] == "published" && return _public(s)
        isnothing(s["deposition_id"]) && return _public(s)
        try
            deposit = Zenodo.get_deposition(client, s["deposition_id"])
            _remote_metadata(s, deposit, client)
            if !isnothing(s["bundle_sha256"])
                _remote_files(s, deposit)
                _finish!(root, s, deposit, client)
            end
            return _public(s)
        catch e
            _remember_error!(root, s, e)
            rethrow()
        end
    end
end

"""Publish once, only after confirmation of the exact environment, ID and archive SHA-256."""
function publish!(root, id, client; confirmation, bundle_sha256, acknowledge_public=false)
    with_publication_lock(publication_path(root, id)) do
        s = _read(root, id)
        _client_matches(s, client)
        # Even a repeat of a published operation must name the reviewed artifact.
        confirmation isa AbstractString && confirmation == confirmation_phrase(s) &&
            bundle_sha256 isa AbstractString && bundle_sha256 == s["bundle_sha256"] && acknowledge_public === true ||
            throw(PublicationError(422, "confirmation_required", "Publishing is irreversible and makes every file public. Confirm the exact environment, deposition ID and archive hash, and acknowledge the privacy/licensing review."))
        s["state"] == "published" && return _public(s)
        s["state"] == "ready" || throw(PublicationError(409, "publication_not_ready", "Only a verified draft may be published. Pending or uncertain submissions must be reconciled, never replayed."))
        try
            _local_integrity(root, s)
            deposit = Zenodo.get_deposition(client, s["deposition_id"])
            _remote_metadata(s, deposit, client)
            _remote_files(s, deposit)
            if get(deposit, "submitted", false) === true
                _finish!(root, s, deposit, client)
                return _public(s)
            end
            s["state"] = "publishing"
            s["last_error"] = nothing
            s["confirmation"] = Dict("phrase" => confirmation, "bundle_sha256" => bundle_sha256, "acknowledge_public" => true)
            _save(root, s, "publication_confirmed") # write-ahead BEFORE the irreversible POST
            response = try
                Zenodo.publish_deposition(client, s["deposition_id"])
            catch e
                s["state"] = e isa Zenodo.RemoteError && !e.ambiguous ? "ready" : "publication_uncertain"
                rethrow()
            end
            # 202 is acceptance, NOT proof of a published record. A subsequent GET
            # (possibly a later refresh after restart) must report submitted/done.
            Zenodo.checked_id(get(response, "id", nothing)) == s["deposition_id"] ||
                throw(PublicationError(502, "deposition_mismatch", "Publish response did not identify the expected deposition. Refresh to reconcile."))
            _save(root, s, "publication_accepted")
            verified = Zenodo.get_deposition(client, s["deposition_id"])
            _finish!(root, s, verified, client)
            return _public(s)
        catch e
            s["state"] == "publishing" && (s["state"] = "publication_uncertain")
            _remember_error!(root, s, e)
            rethrow()
        end
    end
end

function receipt(root, id)
    s = _read(root, id)
    s["state"] == "published" || throw(PublicationError(409, "not_published", "There is no published receipt yet."))
    read_json(joinpath(publication_path(root, id), "publication-receipt.json"))
end

function download_path(root, id, kind)
    s = _read(root, id)
    if kind == "bundle"
        return _local_integrity(root, s), "application/zip", _archive_name(id)
    elseif kind == "receipt"
        receipt(root, id) # enforce published state
        return joinpath(publication_path(root, id), "publication-receipt.json"), "application/json", "publication-" * id * ".json"
    elseif kind == "citation"
        s["state"] == "published" || throw(PublicationError(409, "not_published", "Cite only a published record, not a reserved DOI."))
        return joinpath(publication_path(root, id), "payload", "CITATION.cff"), "text/yaml", "citation-" * id * ".cff"
    end
    throw(PublicationError(404, "file_not_found", "Unknown publication download."))
end

end # module DOIPublications
