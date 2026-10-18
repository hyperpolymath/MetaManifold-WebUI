# SPDX-License-Identifier: MPL-2.0
include(joinpath(@__DIR__, "../../evidence/placement.jl"))
const _EVIDENCE_MAX_BYTES = 10 * 1024 * 1024
_evidence_path(study,file) = joinpath(_trees_dir(study), ".evidence", file * ".json")
_origin_path(study,file) = joinpath(_trees_dir(study), ".sources", file * ".json")
_digest(text) = bytes2hex(sha256(text))

function _evidence_text(study,file)
    _valid_tree_file(file) && _tree_format(file)=="jplace" || throw(ArgumentError("Evidence needs a plain jplace filename"))
    path=joinpath(_trees_dir(study),file)
    islink(path) && throw(ArgumentError("Evidence source may not be a symbolic link"))
    isfile(path) || throw(ArgumentError("Evidence source is missing"))
    filesize(path)<=_TREE_MAX_BYTES || throw(ArgumentError("Evidence source exceeds 50 MB"))
    read(path,String)
end
function _small_doc(path)
    (islink(path) || islink(dirname(path))) && throw(ArgumentError("Sidecar may not be a symbolic link"))
    isfile(path) || return nothing
    filesize(path)<=_EVIDENCE_MAX_BYTES || throw(ArgumentError("Sidecar exceeds 10 MB"))
    JSON3.read(read(path,String),Dict{String,Any})
end
function _sidecar_write(path,doc)
    islink(dirname(path)) && throw(ArgumentError("Sidecar directory may not be a symbolic link"))
    text=JSON3.write(doc)
    sizeof(text)<=_EVIDENCE_MAX_BYTES || throw(ArgumentError("Evidence exceeds 10 MB"))
    _write_atomic(path,text)
end
function _tree_origin(study,file)
    doc=_small_doc(_origin_path(study,file))
    isnothing(doc) && return nothing
    get(doc,"version",nothing)==1 && get(doc,"study",nothing)==study || throw(ArgumentError("Invalid source provenance"))
    doc
end
function _forget_tree!(study,file)
    for path in (_evidence_path(study,file), _origin_path(study,file))
        isfile(path) && rm(path)
    end
end

# All managed tree writers use the same lock. Readers still verify exact digests.
function _generate_evidence(study,file,body)
    raw=_evidence_text(study,file)
    get(body,"source_sha256",nothing)==_digest(raw) || throw(ArgumentError("Tree changed; reload before generating evidence"))
    result=PlacementEvidence.check(raw;threshold=get(body,"threshold",0.95))
    origin=_tree_origin(study,file)
    imported=isnothing(origin)
    if imported
        get(body,"confirm_raw",false)===true || throw(ArgumentError("Confirm this imported file contains raw placements"))
        target=get(body,"accumulated_file",nothing)
        isnothing(target) || (target isa String && target!=file) || throw(ArgumentError("Invalid accumulated filename"))
        targettext=isnothing(target) ? nothing : _evidence_text(study,target)
        isnothing(targettext) || PlacementEvidence.mapping(raw,targettext)
        origin=Dict("version"=>1,"study"=>study,"role"=>"raw","raw"=>file,
                    "raw_sha256"=>_digest(raw),"accumulated"=>target,
                    "accumulated_sha256"=>isnothing(targettext) ? nothing : _digest(targettext),
                    "provenance"=>Dict("kind"=>"explicit_import","run"=>nothing,"config"=>nothing,
                                       "seed"=>nothing,"tools"=>nothing))
        if !isnothing(target)
            existing=_tree_origin(study,target)
            isnothing(existing) || throw(ArgumentError("Accumulated target already has a source association"))
        end
    end
    get(origin,"role",nothing)=="raw" && get(origin,"raw",nothing)==file || throw(ArgumentError("Evidence must be generated from the raw placement file"))
    origin["raw_sha256"]==_digest(raw) || throw(ArgumentError("Raw publication provenance is stale; republish or reimport"))
    target=get(origin,"accumulated",nothing); mapping=nothing; mapping_reason=nothing
    if !isnothing(target)
        try
            targettext=_evidence_text(study,target)
            _digest(targettext)==get(origin,"accumulated_sha256",nothing) || throw(ArgumentError("Accumulated publication is stale"))
            mapping=PlacementEvidence.mapping(raw,targettext)
        catch e
            mapping_reason=sprint(showerror,e)
        end
    end
    doc=Dict("version"=>1,"study"=>study,"created"=>string(now(UTC))*"Z",
             "source"=>origin,"result"=>result,"mapping"=>mapping,"mapping_reason"=>mapping_reason)
    _digest(_evidence_text(study,file))==result.source_sha256 || throw(ArgumentError("Tree changed during evidence generation"))
    sizeof(JSON3.write(doc))<=_EVIDENCE_MAX_BYTES || throw(ArgumentError("Evidence exceeds 10 MB"))
    if imported
        _sidecar_write(_origin_path(study,file),origin)
        isnothing(target) || _sidecar_write(_origin_path(study,target),merge(origin,Dict("role"=>"accumulated")))
    end
    _sidecar_write(_evidence_path(study,file),doc)
    _read_evidence(study,file)
