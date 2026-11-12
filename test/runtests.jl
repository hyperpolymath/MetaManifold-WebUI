#!/usr/bin/env julia
# Time before the first test file: package loading and the run's set-up.
const _SCRIPT_START = time()
# MetaManifold test suite
#
# Run with:
#   julia --project=. test/runtests.jl
#
# For integration tests (requires tools + databases):
#   julia --project=. -t4 test/runtests.jl --integration
#
# Name unit test files to run only those, e.g.
#   julia --project=. test/runtests.jl test_routes.jl trees
#
# Leave files out of a full run, e.g. the ones an earlier step already ran:
#   julia --project=. test/runtests.jl --exclude=trees,test_routes.jl
#
# Every run ends with a table of where the time went, sorted by time. When
# GITHUB_STEP_SUMMARY is set the table is appended there as Markdown, under the
# title in TEST_TIMING_TITLE.
using Test

const RUN_INTEGRATION = "--integration" in ARGS
const RUN_SERVER      = "--server"      in ARGS

const UNIT_FILES = [
    "test_diversity.jl",
    "test_numeric_policy.jl",
    "test_exact_summaries.jl",
    "test_high_precision.jl",
    "test_derived_analyses.jl",
    "test_clade_cumulus.jl",
    "test_merge_taxa.jl",
    "test_config.jl",
    "test_validation.jl",
    "test_tools.jl",
    "test_analysis.jl",
    "test_duckdb_store.jl",
    "test_analysis_duckdb.jl",
    "test_validated_statistics.jl",
    "test_method_catalogue.jl",
    "test_statistics_boundaries.jl",
    "test_statistics_adversarial.jl",
    "test_statistics_properties.jl",
    "test_statistics_ui.jl",
    "test_config_hashing.jl",
    "test_project.jl",
    "test_log.jl",
    "test_databases.jl",
    "test_merge_taxa_mappings.jl",
    "test_routes.jl",
    "test_publication_tables.jl",
    "test_heatmap.jl",
    "test_trees.jl",
    "test_report_funnel.jl",
    "test_phylogeny.jl",
    "test_composition.jl",
    "test_composition_library.jl",
    "test_primers_library.jl",
    "test_databases_library.jl",
    "test_categories.jl",
    "test_read_conservation.jl",
    "test_r_runtime.jl",
    "test_dada2_commands.jl",
    "test_remote_stages.jl",
    "test_jobs.jl",
    "test_provenance.jl",
    "test_occupancy_grade.jl",
    "test_install_pins.jl",
    "test_migrate_composition.jl",
    "test_sample_reads.jl",
    "test_determinism.jl",
    "test_differential.jl",
    "test_evidence.jl",
    "test_evidence_routes.jl",
    "test_permanova.jl",
    "test_ordination.jl",
    "test_write_gates.jl",
    "test_server_security.jl",
    "test_canonical.jl",
    "test_doi.jl",
]

# A name as given on the command line ("test_routes.jl", "routes" or
# "unit/test_routes.jl") as the file name it stands for.
function _unit_file_name(a)
    b = basename(a)
    b = startswith(b, "test_") ? b : "test_" * b
    endswith(b, ".jl") ? b : b * ".jl"
end

# The comma-separated names of every --exclude=a,b option, as file names.
function _excluded_files(args = ARGS)
    names = String[]
    for a in args
        startswith(a, "--exclude=") || continue
        append!(names, filter(!isempty, strip.(split(a[length("--exclude=")+1:end], ','))))
    end
    files = _unit_file_name.(names)
    unknown = filter(f -> !isfile(joinpath(@__DIR__, "unit", f)), files)
    isempty(unknown) || error("No such unit test file to exclude: $(join(unknown, ", "))")
    files
end

# The files named on the command line, or every unit file when none is named,
# less the ones --exclude names.
function _selected_files()
    named = filter(a -> !startswith(a, "--"), ARGS)
    files = isempty(named) ? UNIT_FILES : _unit_file_name.(named)
    unknown = filter(f -> !isfile(joinpath(@__DIR__, "unit", f)), files)
    isempty(unknown) || error("No such unit test file: $(join(unknown, ", "))")
    excluded = _excluded_files()
    filter(f -> !(f in excluded), files)
