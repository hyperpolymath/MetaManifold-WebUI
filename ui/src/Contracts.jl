# SPDX-License-Identifier: AGPL-3.0-only
module Contracts
export StudySummary, Study, ContractError, decode_summary, decode_study, decode_studies

struct ContractError <: Exception
    message::String
end
Base.showerror(io::IO, e::ContractError) = print(io, e.message)

struct StudySummary
    name::String
    run_count::Int
    group_count::Int
    active_job_count::Int
end
struct Study
    summary::StudySummary
    runs::Vector{String}
    groups::Vector{String}
end

function field(obj, key::Symbol)
    obj isa AbstractDict || throw(ContractError("Expected an object"))
    haskey(obj, key) && return obj[key]
    haskey(obj, String(key)) && return obj[String(key)]
    throw(ContractError("Missing field: $key"))
end
function text(value, label)
    value isa AbstractString || throw(ContractError("$label must be a string"))
    String(value)
end
function countfield(obj, key)
    n = field(obj, key)
    (n isa Integer && !(n isa Bool) && 0 <= n <= typemax(Int)) ||
        throw(ContractError("$key must be a nonnegative integer"))
    Int(n)
end
function decode_summary(obj)::StudySummary
    name = text(field(obj, :name), "name")
    isempty(name) && throw(ContractError("name must not be empty"))
    StudySummary(name, countfield(obj, :run_count), countfield(obj, :group_count),
                 countfield(obj, :active_job_count))
end
function names(obj, key)
    values = field(obj, key)
    values isa AbstractVector || throw(ContractError("$key must be an array"))
    [text(v, key) for v in values]
end
function decode_study(obj)::Study
    summary = decode_summary(obj)
    runs, groups = names(obj, :runs), names(obj, :groups)
    length(runs) == summary.run_count || throw(ContractError("run_count disagrees with runs"))
    length(groups) == summary.group_count || throw(ContractError("group_count disagrees with groups"))
    Study(summary, runs, groups)
end
function decode_studies(obj)::Vector{StudySummary}
    obj isa AbstractVector || throw(ContractError("Expected a study array"))
    decode_summary.(obj)
end
end
