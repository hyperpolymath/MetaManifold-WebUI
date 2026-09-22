# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Numeric integrity for the statistics layer (issue #1).
#
# This module exists to keep three claims apart, because collapsing them is how a
# plausible-looking number gets published that nobody can defend:
#
#   exact        an integer count, or a rational built from counts, with no
#                rounding anywhere in its history.
#   approximate  a floating-point value -- including arbitrary precision. Higher
#                precision is NOT exactness; it moves the rounding error, it does
#                not abolish it.
#   rounded      a display value, cut to N digits on purpose for presentation.
#
# The layer cannot make statistics exact; most of them are not. It can refuse to
# conflate these three, and it can fail loudly at every boundary where a silent
# downgrade would otherwise happen: Julia's own `//` (which will happily hand back
# `1//0`), JSON, a JavaScript client whose numbers are Float64, CSV, R and DuckDB.
#
# Nothing here mutates global state except inside `with_precision`, which restores
# what it found and serialises callers, because BigFloat's precision is a process
# global rather than a task-local.
module NumericPolicy

using JSON3, SHA

export NUMERIC_MODES, ORDINARY_PRECISION_BITS, DEFAULT_MAX_DENOMINATOR_BITS,
       NumericPolicySpec, numeric_policy, validate_policy, policy_fingerprint, assert_mode,
       CountOverflowError, ResourceLimitError, UnsupportedRepresentationError,
       require_count, checked_count_sum, exact_fraction, exact_relative_abundance,
       exact_rational_sum, with_precision,
       EXACT, APPROXIMATE, ROUNDED, NumericValue, exact_value, approximate_value,
       rounded_value, is_exact, to_storage, to_display, encode_json_number

## Modes
# :ordinary is the pre-existing behaviour -- Float64 throughout -- and is the only
# mode under which every saved analysis is unchanged. :exact_counts keeps counts as
# integers and proportions as rationals. :high_precision is arbitrary-precision
# floating point at an explicit number of bits, and remains an approximation.
const NUMERIC_MODES = (:ordinary, :exact_counts, :high_precision)

# Float64 has a 53-bit significand, so that is the precision "ordinary" means.
const ORDINARY_PRECISION_BITS = 53

# The largest exponent of 2 that a Float64 can hold as a consecutive integer. Above
# it, a Float64 can hold a value but cannot prove which integer it was.
const MAX_EXACT_FLOAT = big(2)^53

# Exact rationals are kept as Rational{BigInt}; without a ceiling, summing many
# proportions grows the denominator without bound and turns a job into an OOM
# rather than an error. 4096 bits is ~1233 decimal digits.
const DEFAULT_MAX_DENOMINATOR_BITS = 4096

## Failures
# Every failure here names what was attempted and what was observed, because these
# three are the states a caller must not mistake for a result: overflow, an
# arithmetic budget exhausted, and a representation the target cannot carry.

struct CountOverflowError <: Exception
    left  :: BigInt
    right :: BigInt
end

Base.showerror(io::IO, e::CountOverflowError) = print(io,
    "count overflow: $(e.left) + $(e.right) leaves the range of the integer type in ",
    "use; widen the accumulator (on_overflow = :widen) or fix the input")

struct ResourceLimitError <: Exception
    what     :: String
    limit    :: Int
    observed :: Int
end

Base.showerror(io::IO, e::ResourceLimitError) = print(io,
    "exact arithmetic budget exhausted: $(e.what) is $(e.observed) bits, limit ",
    "$(e.limit) bits; raise the limit deliberately or use a method that does not ",
    "need exact rationals")

struct UnsupportedRepresentationError <: Exception
    what   :: String
    value  :: String
    target :: String
end

Base.showerror(io::IO, e::UnsupportedRepresentationError) = print(io,
    "$(e.target) cannot carry $(e.value) as $(e.what) without loss; convert ",
    "explicitly and record which precision was chosen")

## Policy
struct NumericPolicySpec
    mode                 :: Symbol
    precision_bits       :: Int
    max_denominator_bits :: Int
    round_digits         :: Int
end

"""
    numeric_policy(; mode=:ordinary, precision_bits=ORDINARY_PRECISION_BITS,
                     max_denominator_bits=DEFAULT_MAX_DENOMINATOR_BITS, round_digits=6)

The numeric policy one analysis runs under: which mode, at what precision, with what
exact-arithmetic budget and how many digits a display value keeps.

Immutable and passed explicitly, never read from a global. That is what keeps two
concurrent analyses from sharing a precision setting: there is no shared setting to
share.
"""
function numeric_policy(; mode::Symbol = :ordinary,
                          precision_bits::Integer = ORDINARY_PRECISION_BITS,
                          max_denominator_bits::Integer = DEFAULT_MAX_DENOMINATOR_BITS,
                          round_digits::Integer = 6)
    spec = NumericPolicySpec(mode, Int(precision_bits), Int(max_denominator_bits),
                             Int(round_digits))
    validate_policy(spec)
    return spec
