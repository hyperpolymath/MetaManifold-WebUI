# Unit tests for the exact statistics layer (issue #1).
#
# The arithmetic is checked against `test/fixtures/statistics_known_answers.json`,
# which `scripts/statistics-reference.py` produces from a second implementation in
# another language (see that script's header). This file adds what a reference
# cannot: invariants and metamorphic relations that must hold for *any* input,
# adversarial cases, the immutability and provenance of stored records, precision
# isolation between concurrent analyses, and negative controls that check the
# validation actually rejects a wrong implementation.
#
# Nothing here reaches the network, R or DuckDB, so it runs in the ordinary unit
# suite.
using MetaManifold.ExactNumeric
using MetaManifold.ExactStatistics
using JSON3, Dates, Random

# The negative controls share one definition with scripts/statistics-negative-controls.jl,
# so the evidence quoted by the script is the evidence the suite enforces.
include(joinpath(@__DIR__, "..", "..", "scripts", "statistics-negative-controls.jl"))

const _FIXTURE_PATH = joinpath(@__DIR__, "..", "fixtures", "statistics_known_answers.json")

function _parse_fixture_rational(s)
    parts = split(String(s), "/")
    length(parts) == 2 || error("not a rational in the fixture: $s")
    return parse(BigInt, parts[1]) // parse(BigInt, parts[2])
end

_fixture_counts(entry) = BigInt[Int(c) for c in entry["counts"]]

function _fixture_entry(collection, counts::Vector{Int})
    for entry in collection
        [Int(c) for c in entry["counts"]] == counts && return entry
    end
    error("no fixture entry for counts $counts")
end

"""Every subset of `1:k` out of `1:n`, for an independent enumeration check."""
function _foreach_combination(n::Int, k::Int, cb::Function, start::Int = 1,
                              chosen::Vector{Int} = Int[])
    if length(chosen) == k
        cb(chosen)
        return
    end
    for i in start:(n - (k - length(chosen)) + 1)
        push!(chosen, i)
        _foreach_combination(n, k, cb, i + 1, chosen)
        pop!(chosen)
    end
end

"""
    _brute_expected_richness(counts, depth)

Enumerate every subsample of `depth` reads and average the observed richness.
This shares no algebra with the closed form: it is the definition, executed.
"""
function _brute_expected_richness(counts::Vector{Int}, depth::Int)
    reads = Int[]
    for (feature, c) in enumerate(counts)
        for _ in 1:c
            push!(reads, feature)
        end
    end
    n = length(reads)
    total = zero(BigInt)
    subsets = 0
    _foreach_combination(n, depth, chosen -> begin
        total += length(unique(reads[chosen]))
        subsets += 1
    end)
    return total // subsets
end

