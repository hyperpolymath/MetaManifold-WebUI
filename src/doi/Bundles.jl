# SPDX-License-Identifier: MPL-2.0
module DOIBundles

using JSON3, SHA, MD5, Dates, UUIDs
using ..DOIStorage: PublicationError, canonical_json, file_sha256, atomic_write

export validate_metadata, snapshot, write_checksums!, verify_checksums, archive_bundle,
       decorate_bundle!, zenodo_metadata, file_md5, citation_cff, citation_text,
       BUNDLE_FILES, LICENSES

const LICENSES = Dict("CC-BY-4.0" => "cc-by-4.0", "CC-BY-SA-4.0" => "cc-by-sa-4.0", "CC0-1.0" => "cc0-1.0")
const BASE_FILES = Set(["analysis_config.json", "analysis_config.ncl", "analysis_config_chora.deed",
                        "datacite.json", "provenance.json", "content_hash.txt", "README.md"])
const BUNDLE_FILES = union(BASE_FILES, Set(["analysis_result.json", "DANGER_BANNER.txt", "checksums.sha256"]))
const DECORATED_FILES = union(BUNDLE_FILES, Set(["publication.json", "CITATION.cff", "CITATION.txt", "zenodo.json"]))
fail(message) = throw(PublicationError(422, "invalid_publication", message))
file_md5(path::AbstractString) = open(io -> bytes2hex(md5(io)), path)

function _text(value, field; max_length=500, optional=false)
    value isa AbstractString || fail("$field must be text.")
    text = strip(String(value))
    (!optional && isempty(text)) && fail("$field must not be empty.")
    length(text) <= max_length || fail("$field is too long.")
    any(c -> iscntrl(c) && c != '\n' && c != '\t', text) && fail("$field contains control characters.")
    return text
end

function _github_url(value, field, kind)
    text = _text(value, field; max_length=2048, optional=true)
    isempty(text) && return nothing
    pattern = kind == :release ? r"^https://github\.com/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+/releases/tag/[A-Za-z0-9_.~%+/-]+$" :
        r"^https://github\.com/(users|orgs)/[A-Za-z0-9][A-Za-z0-9-]*/projects/[1-9][0-9]*$"
    occursin(pattern, text) || fail("$field must be a public GitHub $(kind == :release ? "release tag" : "Projects v2") URL without credentials, query, or fragment.")
    # Refuse URL parser normalisation and malformed percent escapes.
    any(s -> s in (".", ".."), split(text, '/')) && fail("$field contains a traversal segment.")
    occursin(r"%(?![0-9A-Fa-f]{2})", text) && fail("$field contains an invalid escape.")
    occursin(r"(?i)%2e|%2f|%5c|%0[0-9a-f]|%1[0-9a-f]|%7f", text) && fail("$field contains an unsafe encoded path.")
    return text
end

function _orcid(value)
    text = _text(value, "creator.orcid"; max_length=19)
    occursin(r"^[0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]{3}[0-9X]$", text) || fail("ORCID must use the 0000-0000-0000-000X format.")
    digits = replace(text, "-" => "")
    total = 0
    for d in digits[1:15]
        total = (total + (Int(d) - Int('0'))) * 2
    end
    check = (12 - total % 11) % 11
    string(last(digits)) == (check == 10 ? "X" : string(check)) || fail("ORCID checksum is invalid.")
    return text
end