end

numeric_policy(mode::Symbol) = numeric_policy(; mode)

"""
    validate_policy(spec) -> NumericPolicySpec

Reject a policy that cannot mean anything, at construction rather than in the
middle of an analysis.
"""
function validate_policy(spec::NumericPolicySpec)
    spec.mode in NUMERIC_MODES || throw(ArgumentError(
        "mode must be one of $(join(NUMERIC_MODES, ", ")) -- got '$(spec.mode)'"))
    spec.precision_bits >= 2 || throw(ArgumentError(
        "precision_bits must be at least 2, got $(spec.precision_bits)"))
    spec.precision_bits <= 1_000_000 || throw(ArgumentError(
        "precision_bits above 1e6 is a resource decision, not a configuration; " *
        "got $(spec.precision_bits)"))
    spec.max_denominator_bits >= 32 || throw(ArgumentError(
        "max_denominator_bits must be at least 32, got $(spec.max_denominator_bits)"))
    spec.round_digits >= 0 || throw(ArgumentError(
        "round_digits must not be negative, got $(spec.round_digits)"))
    return spec
end

"""
    assert_mode(spec, mode)

Refuse to continue when the caller needs `mode` and the policy does not provide it.

The failure this prevents is a silent downgrade: an exact path requested, an
ordinary-precision policy in force, and a Float64 result that looks the same as the
exact one would have.
"""
function assert_mode(spec::NumericPolicySpec, mode::Symbol)
    spec.mode === mode || throw(UnsupportedRepresentationError(
        "mode $(mode)", "policy is $(spec.mode)",
        "this analysis; re-run with numeric_policy(; mode = :$mode) or drop the exact requirement"))
    return spec
end

"""
    policy_fingerprint(spec) -> String

A stable SHA256 over the policy's own fields, for provenance and for config hashing:
two runs may be compared only if this agrees.
"""
function policy_fingerprint(spec::NumericPolicySpec)
    canonical = Dict{String,Any}(
        "mode"                 => String(spec.mode),
        "precision_bits"       => spec.precision_bits,
        "max_denominator_bits" => spec.max_denominator_bits,
        "round_digits"         => spec.round_digits,
    )
    return bytes2hex(sha256(JSON3.write(canonical)))
end

## Counts
"""
    require_count(x) -> Integer

`x` as a count, or a loud refusal.

Integers pass through. A float passes only if it is finite, integral, and within
2^53: beyond that a Float64 can hold a value but cannot prove which integer it was,
and the float in hand may already have been rounded by R, by a CSV reader or by a
JavaScript client before this function ever saw it. That history cannot be
inspected, so the value is refused rather than trusted.
"""
function require_count(x)
    x isa Integer && return x
    if x isa Rational
        denominator(x) == 1 && return numerator(x)
        throw(UnsupportedRepresentationError("a count", string(x),
            "a count is an integer; $(x) is not one"))
    end
    if x isa AbstractFloat
        isfinite(x) || throw(UnsupportedRepresentationError("a count", string(x),
            "counts must be finite"))
        isinteger(x) || throw(UnsupportedRepresentationError("a count", string(x),
            "a count is an integer; $(x) is not one"))
        abs(big(x)) <= MAX_EXACT_FLOAT || throw(UnsupportedRepresentationError(
            "an exactly-known count", string(x),
            "Float64 above 2^53 cannot say which integer it holds"))
        return x isa BigFloat ? BigInt(x) : Integer(x)
    end
    throw(UnsupportedRepresentationError("a count", string(x),
        "counts are integers, not $(typeof(x))"))
end

"""
    checked_count_sum(values; on_overflow=:error) -> Integer

The exact sum of `values`, with overflow made visible instead of wrapping.

`on_overflow = :error` refuses; `:widen` continues in `BigInt`, which is the honest
answer for a total that a fixed-width integer cannot hold. A sum that wraps around
to a small number is worse than a failure: it is a wrong total that no downstream
check can detect.
"""
function checked_count_sum(values; on_overflow::Symbol = :error)
    on_overflow in (:error, :widen) || throw(ArgumentError(
        "on_overflow must be :error or :widen, got :$on_overflow"))

    state = iterate(values)
    state === nothing && return 0
    first_value, rest = state
    acc = require_count(first_value)

    while true
        nxt = iterate(values, rest)
        nxt === nothing && break
        value, rest = nxt
        count = require_count(value)

        if acc isa BigInt || count isa BigInt
            acc = acc + count                      # BigInt promotes the other side
            continue
        end
        try
            acc = Base.Checked.checked_add(promote(acc, count)...)
        catch err
            err isa OverflowError || rethrow()
            on_overflow === :widen || throw(CountOverflowError(BigInt(acc), BigInt(count)))
            acc = BigInt(acc) + BigInt(count)
        end
    end
    return acc
