# SPDX-License-Identifier: MPL-2.0
# Tests of the harness itself; fake children are NOT parser conformance evidence.
#
# Run: julia --startup-file=no scripts/tests/test_format_readiness.jl
# Fake installed tools are small /bin/sh scripts, never a production interpreter command.
using Test
using TOML

const ROOT = dirname(dirname(dirname(realpath(@__FILE__))))
include(joinpath(ROOT, "scripts/formats/conformance.jl"))
include(joinpath(ROOT, "scripts/formats/inventory.jl"))
include(joinpath(ROOT, "scripts/formats/probe_kyq.jl"))
using Main.FormatProcess: ToolError, run_probe
using Main.FormatDescendants: ProcessLookupError

# ---- helpers -------------------------------------------------------------

# Run `f` with stdout and stderr captured; returns (value, stdout, stderr).
function capture(f)
    mktempdir() do tmp
        out_path, err_path = joinpath(tmp, "out"), joinpath(tmp, "err")
        value = open(out_path, "w") do out
            open(err_path, "w") do err
                redirect_stdout(out) do
                    redirect_stderr(err) do
                        f()
                    end
                end
            end
        end
        return value, read(out_path, String), read(err_path, String)
    end
end

function write_tool(directory, body)
    path = joinpath(directory, "ijson-jcs")
    write(path, "#!/bin/sh\n$body\n")
    chmod(path, 0o700)
    return path
end

path_with(directory) = directory * ":" * ENV["PATH"]

# A fake installed protocol adapter named ijson-jcs, first on PATH.
function run_fake(body; data=UInt8[], kwargs...)
    mktempdir(; prefix="format tool ") do tmp
        write_tool(tmp, body)
        withenv("PATH" => path_with(tmp)) do
            run_probe("ijson-canon", data; kwargs...)
        end
    end
end

# True when `f` throws a ToolError whose message matches `pattern`.
function tool_error(f, pattern=nothing)
    try
        f()
    catch error
        return error isa ToolError && (pattern === nothing || occursin(pattern, error.msg))
    end
    return false
end

# Corpus rejection: the Python ValueError/TypeError family, including TOML decode errors.
function rejects_corpus(f)
    try
        f()
    catch error
        return error isa Main.FormatProcess.ValueError || error isa TOML.ParserError
    end
    return false
end

mkcase(name, data, valid, expected) =
    Conformance.Case((name, Vector{UInt8}(codeunits(data)), valid, Vector{UInt8}(codeunits(expected))))

# Stands in for the Python Mock child in the cleanup tests.
mutable struct MockChild
    pid::Int
    polls::Vector{Any}
    poll_calls::Int
    kill_error::Bool
    kills::Int
    waits::Vector{Float64}
    wait_result::Int
    closed::Bool
end
MockChild(pid; polls=Any[nothing], kill_error=false) =
    MockChild(pid, polls, 0, kill_error, 0, Float64[], -9, false)
Main.FormatProcess.child_pid(m::MockChild) = m.pid
function Main.FormatProcess.child_poll(m::MockChild)
    m.poll_calls += 1
    return m.polls[min(m.poll_calls, length(m.polls))]
end
function Main.FormatProcess.child_kill(m::MockChild)
    m.kills += 1
    m.kill_error && throw(ProcessLookupError())
end
function Main.FormatProcess.child_wait(m::MockChild, timeout)
    push!(m.waits, timeout)
    return m.wait_result
end
Main.FormatProcess.close_streams(m::MockChild) = (m.closed = true; nothing)

# Warm up compilation so timing-sensitive cases measure the child, not the JIT.
run_fake("true")

# ---- ProcessTests --------------------------------------------------------

