# © 2026 Joshua Benjamin Jewell. All rights reserved.
# Licensed under the GNU Affero General Public License version 3 (AGPLv3).

# Routes: POST /api/v1/studies/{study}/doi/publish
#         GET  /api/v1/studies/{study}/doi/status
#
# Zenodo DOI publication. Disabled by default; requires DOI_ENABLED=true and
# ZENODO_TOKEN (see docs/doi-publication.md). Publication never rewrites
# scientific objects: it mints a DOI for a bundle of existing report files and
# records an immutable receipt.

using Dates
using ..DOI: DOIConfig, PublicationReceipt, load_doi_config, publication_enabled,
             publish_study, journal_state, read_receipt, redact

const _doi_lock = ReentrantLock()

_doi_report_dir(study::String) = joinpath(ServerState.projects_dir(), study, "report")

# Resolve a file the caller wants published, strictly inside the study's report
# directory (blocks path traversal, symlink escapes and hidden files).
"""
    _doi_report_file(study, name) -> Union{String,Nothing}

Resolve an existing report file, rejecting empty names, leading dots and `/`.
Return `nothing` if the report directory or file is absent, or if the resolved
file path does not start with the resolved report directory path. This is a
string prefix check, not a directory boundary check. Failed `realpath` calls
fall back to the unresolved paths.
"""
function _doi_report_file(study::String, name::AbstractString)::Union{String,Nothing}
    isempty(name) && return nothing
    startswith(name, ".") && return nothing
    occursin('/', String(name)) && return nothing
    report_dir = _doi_report_dir(study)
    isdir(report_dir) || return nothing
    cand = joinpath(report_dir, String(name))
    isfile(cand) || return nothing
    # realpath containment: the resolved file must live inside the report dir.
    report_real = try realpath(report_dir) catch; report_dir end
    cand_real   = try realpath(cand)   catch; cand end
    startswith(cand_real, report_real) || return nothing
    return cand_real
end

"""
    _doi_publish_body(req) -> Dict

Parse a JSON object from the request body with string keys. Return an empty
dictionary when reading or parsing fails or the JSON value is not an object.
"""
function _doi_publish_body(req)::Dict{String,Any}
    body = try JSON3.read(String(req.body)) catch; nothing end
    body isa JSON3.Object || return Dict{String,Any}()
    Dict{String,Any}(string(k) => v for (k, v) in body)
end

@post \"/api/v1/studies/{study}/doi/publish\" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                  "Study '$study' not found")
    _valid_name(study) || return json_error(400, "invalid_study", "Invalid study name")
    cfg = load_doi_config()
    publication_enabled(cfg) || return json_error(403, "doi_disabled",
        "DOI publication is disabled: set DOI_ENABLED=true and ZENODO_TOKEN")
    body = _doi_publish_body(req)
    run = string(get(body, "run", ""))
    isempty(run) && return json_error(400, "missing_run", "Body must include 'run'")
    _valid_name(run) || return json_error(400, "invalid_run", "Invalid run name")
    confirm = get(body, "confirm", false) === true
    confirm || return json_error(409, "confirm_required",
        "DOI publication is irreversible: body must include confirm=true")
    raw = get(body, "files", nothing)
    files = raw isa AbstractVector ? String[string(f) for f in raw] : String[]
    isempty(files) && return json_error(400, "missing_files", "Body must include 'files'")
    # Resolve every file inside the report dir before touching anything.
    paths = String[]
    for name in files
        f = _doi_report_file(study, name)
        isnothing(f) && return json_error(400, "invalid_file",
            "Report file not found or outside the report dir: $name")
        push!(paths, f)
    end
    receipt = lock(_doi_lock) do
        publish_study(cfg, study, run, paths; confirm=true)
    end
    json((; study, run, doi=receipt.doi, deposition_id=receipt.deposition_id,
            published=receipt.published, created_at=receipt.created_at))
end

@get \"/api/v1/studies/{study}/doi/status\" function(req, study::String)
    study in _study_names() || return json_error(404, "study_not_found",
                                                  "Study '$study' not found")
    _valid_name(study) || return json_error(400, "invalid_study", "Invalid study name")
    cfg = load_doi_config()
    enabled = publication_enabled(cfg)
    state = journal_state(cfg)
    study_state = [e for e in state if get(e, "study", "") == study]
    receipts = String[]
    for e in study_state
        doi = get(e, "doi", nothing)
        if doi !== nothing && !isempty(doi)
            r = read_receipt(cfg, String(doi))
            r !== nothing && push!(receipts, String(doi))
        end
    end
    json((; enabled, study,
            doi_disabled_reason = enabled ? nothing :
                isempty(get(ENV, "ZENODO_TOKEN", "")) ?
                "ZENODO_TOKEN not configured" : "DOI_ENABLED not set to true",
            transitions=study_state, receipts))
end
