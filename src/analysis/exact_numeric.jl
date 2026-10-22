# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# The numeric policy of the optional statistics layer (issue #1).
#
# This file owns four things and nothing else:
#
#   1. What "exact" and "higher precision" mean here, as one validated,
#      versioned `NumericPolicy` value.
#   2. Checked conversion of counts into arbitrary-precision integers, with an
#      explicit refusal - never a rounding - at every boundary that cannot
#      represent a count exactly.
#   3. Exact rational construction with explicit zero-denominator and resource
#      failures.
#   4. The serialisation contract: every number leaves this layer tagged as an
#      exact value, an approximation, or a rounded display of one of those, so a
#      consumer cannot mistake a display value for a computed one.
#
# Scope, stated plainly. Exact arithmetic removes representation error. It does
# not remove measurement error, sampling uncertainty, model misspecification or
# biological bias, and nothing here estimates any of them. Higher precision is
# not exactness either: a 4096-bit approximation is still an approximation, and
# every value this file labels `"approximation"` is one. Symbolic mathematics is
# out of scope.
#
# Precision isolation. Julia's BigFloat precision is process-global state. Every
# computation that depends on it here runs inside `with_precision`, which takes
# a process-wide lock and restores the previous precision before releasing it,
# so two analyses asking for different precisions can run concurrently without
# either seeing the other's setting. Nothing in this file changes the ambient
# precision permanently, and no result carries an implicit dependence on it: a
# value is rounded to a stated number of bits when it is produced.

module ExactNumeric

export POLICY_VERSION, NUMERIC_MODES, DEFAULT_PRECISION_BITS, MIN_PRECISION_BITS,
       MAX_PRECISION_BITS, DEFAULT_MAX_DIGITS, MAX_MAX_DIGITS, MAX_DISPLAY_DIGITS,
       FLOAT_EXACT_INT_MAX, NumericPolicy, policy_from_config, policy_dict,
       arithmetic_bits, with_precision, approximate_value,
       NumericError, InvalidNumericInput, ZeroDenominator, NumericLimit,
       ResourceLimit, UnsupportedNumericMode, error_code,
       exact_count, exact_counts, exact_ratio, check_limit,
       exact_json, approx_json, parse_exact_json, display_string,
       decimal_digits, numeric_contract

# Version of the numeric policy as a whole: the set of modes, the conversion
# rules, and the JSON tags below. A stored analysis records this string, so a
# later change to any of them is visible against an old result rather than
# silent.
const POLICY_VERSION = "1.0.0"

# `float64`     - IEEE-754 binary64 (53-bit significand), for compatibility
#                 with the values the rest of the application already produces.
# `bigfloat`    - MPFR at `precision_bits`, an approximation computed and
#                 reported at that precision.
# `exact`       - arbitrary-precision integers and exact rationals only. An
#                 operation with no exact representation is refused
#                 (`UnsupportedNumericMode`); it is never computed at some other
#                 precision and returned as if it were what was asked for.
const NUMERIC_MODES = ("float64", "bigfloat", "exact")

const DEFAULT_PRECISION_BITS = 256
# 53 is binary64's significand: below it, "higher precision" would be lower.
const MIN_PRECISION_BITS = 53
# An upper bound rather than a suggestion: past it, an analysis is far more
# likely to be an accident than a requirement, and the cost is unbounded.
const MAX_PRECISION_BITS = 4096

# The largest number of decimal digits allowed in any exact numerator,
# denominator or integer this layer emits or stores.
const DEFAULT_MAX_DIGITS = 4096
const MAX_MAX_DIGITS = 100_000

# Display rounding is presentation only; it never feeds a computation back.
const MAX_DISPLAY_DIGITS = 50

# Binary64 represents every integer in this range exactly, and no other.
const FLOAT_EXACT_INT_MAX = 2^53 - 1

## ---------------------------------------------------------------------------
## Failures
##
## Each of these is a refusal, not a fallback. The statistics layer turns them
## into an explicit unsuccessful state (with a stable machine-readable code)
## instead of a plausible-looking number.
## ---------------------------------------------------------------------------

