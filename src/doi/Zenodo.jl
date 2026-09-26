# SPDX-License-Identifier: MPL-2.0
# Zenodo's documented deposition-v1 API, not the separate InvenioRDM records API.
module Zenodo

using HTTP, JSON3, Dates, Logging

export Client, RemoteError, environment_client, origin, create_deposition,
       get_deposition, upload_file, publish_deposition, checked_id, reserved_doi,
       checked_doi, retry_after_seconds, API_VERSION

const API_VERSION = "deposition-v1"
const ORIGINS = Dict("sandbox" => "https://sandbox.zenodo.org", "production" => "https://zenodo.org")

struct Secret
    value::String
end
Base.show(io::IO, ::Secret) = print(io, "[REDACTED]")

# No remote response bodies or underlying HTTP exceptions escape this boundary.
# Both can contain Authorization headers, request URLs, or reflected credentials.
struct RemoteError <: Exception
    status::Int
    code::String
    message::String
    ambiguous::Bool
    retry_after::Union{Int,Nothing}
end
Base.showerror(io::IO, e::RemoteError) = print(io, e.message)

function _http(method, url, headers, body)
    # Even an operator's HTTP debug logger must not dump a reflected secret from
    # a remote response body. Only the sanitised domain errors leave this boundary.
    with_logger(NullLogger()) do
        HTTP.request(method, url, headers, body;
            redirect=false, retry=false, status_exception=false, logerrors=false,
            connect_timeout=10, readtimeout=120)
    end
end

struct Client{T,S,C}
    environment::String
    token::Secret
    transport::T
    sleeper::S
    clock::C
    attempts::Int
    retry_budget::Int
end

function Client(token::AbstractString; environment::String="sandbox", transport=_http,
                sleeper=sleep, clock=() -> now(UTC), attempts::Int=4, retry_budget::Int=60)
    haskey(ORIGINS, environment) || throw(ArgumentError("Zenodo environment must be sandbox or production"))
    isempty(strip(token)) && throw(ArgumentError("A server-side Zenodo token is required"))
    any(isspace, token) && throw(ArgumentError("Invalid server-side Zenodo token"))
    1 <= attempts <= 5 || throw(ArgumentError("Zenodo attempts must be between 1 and 5"))
    0 <= retry_budget <= 120 || throw(ArgumentError("Zenodo retry budget must be between 0 and 120 seconds"))
    Client(environment, Secret(String(token)), transport, sleeper, clock, attempts, retry_budget)
end
Base.show(io::IO, c::Client) = print(io, "Zenodo.Client(environment=", c.environment, ", token=[REDACTED])")
origin(c::Client) = ORIGINS[c.environment]

function environment_client(env=ENV)
    get(env, "METAMANIFOLD_ZENODO_ENABLED", "false") == "true" ||
        throw(ArgumentError("Zenodo publication is disabled by the server operator"))
    environment = get(env, "METAMANIFOLD_ZENODO_ENVIRONMENT", "sandbox")
    haskey(ORIGINS, environment) || throw(ArgumentError("Zenodo environment must be sandbox or production"))
    key = environment == "sandbox" ? "ZENODO_SANDBOX_TOKEN" : "ZENODO_TOKEN"
    Client(get(env, key, ""); environment)
end

function checked_id(value)
    # Bool is an Integer in Julia, but never a deposition identifier.
    text = value isa AbstractString || (value isa Integer && !(value isa Bool)) ? string(value) : ""
    occursin(r"^[1-9][0-9]{0,17}$", text) ||
        throw(RemoteError(502, "invalid_zenodo_response", "Zenodo returned an invalid deposition identifier.", false, nothing))
    return text
end

function checked_doi(c::Client, value)
    prefix = c.environment == "sandbox" ? "10.5072/zenodo." : "10.5281/zenodo."
    value isa AbstractString && startswith(value, prefix) && occursin(r"^[1-9][0-9]*$", value[length(prefix)+1:end]) ||
        throw(RemoteError(502, "invalid_zenodo_response", "Zenodo returned a DOI for an unexpected service or environment.", false, nothing))
    return String(value)
end
reserved_doi(c::Client, deposit) = checked_doi(c, get(get(get(deposit, "metadata", Dict()), "prereserve_doi", Dict()), "doi", nothing))

function retry_after_seconds(value::AbstractString, clock::DateTime=now(UTC))
    seconds = tryparse(Int, strip(value))
    !isnothing(seconds) && return max(0, seconds)
    occursin(r"^[0-9]+$", strip(value)) && return typemax(Int)
    # HTTP-date (RFC 9110 IMF-fixdate); ignore malformed hints, not valid long waits.
    endswith(value, " GMT") || return nothing
    try
        date = DateTime(value[1:end-4], dateformat"e, dd u yyyy HH:MM:SS")
        return max(0, ceil(Int, Dates.value(date - clock) / 1000))
    catch
        return nothing
    end
end

