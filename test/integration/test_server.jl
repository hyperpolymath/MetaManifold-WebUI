# SPDX-License-Identifier: AGPL-3.0-only
# Integration smoke tests for the Oxygen.jl HTTP server.
#
# These tests start the server as a subprocess to avoid module-redefinition
# conflicts (the main test suite already loads pipeline modules; server.jl
# re-includes them, creating incompatible type instances).
#
# Run via:
#   julia --project=. -t4 test/runtests.jl --integration

@testset "Server smoke tests" begin

    PROJECT_ROOT = joinpath(@__DIR__, "..", "..")

    # Build a minimal data layout the server can enumerate
    tmp_root = mktempdir()
    study_run = joinpath(tmp_root, "data", "smoke_study", "run_A")
    mkpath(study_run)
    # A run directory needs at least one FASTQ pair to be recognised
    touch(joinpath(study_run, "sampleX_R1.fastq.gz"))
    touch(joinpath(study_run, "sampleX_R2.fastq.gz"))

    port = 18765
    server_script = joinpath(PROJECT_ROOT, "src", "server", "server.jl")

    ## `Base.julia_cmd()` propagates the PARENT's flags to the child. Measured on
    ## julia 1.12.5: `--compiled-modules=no` and `--code-coverage=user` both
    ## propagate (`-t` does not). Under the CI line
    ##   julia --project=. -t 2 --code-coverage=user --compiled-modules=no ...
    ## that makes this server load Oxygen + HTTP + every pipeline module with
    ## precompilation DISABLED, which on a cold runner can alone exceed the
    ## readiness budget below.
    ##
    ## Drop `--compiled-modules=no` for the child only. Deliberately KEEP
    ## `--code-coverage=user`: the SIGINT shutdown in the `finally` block below
    ## exists precisely so the child flushes its coverage data, which is what
    ## counts the server's route lines.
    server_argv = collect(Base.julia_cmd().exec)
    filter!(a -> a != "--compiled-modules=no", server_argv)
    push!(server_argv, "--project=$PROJECT_ROOT", server_script)

    ## Capture the child's output. Without this a startup crash is invisible:
    ## the readiness probe below cannot distinguish "crashed" from "not up yet",
    ## so the failure message would carry no evidence at all.
    server_out = joinpath(tmp_root, "server.out.log")
    server_err = joinpath(tmp_root, "server.err.log")

    server_cmd = Cmd(Cmd(server_argv);
                     env=merge(ENV, Dict("JULIA_METAMANIFOLD_ROOT" => tmp_root,
                                         "JULIA_METAMANIFOLD_PORT" => string(port))))
    proc = run(pipeline(server_cmd; stdout=server_out, stderr=server_err); wait=false)

    ## Wait up to 30 s for the server to accept connections.
    ## (60 iterations x 0.5 s sleep. `readtimeout` does NOT add to this: a
    ## refused connection on localhost returns immediately while nothing is
    ## listening, so it never fires during startup.)
    ready = false
    exited_early = false
    for _ in 1:60
        if process_exited(proc)
            exited_early = true
            break
        end
        try
            HTTP.get("http://localhost:$port/api/v1/studies"; readtimeout=1,
                     status_exception=false)
            ready = true
            break
        catch
            sleep(0.5)
        end
    end

    ## Turn a silent `false` into an actual diagnosis. This is what makes a CI
    ## failure here actionable: it settles crash-vs-slow-load in one run.
    function server_failure_report()
        io = IOBuffer()
        println(io, "Server subprocess never became ready on port $port.")
        println(io, "  command       : ", join(server_argv, " "))
        println(io, "  exited early  : ", exited_early)
        if process_exited(proc)
            println(io, "  exit code     : ", proc.exitcode)
        else
            println(io, "  state         : still running (30 s readiness budget exhausted)")
            println(io, "  reading       : consistent with slow cold load, not a crash")
        end
        for (label, path) in (("stdout", server_out), ("stderr", server_err))
            if isfile(path)
                lines = readlines(path)
                if isempty(lines)
                    println(io, "  --- $label: EMPTY ---")
                else
                    tail = lines[max(1, length(lines) - 39):end]
                    println(io, "  --- $label (last $(length(tail)) of $(length(lines)) lines) ---")
                    for l in tail
                        println(io, "    ", l)
                    end
                end
            else
                println(io, "  --- $label: no file (child produced nothing) ---")
            end
        end
        String(take!(io))
    end

    try
        ready || @error server_failure_report()
        @test ready

        if ready
            ## GET /api/v1/studies -> 200, array
            r = HTTP.get("http://localhost:$port/api/v1/studies"; status_exception=false)
            @test r.status == 200
            studies = JSON3.read(String(r.body))
            @test studies isa AbstractVector

            ## GET /api/v1/studies/smoke_study -> 200
            r2 = HTTP.get("http://localhost:$port/api/v1/studies/smoke_study";
                          status_exception=false)
            @test r2.status == 200

            ## GET /api/v1/studies/nonexistent -> 404
            r3 = HTTP.get("http://localhost:$port/api/v1/studies/nonexistent";
                          status_exception=false)
            @test r3.status == 404
            body3 = JSON3.read(String(r3.body))
            @test body3[:error] == "study_not_found"

            ## GET /api/v1/databases -> 200, array
            r4 = HTTP.get("http://localhost:$port/api/v1/databases"; status_exception=false)
            @test r4.status == 200

            ## Path traversal guard -> 403
            r5 = HTTP.get("http://localhost:$port/files/smoke_study/runs/run_A/../../../etc/passwd";
                          status_exception=false)
            @test r5.status in (403, 404)

            @info "Server smoke tests passed on port $port"
        end
    finally
        ## Interrupt rather than hard-kill: SIGINT lets the server unwind and
        ## run its at-exit hooks, which is what flushes --code-coverage data to
        ## disk. A SIGKILL/SIGTERM would terminate before the coverage writer
        ## runs, so the subprocess's route lines would never be counted.
        ## (This is why --code-coverage=user is kept on the child above.)
        if process_running(proc)
            kill(proc, Base.SIGINT)
            for _ in 1:60
                process_running(proc) || break
                sleep(0.25)
            end
            process_running(proc) && kill(proc)
        end
        try
            wait(proc)
        catch
        end
        rm(tmp_root; recursive=true)
    end

end