abstract type NumericError <: Exception end

"An input cannot be represented exactly: a fractional count, NaN, or similar."
struct InvalidNumericInput <: NumericError
    what   :: String
    reason :: String
end

"A divisor was zero, so the requested ratio has no value."
struct ZeroDenominator <: NumericError
    what :: String
end

"An exact value exceeded the policy's `max_digits` bound."
struct NumericLimit <: NumericError
    what  :: String
    limit :: Int
end

"A computation exceeded a declared work bound (iterations or operations)."
struct ResourceLimit <: NumericError
    what  :: String
    limit :: Int
end

"An operation has no representation in the requested numeric mode."
struct UnsupportedNumericMode <: NumericError
    what   :: String
    mode   :: Symbol
    reason :: String
end

Base.showerror(io::IO, e::InvalidNumericInput) =
    print(io, "invalid numeric input ($(e.what)): $(e.reason)")

Base.showerror(io::IO, e::ZeroDenominator) =
    print(io, "zero denominator: $(e.what) has no value when its divisor is zero")

Base.showerror(io::IO, e::NumericLimit) =
    print(io, "exact value limit: $(e.what) needs more than $(e.limit) decimal digits " *
              "in a numerator, denominator or integer (raise numeric.max_digits, within " *
              "its own bound, or select the bigfloat mode explicitly)")

Base.showerror(io::IO, e::ResourceLimit) =
    print(io, "resource limit: $(e.what) would exceed $(e.limit) units of work")

Base.showerror(io::IO, e::UnsupportedNumericMode) =
    print(io, "unsupported numeric mode: $(e.what) has no exact representation, and the " *
              "policy is '$(e.mode)' (nothing was silently computed at another precision). " *
              e.reason)

"""
    error_code(e::NumericError) -> String

The stable code a failure is stored under, for clients that switch on it.
"""
error_code(::InvalidNumericInput)    = "invalid_input"
error_code(::ZeroDenominator)        = "zero_denominator"
error_code(::NumericLimit)           = "resource_limit"
error_code(::ResourceLimit)          = "resource_limit"
error_code(::UnsupportedNumericMode) = "unsupported_numeric_mode"

## ---------------------------------------------------------------------------
## The policy
## ---------------------------------------------------------------------------

"""
    NumericPolicy(; mode="float64", precision_bits=256, max_digits=4096,
                    display_digits=6)

The requested numeric behaviour of one analysis. Immutable, small, and carried
in every stored result's provenance, so a result states the rules it was
computed under rather than inheriting today's defaults.

`mode` is one of `NUMERIC_MODES`. `precision_bits`, in [53, 4096], is MPFR's
working precision and applies to the `bigfloat` mode only; it is still recorded
in the other modes, because a policy is a request, not a report. `max_digits`,
in [16, 100000], bounds every exact numerator, denominator and integer the
analysis may produce. `display_digits`, in [0, 50], is the rounding applied to
*display* strings only.

Every argument is validated strictly. A value of the wrong type is refused
rather than converted: `precision_bits=256.0` is an `ArgumentError`, not 256,
because silently accepting one spelling and not another is how two callers end
up meaning different things. `Bool` is refused for the integer fields.
"""
struct NumericPolicy
    mode           :: Symbol
    precision_bits :: Int
    max_digits     :: Int
    display_digits :: Int
    version        :: String
end

function _strict_int(v, name::String, lo::Integer, hi::Integer)::Int
    (v isa Integer && !(v isa Bool)) || throw(ArgumentError(
        "numeric policy $name must be an integer, not $(typeof(v))"))
    lo <= v <= hi || throw(ArgumentError(
        "numeric policy $name must be between $lo and $hi, not $v"))
    return Int(v)
end

