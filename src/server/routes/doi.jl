# SPDX-License-Identifier: MPL-2.0
# Opt-in, local/single-user publication API. Never accepts tokens or remote API URLs.
using MetaManifold: Zenodo, DOIPublications, DOIWeb
using Random

const _DOI_CSRF = bytes2hex(rand(RandomDevice(), UInt8, 32))
const _DOI_CLIENT_FACTORY = Ref{Function}(() -> Zenodo.environment_client())
_doi_client() = _DOI_CLIENT_FACTORY[]()

function _doi_store_dir(study::String)
    _valid_name(study) || throw(DOIStorage.PublicationError(400, "invalid_study", "Invalid study name."))
    project = joinpath(ServerState.projects_dir(), study)
    islink(project) && throw(DOIStorage.PublicationError(403, "unsafe_storage", "DOI study storage must not be a symlink."))
    root = joinpath(project, ".doi")
    islink(root) && throw(DOIStorage.PublicationError(403, "unsafe_storage", "DOI storage must not be a symlink."))
    return root
end

function _doi_capabilities()
    environment = get(ENV, "METAMANIFOLD_ZENODO_ENVIRONMENT", "sandbox")
    environment in ("sandbox", "production") || (environment = "sandbox")
    enabled = try
        client = _doi_client()
        environment = client.environment
        true
    catch
        false
    end
    Dict("enabled" => enabled, "environment" => environment, "api_version" => Zenodo.API_VERSION, "csrf" => _DOI_CSRF)
end

# Browser mutations must be same-origin (or the one explicitly configured proxy
# origin) AND carry the per-process CSRF token fetched from the same-origin UI.
# This is CSRF protection, not user authentication. Do not expose this local API
# publicly without a separate authenticated reverse proxy.
function _doi_same_origin(req)
    origin = HTTP.header(req, "Origin", "")
    isempty(origin) && return true # non-browser clients still need JSON + CSRF
    configured = get(ENV, "METAMANIFOLD_PUBLIC_ORIGIN", "")
    !isempty(configured) && origin == configured && return true
    uri = try HTTP.URIs.URI(origin) catch; return false end
    uri.scheme in ("http", "https") && isempty(uri.userinfo) && isempty(uri.query) && isempty(uri.fragment) && isempty(uri.path) || return false
    authority = uri.host * (isempty(uri.port) ? "" : ":" * uri.port)
    lowercase(authority) == lowercase(HTTP.header(req, "Host", ""))
end

function _doi_body(req; allowed=String[])
    HTTP.header(req, "X-DOI-CSRF", "") == _DOI_CSRF && _doi_same_origin(req) ||
        throw(DOIStorage.PublicationError(403, "publication_intent_required", "Reload the same-origin DOI page and retry. Its CSRF token or origin is missing or stale."))
    lowercase(strip(first(split(HTTP.header(req, "Content-Type", ""), ';')))) == "application/json" ||
        throw(DOIStorage.PublicationError(415, "json_required", "DOI operations require application/json."))
    length(req.body) <= 65_536 || throw(DOIStorage.PublicationError(413, "request_too_large", "DOI request exceeds 64 KiB."))
    body = try JSON3.read(String(copy(req.body)), Dict{String,Any}) catch
        throw(DOIStorage.PublicationError(400, "invalid_json", "Expected a JSON object."))
    end
    all(k -> k in allowed, keys(body)) || throw(DOIStorage.PublicationError(400, "unknown_field", "Unexpected DOI request field; tokens and API URLs must never be sent by the browser."))
    return body
end

function _doi_json(value; status=200, headers=Pair{String,String}[])
    HTTP.Response(status, vcat(["Content-Type" => "application/json", "Cache-Control" => "no-store"], headers); body=JSON3.write(value))
end