@testset "ProcessTests" begin
    @testset "test_round_trip_binary_io" begin
        raw = repeat(UInt8.(0:255), 200)
        result = run_fake("cat"; data=raw)
        @test (result.code, result.stdout, result.stderr) == (0, raw, UInt8[])
    end

    @testset "test_stderr_separate_and_exit_preserved" begin
        result = run_fake("printf private >&2; exit 7")
        @test (result.code, result.stdout, result.stderr) == (7, UInt8[], Vector{UInt8}("private"))
    end

    @testset "test_missing_binary_is_infrastructure_not_document_rejection" begin
        withenv("PATH" => "") do
            @test tool_error(() -> run_probe("ijson-canon"))
        end
    end

    @testset "test_timeout" begin
        @test tool_error(() -> run_fake("sleep 10"; timeout=0.15), "time budget")
    end

    @testset "test_output_budget_covers_both_streams" begin
        @test tool_error(() -> run_fake("head -c 10000 /dev/zero | tr '\\0' x >&2"; limit=100),
                         "output budget")
    end

    @testset "test_cleanup_kills_direct_child_when_its_group_is_gone" begin
        child = MockChild(12345; polls=Any[nothing])
        Main.FormatProcess.cleanup(child; killpg=pid -> throw(ProcessLookupError()))
        @test child.kills == 1
        @test child.waits == [0.5]
        @test child.closed
    end

    @testset "test_cleanup_reports_a_live_child_that_cannot_be_killed" begin
        child = MockChild(12345; polls=Any[nothing, nothing], kill_error=true)
        @test tool_error(() -> Main.FormatProcess.cleanup(child; killpg=pid -> throw(ProcessLookupError())),
                         "escaped its process group")
        @test isempty(child.waits)
        @test child.poll_calls == 2
        @test child.closed
    end

    @testset "test_input_and_deadline_budgets" begin
        for kwargs in (Dict(:timeout => 0), Dict(:timeout => NaN), Dict(:timeout => Inf),
                       Dict(:limit => 0), Dict(:data => UInt8[0x78, 0x78], :limit => 1))
            @test tool_error(() -> run_fake("true"; kwargs...))
        end
    end

    @testset "test_arbitrary_programs_and_arguments_are_refused" begin
        for argv in ([joinpath(Sys.BINDIR, "julia"), "-e", "nothing"],
                     ["git", "config", "--global", "x", "y"])
            @test tool_error(() -> run_probe(argv))
        end
    end

    @testset "test_symlink_cannot_disguise_an_interpreter_as_a_canonicalizer" begin
        mktempdir() do tmp
            symlink(joinpath(Sys.BINDIR, "julia"), joinpath(tmp, "ijson-jcs"))
            withenv("PATH" => path_with(tmp)) do
                @test tool_error(() -> run_probe("ijson-canon"))
            end
        end
    end

    @testset "test_detached_double_fork_is_killed_and_reaped" begin
        mktempdir() do tmp
            pid_file = joinpath(tmp, "detached.pid")
            body = "( setsid sh -c 'echo \$\$ > \"$pid_file\"; exec sleep 30' & )\nsleep 30"
            @test tool_error(() -> run_fake(body; timeout=0.4), "time budget")
            pid = parse(Int, strip(read(pid_file, String)))
            @test ccall(:kill, Cint, (Cint, Cint), pid, 0) == -1
            @test Libc.errno() == 3  # ESRCH
        end
    end

    @testset "test_missing_procfs_fails_closed" begin
        for hook in (Main.FormatDescendants.LISTDIR, Main.FormatDescendants.READTEXT)
            original = hook[]
            hook[] = _ -> throw(Base.IOError("procfs gone", Base.UV_ENOENT))
            try
                # Stricter than the Python original: the failure must come from
                # supervision, not from a coincidentally missing tool.
                @test tool_error(() -> run_probe("ijson-canon"), "supervision failed")
            finally
                hook[] = original
            end
        end
    end

    @testset "test_existing_child_context_is_refused_before_launch" begin
        launches = Ref(0)
        original_children, original_spawn = Main.FormatDescendants.CHILDREN[], Main.FormatProcess.SPAWN[]
        Main.FormatDescendants.CHILDREN[] = _ -> Set([12345])
        Main.FormatProcess.SPAWN[] = (args...) -> (launches[] += 1; error("must not launch"))
        try
            # A resolvable fake tool is on PATH, so a launch would really be attempted
            # (the Python original never reaches Popen here, which makes its assertion vacuous).
            mktempdir() do tmp
                write_tool(tmp, "true")
                withenv("PATH" => path_with(tmp)) do
                    @test tool_error(() -> run_probe("ijson-canon"), "supervision failed")
                end
            end
            @test launches[] == 0
        finally
            Main.FormatDescendants.CHILDREN[] = original_children
            Main.FormatProcess.SPAWN[] = original_spawn
        end
    end

    @testset "test_descendant_keeping_pipe_open_is_bounded" begin
        @test tool_error(() -> run_fake("sleep 10 &"; timeout=0.2), "time budget")
    end
end

# ---- CorpusTests ---------------------------------------------------------

# Run `f(tool_directory)` with a fake ijson-jcs in "tool with spaces" first on PATH.
function with_fake(f, directory, body)
    folder = joinpath(directory, "tool with spaces")
    mkdir(folder)
    write_tool(folder, body)
    withenv("PATH" => path_with(folder)) do
        f("reference")
    end
end