function NumericPolicy(; mode = "float64",
                       precision_bits = DEFAULT_PRECISION_BITS,
                       max_digits = DEFAULT_MAX_DIGITS,
                       display_digits = 6)
    mode isa AbstractString || throw(ArgumentError(
        "numeric policy mode must be a string, not $(typeof(mode))"))
    m = lowercase(strip(String(mode)))
    m in NUMERIC_MODES || throw(ArgumentError(
        "numeric policy mode must be one of $(join(NUMERIC_MODES, ", ")), not '$mode'"))
    NumericPolicy(Symbol(m),
                  _strict_int(precision_bits, "precision_bits", MIN_PRECISION_BITS, MAX_PRECISION_BITS),
                  _strict_int(max_digits, "max_digits", 16, MAX_MAX_DIGITS),
                  _strict_int(display_digits, "display_digits", 0, MAX_DISPLAY_DIGITS),
                  POLICY_VERSION)
end

const POLICY_KEYS = ("mode", "precision_bits", "max_digits", "display_digits")

"""
    policy_from_config(section=nothing; overrides=nothing) -> NumericPolicy

Build a policy from a config section (a `Dict` from the config cascade, or
`nothing`) and an optional request-level override, with the override applied
last. Keys are `"mode"`, `"precision_bits"`, `"max_digits"` and
`"display_digits"`; `nothing` values mean "not set" and are skipped, so a
cascade's explicit `~` does not shadow the default with a null.

An unknown key is an `ArgumentError`. That is deliberate: a misspelt
`"precision"` must not leave the analysis quietly running at the default while
the caller believes otherwise.
"""
function policy_from_config(section::Union{Nothing,AbstractDict} = nothing;
                            overrides::Union{Nothing,AbstractDict} = nothing)
    values = Dict{String,Any}()
    for source in (section, overrides)
        isnothing(source) && continue
        for (k, v) in source
            key = String(k)
            key in POLICY_KEYS || throw(ArgumentError(
                "unknown numeric policy key '$key' (expected one of $(join(POLICY_KEYS, ", ")))"))
            isnothing(v) && continue
            values[key] = v
        end
    end
    NumericPolicy(; mode            = get(values, "mode", "float64"),
                    precision_bits  = get(values, "precision_bits", DEFAULT_PRECISION_BITS),
                    max_digits      = get(values, "max_digits", DEFAULT_MAX_DIGITS),
                    display_digits  = get(values, "display_digits", 6))
end

"""
    policy_dict(p) -> Dict{String,Any}

The policy as plain JSON-safe data for provenance.
"""
policy_dict(p::NumericPolicy) = Dict{String,Any}(
    "version"        => p.version,
    "mode"           => String(p.mode),
    "precision_bits" => p.precision_bits,
    "precision_applies_to" => p.mode === :bigfloat ? "all arithmetic in this analysis" :
                              "bigfloat mode only (recorded, not used here)",
    "max_digits"     => p.max_digits,
    "display_digits" => p.display_digits,
)

"""
    arithmetic_bits(p) -> Int

The significand width approximate arithmetic runs at: the policy's precision in
`bigfloat` mode, binary64's 53 bits in `float64` mode. Asking an `exact` policy
for it is an `UnsupportedNumericMode`, not a default: there is no approximate
arithmetic in exact mode.
"""
arithmetic_bits(p::NumericPolicy) = p.mode === :bigfloat ? p.precision_bits :
    p.mode === :float64 ? 53 :
    throw(UnsupportedNumericMode("arithmetic_bits", p.mode,
        "exact mode performs no approximate arithmetic"))

## ---------------------------------------------------------------------------
## Precision isolation
## ---------------------------------------------------------------------------

const _PRECISION_LOCK = ReentrantLock()

"""
    with_precision(f, bits) -> f()

Run `f` with BigFloat's working precision set to `bits` and restore the previous
precision before returning, under a process-wide lock.

This is the only way this layer touches the global precision. The lock is what
makes concurrent analyses with different precisions safe: without it, two tasks
would interleave their settings and one would silently compute the other's
precision. The restore in a `finally` is what keeps the setting from leaking
into unrelated code. Nested calls are safe - the lock is reentrant and each
frame restores its own predecessor.
"""
function with_precision(f::Function, bits::Integer)
    bits = _strict_int(bits, "working precision", MIN_PRECISION_BITS, MAX_PRECISION_BITS)
    lock(_PRECISION_LOCK)
    try
        return setprecision(BigFloat, bits) do
            f()
        end
    finally
        unlock(_PRECISION_LOCK)
    end
