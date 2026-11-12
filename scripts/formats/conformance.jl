#!/usr/bin/env julia
# SPDX-License-Identifier: MPL-2.0
# Characterize an installed ijson-jcs-compatible `canon` adapter.
#
# Tests original bytes, exact stdout and documented exit codes. No parsing or
# canonicalization is implemented here. Exit 0 = corpus passed, 1 = mismatch,
# 2 = infrastructure/configuration failure. This is NOT kyq readiness approval.
isdefined(Main, :FormatProcess) || Base.include(Main, joinpath(@__DIR__, "process.jl"))

module Conformance

using TOML
using Main.FormatProcess: ToolError, ValueError, run_probe, pyname, CliOption, parse_cli

const ROOT = dirname(dirname(dirname(realpath(@__FILE__))))
const DESCRIPTION = "Characterize an installed ijson-jcs-compatible `canon` adapter."
const ALLOWED = Set(["id", "input", "hex", "valid", "canonical"])

# One corpus case: id, original bytes, expected verdict, expected canonical bytes.
const Case = NamedTuple{(:name, :data, :valid, :expected),
                        Tuple{String,Vector{UInt8},Bool,Vector{UInt8}}}

# bytes.fromhex: pairs of hex digits, ASCII whitespace allowed between bytes.
function fromhex(text::AbstractString)
    out = UInt8[]
    chars = collect(text)
    i = 1
    while i <= length(chars)
        if chars[i] in (' ', '\t', '\n', '\r', '\f', '\v')
            i += 1
            continue
        end
        (i + 1 <= length(chars) && isascii(chars[i]) && isascii(chars[i + 1]) &&
         isxdigit(chars[i]) && isxdigit(chars[i + 1])) ||
            throw(ValueError("non-hexadecimal number found in fromhex() arg"))
        push!(out, parse(UInt8, string(chars[i], chars[i + 1]); base=16))
        i += 2
    end
    return out
end

function case_input(case)
    haskey(case, "input") == haskey(case, "hex") && throw(ValueError("case needs exactly one input"))
    raw = haskey(case, "input") ? case["input"] : case["hex"]
    raw isa AbstractString || throw(ValueError("input must be a string or hex string"))
    return haskey(case, "input") ? Vector{UInt8}(codeunits(raw)) : fromhex(raw)
end

function parse_case(case)
    if !(case isa AbstractDict) || !isempty(setdiff(Set(keys(case)), ALLOWED))
        throw(ValueError("invalid case fields"))
    end
    name = get(case, "id", "")
    if !(name isa AbstractString) || !occursin(r"^[a-z0-9-]+\z", name)
        throw(ValueError("invalid case id"))
    end
    get(case, "valid", nothing) isa Bool || throw(ValueError("case needs an explicit verdict"))
    case["valid"] != haskey(case, "canonical") &&
        throw(ValueError("only valid cases must have canonical bytes"))
    expected = get(case, "canonical", "")
    expected isa AbstractString || throw(ValueError("canonical bytes must be a UTF-8 string"))
    data, encoded = case_input(case), Vector{UInt8}(codeunits(expected))
    if length(data) > 131072 || length(encoded) > 131072
        throw(ValueError("case exceeds the corpus budget"))
    end
    return Case((String(name), data, case["valid"], encoded))
end

function load_cases(path)
    # Paths come from this repo's constant fixture location or test fixtures,
    # never a CLI-supplied filesystem path. No arbitrary-file reader CLI.
    document = TOML.parse(String(read(path)))
    (get(document, "schema", nothing) isa Int && document["schema"] == 1) ||
        throw(ValueError("unsupported corpus schema"))
    Set(keys(document)) == Set(["schema", "case"]) ||
        throw(ValueError("unsupported corpus fields"))
    cases = document["case"]
    (cases isa AbstractVector && !isempty(cases)) || throw(ValueError("empty or invalid corpus"))
    seen = Set{String}()
    result = Case[]
    for raw in cases
        case = parse_case(raw)
        case.name in seen && throw(ValueError("duplicate case id"))
        push!(seen, case.name)
        push!(result, case)
    end
    return result
end

function check(adapter, cases; timeout=5.0)
    operations = Dict("reference" => "ijson-canon", "candidate" => "kyq-canon")
    operation = operations[adapter]
    passed = true
    for case in cases
        result = run_probe(operation, case.data; timeout=timeout)
        # Rejection must be the documented invalid-input exit, not a crash,
        # missing library, usage failure from a wrapper, or arbitrary nonzero.
        wanted = case.valid ? 0 : 2
        ok = result.code == wanted && result.stdout == case.expected
        println(ok ? "PASS" : "FAIL", " ", case.name)
        passed = passed && ok
    end
    return passed
end

function main(argv=ARGS)
    args = parse_cli("conformance.jl", DESCRIPTION, argv, [
        CliOption("adapter", "ADAPTER"; default="reference", choices=["reference", "candidate"]),
        CliOption("timeout", "TIMEOUT"; default=5.0, convert=s -> parse(Float64, strip(s))),
    ])
    try
        # Validate the entire corpus before invoking the first child.
        cases = load_cases(joinpath(ROOT, "test/fixtures/formats/ijson-jcs.toml"))
        ok = check(args["adapter"], cases; timeout=args["timeout"])
        println("Corpus: $(length(cases)) cases; runtime migration remains separately gated")
        return ok ? 0 : 1
    catch error
        known = error isa ToolError || error isa ValueError || error isa Base.IOError ||
                error isa SystemError || error isa TOML.ParserError
        known || rethrow()
        # Do not echo paths, source text, child stderr or exception values.
        name = error isa TOML.ParserError ? "TOMLDecodeError" : pyname(error)
        println(stderr, "INFRASTRUCTURE: $name; no conformance pass")
        return 2
    end
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    exit(Conformance.main(ARGS))
end