end

## Exact rational arithmetic
function _check_denominator_bits(value::Rational, spec::NumericPolicySpec)
    bits = ndigits(denominator(value), base = 2)
    bits <= spec.max_denominator_bits || throw(ResourceLimitError(
        "denominator", spec.max_denominator_bits, bits))
    return value
end

"""
    exact_fraction(numerator, denominator; policy) -> Rational{BigInt}

`numerator/denominator`, exactly, with a zero denominator refused before any division
happens.

The refusal is the point. Julia's `//` answers `1//0` for a non-zero numerator and
`0//0` for a zero one: a non-finite Rational that flows on into charts and tables
looking like a number. A proportion with no denominator is not a large proportion or
a small one; it is not a proportion.
"""
function exact_fraction(numerator::Integer, denominator::Integer;
                        policy::NumericPolicySpec = numeric_policy())
    iszero(denominator) && throw(UnsupportedRepresentationError(
        "a proportion", "$(numerator)/$(denominator)",
        "a fraction whose denominator is zero; refuse the value rather than carry " *
        "a non-finite Rational past this point"))
    return _check_denominator_bits(Rational{BigInt}(numerator, denominator), policy)
end

"""
    exact_rational_sum(values; policy) -> Union{Rational{BigInt},Nothing}

The exact sum of a collection of rationals, bounded by the policy's denominator
budget.

Returns `nothing` for an empty collection rather than `0`: a sum over nothing has no
value, and a zero here would be read downstream as "the values add up to none".
"""
function exact_rational_sum(values; policy::NumericPolicySpec = numeric_policy())
    acc = nothing
    for value in values
        value isa Rational || throw(UnsupportedRepresentationError(
            "an exact rational", string(value), "exact_rational_sum"))
        acc = isnothing(acc) ? Rational{BigInt}(value) :
              _check_denominator_bits(acc + Rational{BigInt}(value), policy)
    end
    return acc
end

"""
    exact_relative_abundance(count, total; policy) -> Union{Rational{BigInt},Nothing}

`count/total` exactly, or `nothing` when `total == 0`.

`nothing`, not `0.0` and not an error: a sample of zero reads has no composition at
all, so "0 of 0 reads are this feature" is not a proportion that happens to be zero,
it is a proportion that does not exist. Callers must carry it to the presentation
layer as an unsuccessful state, which is why it is not a number here.
"""
function exact_relative_abundance(count::Integer, total::Integer;
                                  policy::NumericPolicySpec = numeric_policy())
    total >= 0 || throw(ArgumentError("total must not be negative, got $total"))
    count >= 0 || throw(ArgumentError("count must not be negative, got $count"))
    count <= total || throw(ArgumentError(
        "count ($count) exceeds total ($total); these are not counts of the same table"))
    iszero(total) && return nothing
    return exact_fraction(count, total; policy)
end

## Precision
# BigFloat's precision lives in a process-wide RefValue, not in the task. Scoping it
# with setprecision() therefore protects one caller from another *only* if the
# callers are serialised, which is what this lock does. Serialising is the same
# trade the R runtime makes: correctness over parallel speed, for work whose answer
# must be defensible.
const _PRECISION_LOCK = ReentrantLock()

"""
    with_precision(f; bits) -> (result, achieved_bits)

Run `f` with BigFloat precision set to `bits`, restoring whatever was there before.

`bits` is explicit so that no caller depends on ambient precision. The pair is
returned together on purpose: a caller that records only its result cannot show
afterwards that the precision it asked for was the precision it got.
"""
function with_precision(f::Function; bits::Integer)
    bits >= 2 || throw(ArgumentError("bits must be at least 2, got $bits"))
    return lock(_PRECISION_LOCK) do
        previous = precision(BigFloat)
        try
            # `achieved` is read INSIDE the scope, before setprecision restores the
            # previous value: read afterwards it reports the precision that was in
            # force before the call, which is exactly the fact this return value
            # exists to establish.
            return setprecision(BigFloat, Int(bits)) do
                value = f()
                (value, precision(BigFloat))
            end
        finally
            setprecision(BigFloat, previous)
        end
    end
end

## Values that know what they are
const EXACT       = :exact
const APPROXIMATE = :approximate
const ROUNDED     = :rounded

struct NumericValue
    value          :: Any
    kind           :: Symbol
    precision_bits :: Union{Int,Nothing}
    digits         :: Union{Int,Nothing}
