#!/usr/bin/env julia
# SPDX-License-Identifier: MPL-2.0
# Probe pinned kyq source recipes without installing or rewriting anything.
#
# Exit 0 means ONLY that build/wasm/test returned success. It does not establish
# parser conformance, an installed executable, or readiness for application use.
# Exit 1 = recipe failure; 2 = missing tools, wrong source pin, or other infra.
isdefined(Main, :FormatProcess) || Base.include(Main, joinpath(@__DIR__, "process.jl"))

module ProbeKyq

using TOML
using Main.FormatProcess: ToolError, ValueError, run_probe, pyname, CliOption, parse_cli

const ROOT = dirname(dirname(dirname(realpath(@__FILE__))))
const DESCRIPTION = "Probe pinned kyq source recipes without installing or rewriting anything."

# bytes.decode(): strict UTF-8.
function decode(bytes)
    isvalid(String, bytes) || throw(ValueError("invalid utf-8", "UnicodeDecodeError"))
    return String(bytes)
end

function probe(source, timeout)
    pin = TOML.parsefile(joinpath(ROOT, "config/format-tools.toml"))["kyq"]
    actual = run_probe("git-head"; cwd=source)
    clean = run_probe("git-status"; cwd=source)
    if actual.code != 0 || strip(decode(actual.stdout)) != pin["revision"] ||
       clean.code != 0 || !isempty(clean.stdout)
        throw(ToolError("source is not the clean pinned revision"))
    end
    version = run_probe("just-version")
    if version.code != 0 || strip(decode(version.stdout)) != "just $(pin["just_version"])"
        throw(ToolError("unexpected just version"))
    end
    ok = true
    for recipe in ("build", "wasm", "test")
        result = run_probe("just-$recipe"; cwd=source, timeout=timeout)
        println("$recipe: exit=$(result.code)")
        ok = ok && result.code == 0
    end
    println("install: NOT_RUN (no isolated-prefix contract has been established)")
    println("parser/CLI conformance: NOT_RUN (separate evidence required)")
    println("MetaManifold migration: BLOCKED pending runtime conformance and isolated installation")
    return ok ? 0 : 1
end

function main(argv=ARGS)
    args = parse_cli("probe_kyq.jl", DESCRIPTION, argv, [
        CliOption("source", "SOURCE"; required=true),
        CliOption("timeout", "TIMEOUT"; default=120.0, convert=s -> parse(Float64, strip(s))),
    ])
    try
        return probe(args["source"], args["timeout"])
    catch error
        known = error isa ToolError || error isa ValueError || error isa Base.IOError ||
                error isa SystemError || error isa KeyError || error isa TOML.ParserError
        known || rethrow()
        name = error isa TOML.ParserError ? "TOMLDecodeError" : pyname(error)
        println(stderr, "INFRASTRUCTURE: $name; kyq readiness not established")
        return 2
    end
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    exit(ProbeKyq.main(ARGS))
end