"""Validate an explicit publication request, independently of analysis-schema defaults."""
function validate_metadata(input::AbstractDict; today=Date(now(UTC)))
    allowed = Set(["title", "description", "creators", "license", "publication_date", "version", "github_release_url", "github_project_url"])
    all(k -> k in allowed, keys(input)) || fail("Unknown publication metadata field. Tokens, API URLs and DOI overrides are never accepted.")
    title = _text(get(input, "title", nothing), "title"; max_length=250)
    description = _text(get(input, "description", nothing), "description"; max_length=10000)
    creators = get(input, "creators", nothing)
    creators isa AbstractVector && 1 <= length(creators) <= 100 || fail("Provide 1–100 named creators.")
    names = Dict{String,String}[]
    for creator in creators
        creator isa AbstractDict || fail("Each creator must be an object.")
        all(k -> k in ("name", "affiliation", "orcid"), keys(creator)) || fail("Unknown creator field.")
        name = _text(get(creator, "name", nothing), "creator.name"; max_length=250)
        lowercase(name) in ("anonymous", "unknown", "test", "your name") && fail("Replace placeholder creators with the actual authors before publication.")
        record = Dict("name" => name)
        if haskey(creator, "affiliation")
            record["affiliation"] = _text(creator["affiliation"], "creator.affiliation"; optional=true)
        end
        haskey(creator, "orcid") && (record["orcid"] = _orcid(creator["orcid"]))
        push!(names, record)
    end
    license = get(input, "license", nothing)
    license isa AbstractString && haskey(LICENSES, license) || fail("Choose an explicit supported licence: CC-BY-4.0, CC-BY-SA-4.0 or CC0-1.0.")
    date_string = _text(get(input, "publication_date", string(today)), "publication_date"; max_length=10)
    date = try Date(date_string, dateformat"yyyy-mm-dd") catch; fail("publication_date must be YYYY-MM-DD.") end
    string(date) == date_string && Date(1900) <= date <= today || fail("publication_date must be a real date between 1900 and today.")
    version = _text(get(input, "version", "1.0.0"), "version"; max_length=100)
    result = Dict{String,Any}("title" => title, "description" => description, "creators" => names,
        "license" => String(license), "publication_date" => date_string, "version" => version)
    for (field, kind) in (("github_release_url", :release), ("github_project_url", :project))
        value = get(input, field, nothing)
        result[field] = isnothing(value) ? nothing : _github_url(value, field, kind)
    end
    return result
end

function _regular_files(directory, allowed)
    isdir(directory) && !islink(directory) || fail("Bundle must be a regular directory.")
    names = readdir(directory)
    all(name -> name in allowed && isfile(joinpath(directory, name)) && !islink(joinpath(directory, name)), names) ||
        fail("Bundle contains an unexpected entry, directory or symlink. Only the documented bundle files may be published.")
    return names
end

"""Read and bind the exact config/result bytes; refuse scaffolds and mismatched results."""
function snapshot(directory::String)
    names = _regular_files(directory, BUNDLE_FILES)
    issubset(BASE_FILES, Set(names)) || fail("Bundle is missing required config, provenance or metadata files.")
    isfile(joinpath(directory, "checksums.sha256")) && verify_checksums(directory)
    config_text = read(joinpath(directory, "analysis_config.json"), String)
    cfg = try JSON3.read(config_text, Dict{String,Any}) catch; fail("Invalid analysis_config.json.") end
    try UUID(cfg["id"]) catch; fail("Bundle config ID must be a UUID.") end
    hash = get(cfg, "hash", "")
    hash isa AbstractString && occursin(r"^[0-9a-f]{64}$", hash) || fail("Bundle config hash must be SHA-256.")
    strip(read(joinpath(directory, "content_hash.txt"), String)) == hash || fail("Bundle content_hash.txt does not match its configuration.")
    cfg["dangerous"] isa Bool || fail("Bundle dangerous flag must be boolean.")
    cfg["dangerous"] && !("DANGER_BANNER.txt" in names) && fail("A dangerous configuration must retain its DANGER banner.")
    result = nothing
    result_sha = nothing
    if "analysis_result.json" in names
        text = read(joinpath(directory, "analysis_result.json"), String)
        result = try JSON3.read(text, Dict{String,Any}) catch; fail("Invalid analysis_result.json.") end
        get(result, "config_id", nothing) == cfg["id"] && get(result, "config_hash", nothing) == hash && get(result, "method", nothing) == cfg["method"] ||
            fail("Result does not belong to this exact analysis configuration.")
        try UUID(result["id"]) catch; fail("Result ID must be a UUID.") end
        rhash = get(result, "hash", "")
        rhash isa AbstractString && occursin(r"^[0-9a-f]{64}$", rhash) || fail("Result hash must be SHA-256.")
        payload = get(result, "results", nothing)
        payload isa AbstractDict && !isempty(payload) || fail("Empty/scaffold results cannot be published. Select a configuration-only bundle explicitly instead.")
        prov = get(result, "provenance", Dict())
        get(prov, "mock", false) === true && fail("Mock results cannot be published.")
        startswith(lowercase(string(get(prov, "note", ""))), "mock result") && fail("Mock results cannot be published.")
        estimation = get(prov, "estimation", Dict())
        get(estimation, "status", "") in ("not_run", "failed") && fail("An analysis which did not run cannot be published as a result.")
        result_sha = bytes2hex(sha256(text))
    end
    return Dict{String,Any}("config_id" => cfg["id"], "config_hash" => hash,
        "config_file_sha256" => bytes2hex(sha256(config_text)), "dangerous" => cfg["dangerous"],
        "result_id" => isnothing(result) ? nothing : result["id"],
        "result_hash" => isnothing(result) ? nothing : result["hash"], "result_file_sha256" => result_sha,
        "kind" => isnothing(result) ? "configuration" : "analysis_result")
