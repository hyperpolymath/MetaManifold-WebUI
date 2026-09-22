# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# `using MetaManifold.NumericPolicy` here, not only at the harness: CI also runs this
# goal outside the full suite, where nothing else has imported the module.
using MetaManifold.NumericPolicy
using Test, Random, SHA, JSON3

const NP = MetaManifold.NumericPolicy

@testset "NumericPolicy" begin

    @testset "policy: validated at construction, fingerprinted for provenance" begin
        spec = NP.numeric_policy(; mode = :exact_counts)
        @test spec.mode === :exact_counts
        @test spec.precision_bits == NP.ORDINARY_PRECISION_BITS
        @test NP.validate_policy(spec) === spec

        @test_throws ArgumentError NP.numeric_policy(; mode = :symbolic)
        @test_throws ArgumentError NP.numeric_policy(; precision_bits = 1)
        @test_throws ArgumentError NP.numeric_policy(; max_denominator_bits = 8)
        @test_throws ArgumentError NP.numeric_policy(; round_digits = -1)

        # The fingerprint is what makes two runs comparable: same policy, same hash;
        # a changed field, a changed hash.
        @test NP.policy_fingerprint(spec) == NP.policy_fingerprint(NP.numeric_policy(; mode = :exact_counts))
        @test NP.policy_fingerprint(spec) != NP.policy_fingerprint(NP.numeric_policy(; mode = :high_precision))
        @test NP.policy_fingerprint(spec) != NP.policy_fingerprint(
            NP.numeric_policy(; mode = :exact_counts, precision_bits = 128))
        @test length(NP.policy_fingerprint(spec)) == 64
    end

    @testset "a requested mode is never silently downgraded" begin
        ordinary = NP.numeric_policy(; mode = :ordinary)
        exact = NP.numeric_policy(; mode = :exact_counts)
        @test NP.assert_mode(exact, :exact_counts) === exact
        err = try
            NP.assert_mode(ordinary, :exact_counts)
            nothing
        catch e
            e
        end
        @test err isa NP.UnsupportedRepresentationError
        # The message must name both sides: what was asked for and what was in force.
        @test occursin("exact_counts", sprint(showerror, err))
        @test occursin("ordinary", sprint(showerror, err))
    end

    @testset "counts: what a count may be" begin
        @test NP.require_count(7) === 7
        @test NP.require_count(Int32(7)) === Int32(7)
        @test NP.require_count(big(7)) == 7
        @test NP.require_count(2^53 - 1) == 2^53 - 1

        # A float that happens to hold a whole number is accepted where it is exactly
        # that number, and refused once Float64 can no longer say which integer it is.
        @test NP.require_count(7.0) === 7
        @test NP.require_count(big(2)^53) == big(2)^53
        @test_throws NP.UnsupportedRepresentationError NP.require_count(big(2)^53 + 2.0)

        # The negative control: the value below IS 9007199254740993 as computed, and
        # the refusal above is not a formality -- merely rounding the same number to
        # Float64 loses a count outright.
        @test BigInt(big(2)^53 + 3) != BigInt(Float64(big(2)^53 + 3))

        @test_throws NP.UnsupportedRepresentationError NP.require_count(2.5)
        @test_throws NP.UnsupportedRepresentationError NP.require_count(NaN)
        @test_throws NP.UnsupportedRepresentationError NP.require_count(Inf)
        @test_throws NP.UnsupportedRepresentationError NP.require_count(3 // 2)
        @test_throws NP.UnsupportedRepresentationError NP.require_count("12")
        @test NP.require_count(6 // 1) == 6
    end

    @testset "counts: overflow is named, not wrapped" begin
        huge = typemax(Int64)
        @test NP.checked_count_sum([1, 2, 3]) == 6
        @test NP.checked_count_sum(Int[]) == 0
        @test NP.checked_count_sum([Int32(2), Int64(3)]) == 5

        err = try
            NP.checked_count_sum([huge, 1])
            nothing
        catch e
            e
        end
        @test err isa NP.CountOverflowError
        @test occursin(string(huge), sprint(showerror, err))

        # Widening is the honest answer for a total a fixed-width integer cannot hold,
        # and it says so in its type.
        widened = NP.checked_count_sum([huge, 1]; on_overflow = :widen)
        @test widened isa BigInt
        @test widened == big(huge) + 1

        @test_throws ArgumentError NP.checked_count_sum([1]; on_overflow = :shrug)
    end

    @testset "proportions: a zero denominator has no proportion to report" begin
        policy = NP.numeric_policy(; mode = :exact_counts)
        @test NP.exact_relative_abundance(1, 4; policy) == 1 // 4
        @test NP.exact_relative_abundance(0, 4; policy) == 0 // 1
        @test NP.exact_relative_abundance(4, 4; policy) == 1 // 1

        # The all-zero sample. Julia's own `//` would answer `1//0` and `0//0` is an
        # exception only by accident: neither is a proportion, and this returns
        # neither a number nor a throw -- it returns `nothing`, an unsuccessful state
        # the presentation layer has to handle.
        @test NP.exact_relative_abundance(0, 0; policy) === nothing
        @test 1 // 0 isa Rational{Int}          # the behaviour being refused
        @test_throws NP.UnsupportedRepresentationError NP.exact_fraction(1, 0; policy)

        # Impossible inputs are programming errors, not data states, and throw.
        @test_throws ArgumentError NP.exact_relative_abundance(5, 4; policy)
        @test_throws ArgumentError NP.exact_relative_abundance(-1, 4; policy)
        @test_throws ArgumentError NP.exact_relative_abundance(1, -4; policy)
    end

    @testset "exact arithmetic keeps its exactness" begin
        policy = NP.numeric_policy(; mode = :exact_counts)
        thirds = [NP.exact_relative_abundance(1, 3; policy),
                  NP.exact_relative_abundance(1, 3; policy),
                  NP.exact_relative_abundance(1, 3; policy)]
        @test NP.exact_rational_sum(thirds; policy) == 1 // 1

        # Metamorphic: proportions of a table sum to exactly one, a property Float64
        # only approximates. This is the invariant the exact path exists to hold.
        rng = Random.Xoshiro(20260922)
        for _ in 1:50
            counts = rand(rng, 1:10_000, 25)
            total = NP.checked_count_sum(counts)
            parts = [NP.exact_relative_abundance(c, total; policy) for c in counts]
            @test NP.exact_rational_sum(parts; policy) == 1 // 1
        end

        # An empty sum is not zero: nothing was added, so the sum has no value.
        @test NP.exact_rational_sum(Rational{BigInt}[]; policy) === nothing
    end

    @testset "exact arithmetic has a budget, and exhausting it is loud" begin
        tiny = NP.numeric_policy(; mode = :exact_counts, max_denominator_bits = 32)
        ok = [NP.exact_fraction(1, 2; policy = tiny), NP.exact_fraction(1, 3; policy = tiny)]
        @test NP.exact_rational_sum(ok; policy = tiny) == 5 // 6

        # Eleven primes: their lcm is 2.0e11, which is 38 bits of denominator, so the
        # budget is exhausted partway through rather than at the first term.
        primed = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31]
        primes = [NP.exact_fraction(1, p; policy = tiny) for p in primed]
        err = try
            NP.exact_rational_sum(primes; policy = tiny)
            nothing
        catch e
            e
        end
        @test err isa NP.ResourceLimitError
        @test occursin("denominator", sprint(showerror, err))
        @test err.limit == 32
        @test err.observed > err.limit

        # The same sum is fine under the default budget, so the limit is a budget and
        # not a bug.
        @test NP.exact_rational_sum(primes; policy = NP.numeric_policy()) ==
              sum(1 // p for p in primed)
    end

    @testset "precision: scoped, explicit, and reported back" begin
        @test precision(BigFloat) == 256        # Julia's default, before anything here

        result, achieved = NP.with_precision(() -> BigFloat(1) / 3; bits = 512)
        @test achieved == 512
        @test precision(result) == 512
        @test precision(BigFloat) == 256        # restored, not left behind

        @test_throws ArgumentError NP.with_precision(() -> 1; bits = 1)

        # Higher precision is not exactness: more bits still round.
        exact_third = NP.exact_fraction(1, 3; policy = NP.numeric_policy())
        wide, _ = NP.with_precision(() -> BigFloat(1) / 3; bits = 512)
        @test BigFloat(exact_third) != wide
    end

    @testset "precision: two analyses do not share a setting" begin
        # BigFloat precision is a process global, so isolation is by serialisation.
        # Each task asserts what it observed *while it held the scope*; the lock is
        # what makes those observations true rather than racy.
        bits = [128, 256, 512, 1024, 2048, 4096]
        observed = Vector{Int}(undef, length(bits))
        tasks = [Threads.@spawn begin
                     _, achieved = NP.with_precision(() -> precision(BigFloat); bits = b)
                     observed[i] = achieved
                 end for (i, b) in enumerate(bits)]
        foreach(wait, tasks)
        @test observed == bits
        @test precision(BigFloat) == 256
    end

    @testset "values carry what they are, and the boundaries respect it" begin
        count = NP.exact_value(42)
        @test NP.is_exact(count)
        @test NP.is_exact(NP.exact_value(3 // 4))
        @test !NP.is_exact(NP.approximate_value(0.5))
        @test !NP.is_exact(NP.rounded_value(0.5; digits = 2))

        @test_throws NP.UnsupportedRepresentationError NP.exact_value(0.5)
        @test_throws NP.UnsupportedRepresentationError NP.approximate_value(1)
        @test_throws NP.UnsupportedRepresentationError NP.rounded_value(1; digits = 2)

        # Storage: small counts stay numbers, big ones and rationals become strings.
        @test NP.to_storage(count) === 42
        @test NP.to_storage(NP.exact_value(big(2)^53 + 1)) == "9007199254740993"
        @test NP.to_storage(NP.exact_value(3 // 4)) == "3/4"
        @test NP.to_storage(NP.approximate_value(0.5)) === 0.5
        @test_throws NP.UnsupportedRepresentationError NP.to_storage(NP.approximate_value(NaN))

        # Display says which kind it is showing, and rounds only here.
        @test NP.to_display(count) == "42"
        @test occursin("exact", NP.to_display(NP.exact_value(3 // 4)))
        @test occursin("approximate", NP.to_display(NP.approximate_value(0.123456789)))
    end

    @testset "the JSON boundary refuses loss rather than performing it" begin
        @test NP.encode_json_number(7) === 7
        @test NP.encode_json_number(2^53 - 1) == 2^53 - 1
        @test NP.encode_json_number(big(2)^53) == "9007199254740992"
        @test NP.encode_json_number(big(2)^53 + 1) == "9007199254740993"
        @test NP.encode_json_number(3 // 4) == "3/4"
        @test NP.encode_json_number(0.5) === 0.5
        @test NP.encode_json_number(BigFloat(1) / 3) isa String

        # The negative control the whole boundary exists for: the JavaScript client
        # would receive 9007199254740992 for a count of 9007199254740993 if this were
        # a JSON number.
        lost = Float64(big(2)^53 + 1)
        @test Int64(lost) != 9007199254740993
        @test NP.encode_json_number(big(2)^53 + 1) != lost

        @test_throws NP.UnsupportedRepresentationError NP.encode_json_number(NaN)
        @test_throws NP.UnsupportedRepresentationError NP.encode_json_number(Inf)
        @test_throws NP.UnsupportedRepresentationError NP.encode_json_number(-Inf)
        @test_throws NP.UnsupportedRepresentationError NP.encode_json_number("12")
        @test_throws NP.UnsupportedRepresentationError NP.encode_json_number(nothing)

        # And the encodings survive a round trip through JSON itself, since that is the
        # trip they are for.
        payload = JSON3.write(Dict("count" => NP.encode_json_number(big(2)^53 + 1),
                                   "prop" => NP.encode_json_number(3 // 4),
                                   "mean" => NP.encode_json_number(0.5)))
        back = JSON3.read(payload)
        @test back["count"] == "9007199254740993"
        @test back["prop"] == "3/4"
        @test back["mean"] == 0.5
    end
end