function _doi_error(e)
    if e isa DOIStorage.PublicationError
        return _doi_json(Dict("error" => e.code, "message" => e.message); status=e.status)
    elseif e isa Zenodo.RemoteError
        status = e.status == 429 ? 429 : e.status in (400, 409, 415, 422) ? 422 : 502
        headers = isnothing(e.retry_after) ? Pair{String,String}[] : ["Retry-After" => string(e.retry_after)]
        return _doi_json(Dict("error" => e.code, "message" => e.message, "outcome_uncertain" => e.ambiguous); status, headers)
    elseif e isa ArgumentError
        return _doi_json(Dict("error" => "publication_unavailable", "message" => "Check the server's Zenodo enable flag, environment and token, and the request values. No token is accepted through this API."); status=503)
    end
    # Do not log the exception or its backtrace: HTTP exceptions can carry headers.
    @warn "DOI operation failed locally; inspect the publication journal (credentials omitted)"
    _doi_json(Dict("error" => "publication_failed", "message" => "Publication failed locally. Reload saved publications and reconcile the existing operation before retrying."); status=500)
end

function _doi_api(f::Function, req, study; mutation=false)
    try
        _valid_name(study) && study in _study_names() || throw(DOIStorage.PublicationError(404, "study_not_found", "Study not found."))
        if mutation
            # Also excludes study rename/deletion while a network operation owns
            # this journal. The per-record lock protects library/CLI callers too.
            return DOIStorage.with_publication_lock(_doi_store_dir(study)) do
                study in _study_names() || throw(DOIStorage.PublicationError(404, "study_not_found", "Study not found."))
                f()
            end
        end
        f()
    catch e
        _doi_error(e)
    end
end

# Called by existing destructive study routes. Keeping a publication journal is
# part of the idempotency guarantee, not disposable UI cache.
function _doi_protect_study_mutation(f::Function, study)
    try
        DOIStorage.with_publication_lock(_doi_store_dir(study)) do
            isempty(DOIPublications.publications(_doi_store_dir(study))) ||
                throw(DOIStorage.PublicationError(409, "study_has_publications", "This study has DOI publication journals. Keep its name and archive/back up the study instead of deleting its publication history."))
            f()
        end
    catch e
        _doi_error(e)
    end
end

@get "/api/v1/doi/capabilities" function(req)
    _doi_json(_doi_capabilities())
end

@get "/api/v1/doi/assets/{name}" function(req, name::String)
    name in ("publication.js", "publication.css") || return json_error(404, "file_not_found", "Unknown DOI asset")
    mime = endswith(name, ".js") ? "text/javascript" : "text/css"
    path = joinpath(@__DIR__, "..", "..", "doi", "assets", name)
    HTTP.Response(200, ["Content-Type" => mime, "X-Content-Type-Options" => "nosniff"]; body=read(path))
end

@get "/api/v1/studies/{study}/doi-ui" function(req, study::String)
    _doi_api(req, study) do
        capabilities = _doi_capabilities()
        selected = get(HTTP.queryparams(req), "config", "")
        html = DOIWeb.render_page(study, _DOI_CSRF, capabilities["environment"], capabilities["enabled"]; selected_config=selected)
        HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8", "Cache-Control" => "no-store",
            "X-Content-Type-Options" => "nosniff", "Referrer-Policy" => "no-referrer",
            "Content-Security-Policy" => "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'self'"]; body=html)
    end
end

@get "/api/v1/studies/{study}/analysis-config/{id}/results" function(req, study::String, id::String)
    _doi_api(req, study) do
        haskey(_get_study_configs(study), id) || throw(DOIStorage.PublicationError(404, "config_not_found", "Saved configuration not found."))
        results = [Dict("id" => r.id, "hash" => r.hash, "created_at" => string(r.created_at),
            "publishable" => !isempty(r.results) && get(r.provenance, "mock", false) !== true)
            for r in values(_get_study_results(study)) if r.config_id == id]
        _doi_json(Dict("results" => results))
    end
end

@get "/api/v1/studies/{study}/doi-publications" function(req, study::String)
    _doi_api(req, study) do
        _doi_json(Dict("publications" => DOIPublications.publications(_doi_store_dir(study))))
    end
end