end

function write_checksums!(directory::String)
    names = sort!(_regular_files(directory, DECORATED_FILES))
    text = join((file_sha256(joinpath(directory, name)) * "  " * name * "\n" for name in names if name != "checksums.sha256"))
    write(joinpath(directory, "checksums.sha256"), text)
    return file_sha256(joinpath(directory, "checksums.sha256"))
end

function verify_checksums(directory::String)
    names = _regular_files(directory, DECORATED_FILES)
    path = joinpath(directory, "checksums.sha256")
    isfile(path) || fail("Bundle checksum manifest is missing.")
    seen = Set{String}()
    for line in eachline(path)
        m = match(r"^([0-9a-f]{64})  ([A-Za-z0-9_.-]+)$", line)
        !isnothing(m) || fail("Invalid bundle checksum manifest.")
        hash, name = m.captures
        name in names && name != "checksums.sha256" && !(name in seen) || fail("Checksum manifest contains an unexpected or repeated file.")
        file_sha256(joinpath(directory, name)) == hash || fail("Bundle integrity check failed; a file changed after preparation.")
        push!(seen, name)
    end
    seen == setdiff(Set(names), Set(["checksums.sha256"])) || fail("Bundle checksum manifest does not cover every file.")
    return true
end

function archive_bundle(directory::String, destination::String)
    verify_checksums(directory)
    isnothing(Sys.which("zip")) && throw(PublicationError(503, "zip_unavailable", "The server needs the zip executable to create a DOI bundle."))
    ispath(destination) && fail("Refusing to overwrite an existing publication archive.")
    # Relative, sorted members; never archive absolute temporary paths or stale files.
    files = sort!(readdir(directory))
    try
        run(Cmd(`zip -q -X $(abspath(destination)) $files`; dir=directory))
    catch
        isfile(destination) && rm(destination)
        throw(PublicationError(500, "archive_failed", "Could not create the DOI archive. No upload was attempted."))
    end
    return destination
end

_html(text) = replace(text, '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;", '\'' => "&#39;")

function zenodo_metadata(metadata, binding, publication_id)
    kind = binding["kind"] == "configuration" ? "Configuration only; no analysis results are included." : "Analysis configuration, selected results and provenance."
    warning = binding["dangerous"] ? " DANGER: scientific overrides are present; see DANGER_BANNER.txt and disclose them when citing." : ""
    related = Dict{String,String}[]
    for (field, relation) in (("github_release_url", "isSupplementTo"), ("github_project_url", "references"))
        isnothing(metadata[field]) || push!(related, Dict("identifier" => metadata[field], "relation" => relation))
    end
    Dict{String,Any}("title" => metadata["title"], "upload_type" => "dataset",
        "description" => "<p>" * _html(metadata["description"]) * "</p><p>" * kind * warning * "</p>",
        "creators" => metadata["creators"], "access_right" => "open", "license" => LICENSES[metadata["license"]],
        "publication_date" => metadata["publication_date"], "version" => metadata["version"],
        "prereserve_doi" => true, "related_identifiers" => related,
        "notes" => "MetaManifold publication " * publication_id * "; config SHA-256 " * binding["config_hash"],
        "keywords" => ["MetaManifold", "reproducibility", binding["kind"]])
