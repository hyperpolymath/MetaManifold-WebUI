# Integration smoke tests for the Oxygen.jl HTTP server.
#
# These tests start the server as a subprocess, so that they exercise the
# real listener and middleware stack.
#
# Run via:
#   julia --project=. -t4 test/runtests.jl --server

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
    server_script = joinpath(PROJECT_ROOT, "scripts", "serve.jl")
    proc = run(Cmd(`$(Base.julia_cmd()) --project=$PROJECT_ROOT $server_script`;
                   env=merge(ENV, Dict("JULIA_METAMANIFOLD_ROOT" => tmp_root,
                                      "JULIA_METAMANIFOLD_PORT" => string(port))));
               wait=false)

    # CI loads the server with --compiled-modules=no, which takes minutes.
    ready = false
    for _ in 1:1200
        process_running(proc) || break
        try
            HTTP.get("http://localhost:$port/api/v1/studies"; readtimeout=1,
                     status_exception=false)
            ready = true
            break
        catch
            sleep(0.5)
        end
    end

    try
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

            ## Validated direct statistics through the real listener/middleware.
            statistics_url = "http://localhost:$port/api/v1/statistics/summaries"
            statistics_headers = ["Content-Type" => "application/json",
                                  "Origin" => "http://localhost:$port"]
            statistics_payload = Dict(
                "numeric_policy" => Dict("mode" => "exact_counts"),
                "sample_labels" => ["A", "B"],
                "feature_labels" => ["f1", "f2"],
                "counts" => [[1, "9007199254740993"], [3, 1]],
                "persist" => true,
            )
            statistics_response = HTTP.post(statistics_url, statistics_headers,
                JSON3.write(statistics_payload); status_exception=false)
            @test statistics_response.status == 200
            statistics = JSON3.read(String(statistics_response.body))
            @test statistics.samples[2].total == "9007199254740994"
            statistics_id = String(statistics.analysis_id)
            persisted = HTTP.get("http://localhost:$port/api/v1/statistics/derived/$statistics_id";
                                 status_exception=false)
            @test persisted.status == 200
            @test JSON3.read(String(persisted.body)).analysis_id == statistics_id
            bad_statistics = merge(statistics_payload, Dict(
                "counts" => [[1.0, 2], [3, 1]], "persist" => false))
            rejected = HTTP.post(statistics_url, statistics_headers,
                JSON3.write(bad_statistics); status_exception=false)
            @test rejected.status == 422

            ## Configuration persistence through the real listener/middleware.
            config_url = "http://localhost:$port/api/v1/config"
            headers = ["Content-Type"=>"application/json", "Origin"=>"http://localhost:$port"]
            for (submitted, canonical) in ((" ML ", "ml"), (" GLMGAMPOI ", "glmGamPoi"))
                response = HTTP.patch(config_url, headers,
                    JSON3.write(Dict("analysis.differential.method"=>"nb_glm",
                                     "analysis.differential.dispersion"=>submitted)); status_exception=false)
                @test response.status == 200
                @test JSON3.read(String(response.body))["analysis.differential.dispersion"].value == canonical
                response = HTTP.get(config_url; status_exception=false)
                @test response.status == 200
                @test JSON3.read(String(response.body))["analysis.differential.dispersion"].value == canonical
                saved = YAML.load_file(joinpath(tmp_root, "config", "pipeline.yml"))
                @test saved["analysis"]["differential"]["dispersion"] == canonical
            end

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
        kill(proc, Base.SIGINT)
        for _ in 1:60
            process_running(proc) || break
            sleep(0.25)
        end
        process_running(proc) && kill(proc)
        try
            wait(proc)
        catch
        end
        rm(tmp_root; recursive=true)
    end

end