function _remote_error(status; ambiguous=false, retry_after=nothing)
    code, message = if status == 401
        ("zenodo_unauthorized", "Zenodo rejected the server token. Ask the operator to check its environment and validity.")
    elseif status == 403
        ("zenodo_forbidden", "Zenodo refused this operation. Check ownership and deposit:write / deposit:actions scopes.")
    elseif status == 404
        ("zenodo_not_found", "The Zenodo draft was not found. Check the account and environment; no replacement was created.")
    elseif status == 429
        ("zenodo_rate_limited", "Zenodo rate limit reached. Wait before retrying the same operation.")
    elseif status in (400, 409, 415, 422)
        ("zenodo_rejected", "Zenodo rejected the draft or its metadata. Review the draft on Zenodo; no DOI is claimed as published.")
    elseif 300 <= status < 400
        ("zenodo_redirect_refused", "Zenodo redirected a credentialed request. Redirects are refused for token safety.")
    else
        ("zenodo_unavailable", "Zenodo did not return a usable response. Refresh or reconcile the existing publication; do not create a replacement.")
    end
    RemoteError(status, code, message, ambiguous, retry_after)
end

# Factory bodies are reopened on EVERY attempt, including streamed uploads. HTTP.jl's
# automatic retries are disabled so an uncertain POST is never silently replayed.
function _request(c::Client, method::String, url::String; body_factory=() -> "", content_type="application/json", content_length=nothing, expected=(200,))
    # All endpoints are built here; only the bucket link is taken from a response,
    # and it goes through a stricter origin/path validator below.
    startswith(url, origin(c) * "/api/") || throw(ArgumentError("Refusing foreign Zenodo endpoint"))
    headers = ["Authorization" => "Bearer " * c.token.value,
               "Content-Type" => content_type, "Accept" => "application/json",
               "User-Agent" => "MetaManifold-WebUI/doi-v1"]
    isnothing(content_length) || push!(headers, "Content-Length" => string(content_length))
    safe = method in ("GET", "PUT")
    waited = 0
    for attempt in 1:c.attempts
        response = nothing
        body = body_factory()
        try
            response = c.transport(method, url, headers, body)
        catch
            if !safe || attempt == c.attempts
                throw(_remote_error(503; ambiguous=!safe))
            end
        finally
            body isa IO && close(body)
        end
        if !isnothing(response)
            if response.status in expected
                try
                    result = JSON3.read(String(response.body), Dict{String,Any})
                    return result
                catch
                    throw(RemoteError(502, "invalid_zenodo_response", "Zenodo returned malformed JSON; reconcile the existing operation before retrying.", !safe, nothing))
                end
            end
            hint = retry_after_seconds(HTTP.header(response, "Retry-After", ""), c.clock())
            # A definite 429 is safe to retry even for POST. 5xx/transport failures
            # on create or publish are ambiguous and must be reconciled instead.
            retryable = response.status == 429 || (safe && response.status in (500, 502, 503, 504))
            retryable && attempt < c.attempts ||
                throw(_remote_error(response.status; ambiguous=!safe && (response.status >= 500 || response.status < 400 || response.status == 408), retry_after=hint))
            delay = isnothing(hint) ? 2^(attempt - 1) : hint
        else
            delay = 2^(attempt - 1)
        end
        # Never truncate Retry-After and then retry too early. Return the hint to
        # the caller when the server requests a wait beyond our bounded budget.
        if delay > c.retry_budget - waited
            isnothing(response) && throw(_remote_error(503))
            throw(_remote_error(response.status; retry_after=delay))
        end
        c.sleeper(delay)
        waited += delay
    end
    error("unreachable retry state")
end

const DEPOSITIONS = "/api/deposit/depositions"
_endpoint(c, id) = origin(c) * DEPOSITIONS * "/" * checked_id(id)
create_deposition(c::Client, metadata) = _request(c, "POST", origin(c) * DEPOSITIONS;
    body_factory=() -> JSON3.write(Dict("metadata" => metadata)), expected=(201,))
get_deposition(c::Client, id) = _request(c, "GET", _endpoint(c, id))
publish_deposition(c::Client, id) = _request(c, "POST", _endpoint(c, id) * "/actions/publish";
    body_factory=() -> "{}", expected=(200, 202))

function _bucket(c::Client, deposit)
    url = get(get(deposit, "links", Dict()), "bucket", nothing)
    url isa AbstractString || throw(RemoteError(502, "invalid_bucket", "Zenodo did not provide an upload bucket.", false, nothing))
    prefix = origin(c) * "/api/files/"
    startswith(url, prefix) && occursin(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", url[length(prefix)+1:end]) ||
        throw(RemoteError(502, "unsafe_bucket", "Refusing an upload bucket outside the selected Zenodo origin or API path.", false, nothing))
    return String(url)
end

function upload_file(c::Client, deposit, path::String, filename::String)
    occursin(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,150}\.zip$", filename) || throw(ArgumentError("Invalid bundle filename"))
    _request(c, "PUT", _bucket(c, deposit) * "/" * filename;
        body_factory=() -> open(path, "r"), content_type="application/zip", content_length=filesize(path), expected=(200, 201))
end

end # module Zenodo