end

function _read_evidence(study,file)
    origin=_tree_origin(study,file)
    isnothing(origin) && return (;state="missing",message="No source association; explicitly identify an imported raw file before generating evidence")
    role=get(origin,"role",nothing)
    role=="context" && return (;state="not_applicable",message="Reference copy is context only")
    role in ("raw","accumulated") || throw(ArgumentError("Invalid tree role"))
    rawfile=get(origin,"raw",nothing)
    rawfile isa String && _valid_tree_file(rawfile) && _tree_format(rawfile)=="jplace" || throw(ArgumentError("Invalid raw source filename"))
    stale(message) = (;state="stale",message,role,raw_file=rawfile)
    doc=_small_doc(_evidence_path(study,rawfile))
    isnothing(doc) && return (;state="missing",message="Raw evidence has not been generated",role,raw_file=rawfile)
    get(doc,"version",nothing)==1 && get(doc,"study",nothing)==study || throw(ArgumentError("Invalid evidence schema or study"))
    get(doc,"source",nothing)==merge(origin,Dict("role"=>"raw")) ||
        return stale("Publication provenance changed; regenerate from raw source")
    raw=try _evidence_text(study,rawfile) catch; return stale("Raw source is missing"); end
    result=get(doc,"result",nothing)
    result isa AbstractDict || throw(ArgumentError("Missing evidence result"))
    get(result,"source_sha256",nothing)==_digest(raw) || return stale("Raw source changed; evidence withdrawn")
    # Recompute on read: a malformed/tampered sidecar cannot introduce false results.
    expected=JSON3.read(JSON3.write(PlacementEvidence.check(raw;threshold=get(result,"threshold",nothing))),Dict{String,Any})
    expected==result || throw(ArgumentError("Evidence does not match the current checker"))
    mapping=nothing; mapping_reason=get(doc,"mapping_reason",nothing)
    target=get(origin,"accumulated",nothing)
    if !isnothing(target)
        try
            text=_evidence_text(study,target)
            _digest(text)==get(origin,"accumulated_sha256",nothing) || throw(ArgumentError("Accumulated source changed"))
            expectedmap=JSON3.read(JSON3.write(PlacementEvidence.mapping(raw,text)),Vector{Dict{String,Any}})
            expectedmap==get(doc,"mapping",nothing) || throw(ArgumentError("Accumulated mapping is invalid"))
            mapping=expectedmap; mapping_reason=nothing
        catch e
            mapping_reason=sprint(showerror,e)
        end
    end
    role=="accumulated" && isnothing(mapping) && return stale(something(mapping_reason,"Mapping unavailable"))
    (;state="ready",role,raw_file=rawfile,source_sha256=_digest(_evidence_text(study,file)),
      result,mapping,mapping_reason,provenance=origin["provenance"])
end

@get "/api/v1/studies/{study}/trees/{file}/evidence" function(req,study::String,file::String)
    err=_tree_request_error(study,file); isnothing(err) || return err
    lock(_tree_view_lock) do
        try; json(_read_evidence(study,file))
        catch e; json((;state="invalid",message=sprint(showerror,e))); end
    end
end
@post "/api/v1/studies/{study}/trees/{file}/evidence" function(req,study::String,file::String)
    err=_tree_request_error(study,file); isnothing(err) || return err
    sizeof(req.body)<=4096 || return json_error(413,"too_large","Evidence request exceeds 4 KB")
    lock(_tree_view_lock) do
        try
            body=JSON3.read(String(req.body),Dict{String,Any})
            json(_generate_evidence(study,file,body))
        catch e
            json_error(400,"invalid_evidence",sprint(showerror,e))
        end
    end
end