end

# Where the time went: one row per unit file and per block, then the table.
const _TIMINGS = Tuple{String,Float64}[]

function _timed(f, label)
    t0 = time()
    try
        f()
    finally
        push!(_TIMINGS, (label, time() - t0))
    end
end

function _timing_report()
    rows = sort(_TIMINGS; by = last, rev = true)
    total = sum(last, rows; init = 0.0)
    fmt(s) = s >= 60 ? string(floor(Int, s / 60), "m", lpad(round(Int, s % 60), 2, '0'), "s") :
             string(round(s; digits = 1), "s")
    title = get(ENV, "TEST_TIMING_TITLE", "Julia test timings")
    println("\n", title, " (", fmt(total), " measured)")
    for (label, s) in rows
        println(rpad(label, 48), lpad(fmt(s), 9), lpad(string(round(Int, 100 * s / max(total, eps())), "%"), 6))
    end
    summary = get(ENV, "GITHUB_STEP_SUMMARY", "")
    if !isempty(summary)
        open(summary, "a") do io
            println(io, "### ", title, "\n")
            println(io, "| Step | Time | Share |\n| --- | ---: | ---: |")
            for (label, s) in rows
                println(io, "| `", label, "` | ", fmt(s), " | ", round(Int, 100 * s / max(total, eps())), "% |")
            end
            println(io, "| **Measured total** | **", fmt(total), "** | |\n")
        end
    end
end

using MetaManifold
using CSV, DataFrames, JSON3, Logging, YAML, DuckDB, DBInterface, Dates

using MetaManifold.PipelineTypes, MetaManifold.PipelineLog, MetaManifold.Config
using MetaManifold.Databases, MetaManifold.DuckDBStore, MetaManifold.Validation
using MetaManifold.Tools, MetaManifold.TaxonomyTableTools, MetaManifold.ProjectSetup
using MetaManifold.DiversityMetrics, MetaManifold.Analysis
using MetaManifold.Categories, MetaManifold.CompositionLibrary

# The load is everything above: the packages and MetaManifold itself.
push!(_TIMINGS, ("load packages and MetaManifold", time() - _SCRIPT_START))

## Unit tests (always run)
# The table is printed even when a test fails, so the cost of a failing run is
# visible too. The failure still propagates: finally does not swallow it.
try
@testset "MetaManifold" begin

    # Each file gets its own testset so that a throw at a file's top level -- outside
    # any of that file's own testsets -- is reported against the file that caused it
    # and does not abort the loop. Bare `include` here meant one such throw silently
    # skipped every remaining unit file (and the occupancy probe below) while the
    # summary still looked like a single stray error.
    for f in _selected_files()
        _timed(f) do
            @testset "$f" begin
                include(joinpath(@__DIR__, "unit", f))
            end
        end
    end

    ## Occupancy probe and the two-thread disagreement test (MMW-01), with the
    ## full suite. Its vsearch part skips, saying so, when vsearch is not on PATH.
    if isempty(filter(a -> !startswith(a, "--"), ARGS))
        _timed("occupancy_disagreement_test.jl") do
            include("occupancy_disagreement_test.jl")
        end
    end

    ## Integration tests (opt-in)
    if RUN_INTEGRATION
        using MetaManifold.DADA2, MetaManifold.OTUPipeline
        _timed("integration/test_pipeline.jl") do
            include("integration/test_pipeline.jl")
        end
    else
        @info "Skipping integration tests (pass --integration to enable)"
    end

    ## Server smoke tests (opt-in, starts a Julia subprocess - slow on first run)
    if RUN_SERVER
        using HTTP
        _timed("integration/test_server.jl") do
            include("integration/test_server.jl")
        end
    else
        @info "Skipping server smoke tests (pass --server to enable)"
    end

end
finally
    _timing_report()
end