end

"""
    approximate_value(f, policy; what="value") -> BigFloat

Run the closure `f` at the policy's working precision and return its result.

`f` must construct its own `BigFloat`s (from integers or strings) so that every
value it touches is at the requested precision; the closure is evaluated with
the global precision set accordingly, so `BigFloat(n)` inside it is exact.
In `exact` mode this refuses: an approximation was not requested, and returning
one would be the silent downgrade this layer exists to prevent.
"""
function approximate_value(f::Function, policy::NumericPolicy; what::AbstractString = "value")
    policy.mode === :exact && throw(UnsupportedNumericMode(String(what), policy.mode,
        "select bigfloat (or float64) explicitly if an approximation is what you want"))
    bits = arithmetic_bits(policy)
    return with_precision(bits) do
        v = f()
        v isa BigFloat ? v : BigFloat(v)
    end
end

## ---------------------------------------------------------------------------
## Counts: checked conversion
## ---------------------------------------------------------------------------

"""
    exact_count(x; what="count") -> BigInt

`x` as an exact non-negative integer, or a refusal.

Accepted: non-negative `Integer`s of any width, `Rational`s with denominator 1,
and finite integral `AbstractFloat`s whose magnitude is at most 2^53-1. The last
bound is the point of the rule: binary64 cannot represent every integer above
it, so a float that large may already be a rounded neighbour of the count it
came from, and accepting it would be claiming an exactness the boundary did not
have. Refused, with the reason stated: fractional values (never rounded), NaN
and infinities, negatives, `Bool`, and unsupported types.
"""
function exact_count(x::Real; what::AbstractString = "count")
    if x isa Bool
        throw(InvalidNumericInput(String(what), "a Bool is not a read count"))
    elseif x isa Integer
        x >= 0 || throw(InvalidNumericInput(String(what),
            "counts must be non-negative, got $x"))
        return BigInt(x)
    elseif x isa Rational
        denominator(x) == 1 || throw(InvalidNumericInput(String(what),
            "the fractional value $x is refused rather than rounded"))
        c = numerator(x)
        c >= 0 || throw(InvalidNumericInput(String(what),
            "counts must be non-negative, got $x"))
        return BigInt(c)
    elseif x isa AbstractFloat
        isfinite(x) || throw(InvalidNumericInput(String(what),
            "the non-finite value $x is not a count"))
        isinteger(x) || throw(InvalidNumericInput(String(what),
            "the fractional value $x is refused rather than rounded"))
        abs(x) <= FLOAT_EXACT_INT_MAX || throw(InvalidNumericInput(String(what),
            "the floating-point value $x is above 2^53-1, where binary64 no longer " *
            "represents every integer; it cannot be trusted to name the count it came from"))
        c = BigInt(x)
        c >= 0 || throw(InvalidNumericInput(String(what),
            "counts must be non-negative, got $x"))
        return c
    end
    throw(InvalidNumericInput(String(what),
        "unsupported count type $(typeof(x))"))
end

_index_string(i) = i isa CartesianIndex ? string(Tuple(i)) : string(i)

"""
    exact_counts(counts) -> Matrix{BigInt}

`counts` converted entry by entry with `exact_count`. The first refusal names
the offending position, so a bad cell in a wide table is findable.
"""
function exact_counts(counts::AbstractMatrix{<:Real})
    out = Matrix{BigInt}(undef, size(counts))
    for i in eachindex(counts)
        out[i] = exact_count(counts[i]; what = "count[$( _index_string(i) )]")
    end
    return out
end

function exact_counts(counts::AbstractVector{<:Real})
    out = Vector{BigInt}(undef, length(counts))
    for i in eachindex(counts)
        out[i] = exact_count(counts[i]; what = "count[$( _index_string(i) )]")
    end
    return out
end

## ---------------------------------------------------------------------------
## Exact values and their bounds
## ---------------------------------------------------------------------------

