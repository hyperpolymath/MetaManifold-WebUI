# SPDX-License-Identifier: AGPL-3.0-only
module BackendClient
using HTTP, JSON3
using ..Contracts
export Backend, BackendError, list_studies, get_study, study_path

struct BackendError <: Exception
    status::Int
    code::String
    message::String
end
Base.showerror(io::IO, e::BackendError) = print(io, e.message)

"Server-configured origin; never constructed from a browser field."
struct Backend
    origin::String
    timeout::Float64
    function Backend(origin::AbstractString; timeout::Real=10)
        u = HTTP.URI(origin)
        u.scheme in ("http", "https") && !isempty(u.host) && isempty(u.userinfo) &&
            isempty(u.query) && isempty(u.fragment) && u.path in ("", "/") ||
            throw(ArgumentError("Backend must be an HTTP(S) origin without credentials, path, query or fragment"))
        isfinite(timeout) && timeout > 0 || throw(ArgumentError("Timeout must be positive and finite"))
        new(rstrip(String(origin), '/'), Float64(timeout))
    end
end
function study_path(name::AbstractString)
    (isempty(name) || name in (".", "..") || any(c -> c in ('/', '\\') || iscntrl(c), name)) &&
        throw(ArgumentError("Invalid study path segment"))
    "/api/v1/studies/" * HTTP.URIs.escapeuri(name)
end

function request_json(b::Backend, path::String)
    response = try
        HTTP.get(b.origin * path; status_exception=false, redirect=false,
                 connect_timeout=min(b.timeout, 3), request_timeout=b.timeout)
    catch e
        e isa InterruptException && rethrow()
        throw(BackendError(0, "backend_unavailable", "Cannot reach the MetaManifold backend. Check that it is running, then retry."))
    end
    payload = try
        JSON3.read(String(response.body))
    catch
        throw(BackendError(response.status, "invalid_response", "Backend returned invalid JSON."))
    end
    if !(200 <= response.status < 300)
        code = payload isa AbstractDict ? get(payload, :error, "backend_error") : "backend_error"
        # Do not expose arbitrary backend internals or raw response bodies to browsers.
        message = response.status == 404 ? "Study not found. It may have been renamed or deleted." :
                  response.status == 503 ? "Backend is busy. Retry shortly." :
                  "Backend request failed (HTTP $(response.status))."
        throw(BackendError(response.status, code isa AbstractString ? String(code) : "backend_error", message))
    end
    payload
end
list_studies(b::Backend) = decode_studies(request_json(b, "/api/v1/studies"))
get_study(b::Backend, name::AbstractString) = decode_study(request_json(b, study_path(name)))
end