end

"""
    exact_value(x)
    approximate_value(x; bits=nothing)
    rounded_value(x; digits)

The three kinds of number this layer is willing to carry.

An `NumericValue` is what a caller passes when the number may reach a user, a file or
another language, because at those boundaries the kind decides what is safe: exact
values must not be handed to a Float64 boundary, and approximate ones must not be
presented as exact.
"""
function exact_value(x)
    (x isa Integer || x isa Rational) || throw(UnsupportedRepresentationError(
        "an exact value", string(x),
        "exact_value; integer counts and rationals are exact, $(typeof(x)) is not"))
    x isa Rational && denominator(x) == 0 && throw(UnsupportedRepresentationError(
        "an exact value", string(x), "a rational needs a non-zero denominator"))
    return NumericValue(x, EXACT, nothing, nothing)
end

function approximate_value(x; bits::Union{Integer,Nothing} = nothing)
    x isa AbstractFloat || throw(UnsupportedRepresentationError(
        "an approximate value", string(x),
        "approximate_value; $(typeof(x)) is not floating point"))
    return NumericValue(x, APPROXIMATE, isnothing(bits) ? nothing : Int(bits), nothing)
end

function rounded_value(x; digits::Integer)
    x isa AbstractFloat || throw(UnsupportedRepresentationError(
        "a rounded value", string(x),
        "rounded_value; round an approximate float explicitly"))
    digits >= 0 || throw(ArgumentError("digits must not be negative, got $digits"))
    return NumericValue(x, ROUNDED, nothing, Int(digits))
end

"""
    is_exact(v::NumericValue) -> Bool

Whether `v` may be read as a count or a proportion without an approximation in its
history. False means it is a number, not a fact.
"""
is_exact(v::NumericValue) = v.kind === EXACT

## Boundaries
"""
    to_storage(v::NumericValue) -> Union{Integer,String,Float64}

The representation this value may be stored and shipped as.

Exact integers up to 2^53 stay integers -- that is the range a JavaScript client
reproduces exactly, and this application has one. Everything exact beyond that, and
every rational, travels as a string, because a JSON number on the way through a
browser is a Float64 and would silently round: a count of 9007199254740993 arrives
as 9007199254740992. Approximate values travel as Float64, and non-finite ones are
refused, since JSON cannot carry them at all.
"""
function to_storage(v::NumericValue)
    x = v.value
    if v.kind === EXACT
        if x isa Integer
            return abs(big(x)) <= MAX_EXACT_FLOAT - 1 ? x : string(x)
        end
        return string(numerator(x), "/", denominator(x))
    end
    if x isa Float64
        isfinite(x) || throw(UnsupportedRepresentationError("a stored number", string(x),
            "JSON and JavaScript; neither carries Inf or NaN faithfully"))
        return x
    end
    return x isa BigFloat ? string(x) : Float64(x)
end

"""
    to_display(v::NumericValue; digits=6) -> String

The string a person reads.

Rounding happens here and only here, and a rounded value says so in its own type
before it arrives.
"""
function to_display(v::NumericValue; digits::Integer = 6)
    digits >= 0 || throw(ArgumentError("digits must not be negative, got $digits"))
    if v.kind === EXACT
        return v.value isa Integer ? string(v.value) :
               string(v.value, " (exact; ", digits, "dp = ",
                      round(BigFloat(numerator(v.value)) / BigFloat(denominator(v.value));
                            digits = digits), ")")
    end
    kept = v.kind === ROUNDED && !isnothing(v.digits) ? v.digits : Int(digits)
    return string(round(v.value; digits = kept), " (", v.kind, ", ", kept, "dp)")
end

"""
    encode_json_number(x)

The JSON-safe form of a bare number, for values that have not been wrapped yet.

Rules, in order: an integer inside 2^53 is a JSON number; any other integer is a
string; a rational is a string; a BigFloat is a string, because its precision is the
reason it is not a Float64; a finite Float64 is a JSON number; anything non-finite or
unrecognised is refused.
"""
function encode_json_number(x)
    if x isa Integer
        return abs(big(x)) <= MAX_EXACT_FLOAT - 1 ? x : string(x)
    end
    x isa Rational && return string(numerator(x), "/", denominator(x))
    x isa BigFloat && return string(x)
    if x isa Float64
        isfinite(x) || throw(UnsupportedRepresentationError("a JSON number", string(x),
            "JSON; Inf and NaN have no JSON representation"))
        return x
    end
    x isa AbstractFloat && return encode_json_number(Float64(x))
    throw(UnsupportedRepresentationError("a JSON number", string(x),
        "JSON; unsupported type $(typeof(x))"))
end

end # module
