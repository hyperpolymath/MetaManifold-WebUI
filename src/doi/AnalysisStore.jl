# SPDX-License-Identifier: MPL-2.0
# Persistence required by the DOI workflow: a backend restart must not erase the
# config/result named by a reviewed draft. The publication journal keeps its own
# immutable snapshots as well, so it never follows a moving "latest result".
module AnalysisStore

using JSON3, Dates, UUIDs, OrderedCollections
using ..DOIStorage
import ..AnalysisConfig

export configs, results, save_config!, save_result!, delete_config!, result_json

function _record_path(root, kind, id)
    try UUID(id) catch; throw(PublicationError(400, "invalid_id", "Analysis ID must be a UUID.")) end
    joinpath(root, kind, id * ".json")
end

function configs(root)
    directory = joinpath(root, "configs")
    output = Dict{String,AnalysisConfig.AnalysisConfigStruct}()
    isdir(directory) || return output
    for name in readdir(directory)
        endswith(name, ".json") || continue
        path = joinpath(directory, name)
        islink(path) && throw(PublicationError(409, "unsafe_storage", "Stored analysis must not be a symlink."))
        text = read(path, String)
        cfg = AnalysisConfig.from_json(text)
        # from_json supports caller-supplied hashes for legacy uses; storage must
        # not trust one. Reconstruct without it and compare the computed hash.
        data = JSON3.read(text, Dict{String,Any})
        data["hash"] = nothing
        AnalysisConfig.from_json(JSON3.write(data)).hash == cfg.hash ||
            throw(PublicationError(409, "config_hash_mismatch", "Stored analysis configuration failed its content-hash check."))
        name == cfg.id * ".json" || throw(PublicationError(409, "config_id_mismatch", "Stored configuration ID differs from its filename."))
        output[cfg.id] = cfg
    end
    return output
end

function result_json(result::AnalysisConfig.AnalysisResult)
    JSON3.write(OrderedDict{String,Any}("id" => result.id, "config_id" => result.config_id,
        "config_hash" => result.config_hash, "created_at" => string(result.created_at),
        "method" => AnalysisConfig.METHOD_TO_STRING[result.method], "results" => result.results,
        "provenance" => result.provenance, "hash" => result.hash))
end

function results(root)
    directory = joinpath(root, "results")
    output = Dict{String,AnalysisConfig.AnalysisResult}()
    isdir(directory) || return output
    for name in readdir(directory)
        endswith(name, ".json") || continue
        path = joinpath(directory, name)
        islink(path) && throw(PublicationError(409, "unsafe_storage", "Stored result must not be a symlink."))
        data = JSON3.read(read(path, String))
        method = AnalysisConfig.METHOD_STRINGS[String(data.method)]
        # Keep result entry ordering: the existing scientific hash format is
        # order-sensitive. Do not canonical-sort the original scientific object.
        result = AnalysisConfig.AnalysisResult(id=String(data.id), config_id=String(data.config_id),
            config_hash=String(data.config_hash), created_at=DateTime(data.created_at), method=method,
            results=OrderedDict{String,Any}(String(k) => v for (k, v) in data.results),
            provenance=OrderedDict{String,Any}(String(k) => v for (k, v) in data.provenance))
        result.hash == data.hash && name == result.id * ".json" ||
            throw(PublicationError(409, "result_hash_mismatch", "Stored analysis result failed its content-hash check."))
        output[result.id] = result
    end
    return output
end

function _save(root, kind, id, text)
    with_publication_lock(root) do
        path = _record_path(root, kind, id)
        if isfile(path)
            read(path, String) == text || throw(PublicationError(409, "immutable_analysis", "An immutable analysis ID already exists with different content."))
        else
            atomic_write(path, text)
        end
        return id
    end
end
save_config!(root, cfg::AnalysisConfig.AnalysisConfigStruct) = _save(root, "configs", cfg.id, AnalysisConfig.to_json(cfg))
save_result!(root, result::AnalysisConfig.AnalysisResult) = _save(root, "results", result.id, result_json(result))

function delete_config!(root, id)
    with_publication_lock(root) do
        path = _record_path(root, "configs", id)
        isfile(path) || throw(PublicationError(404, "config_not_found", "Analysis configuration not found."))
        rm(path)
    end
end

end # module AnalysisStore