@testset "ExactStatistics" begin

    fixture = JSON3.read(read(_FIXTURE_PATH, String))
    full_policy = NumericPolicy(mode = "exact", max_digits = 100_000)

    @testset "catalogue is bounded and self-describing" begin
        cat = method_catalogue()
        @test Set(keys(cat)) == Set(["summarise.counts", "describe.alpha",
                                     "describe.proportions",
                                     "rarefaction.expected_richness",
                                     "compare.taxon_ratio"])
        for (name, entry) in cat
            @test entry["version"] == METHOD_VERSION
            @test !isempty(entry["title"])       || error("$name has no title")
            @test entry["numeric_modes"] == collect(NUMERIC_MODES)
            # Every method states what it does not claim. A method with nothing to
            # say here does not belong in a validated catalogue.
            @test !isempty(entry["uncertainty"])
            @test !isempty(entry["multiple_testing"])
            @test !isempty(entry["limitations"])
            @test entry["design_required"] === false
        end
        @test GLOBAL_LIMITATIONS isa Vector{String}
        @test any(l -> occursin("no hypothesis test", l), GLOBAL_LIMITATIONS)
        @test any(l -> occursin("Higher precision is not exactness", l), GLOBAL_LIMITATIONS)
    end

    @testset "known answers: Simpson index (independent reference)" begin
        for entry in fixture["simpson"]
            counts = _fixture_counts(entry)
            expected = _parse_fixture_rational(entry["value"])
            @test simpson_index(counts) == expected
            # Metamorphic: a permutation and a uniform rescaling cannot change it.
            @test simpson_index(reverse(counts)) == expected
            @test simpson_index(3 .* counts) == expected
            # The independent reference's own permutation/rescaling results.
            @test _parse_fixture_rational(entry["permuted_value"]) == expected
            @test _parse_fixture_rational(entry["scaled_by_three"]) == expected
            @test display_string(simpson_index(counts); digits = 6) == String(entry["display_6"])
        end
        @test_throws ZeroDenominator simpson_index(BigInt[0, 0, 0])
    end

    @testset "known answers: expected richness (closed form, enumeration, fixture)" begin
        for entry in fixture["expected_richness"]
            counts = _fixture_counts(entry)
            depth = Int(entry["depth"])
            expected = _parse_fixture_rational(entry["value"])
            @test expected_richness(counts, depth; policy = full_policy) == expected
            @test expected_richness(reverse(counts), depth; policy = full_policy) == expected
            @test display_string(expected_richness(counts, depth; policy = full_policy);
                                 digits = 6) == String(entry["display_6"])
            if entry["brute_force"] !== nothing
                enumerated = _parse_fixture_rational(entry["brute_force"])
                @test enumerated == expected
                ints = [Int(c) for c in counts]
                @test _brute_expected_richness(ints, depth) == expected
            end
        end

        # The same enumeration, on cases the fixture does not pin: the definition
        # and the closed form must agree, so neither can be wrong in isolation.
        for (counts, depth) in (([1, 2, 3], 2), ([2, 2, 2], 3), ([3, 1, 0], 2), ([1, 1], 1))
            @test expected_richness(BigInt.(counts), depth; policy = full_policy) ==
                  _brute_expected_richness(counts, depth)
        end
    end

    @testset "known answers: Shannon index at higher precision" begin
        for entry in fixture["shannon"]
            counts = _fixture_counts(entry)
            policy = NumericPolicy(mode = "bigfloat", precision_bits = 256)
            value = shannon_index(counts, policy)
            @test precision(value) == 256
            reference = with_precision(400) do
                parse(BigFloat, String(entry["value_decimal"]))
            end
            @test abs(value - reference) < big"1e-55"
            # A decimal reference was computed at 80 digits; 55 leaves a margin for
            # its own rounding, and a mismatch of any more would be a real defect.
            @test Float64(value) ≈ Float64(entry["double"]) atol = 1e-12
        end
        @test_throws ZeroDenominator shannon_index(BigInt[0, 0], NumericPolicy())
        @test_throws UnsupportedNumericMode shannon_index(BigInt[1, 2],
                                                          NumericPolicy(mode = "exact"))
    end

    @testset "known answers: exact proportions" begin
        for entry in fixture["proportions"]
            counts = [Int(c) for c in entry["counts"]]
            total = sum(counts)
            got = [proportion_value(c, total) for c in counts]
            @test got == [_parse_fixture_rational(v) for v in entry["values"]]
            @test sum(got) == 1 // 1
        end
        @test_throws ZeroDenominator proportion_value(0, 0)
    end

    @testset "invariants and metamorphic relations (generative)" begin
        rng = MersenneTwister(20261022)
        for _ in 1:15
            counts = [rand(rng, 0:12) for _ in 1:rand(rng, 2:6)]
            total = sum(counts)
            total == 0 && continue
            rich = count(!iszero, counts)
            counts_big = BigInt.(counts)

            # E[S_total] is the observed richness; E[S_1] is 1 for any non-empty
            # library; the expectation is monotone in depth and bounded by it.
            @test expected_richness(counts_big, 1; policy = full_policy) == 1
            @test expected_richness(counts_big, total; policy = full_policy) == rich
            previous = zero(Rational{BigInt})
            for m in 1:total
                e = expected_richness(counts_big, m; policy = full_policy)
                @test 1 <= e <= rich
                @test e >= previous
                previous = e
            end

            # The higher-precision path must agree with the exact one to the
            # precision it claims; disagreement would mean one of them is wrong.
            approx = expected_richness(counts_big, max(1, total ÷ 2);
                                       policy = NumericPolicy(mode = "bigfloat",
                                                              precision_bits = 256))
            exact = expected_richness(counts_big, max(1, total ÷ 2); policy = full_policy)
            @test abs(approx - BigFloat(exact)) < big"1e-40"

            # Simpson is a proportion-like quantity in [0, 1) for a real table.
            s = simpson_index(counts_big)
            @test 0 <= s < 1
            @test simpson_index(2 .* counts_big) == s
        end
    end

    @testset "adversarial inputs are refused explicitly" begin
        # Huge counts are exact, and a count above 2^53 arriving as a float is not
        # silently trusted.
        huge = BigInt[big(10)^40]
        @test simpson_index(huge) == 0 // 1
        @test_throws InvalidNumericInput exact_count(Float64(2)^53)
        @test_throws InvalidNumericInput exact_count(1.5)
        # A value whose exact representation breaches the digit bound is a named
        # resource_limit failure, not a rounded answer.
        @test_throws NumericLimit expected_richness(BigInt[1, big(10)^20], 2;
                                                   policy = NumericPolicy(mode = "exact",
                                                                          max_digits = 16))

        # An all-zero table has no index at all, at any precision.
        zero_table = zeros(Int, 2, 3)
        rec = analyse(zero_table, ["A", "B"], ["f1", "f2", "f3"];
                      method = "describe.alpha", policy = NumericPolicy(mode = "bigfloat"))
        @test rec["status"] == "partial"
        @test any(f -> f["code"] == "zero_denominator", rec["failures"])
        @test any(w -> w["code"] == "zero_reads", rec["warnings"])

        # Tiny probabilities: one read against a billion still has a defined,
        # positive Shannon index, and it must not underflow to zero.
        tiny = BigInt[1, 10]^9
        h = shannon_index(tiny, NumericPolicy(mode = "bigfloat", precision_bits = 256))
        @test h > 0
        @test abs(h - with_precision(300) do
            p = BigFloat(1) / BigFloat(sum(tiny))
            q = BigFloat(10)^9 / BigFloat(sum(tiny))
            -(p * log(p) + q * log(q))
        end) < big"1e-50"

        # A rarefaction depth above the library is refused, not clamped.
        rec = analyse([3 0; 0 4], ["A", "B"], ["f1", "f2"];
                      method = "rarefaction.expected_richness",
                      policy = NumericPolicy(mode = "exact"),
                      options = Dict{String,Any}("depth" => 10))
        @test rec["status"] == "partial"
        @test any(f -> f["code"] == "depth_exceeds_library", rec["failures"])
    end

    @testset "simulation study: the exact expectation is the sampling mean" begin
        # A pre-set tolerance: four standard errors of the simulated mean, so a
        # correct implementation fails about once in 30,000 such studies while a
        # bias of one part in a hundred is caught easily. Deterministic seed, so
        # the check cannot flake between runs.
        counts = [4, 6, 2, 8]
        depth = 5
        exact = expected_richness(BigInt.(counts), depth; policy = full_policy)
        reads = Int[]
        for (feature, c) in enumerate(counts)
            for _ in 1:c
                push!(reads, feature)
            end
        end
        rng = MersenneTwister(987654)
        n = 4_000
        values = Vector{Int}(undef, n)
        for i in 1:n
            subset = randperm(rng, length(reads))[1:depth]
            values[i] = length(unique(reads[subset]))
        end
        μ = sum(values) / n
        σ = sqrt(sum((v - μ)^2 for v in values) / (n - 1))
        se = σ / sqrt(n)
        @test abs(μ - Float64(exact)) <= 4 * se + 1e-12
    end

    @testset "analyse: counts summary" begin
        samples  = ["S1", "S2", "S3"]
        features = ["ASV1", "ASV2", "ASV3"]
        mat = [10 20 0;
               0  0  0;
               5  5 10]
        rec = analyse(mat, samples, features; method = "summarise.counts",
                      policy = NumericPolicy(mode = "exact"),
                      source = Dict{String,Any}("run" => "r1"))
        @test rec["status"] == "complete"
        @test isempty(rec["failures"])
        @test rec["results"]["corpus"]["total_reads"]["value"] == "50"
        @test rec["results"]["samples"][1]["total_reads"]["value"] == "30"
        @test rec["results"]["samples"][1]["richness"]["value"] == "2"
        @test rec["results"]["samples"][1]["mean_per_feature"]["value"] == "10/1"
        @test rec["results"]["samples"][2]["total_reads"]["value"] == "0"
        @test rec["results"]["features"][3]["total_reads"]["value"] == "10"
        @test rec["results"]["features"][3]["prevalence"]["value"] == "2"
        @test rec["diagnostics"]["counts"]["zero_total_samples"] == 1
        @test rec["diagnostics"]["numeric_mode"] == "exact"
        @test rec["provenance"]["input"]["source"]["run"] == "r1"
        @test rec["provenance"]["method"]["name"] == "summarise.counts"
        @test rec["provenance"]["numeric_policy"]["mode"] == "exact"
        @test rec["provenance"]["seed"] == 0
        @test rec["provenance"]["software"]["mpfr"] isa String
        @test length(rec["limitations"]) >= length(GLOBAL_LIMITATIONS)
    end

    @testset "analyse: alpha, exact and approximate modes" begin
        mat = reshape([90, 10], 1, 2)
        samples = ["A"]; features = ["f1", "f2"]

        exact = analyse(mat, samples, features; method = "describe.alpha",
                        policy = NumericPolicy(mode = "exact"))
        sample = exact["results"]["samples"][1]
        @test sample["richness"]["kind"] == "exact"
        @test sample["simpson"]["kind"] == "exact"
        @test sample["simpson"]["value"] == "9/50"
        # The exact mode refuses what has no exact value, and says why, instead of
        # quietly returning a float.
        @test sample["shannon"]["status"] == "unsuccessful"
        @test sample["shannon"]["code"] == "unsupported_numeric_mode"
        @test sample["evenness"]["code"] == "unsupported_numeric_mode"
        @test sample["status"] == "partial"
        @test exact["status"] == "partial"
        @test any(f -> f["code"] == "unsupported_numeric_mode", exact["failures"])

        big = analyse(mat, samples, features; method = "describe.alpha",
                      policy = NumericPolicy(mode = "bigfloat", precision_bits = 256))
        h = big["results"]["samples"][1]["shannon"]
        @test h["kind"] == "approximation"
        @test h["type"] == "mpfr"
        @test h["precision_bits"] == 256
        entry = _fixture_entry(fixture["shannon"], [90, 10])
        reference = with_precision(400) do
            parse(BigFloat, String(entry["value_decimal"]))
        end
        @test abs(parse(BigFloat, h["value"]) - reference) < big"1e-55"

        f64 = analyse(mat, samples, features; method = "describe.alpha",
                      policy = NumericPolicy(mode = "float64"))
        h64 = f64["results"]["samples"][1]["shannon"]
        @test h64["type"] == "binary64"
        @test h64["precision_bits"] == 53
        @test parse(Float64, h64["value"]) ≈ Float64(entry["double"]) atol = 1e-12

        # Evenness is undefined for a single observed feature, and says so.
        lonely = analyse([5 0], ["A"], ["f1", "f2"]; method = "describe.alpha",
                         policy = NumericPolicy(mode = "float64"))
        @test lonely["results"]["samples"][1]["evenness"]["code"] == "invalid_input"
    end

    @testset "analyse: proportions" begin
        mat = [1 2; 0 0; 90 10]
        samples = ["S1", "S2", "S3"]
        features = ["f1", "f2"]
        rec = analyse(mat, samples, features; method = "describe.proportions",
                      policy = NumericPolicy(mode = "exact"))
        @test rec["results"]["samples"][1]["proportions"][1]["value"] == "1/3"
        @test rec["results"]["samples"][1]["proportions"][2]["value"] == "2/3"
        # The zero-read sample has no proportions at all, and is not filled with
        # zeros to make the table rectangular.
        @test rec["results"]["samples"][2]["status"] == "partial"
        @test rec["results"]["samples"][2]["proportions"][1]["code"] == "zero_denominator"
        @test rec["results"]["samples"][2]["total_reads"]["value"] == "0"
        @test rec["results"]["corpus"]["proportions"][1]["value"] == "91/103"
        @test rec["status"] == "partial"
    end

    @testset "analyse: rarefaction and taxon ratio" begin
        mat = [2 3; 0 4]
        samples = ["S1", "S2"]
        features = ["f1", "f2"]
        rec = analyse(mat, samples, features; method = "rarefaction.expected_richness",
                      policy = NumericPolicy(mode = "exact"),
                      options = Dict{String,Any}("depth" => 2))
        @test rec["results"]["samples"][1]["expected_richness"]["value"] == "8/5"
        @test rec["results"]["samples"][2]["expected_richness"]["value"] == "1/1"
        @test rec["results"]["depth"] == 2

        # A work bound is an explicit refusal, not a slow request.
        too_deep = analyse(ones(Int, 3, 4000), ["a", "b", "c"], string.("f", 1:4000);
                           method = "rarefaction.expected_richness",
                           policy = NumericPolicy(mode = "exact"),
                           options = Dict{String,Any}("depth" => 5000))
        @test too_deep["status"] == "unsuccessful"
        @test too_deep["failures"][1]["code"] == "resource_limit"
        @test isempty(too_deep["results"])

        rmat = [2 3; 4 0]
        ratio = analyse(rmat, samples, features; method = "compare.taxon_ratio",
                        policy = NumericPolicy(mode = "exact"),
                        options = Dict{String,Any}("numerator" => "f1",
                                                   "denominator" => "f2"))
        @test ratio["results"]["corpus"]["ratio"]["value"] == "2/1"
        @test ratio["results"]["samples"][2]["ratio"]["code"] == "zero_denominator"
        @test ratio["results"]["samples"][1]["ratio"]["value"] == "2/3"

        @test_throws ArgumentError analyse(mat, samples, features;
                                           method = "compare.taxon_ratio",
                                           options = Dict{String,Any}("numerator" => "f1"))
        @test_throws ArgumentError analyse(mat, samples, features;
                                           method = "compare.taxon_ratio",
                                           options = Dict{String,Any}("numerator" => "nope",
                                                                      "denominator" => "f2"))
        @test_throws ArgumentError analyse(mat, samples, features;
                                           method = "compare.taxon_ratio",
                                           options = Dict{String,Any}("numerator" => "f1",
                                                                      "denominator" => "f1"))
    end

    @testset "analyse: request errors are errors, data problems are records" begin
        mat = [1 2; 3 4]
        samples = ["A", "B"]; features = ["f1", "f2"]

        @test_throws ArgumentError analyse(mat, samples, features; method = "describe.magic")
        @test_throws ArgumentError analyse(mat, ["A"], features; method = "summarise.counts")
        @test_throws ArgumentError analyse(mat, samples, features;
                                           method = "summarise.counts",
                                           options = Dict{String,Any}("depth" => 3))
        @test_throws ArgumentError analyse(mat, samples, features;
                                           method = "rarefaction.expected_richness",
                                           options = Dict{String,Any}("depth" => 0))
        @test_throws ArgumentError analyse(mat, samples, features;
                                           method = "rarefaction.expected_richness",
                                           options = Dict{String,Any}("depth" => 2.5))
        @test_throws ArgumentError analyse(mat, samples, features;
                                           method = "summarise.counts",
                                           options = Dict{String,Any}("depth" => :two))
        @test_throws ArgumentError analyse(mat, samples, features;
                                           method = "summarise.counts", seed = true)
        @test_throws ArgumentError analyse(mat, samples, features;
                                           method = "summarise.counts", seed = 2^60)

        fractional = [1.0 2.0; 3.0 1.5]
        rec = analyse(fractional, samples, features; method = "summarise.counts")
        @test rec["status"] == "unsuccessful"
        @test isempty(rec["results"])
        @test rec["failures"][1]["code"] == "invalid_input"
        @test occursin("count[2,2]", rec["failures"][1]["message"])
        @test rec["diagnostics"]["conversion_failed"] === true

        too_big = [Float64(2)^53 1.0; 2.0 3.0]
        rec = analyse(too_big, samples, features; method = "summarise.counts")
        @test rec["status"] == "unsuccessful"
        @test rec["failures"][1]["code"] == "invalid_input"
        @test occursin("2^53", rec["failures"][1]["message"])

        # Duplicate names are warned about, not silently de-duplicated, because the
        # position of a duplicated name is the only way to tell the entries apart.
        rec = analyse([1 2; 3 4], ["A", "A"], ["f1", "f1"];
                      method = "summarise.counts")
        @test any(w -> w["code"] == "duplicate_sample_names", rec["warnings"])
        @test any(w -> w["code"] == "duplicate_feature_names", rec["warnings"])
    end

    @testset "input fingerprint" begin
        a = input_fingerprint(BigInt[1 2; 3 4], ["A", "B"], ["f1", "f2"])
        @test length(a) == 64
        @test occursin(r"^[0-9a-f]{64}$", a)
        @test a == input_fingerprint(BigInt[1 2; 3 4], ["A", "B"], ["f1", "f2"])
        @test a != input_fingerprint(BigInt[1 2; 3 5], ["A", "B"], ["f1", "f2"])
        @test a != input_fingerprint(BigInt[1 2; 3 4], ["B", "A"], ["f1", "f2"])
        @test a != input_fingerprint(BigInt[1 2; 3 4], ["A", "B"], ["f2", "f1"])
        # Counts above 2^53 are fingerprinted exactly, not through a float.
        big = input_fingerprint(reshape(BigInt[10]^30, 1, 1), ["A"], ["f1"])
        @test big isa String
        @test_throws ArgumentError input_fingerprint(BigInt[1 2; 3 4], ["A"], ["f1", "f2"])
    end

    @testset "records are immutable, content-addressed and reproducible" begin
        mat = [1 2; 3 4]
        samples = ["A", "B"]; features = ["f1", "f2"]
        rec = analyse(mat, samples, features; method = "summarise.counts",
                      policy = NumericPolicy(mode = "exact"))
        tmp = mktempdir()
        stamp = DateTime(2026, 10, 22, 12, 0, 0)

        first_write = write_record(tmp, rec; created_at = stamp)
        @test first_write.created
        @test isfile(first_write.path)
        @test endswith(first_write.path, first_write.id * ".json")
        @test dirname(first_write.path) == record_directory(tmp)
        @test analysis_id(rec) == first_write.id

        # Idempotent: the same analysis at a later time is the same record, and the
        # stored file keeps its original timestamp.
        second_write = write_record(tmp, rec; created_at = DateTime(2026, 10, 23, 1, 2, 3))
        @test !second_write.created
        @test second_write.path == first_write.path
        @test second_write.bytes == first_write.bytes
        @test analysis_id(rec) == first_write.id

        # `created_at` is outside the content address; a changed setting is not.
        with_stamp = copy(rec)
        with_stamp["created_at"] = "1999-01-01T00:00:00Z"
        @test analysis_id(with_stamp) == first_write.id
        other = analyse(mat, samples, features; method = "summarise.counts",
                        policy = NumericPolicy(mode = "bigfloat"))
        @test analysis_id(other) != first_write.id
        other_write = write_record(tmp, other; created_at = stamp)
        @test other_write.created
        @test other_write.path != first_write.path
        @test length(list_records(tmp)) == 2

        # Byte-identical on another machine, at the same timestamp.
        tmp2 = mktempdir()
        elsewhere = write_record(tmp2, rec; created_at = stamp)
        @test elsewhere.id == first_write.id
        @test elsewhere.bytes == first_write.bytes

        # Reading back is the stored document, not a re-computation.
        got = read_record(tmp, first_write.id)
        @test got["analysis_id"] == first_write.id
        @test got["status"] == rec["status"]
        @test got["method"]["name"] == "summarise.counts"
        @test got["provenance"]["input"]["fingerprint"] == rec["provenance"]["input"]["fingerprint"]
        @test got["created_at"] == "2026-10-22T12:00:00Z"
        @test read_record(tmp, repeat("a", 64)) === nothing
        @test_throws ArgumentError read_record(tmp, "../etc/passwd")
        @test_throws ArgumentError read_record(tmp, "not-an-id")

        # A record is write-once: tampering is a conflict, never an overwrite.
        write(first_write.path, "{\"tampered\":true}")
        @test_throws RecordConflict write_record(tmp, rec)

        # A damaged record is listed as unreadable rather than hidden: a missing
        # record and a broken one are different facts.
        write(joinpath(record_directory(tmp), repeat("b", 64) * ".json"), "not json")
        listed = list_records(tmp)
        @test length(listed) == 3
        @test count(x -> get(x, "unreadable", false), listed) == 1
        @test any(x -> x["analysis_id"] == first_write.id && !x["unreadable"], listed)
    end

    @testset "precision is isolated between concurrent analyses" begin
        before = precision(BigFloat)
        mat = reshape([90, 10], 1, 2)
        samples = ["A"]; features = ["f1", "f2"]
        low  = analyse(mat, samples, features; method = "describe.alpha",
                       policy = NumericPolicy(mode = "bigfloat", precision_bits = 128))
        high = analyse(mat, samples, features; method = "describe.alpha",
                       policy = NumericPolicy(mode = "bigfloat", precision_bits = 1024))
        @test low["results"]["samples"][1]["shannon"]["precision_bits"] == 128
        @test high["results"]["samples"][1]["shannon"]["precision_bits"] == 1024
        @test low["results"]["samples"][1]["shannon"]["value"] !=
              high["results"]["samples"][1]["shannon"]["value"]

        tasks = [Threads.@spawn analyse(mat, samples, features;
                                        method = "describe.alpha",
                                        policy = NumericPolicy(mode = "bigfloat",
                                                               precision_bits = (i % 2 == 0 ? 128 : 1024)))
                 for i in 1:16]
        for (i, task) in enumerate(tasks)
            record = fetch(task)
            wanted = i % 2 == 0 ? low : high
            @test record["results"]["samples"][1]["shannon"]["value"] ==
                  wanted["results"]["samples"][1]["shannon"]["value"]
            @test record["results"]["samples"][1]["shannon"]["precision_bits"] ==
                  wanted["results"]["samples"][1]["shannon"]["precision_bits"]
            @test analysis_id(record) == analysis_id(wanted)
        end
        @test precision(BigFloat) == before
    end

    @testset "the optional layer does not disturb the existing analysis path" begin
        # The layer is opt-in: calling it must leave the modules it does not own
        # exactly as they were, and must not move the global precision.
        before = precision(BigFloat)
        baseline = (MetaManifold.DiversityMetrics.richness([1, 0, 2, 2]),
                    MetaManifold.DiversityMetrics.shannon([50, 50]),
                    MetaManifold.DiversityMetrics.simpson([50, 50]))
        analyse([90 10; 5 5], ["A", "B"], ["f1", "f2"]; method = "describe.alpha",
                policy = NumericPolicy(mode = "bigfloat", precision_bits = 512))
        after = (MetaManifold.DiversityMetrics.richness([1, 0, 2, 2]),
                 MetaManifold.DiversityMetrics.shannon([50, 50]),
                 MetaManifold.DiversityMetrics.simpson([50, 50]))
        @test after == baseline
        @test precision(BigFloat) == before
    end

    @testset "negative controls: wrong implementations are caught" begin
        # Each check is the validation that guards the real implementation. It must
        # accept the real one and reject a deliberately wrong one; if a mutant
        # passes, the check is not testing what it claims to.
        @test !isempty(NEGATIVE_CONTROL_CHECKS)
        for control in NEGATIVE_CONTROL_CHECKS
            @test control.validate(control.real)
            @test !control.validate(control.mutant)
        end
        @test run_negative_controls(devnull)
    end

end