"""
    decimal_digits(x) -> Int

Number of decimal digits in |x| (1 for zero). Computed from the decimal
expansion rather than a logarithm, so it is exact for arbitrary-precision
integers.
"""
decimal_digits(x::Integer) = x == 0 ? 1 : length(string(abs(BigInt(x))))

"""
    check_limit(x, policy; what="value")

Refuse an exact integer or rational whose numerator or denominator exceeds
`policy.max_digits` decimal digits.

Both halves of a rational are bounded: a rational can be tiny and yet carry an
enormous exact representation, and it is the representation that consumes memory
and makes a stored result unreadable.
"""
function check_limit(x::Integer, policy::NumericPolicy; what::AbstractString = "value")
    decimal_digits(x) <= policy.max_digits || throw(NumericLimit(String(what), policy.max_digits))
    return x
end

function check_limit(x::Rational, policy::NumericPolicy; what::AbstractString = "value")
    d = max(decimal_digits(numerator(x)), decimal_digits(denominator(x)))
    d <= policy.max_digits || throw(NumericLimit(String(what), policy.max_digits))
    return x
end

"""
    exact_ratio(num, den; policy, what="ratio") -> Rational{BigInt}

`num/den` as an exact rational, in lowest terms.

A zero denominator is a `ZeroDenominator`, never a substituted value and never
an infinity. The result is checked against `max_digits` before it is returned.
"""
function exact_ratio(num::Integer, den::Integer;
                     policy::NumericPolicy = NumericPolicy(),
                     what::AbstractString = "ratio")
    (num isa Bool || den isa Bool) && throw(InvalidNumericInput(String(what),
        "a Bool is not a count or a divisor"))
    BigInt(den) == 0 && throw(ZeroDenominator(String(what)))
    q = BigInt(num) // BigInt(den)
    return check_limit(q, policy; what = what)
end

## ---------------------------------------------------------------------------
## Display: rounded, always labelled as such
## ---------------------------------------------------------------------------

"""Round an exact rational to an integer, half to even."""
function _round_ratio(num::BigInt, den::BigInt)::BigInt
    den == 0 && throw(ZeroDenominator("display"))
    if den < 0
        num, den = -num, -den
    end
    q, r = divrem(num, den)          # truncating; r has the sign of num
    twice = 2 * abs(r)
    if twice > den
        return num < 0 ? q - 1 : q + 1
    elseif twice == den
        # A tie: move to the even neighbour, which for an odd q means one step
        # away from zero.
        return isodd(abs(q)) ? (num < 0 ? q - 1 : q + 1) : q
    end
    return q
end

"""Render a value already scaled by 10^`digits` as a fixed-point decimal."""
function _scaled_decimal(n::BigInt, digits::Int)::String
    s = string(abs(n))
    sign = n < 0 ? "-" : ""
    digits == 0 && return sign * s
    if length(s) <= digits
        s = repeat("0", digits - length(s) + 1) * s
    end
    return string(sign, first(s, length(s) - digits), ".", last(s, digits))
end

"""Round a BigFloat to the nearest integer, half to even, using only exact steps."""
function _round_to_bigint(y::BigFloat)::BigInt
    isfinite(y) || throw(InvalidNumericInput("value",
        "display formatting requires a finite value, got $y"))
    return with_precision(max(precision(y), MIN_PRECISION_BITS)) do
        f = floor(y)                 # exact: the result is integral
        frac = y - f                 # exact at y's own precision
        q = BigInt(f)
        half = BigFloat(1) / 2
        if frac > half
            q += 1
        elseif frac == half && isodd(abs(q))
            q += 1                   # half to even
        end
        q
    end
end

"""
    display_string(x; digits=6) -> String

A fixed-point rendering of `x`, rounded half-to-even to `digits` decimal places.

Display is presentation. It is never read back into a computation, and every
JSON document this layer writes marks a display value with
`"display_rounded" => true`, so the rounded string and the computed value cannot
be confused. Exact integers are rendered in full, without rounding.
"""
display_string(x::Integer; digits::Integer = 6) = string(BigInt(x))

