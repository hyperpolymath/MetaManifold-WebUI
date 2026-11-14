# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# SPDX-License-Identifier: MPL-2.0

# The native aldex2 method compared with the R package ALDEx2's own output on the
# same counts, stored as fixtures (test/fixtures/native_da/). The fixtures are
# produced by test/fixtures/native_da/generate_reference.jl, which needs R and
# the Bioconductor ALDEx2 package; this test needs neither.
#
# Two count tables are compared: counts.tsv (no zeros) and counts_zeros.tsv
# (zeros on purpose, including a taxon that is all zero in one group, so that
# ALDEx2's Dirichlet prior and its handling of zeros are exercised). Each has a
# reference table and a metadata file recording the R, Bioconductor and ALDEx2
# versions, the settings, the seeds, the counts file's SHA-256 and R's own spread.
# A missing or half-present fixture set is a failure, never a skip: this test
# fails if any of the six files is absent.
#
# Tolerance, in plain words. Both implementations are Monte Carlo and use
# different random number generators, so they cannot agree exactly. The yardstick
# is R's own spread: the generator runs ALDEx2 under a primary seed and under 19
# other seeds (2 to 20) and records, per column, the largest difference between
# any of those runs and the primary run. The native result must lie within
# SLACK times that spread of the primary R result, plus an absolute FLOOR in the
# column's units.
#
# What that rule is and is not. With k spread seeds, the chance, for one column,
# that an identical method (one whose output is just another draw from R's own
# distribution) exceeds 1 times the maximum spread is 1/(k+1): 5% at k = 19.
# Slack 2 plus the floor is a margin on top of that. It is a heuristic cushion,
# not a calibrated test: it has no stated false-failure or detection rate, and it
# can miss a native difference that is smaller than the margin. It follows the
# rule in the CompositionalDA package's own oracle
# (test/oracle/runoracle.jl).

using MetaManifold, Test
using CSV, DataFrames, JSON3, SHA
using MetaManifold.Differential

const NATIVE_REF_DIR = joinpath(@__DIR__, "..", "fixtures", "native_da")
# (label, counts file, reference table, metadata) per table.
const NATIVE_REF_SETS = (
    ("no zeros", "counts.tsv", "reference_aldex2.tsv", "reference_meta.json"),
    ("with zeros", "counts_zeros.tsv", "reference_aldex2_zeros.tsv", "reference_meta_zeros.json"))

# SLACK multiplies R's own seed-to-seed spread; FLOOR is added in each column's
# own units, so that a spread of nearly zero does not demand exact agreement.
const NATIVE_REF_SLACK = 2.0
const NATIVE_REF_FLOOR = (effect = 0.05, pvalue = 0.01, qvalue = 0.01,
    wi_pvalue = 0.01, wi_qvalue = 0.01, diff_btw = 0.05, diff_win = 0.05, rab_all = 0.05)

function native_reference_comparison(label, counts_file, reference_file, meta_file)
    counts_path = joinpath(NATIVE_REF_DIR, counts_file)
    meta = JSON3.read(read(joinpath(NATIVE_REF_DIR, meta_file), String))
    reference = CSV.read(joinpath(NATIVE_REF_DIR, reference_file), DataFrame; delim = '\t')
    table = CSV.read(counts_path, DataFrame; delim = '\t')

    # The fixtures must be for this counts table, and say what made them.
    @test meta.counts_sha256 == bytes2hex(open(sha256, counts_path))
    @test !isempty(meta.versions.r) && !isempty(meta.versions.aldex2) &&
          !isempty(meta.versions.bioconductor)
    @test meta.contrast == "treated vs control"
    @test collect(meta.spread_seeds) == collect(2:20)

    taxa = names(table)[3:end]
    counts = Matrix{Int}(table[:, 3:end])
    samples = String.(table.sample)
    groups = String.(table.group)
    @test reference.taxon == taxa

    config = DifferentialConfig(; method = "aldex2", mc_samples = meta.mc_samples, seed = 1)
    native = differential_abundance(counts, samples, taxa, groups;
        reference = "control", contrast = "treated", config)
    rows = Dict(r["taxon"] => r for r in native["rows"])
    ours = (effect = r -> r["aldex_effect"], pvalue = r -> r["pvalue"], qvalue = r -> r["padj"],
            wi_pvalue = r -> r["wilcoxon_pvalue"], wi_qvalue = r -> r["wilcoxon_padj"],
            diff_btw = r -> r["estimate"], diff_win = r -> r["aldex_diff_within"],
            rab_all = r -> r["aldex_abundance"])

    for column in keys(NATIVE_REF_FLOOR)
        name = String(column)
        gap = maximum(abs(ours[column](rows[t]) - reference[i, name])
                      for (i, t) in enumerate(taxa))
        spread = Float64(meta.max_seed_to_seed_difference[name])
        bound = NATIVE_REF_SLACK * spread + NATIVE_REF_FLOOR[column]
        @info "native vs R ALDEx2 ($label)" column gap spread bound
        @test gap <= bound
    end

    # The 0.05 call on each taxon must agree, unless both values are within the
    # floor of each other (a value sitting on the boundary can fall either way).
    for (i, t) in enumerate(taxa)
        @test (rows[t]["padj"] < 0.05) == (reference.qvalue[i] < 0.05) ||
              abs(rows[t]["padj"] - reference.qvalue[i]) <= NATIVE_REF_FLOOR.qvalue
    end
end

# A missing fixture is a failure: it must never read as a pass, a skip or a
# broken test that a deleted file could hide behind.
const _ref_files = [joinpath(NATIVE_REF_DIR, f) for (_, c, r, m) in NATIVE_REF_SETS for f in (c, r, m)]
const _ref_missing = filter(!isfile, _ref_files)
isempty(_ref_missing) || @error "native aldex2 reference fixtures are missing; regenerate with " *
    "`julia --project=. test/fixtures/native_da/generate_reference.jl` in a session with R " *
    "and Bioconductor ALDEx2, then commit the output" missing = _ref_missing

@testset "Native aldex2 against R ALDEx2" begin
    @testset "fixtures are present" begin
        @test isempty(_ref_missing)
    end
    if isempty(_ref_missing)
        for (label, counts_file, reference_file, meta_file) in NATIVE_REF_SETS
            @testset "$label ($counts_file)" begin
                native_reference_comparison(label, counts_file, reference_file, meta_file)
            end
        end
    end
end