end

function citation_text(metadata, doi)
    join((c["name"] for c in metadata["creators"]), "; ") * " (" * metadata["publication_date"][1:4] * "). " *
        metadata["title"] * " (" * metadata["version"] * ") [Data set]. Zenodo. https://doi.org/" * doi
end

function citation_cff(metadata, doi)
    io = IOBuffer()
    println(io, "cff-version: 1.2.0\nmessage: \"Cite the published Zenodo record; reserved and sandbox DOIs are not production citations.\"\ntype: dataset")
    for (key, value) in (("title", metadata["title"]), ("doi", doi), ("version", metadata["version"]),
                         ("date-released", metadata["publication_date"]), ("license", metadata["license"]))
        println(io, key, ": ", JSON3.write(value)) # JSON strings are valid quoted YAML scalars.
    end
    println(io, "authors:")
    for creator in metadata["creators"]
        println(io, "  - name: ", JSON3.write(creator["name"]))
        haskey(creator, "orcid") && println(io, "    orcid: ", JSON3.write("https://orcid.org/" * creator["orcid"]))
    end
    return String(take!(io))
end

function decorate_bundle!(directory, metadata, binding, publication_id, environment, deposit_id, doi)
    # Publication is an external attestation, not an edit to the hashed config/result.
    publication = merge(copy(binding), Dict("schema_version" => "1.0.0", "publication_id" => publication_id,
        "environment" => environment, "deposition_id" => deposit_id, "doi" => doi, "state" => "reserved",
        "github_release_url" => metadata["github_release_url"], "github_project_url" => metadata["github_project_url"]))
    write(joinpath(directory, "publication.json"), canonical_json(publication))
    write(joinpath(directory, "CITATION.cff"), citation_cff(metadata, doi))
    write(joinpath(directory, "CITATION.txt"), citation_text(metadata, doi) * "\n")
    write(joinpath(directory, "zenodo.json"), canonical_json(zenodo_metadata(metadata, binding, publication_id)))
    # DataCite metadata uses its own schema, NOT the deposition request schema.
    related = [Dict("relatedIdentifier" => metadata[f], "relatedIdentifierType" => "URL", "relationType" => relation)
        for (f, relation) in (("github_release_url", "IsSupplementTo"), ("github_project_url", "References")) if !isnothing(metadata[f])]
    datacite = Dict("identifiers" => [Dict("identifier" => doi, "identifierType" => "DOI")],
        "creators" => [Dict("name" => c["name"]) for c in metadata["creators"]],
        "titles" => [Dict("title" => metadata["title"])], "publisher" => "Zenodo",
        "publicationYear" => parse(Int, metadata["publication_date"][1:4]),
        "types" => Dict("resourceTypeGeneral" => "Dataset", "resourceType" => binding["kind"]),
        "descriptions" => [Dict("description" => metadata["description"], "descriptionType" => "Abstract")],
        "rightsList" => [Dict("rights" => metadata["license"], "rightsIdentifier" => lowercase(metadata["license"]), "rightsIdentifierScheme" => "SPDX")],
        "relatedIdentifiers" => related, "version" => metadata["version"],
        "alternateIdentifiers" => [Dict("alternateIdentifier" => binding["config_hash"], "alternateIdentifierType" => "SHA-256")])
    write(joinpath(directory, "datacite.json"), canonical_json(datacite))
    open(joinpath(directory, "README.md"), "a") do io
        println(io, "\n## Zenodo publication\n\nEnvironment: ", environment, ". Kind: ", binding["kind"], ".")
        println(io, "\nReserved DOI: ", doi, ". It is registered only after publication. Sandbox records are test records.")
        println(io, "\n", citation_text(metadata, doi))
        println(io, "\n`publication.json` binds the DOI to the original config/result hashes without changing them.")
        println(io, "`checksums.sha256` covers every payload file. The separate post-publication receipt records the archive hash (avoiding a circular hash).")
        println(io, "Raw inputs and reference databases are not included; their availability must be described by the authors.")
    end
    write_checksums!(directory)
    return directory
end

end # module DOIBundles