function display_string(x::Rational; digits::Integer = 6)
    d = clamp(Int(digits), 0, MAX_DISPLAY_DIGITS)
    scale = BigInt(10)^d
    return _scaled_decimal(_round_ratio(BigInt(numerator(x)) * scale, BigInt(denominator(x))), d)
end

function display_string(x::BigFloat; digits::Integer = 6)
    isfinite(x) || throw(InvalidNumericInput("value",
        "display formatting requires a finite value, got $x"))
    d = clamp(Int(digits), 0, MAX_DISPLAY_DIGITS)
    # 4 bits per decimal digit is ample to hold 10^d exactly, with room for the
    # value's own significand.
    y = with_precision(max(precision(x), 4 * d + 64)) do
        x * BigFloat(10)^d
    end
    return _scaled_decimal(_round_to_bigint(y), d)
end

function display_string(x::AbstractFloat; digits::Integer = 6)
    isfinite(x) || throw(InvalidNumericInput("value",
        "display formatting requires a finite value, got $x"))
    d = clamp(Int(digits), 0, MAX_DISPLAY_DIGITS)
    # Float64 -> BigFloat is exact, so the binary value is displayed as the
    # number it actually is (0.1 shows as 0.100000, not as a rounded 0.3).
    return with_precision(max(64, 4 * d + 64)) do
        display_string(BigFloat(x); digits = d)
    end
end

## ---------------------------------------------------------------------------
## The serialisation contract
## ---------------------------------------------------------------------------

"""
    exact_json(x; policy) -> Dict{String,Any}

An exact integer or rational, tagged.

    {"kind": "exact", "type": "integer",  "value": "12345", "display": "12345"}
    {"kind": "exact", "type": "rational", "numerator": "3", "denominator": "4",
     "value": "3/4", "display": "0.750000", "display_rounded": true}

Integers are always decimal *strings*, never JSON numbers: a count above
2^53-1 would not survive a JSON round trip as a number, and emitting it as one
is how exact counts quietly stop being exact in a browser or an R session. The
rational is normalised (lowest terms, positive denominator) and a zero
denominator is refused here as everywhere else.
"""
function exact_json(x::Integer; policy::NumericPolicy = NumericPolicy())
    v = BigInt(x)
    check_limit(v, policy; what = "integer value")
    return Dict{String,Any}("kind"    => "exact",
                            "type"    => "integer",
                            "value"   => string(v),
                            "display" => string(v))
end

function exact_json(x::Bool; policy::NumericPolicy = NumericPolicy())
    throw(InvalidNumericInput("value", "a Bool is not an exact statistic"))
end

function exact_json(x::Rational; policy::NumericPolicy = NumericPolicy())
    den = denominator(x)
    den == 0 && throw(ZeroDenominator("rational value"))
    q = BigInt(numerator(x)) // BigInt(den)
    check_limit(q, policy; what = "rational value")
    n, d = numerator(q), denominator(q)
    return Dict{String,Any}("kind"           => "exact",
                            "type"           => "rational",
                            "numerator"      => string(n),
                            "denominator"    => string(d),
                            "value"          => string(n) * "/" * string(d),
                            "display"        => display_string(q; digits = policy.display_digits),
                            "display_rounded" => d != 1)
end

"""
    approx_json(x; policy) -> Dict{String,Any}

An approximate value, tagged as one.

    {"kind": "approximation", "type": "mpfr", "value": "...", "precision_bits": 256,
     "rounding": "round-to-nearest-ties-to-even", "display": "0.693147",
     "display_rounded": true}

`value` is the computed approximation rendered as a decimal string (strings
again, so no consumer's JSON number type can silently shorten it). Non-finite
values are refused rather than encoded as `NaN`/`Infinity`, which are not JSON.
"""
function approx_json(x::BigFloat; policy::NumericPolicy = NumericPolicy(),
                     what::AbstractString = "value")
    isfinite(x) || throw(InvalidNumericInput(String(what),
        "a non-finite result is not a number and cannot be stored"))
    return Dict{String,Any}("kind"           => "approximation",
                            "type"           => "mpfr",
                            "value"          => string(x),
                            "precision_bits" => precision(x),
                            "rounding"       => "round-to-nearest-ties-to-even",
                            "display"        => display_string(x; digits = policy.display_digits),
                            "display_rounded" => true)
