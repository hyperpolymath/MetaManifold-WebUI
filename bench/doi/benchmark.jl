# SPDX-License-Identifier: MPL-2.0
# Credential-free warmed publication microbenchmarks. No R or live Zenodo calls.
# Run with the pinned isolated environment; stdout is a machine-readable report:
# julia --project=test/doi bench/doi/benchmark.jl > /tmp/doi-performance.json
using JSON3, Test, HTTP, Dates, SHA, MD5
include(joinpath(@__DIR__, "..", "..", "test", "doi", "bootstrap.jl"))
const S = DOIIsolated.DOIStorage
const B = DOIIsolated.DOIBundles
const Z = DOIIsolated.Zenodo
const P = DOIIsolated.DOIPublications
include(joinpath(@__DIR__, "..", "..", "test", "doi", "fixtures.jl"))

function measure(operation; samples=31)
    for _ in 1:3; operation(); end # exclude first-compilation costs
    GC.gc()
    trials = [@timed(operation()) for _ in 1:samples]
    midpoint = cld(samples, 2)
    Dict("median_ns" => sort!([t.time * 1e9 for t in trials])[midpoint],
         "median_bytes" => sort!([t.bytes for t in trials])[midpoint])
end

report = Dict{String,Any}("schema_version" => 1, "julia_version" => string(VERSION),
    "cpu" => Sys.CPU_NAME, "os" => string(Sys.KERNEL), "arch" => string(Sys.ARCH),
    "threads" => Threads.nthreads(), "samples" => 31, "payload_bytes" => 8 * 1024 * 1024,
    "metrics" => Dict{String,Any}())
prepared_fixture() do tmp, root, source, fake, client, prepared
    path = joinpath(tmp, "bounded-download.bin")
    write(path, repeat("0123456789abcdef", div(report["payload_bytes"], 16)))
    metadata = B.validate_metadata(metadata_fixture())
    report["metrics"]["metadata_validation"] = measure(() -> B.validate_metadata(metadata_fixture()))
    report["metrics"]["snapshot_checksums"] = measure(() -> B.snapshot(source))
    report["metrics"]["archive_sha256_8MiB"] = measure(() -> S.file_sha256(path))
    report["metrics"]["download_8MiB"] = measure(() -> write(devnull, S.FileBody(path)))
    before = length(fake.calls)
    report["metrics"]["prepared_replay"] = measure(() -> P.prepare!(root, source, metadata, client))
    length(fake.calls) == before || error("A prepared replay must not perform network operations")
    publish_fixture(root, prepared, client)
    before = length(fake.calls)
    report["metrics"]["published_replay"] = measure(() -> publish_fixture(root, prepared, client))
    length(fake.calls) == before || error("A published replay must not perform network operations")
    # Resource-safety contract, independent of CPU speed or a historical baseline.
    report["metrics"]["download_8MiB"]["median_bytes"] <= 2 * 1024 * 1024 ||
        error("Download allocation exceeded its bounded-memory budget (2 MiB)")
end
println(S.canonical_json(report))