@testset "CorpusTests" begin
    @testset "test_raw_fixtures_survive_loading" begin
        cases = Conformance.load_cases(joinpath(ROOT, "test/fixtures/formats/ijson-jcs.toml"))
        @test length(cases) >= 30
        by_id = Dict(c.name => c for c in cases)
        @test by_id["invalid-utf8"].data == vcat(UInt8['[', '"'], 0xff, UInt8['"', ']'])
        @test by_id["escaped-equivalent-key"].data == Vector{UInt8}("{\"a\":1,\"\\u0061\":2}")
        @test by_id["exponent-thresholds"].expected == Vector{UInt8}("[0.000001,1e-7,1e+21]")
    end

    @testset "test_bad_and_ambiguous_corpora_fail_before_running_tools" begin
        for contents in (
            "schema=2\ncase=[]\n", "schema=true\ncase=[]\n", "schema=1\ncase=[]\n",
            "schema=1\n[[case]]\nid='a'\ninput='{}'\nvalid=true\n",
            "schema=1\n[[case]]\nid='a'\ninput='{}'\nhex='ff'\nvalid=false\n",
            "schema=1\n[[case]]\nid='a'\ninput='{}'\nvalid='false'\n",
            "schema=1\n[[case]]\nid='a'\ninput='{}'\nvalid=false\nunknown=1\n",
            "schema=1\n[[case]]\nid='a'\nhex='not-hex'\nvalid=false\n",
        )
            mktempdir() do tmp
                path = joinpath(tmp, "cases.toml")
                write(path, contents)
                @test rejects_corpus(() -> Conformance.load_cases(path))
            end
        end
    end

    @testset "test_duplicate_ids_fail" begin
        case = "\n[[case]]\nid='a'\ninput='{}'\nvalid=false\n"
        mktempdir() do tmp
            path = joinpath(tmp, "cases.toml")
            write(path, "schema=1\n" * case * case)
            @test rejects_corpus(() -> Conformance.load_cases(path))
        end
    end

    @testset "test_mutants_cannot_pass_as_canonicalizers" begin
        cases = [mkcase("valid", " {\"a\":1} ", true, "{\"a\":1}"),
                 mkcase("invalid", "{\"a\":1,\"a\":2}", false, "")]
        # Always-success, always-invalid, crashes, and passthrough all fail.
        for body in ("exit 0", "exit 2", "exit 1", "cat")
            mktempdir() do tmp
                passed, _, _ = capture() do
                    with_fake(tmp, body) do adapter
                        Conformance.check(adapter, cases)
                    end
                end
                @test passed == false
            end
        end
    end

    @testset "test_correct_adapter_protocol_passes_and_redacts_diagnostics" begin
        cases = [mkcase("valid", "true", true, "true"), mkcase("invalid", "broken", false, "")]
        body = """
        input=\$(cat)
        if [ "\$input" = true ]; then
          printf true
        else
          printf 'private input' >&2
          exit 2
        fi"""
        mktempdir() do tmp
            passed, out, _ = capture() do
                with_fake(tmp, body) do adapter
                    Conformance.check(adapter, cases)
                end
            end
            @test passed == true
            @test !occursin("private input", out)
        end
    end

    @testset "test_exact_bytes_no_newline_or_wrong_order" begin
        cases = [mkcase("order", "{}", true, "{\"a\":1,\"z\":2}")]
        for body in ("printf '%s' '{\"z\":2,\"a\":1}'", "printf '%s\\n' '{\"a\":1,\"z\":2}'")
            mktempdir() do tmp
                passed, _, _ = capture() do
                    with_fake(tmp, body) do adapter
                        Conformance.check(adapter, cases)
                    end
                end
                @test passed == false
            end
        end
    end

    @testset "test_missing_tool_cli_fails_closed_without_echoing_input" begin
        code, out, err = capture() do
            withenv("PATH" => "") do
                Conformance.main(String[])
            end
        end
        @test code == 2
        @test occursin("no conformance pass", err)
        @test !occursin("9007199254740992", out * err)
    end

    @testset "test_kyq_probe_missing_source_is_not_a_pass" begin
        code, _, _ = capture() do
            ProbeKyq.main(["--source", "/nonexistent/kyq"])
        end
        @test code == 2
    end
end

# ---- InventoryTests ------------------------------------------------------

@testset "InventoryTests" begin
    @testset "test_inventory_covers_hidden_new_files_and_never_echoes_source" begin
        mktempdir() do tmp
            run(`git init -q $tmp`)
            mkpath(joinpath(tmp, ".github/workflows"))
            write(joinpath(tmp, ".github/workflows/probe.yml"), "name: \"private-value\"\nrun: jq -r .value\n")
            write(joinpath(tmp, "client.ts"), "res.json();\nJSON.parse(\"private-value\")\n")
            symlink("/etc/passwd", joinpath(tmp, "foreign.json"))
            write(joinpath(tmp, ".gitignore"), "ignored.py\n")
            write(joinpath(tmp, "ignored.py"), "json.loads(\"ignore\")")
            rows = Inventory.inventory(realpath(tmp))
            @test any(r -> r.path == ".github/workflows/probe.yml", rows)
            @test any(r -> r.kind == "symlink" && r.path == "foreign.json", rows)
            @test any(r -> r.line == 2 && r.operation == "JSON.parse", rows)
            @test any(r -> r.path == ".github/workflows/probe.yml" && r.line == 2 &&
                           r.operation == "shell jq/yq candidate", rows)
            @test !any(r -> r.path == "ignored.py", rows)
            @test !occursin("private-value", repr(rows))
        end
    end
end