end

function approx_json(x::AbstractFloat; policy::NumericPolicy = NumericPolicy(),
                     what::AbstractString = "value")
    isfinite(x) || throw(InvalidNumericInput(String(what),
        "a non-finite result is not a number and cannot be stored"))
    return Dict{String,Any}("kind"           => "approximation",
                            "type"           => x isa Float64 ? "binary64" : string(typeof(x)),
                            "value"          => string(x),
                            "precision_bits" => x isa Float64 ? 53 : 8 * sizeof(x),
                            "rounding"       => "round-to-nearest-ties-to-even",
                            "display"        => display_string(x; digits = policy.display_digits),
                            "display_rounded" => true)
end

"""
    parse_exact_json(d) -> Union{BigInt,Rational{BigInt}}

Read an exact value back from its stored document. This is the round-trip half
of the contract: whatever `exact_json` writes, this returns as the same value,
and anything else - a wrong tag, a missing field, a zero denominator, an
unparseable string - is an `ArgumentError`.
"""
function parse_exact_json(d::AbstractDict)
    get(d, "kind", nothing) == "exact" || throw(ArgumentError(
        "not an exact value document: missing or wrong 'kind'"))
    t = get(d, "type", nothing)
    if t == "integer"
        v = get(d, "value", nothing)
        v isa AbstractString || throw(ArgumentError(
            "an exact integer is stored as a decimal string, not $(typeof(v))"))
        return parse(BigInt, v)
    elseif t == "rational"
        n = get(d, "numerator", nothing)
        m = get(d, "denominator", nothing)
        (n isa AbstractString && m isa AbstractString) || throw(ArgumentError(
            "an exact rational is stored as numerator and denominator strings"))
        num = parse(BigInt, n)
        den = parse(BigInt, m)
        den == 0 && throw(ZeroDenominator("stored rational"))
        return num // den
    end
    throw(ArgumentError("unknown exact representation $(repr(t))"))
end

"""
    numeric_contract() -> Dict{String,Any}

The cross-language and storage contract, as data, so that documentation and
tests quote the same text rather than drifting apart.

1. Exact stays exact: counts become arbitrary-precision integers, and every
   exact field is emitted as decimal strings.
2. Exact rationals are normalised, denominator positive, zero denominator
   refused.
3. Approximations are tagged with their engine, precision and rounding mode;
   they are never promoted to "exact" by any later step.
4. Display values are rounded separately and marked `display_rounded`.
5. Unsupported representations are rejected explicitly - NaN, infinities,
   fractional counts, float counts above 2^53-1, integers outside JSON's exact
   range emitted as numbers.
"""
numeric_contract() = Dict{String,Any}(
    "version" => POLICY_VERSION,
    "integer" => Dict{String,Any}(
        "representation" => "arbitrary-precision integer",
        "json"           => "decimal string in 'value' (never a JSON number)",
        "range"          => "unbounded, subject to max_digits",
        "refused"        => ["fractional counts", "negative counts", "NaN", "Infinity",
                             "float counts with |x| > 2^53-1", "Bool"],
    ),
    "rational" => Dict{String,Any}(
        "representation" => "Rational{BigInt}, lowest terms, positive denominator",
        "json"           => "'numerator' and 'denominator' decimal strings, plus 'value' as n/d",
        "refused"        => ["zero denominator", "numerator or denominator above max_digits"],
    ),
    "approximation" => Dict{String,Any}(
        "representation" => "BigFloat (MPFR) or binary64",
        "json"           => "'value' as a decimal string, with 'precision_bits' and 'rounding'",
        "refused"        => ["NaN", "Infinity", "requesting it in exact mode"],
    ),
    "display" => Dict{String,Any}(
        "representation" => "fixed-point decimal string, half-to-even",
        "json"           => "'display', with 'display_rounded' => true unless the value is an exact integer",
    ),
    "json_number_boundary" => "values outside -(2^53-1) .. 2^53-1 are never written as JSON numbers",
)

end # module ExactNumeric
