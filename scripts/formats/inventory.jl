#!/usr/bin/env julia
# SPDX-License-Identifier: MPL-2.0
# Inventory lexical JSON/YAML candidates; NEVER a compliance verdict.
#
# Includes tracked and non-ignored new files, including hidden workflow/hooks.
# Search hits can be comments/test strings. Aliases/dynamic dispatch require human
# review. Prints locations/operation names, not source lines or document contents.
isdefined(Main, :FormatProcess) || Base.include(Main, joinpath(@__DIR__, "process.jl"))

module Inventory

using Main.FormatProcess: CliOption, parse_cli

const ROOT = dirname(dirname(dirname(realpath(@__FILE__))))
const DESCRIPTION = "Inventory lexical JSON/YAML candidates; NEVER a compliance verdict."
const CODE = Set([".yaml", ".yml", ".kyaml", ".jl", ".ts", ".tsx", ".js", ".mjs", ".py",
                  ".sh", ".R", ".r", ".rs"])
const DATA = Set([".json", ".jsonl", ".yaml", ".yml", ".kyaml"])
# (*UCP) makes \b, \w and \s Unicode-aware, as they are for Python str patterns.
const PATTERNS = [
    "JSON3.read" => r"(*UCP)\bJSON3\.read\s*\(",
    "JSON3.write" => r"(*UCP)\bJSON3\.write\s*\(",
    "YAML IO" => r"(*UCP)\bYAML\.(?:load_file|load|write_file|write)\s*\(",
    "strict/JCS adapter" => r"(*UCP)\b(?:ijson_read|jcs_bytes|jcs_sha256|ijsonJcsStringify|_request_json)\s*\(",
    "JSON.parse" => r"(*UCP)\bJSON\.parse\s*\(",
    "JSON.stringify" => r"(*UCP)\bJSON\.stringify\s*\(",
    "response.json candidate" => r"(*UCP)\.json\s*\(",
    "Python JSON IO" => r"(*UCP)\bjson\.(?:load|loads|dump|dumps)\s*\(",
    "Oxygen JSON candidate" => r"(*UCP)(?<![\w.])json\s*\(",
    "R JSON IO" => r"(*UCP)\b(?:jsonlite::)?(?:fromJSON|toJSON|read_json|write_json)\s*\(",
    "shell jq/yq candidate" => r"(*UCP)(?m)(?<![\w/-])(?:jq|yq)\s+(?:-[A-Za-z]|['\"])",
]

const Row = NamedTuple{(:kind, :bucket, :path, :line, :operation),
                       Tuple{String,String,String,Int,String}}

struct InvalidUTF8 <: Exception end
Base.showerror(io::IO, ::InvalidUTF8) = print(io, "UnicodeError")

# Routing buckets, NOT automatic approval or proof of ownership/compliance.
function category(name::AbstractString)
    if startswith(name, "test/") || startswith(name, "tests/")
        return "test-fixture-or-oracle"
    end
    startswith(name, ".github/") && return "workflow-or-service-config"
    if startswith(name, "src/core/doi") || startswith(name, "src/core/epistemic") ||
       startswith(name, "src/core/provenance")
        return "legacy-identity-sensitive-review"
    end
    if name == "renv.lock" || name == "frontend/bun.lock" || startswith(name, "renv/")
        return "external-tool-owned-review"
    end
    (startswith(name, "src/") || startswith(name, "frontend/src/")) &&
        return "application-mixed-boundaries-review"
    (startswith(name, "config/") || startswith(name, "data/")) && return "configuration-review"
    if startswith(name, "scripts/") || startswith(name, "bench/") || startswith(name, "proofs/")
        return "tooling-or-reference-review"
    end
    return "untriaged"
end

# pathlib.PurePath.suffix: text from the last dot, unless it is the first or last character.
function suffix_of(name::AbstractString)
    i = findlast('.', name)
    (i === nothing || i == 1 || i == lastindex(name)) && return ""
    return name[i:end]
end

# Strict UTF-8 decode, then universal newlines like Path.read_text().
function read_text(path)
    bytes = read(path)
    isvalid(String, bytes) || throw(InvalidUTF8())
    text = String(bytes)
    return replace(replace(text, "\r\n" => "\n"), "\r" => "\n")
end

function file_rows(emit, root, name)
    path = joinpath(root, name)
    bucket = category(name)
    if islink(path)
        emit(Row(("symlink", bucket, name, 0, "target-not-followed")))
        return
    end
    if !isfile(path)
        emit(Row(("missing", bucket, name, 0, "missing-worktree-file")))
        return
    end
    base = basename(name)
    suffix = suffix_of(base)
    if suffix in DATA || base == "renv.lock" || base == "bun.lock"
        emit(Row(("document", bucket, name, 0, "format-owner-needs-review")))
    end
    suffix in CODE || return
    local text
    try
        text = read_text(path)
    catch error
        error isa InvalidUTF8 || rethrow()
        emit(Row(("unreadable", bucket, name, 0, "invalid-utf8-source")))
        return
    end
    codeunit_text = codeunits(text)
    for (label, pattern) in PATTERNS
        for match in eachmatch(pattern, text)
            line = count(==(0x0a), view(codeunit_text, 1:(match.offset - 1))) + 1
            emit(Row(("candidate", bucket, name, line, label)))
        end
    end
end

# Streams rows to `emit`, like the generator it replaces: an error part-way
# leaves the earlier rows already emitted.
function each_row(emit, root)
    raw = read(pipeline(Cmd(`git ls-files --cached --others --exclude-standard -z`; dir=root);
                        stderr=devnull))
    names = String[]
    start = 1
    for stop in vcat(findall(==(0x00), raw), length(raw) + 1)
        piece = raw[start:(stop - 1)]
        start = stop + 1
        isempty(piece) && continue
        isvalid(String, piece) || throw(InvalidUTF8())
        push!(names, String(piece))
    end
    for name in sort!(unique!(names))
        file_rows(emit, root, name)
    end
end

function inventory(root)
    rows = Row[]
    each_row(row -> push!(rows, row), root)
    return rows
end

# csv.writer(delimiter="\t", lineterminator="\n"), QUOTE_MINIMAL.
function csv_field(value)
    text = string(value)
    if occursin(r"[\t\"\n]", text)
        return "\"" * replace(text, "\"" => "\"\"") * "\""
    end
    return text
end
write_row(io, values) = print(io, join(map(csv_field, Tuple(values)), '\t'), '\n')

function main(argv=ARGS)
    args = parse_cli("inventory.jl", DESCRIPTION, argv, [
        CliOption("root", "ROOT"; default=ROOT),
    ])
    root = try
        realpath(args["root"])
    catch
        abspath(args["root"])
    end
    write_row(stdout, ("kind", "routing-bucket-not-verdict", "path", "line", "operation"))
    try
        each_row(row -> write_row(stdout, row), root)
        return 0
    catch error
        known = error isa Base.IOError || error isa SystemError || error isa InvalidUTF8 ||
                error isa ProcessFailedException
        known || rethrow()
        println(stderr, "inventory failed; no completeness or compliance claim")
        return 2
    end
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    exit(Inventory.main(ARGS))
end
