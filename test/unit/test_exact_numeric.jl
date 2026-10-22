# Unit tests for the numeric policy of the exact statistics layer (issue #1).
#
# What these tests are for: they pin the *contract* - which representations are
# accepted, which are refused, how a value is tagged on the way out, and that the
# working precision of one analysis cannot leak into another's. The arithmetic
# itself is checked against an independent implementation in
# test/unit/test_exact_statistics.jl (fixture: test/fixtures/statistics_known_answers.json).
using MetaManifold.ExactNumeric
using Random

@testset "ExactNumeric" begin

    @testset "policy validation" begin
        p = NumericPolicy()
        @test p.mode === :float64
        @test p.precision_bits == DEFAULT_PRECISION_BITS
        @test p.max_digits == DEFAULT_MAX_DIGITS
        @test p.display_digits == 6
        @test p.version == POLICY_VERSION

        @test NumericPolicy(mode = " Exact ").mode === :exact
        @test NumericPolicy(mode = "FLOAT64").mode === :float64
        @test NumericPolicy(mode = "bigfloat", precision_bits = 1024).precision_bits == 1024
        @test NumericPolicy(precision_bits = MIN_PRECISION_BITS).precision_bits == 53
        @test NumericPolicy(precision_bits = MAX_PRECISION_BITS).precision_bits == 4096
        @test NumericPolicy(max_digits = MAX_MAX_DIGITS).max_digits == MAX_MAX_DIGITS
        @test NumericPolicy(display_digits = MAX_DISPLAY_DIGITS).display_digits == 50

        # Unsupported or mistyped requests are refused, never coerced.
        @test_throws ArgumentError NumericPolicy(mode = "decimal")
        # (mode is matched case-insensitively, like every other name in the config)
        @test_throws ArgumentError NumericPolicy(mode = :exact)
        @test_throws ArgumentError NumericPolicy(precision_bits = 52)
        @test_throws ArgumentError NumericPolicy(precision_bits = 4097)
        @test_throws ArgumentError NumericPolicy(precision_bits = 256.0)
        @test_throws ArgumentError NumericPolicy(precision_bits = true)
        @test_throws ArgumentError NumericPolicy(max_digits = 15)
        @test_throws ArgumentError NumericPolicy(max_digits = MAX_MAX_DIGITS + 1)
        @test_throws ArgumentError NumericPolicy(display_digits = -1)
        @test_throws ArgumentError NumericPolicy(display_digits = 51)
    end

    @testset "policy_from_config" begin
        cfg = Dict{String,Any}("mode" => "bigfloat", "precision_bits" => 512,
                               "max_digits" => 128, "display_digits" => 4)
        p = policy_from_config(cfg)
        @test p.mode === :bigfloat
        @test p.precision_bits == 512
        @test p.max_digits == 128
        @test p.display_digits == 4

        # An override is applied last, and a `nothing` (YAML's `~`) means "unset"
        # rather than "null", so a cascade cannot shadow a default with nothing.
        p2 = policy_from_config(cfg; overrides = Dict("precision_bits" => 256, "mode" => nothing))
        @test p2.precision_bits == 256
        @test p2.mode === :bigfloat

        @test policy_from_config() == NumericPolicy()
        @test policy_from_config(nothing; overrides = nothing) == NumericPolicy()

        # A misspelt key is a hard error: silently running at the default while
        # the caller believes otherwise is the failure this layer exists to avoid.
        @test_throws ArgumentError policy_from_config(Dict("precision" => 256))
        @test_throws ArgumentError policy_from_config(Dict("mode" => "exact", "unknown" => 1))
        @test_throws ArgumentError policy_from_config(Dict("mode" => "octal"))
    end

    @testset "policy_dict and arithmetic_bits" begin
        d = policy_dict(NumericPolicy(mode = "bigfloat", precision_bits = 128))
        @test d["version"] == POLICY_VERSION
        @test d["mode"] == "bigfloat"
        @test d["precision_bits"] == 128
        @test occursin("all arithmetic", d["precision_applies_to"])

        @test arithmetic_bits(NumericPolicy()) == 53
        @test arithmetic_bits(NumericPolicy(mode = "bigfloat", precision_bits = 300)) == 300
        @test_throws UnsupportedNumericMode arithmetic_bits(NumericPolicy(mode = "exact"))
    end

    @testset "exact_count refuses rather than rounds" begin
        @test exact_count(0) == 0 && exact_count(0) isa BigInt
        @test exact_count(12) == 12
        @test exact_count(typemax(Int)) == typemax(Int)
        @test exact_count(Int128(2)^100) == BigInt(2)^100
        @test exact_count(big(2)^200) == BigInt(2)^200
        @test exact_count(4 // 1) == 4 && exact_count(4 // 1) isa BigInt
        @test exact_count(42.0) == 42
        @test exact_count(Float32(7)) == 7
        @test exact_count(Float64(FLOAT_EXACT_INT_MAX)) == FLOAT_EXACT_INT_MAX

        # Fractional values are refused, never rounded to the nearest integer.
        @test_throws InvalidNumericInput exact_count(1 // 2)
        @test_throws InvalidNumericInput exact_count(2.5)
        @test_throws InvalidNumericInput exact_count(0.0001)
        # Non-finite values are not counts.
        @test_throws InvalidNumericInput exact_count(NaN)
        @test_throws InvalidNumericInput exact_count(Inf)
        # Negatives are not counts.
        @test_throws InvalidNumericInput exact_count(-1)
        @test_throws InvalidNumericInput exact_count(-0.5)
        # A Bool is not a count, even though Bool <: Integer.
        @test_throws InvalidNumericInput exact_count(true)
        # Above 2^53-1 a binary float is no longer a faithful name for an integer.
        @test_throws InvalidNumericInput exact_count(Float64(2)^53)

        err = try
            exact_count(2.5; what = "count[3,7]")
        catch e
            e
        end
        @test err isa InvalidNumericInput
        @test occursin("count[3,7]", sprint(showerror, err))
        @test error_code(err) == "invalid_input"
    end

    @testset "exact_counts names the offending cell" begin
        m = [1 2; 3 4]
        exact = exact_counts(m)
        @test eltype(exact) === BigInt
        @test exact == BigInt[1 2; 3 4]

        bad = [1.0 2.0; 3.0 1.5]
        err = try
            exact_counts(bad)
        catch e
            e
        end
        @test err isa InvalidNumericInput
        @test occursin("count[2,2]", sprint(showerror, err))
    end

    @testset "exact_ratio" begin
        @test exact_ratio(6, 4) == 3 // 2
        @test exact_ratio(6, 4) isa Rational{BigInt}
        @test exact_ratio(-6, 4) == -3 // 2
        @test exact_ratio(6, -4) == -3 // 2      # denominator normalised positive
        @test exact_ratio(0, 5) == 0 // 1
        @test exact_ratio(5, 1) == 5 // 1
        @test_throws ZeroDenominator exact_ratio(1, 0)
        @test_throws InvalidNumericInput exact_ratio(true, 2)
        @test error_code(ZeroDenominator("x")) == "zero_denominator"

        # The digit bound is enforced on both halves of the rational.
        tiny = NumericPolicy(max_digits = 16)
        @test_throws NumericLimit exact_ratio(big(10)^20, 3; policy = tiny)
        @test_throws NumericLimit exact_ratio(1, big(3)^50; policy = tiny)
        @test error_code(NumericLimit("x", 16)) == "resource_limit"
        @test error_code(ResourceLimit("x", 16)) == "resource_limit"
        @test error_code(UnsupportedNumericMode("x", :exact, "y")) == "unsupported_numeric_mode"
    end

    @testset "check_limit and decimal_digits" begin
        @test decimal_digits(0) == 1
        @test decimal_digits(9) == 1
        @test decimal_digits(-12345) == 5
        @test decimal_digits(big(10)^100) == 101

        policy = NumericPolicy(max_digits = 16)
        @test check_limit(big(10)^15, policy) == big(10)^15
        @test_throws NumericLimit check_limit(big(10)^16, policy)
        @test check_limit(1 // 3, policy) == 1 // 3
    end

    @testset "display_string is rounded, and rounds half to even" begin
        @test display_string(1234; digits = 6) == "1234"
        @test display_string(big(10)^30; digits = 6) == string(big(10)^30)
        @test display_string(3 // 4; digits = 6) == "0.750000"
        @test display_string(1 // 3; digits = 4) == "0.3333"
        @test display_string(2 // 3; digits = 4) == "0.6667"
        @test display_string(-1 // 3; digits = 4) == "-0.3333"
        @test display_string(1 // 8; digits = 2) == "0.12"      # 0.125 -> 0.12
        @test display_string(3 // 8; digits = 2) == "0.38"      # 0.375 -> 0.38
        @test display_string(5 // 2; digits = 0) == "2"         # 2.5 -> 2 (even)
        @test display_string(7 // 2; digits = 0) == "4"         # 3.5 -> 4 (even)
        @test display_string(-5 // 2; digits = 0) == "-2"
        @test display_string(-7 // 2; digits = 0) == "-4"
        @test display_string(1 // 1000; digits = 2) == "0.00"
        @test display_string(0 // 1; digits = 2) == "0.00"

        # A binary64 is displayed as the number it actually is, not as the decimal
        # it was typed as.
        @test display_string(0.1; digits = 6) == "0.100000"
        @test display_string(0.5; digits = 3) == "0.500"
        @test display_string(3.0; digits = 2) == "3.00"
        @test_throws InvalidNumericInput display_string(NaN)
        @test_throws InvalidNumericInput display_string(Inf)

        h = with_precision(256) do
            BigFloat(1) / 3
        end
        @test display_string(h; digits = 6) == "0.333333"
        @test display_string(h; digits = 12) == "0.333333333333"
        @test_throws InvalidNumericInput display_string(BigFloat(NaN))
    end

    @testset "exact_json and its round trip" begin
        policy = NumericPolicy(display_digits = 4)

        d = exact_json(big(10)^40; policy = policy)
        @test d["kind"] == "exact"
        @test d["type"] == "integer"
        @test d["value"] == string(big(10)^40)     # always a string, never a JSON number
        @test d["display"] == string(big(10)^40)
        @test parse_exact_json(d) == big(10)^40

        r = exact_json(3 // 4; policy = policy)
        @test r["type"] == "rational"
        @test r["numerator"] == "3"
        @test r["denominator"] == "4"
        @test r["value"] == "3/4"
        @test r["display"] == "0.7500"
        @test r["display_rounded"] === true
        @test parse_exact_json(r) == 3 // 4

        @test_throws InvalidNumericInput exact_json(true)
        @test_throws NumericLimit exact_json(big(10)^20; policy = NumericPolicy(max_digits = 16))
        @test error_code(InvalidNumericInput("x", "y")) == "invalid_input"
    end

    @testset "parse_exact_json refuses malformed documents" begin
        @test_throws ArgumentError parse_exact_json(Dict{String,Any}())
        @test_throws ArgumentError parse_exact_json(Dict{String,Any}("kind" => "approx", "type" => "integer", "value" => "1"))
        @test_throws ArgumentError parse_exact_json(Dict{String,Any}("kind" => "exact", "type" => "integer"))
        @test_throws ArgumentError parse_exact_json(Dict{String,Any}("kind" => "exact", "type" => "integer", "value" => 1))
        @test_throws ArgumentError parse_exact_json(Dict{String,Any}("kind" => "exact", "type" => "integer", "value" => "1.5"))
        @test_throws ArgumentError parse_exact_json(Dict{String,Any}("kind" => "exact", "type" => "rational", "numerator" => "1"))
        @test_throws ZeroDenominator parse_exact_json(Dict{String,Any}("kind" => "exact", "type" => "rational",
                                                                      "numerator" => "1", "denominator" => "0"))
        @test_throws ArgumentError parse_exact_json(Dict{String,Any}("kind" => "exact", "type" => "decimal", "value" => "1"))

        # Generative fuzz at the parsing boundary: no input may slip through as a
        # value, and nothing other than a declared refusal may be thrown.
        rng = MersenneTwister(20261022)
        keys = ["kind", "type", "value", "numerator", "denominator"]
        vals = Any["exact", "integer", "rational", "approx", "1", "0", "-3", "abc", "3/4",
                   "1e5", 1, 2.5, nothing, true]
        for _ in 1:300
            d = Dict{String,Any}()
            for _ in 1:rand(rng, 1:4)
                d[rand(rng, keys)] = rand(rng, vals)
            end
            outcome = try
                parse_exact_json(d)
                :accepted
            catch e
                (e isa ArgumentError || e isa ZeroDenominator) ? :refused : :unexpected
            end
            @test outcome != :unexpected
        end
    end

    @testset "approx_json is tagged, and refuses non-finite values" begin
        policy = NumericPolicy(display_digits = 6)
        d = approx_json(0.5; policy = policy)
        @test d["kind"] == "approximation"
        @test d["type"] == "binary64"
        @test d["precision_bits"] == 53
        @test d["display"] == "0.500000"
        @test d["display_rounded"] === true

        b = with_precision(512) do
            sqrt(BigFloat(2))
        end
        j = approx_json(b; policy = policy)
        @test j["type"] == "mpfr"
        @test j["precision_bits"] == 512
        @test parse(Float64, j["value"]) ≈ sqrt(2.0) atol = 1e-15

        @test_throws InvalidNumericInput approx_json(NaN)
        @test_throws InvalidNumericInput approx_json(Inf; policy = policy)
        @test_throws InvalidNumericInput approx_json(BigFloat(Inf))
    end

    @testset "with_precision restores the ambient precision" begin
        before = precision(BigFloat)
        v = with_precision(128) do
            @test precision(BigFloat) == 128
            BigFloat(1) / 3
        end
        @test precision(BigFloat) == before
        @test precision(v) == 128

        # Nested calls restore their own predecessor.
        outer = with_precision(256) do
            inner = with_precision(512) do
                @test precision(BigFloat) == 512
                BigFloat(1) / 7
            end
            @test precision(BigFloat) == 256
            inner
        end
        @test precision(outer) == 512
        @test precision(BigFloat) == before

        @test_throws ArgumentError with_precision(() -> 1, 52)
        @test_throws ArgumentError with_precision(() -> 1, 256.0)
    end

    @testset "concurrent analyses do not share precision" begin
        before = precision(BigFloat)
        bitsets = [64, 128, 256, 1024]

        sequential = Dict{Int,BigFloat}()
        for bits in bitsets
            sequential[bits] = with_precision(bits) do
                BigFloat(1) / 3
            end
        end

        tasks = [Threads.@spawn begin
                     bits = bitsets[mod1(i, length(bitsets))]
                     with_precision(bits) do
                         v = BigFloat(1) / 3
                         (bits, precision(v), v)
                     end
                 end for i in 1:64]
        observed = fetch.(tasks)
        for (bits, prec, v) in observed
            @test prec == bits
            @test v == sequential[bits]
        end
        # And the interleaving left nothing behind.
        @test precision(BigFloat) == before
    end

    @testset "approximate_value obeys the policy" begin
        v = approximate_value(NumericPolicy(mode = "bigfloat", precision_bits = 200)) do
            BigFloat(1) / 7
        end
        @test precision(v) == 200
        @test v ≈ 1 / 7 atol = 1e-15

        f = approximate_value(NumericPolicy()) do
            BigFloat(1) / 3
        end
        @test precision(f) == 53

        @test_throws UnsupportedNumericMode approximate_value(() -> BigFloat(1),
                                                             NumericPolicy(mode = "exact"))
    end

    @testset "numeric_contract states the boundaries" begin
        c = numeric_contract()
        @test c["version"] == POLICY_VERSION
        @test c["integer"]["json"] == "decimal string in 'value' (never a JSON number)"
        @test "zero denominator" in c["rational"]["refused"]
        @test any(x -> occursin("2^53", x), c["integer"]["refused"])
        @test occursin("2^53", c["json_number_boundary"])
        @test c["approximation"]["json"] isa String
    end

end