@post "/api/v1/studies/{study}/doi-publications" function(req, study::String)
    _doi_api(req, study; mutation=true) do
        body = _doi_body(req; allowed=["config_id", "result_id", "metadata", "acknowledge_upload"])
        get(body, "acknowledge_upload", false) === true || throw(DOIStorage.PublicationError(422, "upload_consent_required", "Review privacy and consent to sending the selected bundle to Zenodo before preparing a draft."))
        haskey(body, "result_id") || throw(DOIStorage.PublicationError(422, "payload_selection_required", "Explicitly select result_id, or null for a configuration-only bundle. Latest-result selection is not supported."))
        config_id = get(body, "config_id", nothing)
        config_id isa AbstractString || throw(DOIStorage.PublicationError(422, "config_required", "Select a saved configuration."))
        configs = _get_study_configs(study)
        haskey(configs, config_id) || throw(DOIStorage.PublicationError(404, "config_not_found", "Saved configuration not found."))
        metadata = get(body, "metadata", nothing)
        metadata isa AbstractDict || throw(DOIStorage.PublicationError(422, "metadata_required", "Explicit publication metadata is required."))
        metadata = DOIBundles.validate_metadata(metadata)
        result_id = body["result_id"]
        results = _get_study_results(study)
        result = if isnothing(result_id)
            nothing
        elseif result_id isa AbstractString && haskey(results, result_id)
            results[result_id]
        else
            throw(DOIStorage.PublicationError(404, "result_not_found", "Selected result not found."))
        end
        client = _doi_client()
        value = mktempdir() do tmp
            bundle = joinpath(tmp, "bundle")
            AnalysisConfig.create_doi_bundle(configs[config_id], result, bundle;
                title=metadata["title"], authors=String[c["name"] for c in metadata["creators"]],
                license=metadata["license"], description=metadata["description"])
            DOIPublications.prepare!(_doi_store_dir(study), bundle, metadata, client)
        end
        _doi_json(value)
    end
end

@get "/api/v1/studies/{study}/doi-publications/{id}" function(req, study::String, id::String)
    _doi_api(req, study) do
        _doi_json(DOIPublications.status(_doi_store_dir(study), id))
    end
end

@post "/api/v1/studies/{study}/doi-publications/{id}/resume" function(req, study::String, id::String)
    _doi_api(req, study; mutation=true) do
        _doi_body(req)
        _doi_json(DOIPublications.resume!(_doi_store_dir(study), id, _doi_client()))
    end
end

@post "/api/v1/studies/{study}/doi-publications/{id}/refresh" function(req, study::String, id::String)
    _doi_api(req, study; mutation=true) do
        _doi_body(req)
        _doi_json(DOIPublications.refresh!(_doi_store_dir(study), id, _doi_client()))
    end
end

@post "/api/v1/studies/{study}/doi-publications/{id}/recover" function(req, study::String, id::String)
    _doi_api(req, study; mutation=true) do
        body = _doi_body(req; allowed=["deposition_id"])
        _doi_json(DOIPublications.recover_creation!(_doi_store_dir(study), id, get(body, "deposition_id", nothing), _doi_client()))
    end
end

@post "/api/v1/studies/{study}/doi-publications/{id}/publish" function(req, study::String, id::String)
    _doi_api(req, study; mutation=true) do
        body = _doi_body(req; allowed=["confirmation", "bundle_sha256", "acknowledge_public"])
        _doi_json(DOIPublications.publish!(_doi_store_dir(study), id, _doi_client();
            confirmation=get(body, "confirmation", nothing), bundle_sha256=get(body, "bundle_sha256", nothing),
            acknowledge_public=get(body, "acknowledge_public", false)))
    end
end

@get "/api/v1/studies/{study}/doi-publications/{id}/download/{kind}" function(req, study::String, id::String, kind::String)
    _doi_api(req, study) do
        path, mime, name = DOIPublications.download_path(_doi_store_dir(study), id, kind)
        HTTP.Response(200, ["Content-Type" => mime, "Cache-Control" => "no-store",
            "Content-Disposition" => "attachment; filename=\"$name\"", "X-Content-Type-Options" => "nosniff",
            "Content-Length" => string(filesize(path))]; body=DOIStorage.FileBody(path))
    end
end
