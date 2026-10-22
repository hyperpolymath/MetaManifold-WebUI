# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# The optional, validated statistics layer (issue #1).
#
# This module is descriptive and exact-arithmetic in scope. It deliberately does
# not contain a hypothesis test, a p-value, a confidence interval or a model fit
# yet: the issue that asks for those requires method-specific acceptance
# tolerances and independent scientific review first, and shipping an unvalidated
# test is worse than shipping none. What it does contain is a small, fixed
# catalogue of summaries (/`METHOD_CATALOGUE`/), each with its supported response
# type, numeric modes, uncertainty statement and limitations published alongside
# the code, so a caller can see what is and is not claimed.
#
# Three properties run through everything here:
#
#   * Numbers are never guessed. A statistic that cannot be computed exactly on
#     the requested terms fails with a code, and the failure is stored with the
#     record: `zero_denominator`, `resource_limit`, `invalid_input`,
#     `unsupported_numeric_mode`, `depth_exceeds_library`.
#   * Results are immutable and linked. Every analysis is content-addressed and
#     written once; re-running with different settings produces a *new* record
#     that names the input fingerprint it came from, never an overwrite.
#   * Provenance travels with the numbers: method version, numeric policy,
#     parameters, software and MPFR versions, and the input fingerprint.
#
# The layer is optional. Nothing in `DiversityMetrics`, `Analysis` or the
# pipeline calls it, so existing behaviour is unchanged when it is not selected.

module ExactStatistics

using Dates, JSON3
using ..ExactNumeric
using ..ExactNumeric: NUMERIC_MODES, NumericPolicy, NumericError, InvalidNumericInput,
                      ZeroDenominator, NumericLimit, ResourceLimit, UnsupportedNumericMode,
                      error_code, exact_count, exact_counts, exact_ratio, check_limit,
                      exact_json, approx_json, parse_exact_json, display_string,
                      arithmetic_bits, policy_dict, approximate_value
using ..Canonical: jcs_bytes, jcs_sha256

export METHOD_VERSION, RECORD_SCHEMA, METHOD_CATALOGUE, method_catalogue,
       GLOBAL_LIMITATIONS, analyse, analysis_id, record_directory, write_record,
       read_record, list_records, RecordConflict, input_fingerprint,
       simpson_index, shannon_index, expected_richness, proportion_value

# Version of the method catalogue and the shape of a result. A change to what a
# method computes bumps this, and stored records keep the version they were made
# under.
const METHOD_VERSION = "1.0.0"

# Schema tag of a stored record, distinct from the method version so that the
# storage layout can evolve without pretending an analysis changed.
const RECORD_SCHEMA = "metamanifold.statistics/1"

# Rarefaction is exact but not free: the expectation is a product of `depth`
# rational factors per feature. Both bounds are refusals, not truncations.
const MAX_RAREFACTION_DEPTH = 10_000
const MAX_RAREFACTION_WORK  = 5_000_000

## ---------------------------------------------------------------------------
## What this layer claims, method by method
## ---------------------------------------------------------------------------

"""
    METHOD_CATALOGUE

The bounded catalogue approved for this layer. Read-only: it is published as
data so the server can list it, the documentation can quote it, and a test can
check that every method named here actually exists.

Each entry records the response type it accepts, whether it needs study-design
information, which numeric modes it supports, which of its fields are exact and
which are approximations, its uncertainty and multiple-testing statement, and
its limitations. A method that cannot state those things does not belong here.
"""
const METHOD_CATALOGUE = Dict{String,Any}(

    "summarise.counts" => Dict{String,Any}(
        "version"      => METHOD_VERSION,
        "title"        => "Per-sample and per-feature read-count summary",
        "description"  => "Exact totals, observed richness, zero-count features and mean " *
                          "reads per feature, per sample and per feature, over the supplied " *
                          "count matrix.",
        "response"     => "non-negative integer counts; samples x features",
        "design_required" => false,
        "numeric_modes"   => collect(NUMERIC_MODES),
        "exact_fields"     => ["counts", "totals", "richness", "prevalence"],
        "approximate_fields" => ["mean reads per feature (exact in exact mode)"],
        "options"      => Dict{String,Any}(),
        "uncertainty"  => "None. These are census summaries of the counts supplied, not " *
                          "estimates of a population quantity, so there is no sampling " *
                          "model to attach an interval to.",
        "effect_size"  => "None: no comparison between groups is made.",
        "multiple_testing" => "Not applicable: no test is performed.",
        "limitations"  => [
            "A mean over features weights every feature equally, which has no biological " *
            "interpretation unless the features are a meaningful sampling unit.",
            "Zeros are counted, not interpreted. A zero can mean absence, failure to " *
            "amplify, or a read lost to depth; this method cannot tell them apart.",
        ],
    ),

    "describe.alpha" => Dict{String,Any}(
        "version"      => METHOD_VERSION,
        "title"        => "Alpha diversity summary (richness, Simpson, Shannon, evenness)",
        "description"  => "Observed richness, the Gini-Simpson index, the Shannon index and " *
                          "Pielou evenness, per sample and for the pooled corpus.",
        "response"     => "non-negative integer counts; samples x features",
        "design_required" => false,
        "numeric_modes"   => collect(NUMERIC_MODES),
        "exact_fields"     => ["richness"],
        "approximate_fields" => ["Simpson index in float64/bigfloat modes (exact rational in " *
                          "exact mode)", "Shannon index (never exact)", "Pielou evenness (never exact)"],
        "options"      => Dict{String,Any}(),
        "uncertainty"  => "None. Indices are computed from the observed counts; no interval " *
                          "is estimated, because no sampling model is assumed.",
        "effect_size"  => "None: no comparison between groups is made.",
        "multiple_testing" => "Not applicable: no test is performed.",
        "limitations"  => [
            "Indices are depth-sensitive unless the counts are rarefied first; this single " *
            "sample summary does not normalise for library size, and comparing raw-index " *
            "values across samples of different depth is not valid.",
            "The Shannon index and Pielou evenness are transcendental and have no exact " *
            "value: they are tagged `approximation` and refused outright in exact mode.",
            "Pielou evenness is undefined for a sample with fewer than two observed " *
            "features, and is reported as unsuccessful there rather than as zero or one.",
            "Simpson here is the Gini-Simpson complement 1 - sum(p_i^2) on observed " *
            "relative abundances. It is not an unbiased estimator of the population " *
            "index, and no correction is applied.",
        ],
    ),

    "describe.proportions" => Dict{String,Any}(
        "version"      => METHOD_VERSION,
        "title"        => "Per-sample and corpus read proportions",
        "description"  => "Each feature's share of its sample and of the whole corpus.",
        "response"     => "non-negative integer counts; samples x features",
        "design_required" => false,
        "numeric_modes"   => collect(NUMERIC_MODES),
        "exact_fields"     => ["counts", "sample totals", "corpus totals"],
        "approximate_fields" => ["proportions in float64/bigfloat modes (exact rational in " *
                          "exact mode)"],
        "options"      => Dict{String,Any}(),
        "uncertainty"  => "None: a proportion of the observed reads is a census quantity.",
        "effect_size"  => "None: no comparison between groups is made.",
        "multiple_testing" => "Not applicable: no test is performed.",
        "limitations"  => [
            "A proportion of reads is not an estimate of an organism's relative abundance; " *
            "it is confounded by copy number, extraction and amplification efficiency.",
            "A sample with zero reads has no proportions. It is reported as unsuccessful " *
            "for that sample, never as all-zero rows.",
            "Proportions are compositional: they sum to one, so they are not independent " *
            "of each other and must not be used as independent response variables.",
        ],
    ),

    "rarefaction.expected_richness" => Dict{String,Any}(
        "version"      => METHOD_VERSION,
        "title"        => "Exact expected richness at a given rarefied depth",
        "description"  => "Hurlbert's (1971) expected number of observed features in a " *
                          "subsample of `depth` reads drawn without replacement from each " *
                          "sample. Exact rational in exact mode; no resampling is performed.",
        "response"     => "non-negative integer counts; samples x features",
        "design_required" => false,
        "numeric_modes"   => collect(NUMERIC_MODES),
        "exact_fields"     => ["expected richness in exact mode"],
        "approximate_fields" => ["expected richness in float64/bigfloat modes"],
        "options"      => Dict{String,Any}(
            "depth" => Dict{String,Any}(
                "required" => true,
                "type"     => "integer",
                "range"    => "1 .. $(MAX_RAREFACTION_DEPTH), and no more than the sample's library size",
                "description" => "reads per subsample",
            ),
        ),
        "uncertainty"  => "None beyond the subsampling itself: this is the exact expectation " *
                          "over subsamples, not an interval and not a resampled estimate. It " *
                          "carries no Monte Carlo error, which is the point of computing it " *
                          "in closed form.",
        "effect_size"  => "None: no comparison between groups is made.",
        "multiple_testing" => "Not applicable: no test is performed.",
        "limitations"  => [
            "The expectation assumes reads are sampled without replacement from the " *
            "observed library and that the observed library is the whole community. It " *
            "does not correct for unobserved species, PCR bias or sequencing error.",
            "Rarefaction discards reads. Standardising depth does not make indices " *
            "comparable across samples that differ in richness, and an expected value is " *
            "not an observed value.",
            "A depth above a sample's library size is refused rather than clamped.",
            "Exact mode can exceed `max_digits` at large depth; the failure is explicit " *
            "and says so, and no approximation is substituted.",
        ],
    ),

    "compare.taxon_ratio" => Dict{String,Any}(
        "version"      => METHOD_VERSION,
        "title"        => "Exact read-count ratio between two features",
        "description"  => "The ratio of two named features' total counts, corpus-wide and " *
                          "per sample.",
        "response"     => "non-negative integer counts; samples x features",
        "design_required" => false,
        "numeric_modes"   => collect(NUMERIC_MODES),
        "exact_fields"     => ["counts", "ratio in exact mode"],
        "approximate_fields" => ["ratio in float64/bigfloat modes"],
        "options"      => Dict{String,Any}(
            "numerator" => Dict{String,Any}("required" => true, "type" => "feature name"),
            "denominator" => Dict{String,Any}("required" => true, "type" => "feature name"),
        ),
        "uncertainty"  => "None: a ratio of observed counts, with no interval estimated.",
        "effect_size"  => "The ratio is a descriptive fold-ratio, not a tested effect. " *
                          "No null value is assumed and no significance is implied.",
        "multiple_testing" => "Not applicable: no test is performed.",
        "limitations"  => [
            "A ratio of read counts is not a ratio of abundances; it inherits every bias in " *
            "the counts it is built from.",
            "A zero denominator is refused for the scope in which it occurs (corpus or " *
            "sample); it is never replaced by a pseudocount here.",
            "Two features chosen because their ratio looks interesting produce a biased " *
            "summary; this method does not know how the pair was selected.",
        ],
    ),
)

"""
    method_catalogue() -> Dict{String,Any}

The catalogue itself. Callers must treat it as read-only.
"""
method_catalogue() = METHOD_CATALOGUE

"""
Global statements attached to every record, so no result can be read as claiming
more than the layer supports.
"""
const GLOBAL_LIMITATIONS = [
    "This layer produces descriptive summaries only. It performs no hypothesis test, " *
    "estimates no p-value, confidence interval or effect size, and makes no statement " *
    "about significance.",
    "Exact arithmetic removes representation error and nothing else. Measurement error, " *
    "sampling uncertainty, model misspecification and biological bias are all unaffected.",
    "Higher precision is not exactness. Values tagged `approximation` are approximations " *
    "at the stated precision and rounding mode, and no later step promotes them.",
    "Counts are read from the results database as binary64; values above 2^53-1 cannot be " *
    "trusted to be the integers they came from and are refused.",
]

## ---------------------------------------------------------------------------
## Failures, warnings and the per-entry state machine
## ---------------------------------------------------------------------------

mutable struct _Context
    policy   :: NumericPolicy
    warnings :: Vector{Dict{String,Any}}
    failures :: Vector{Dict{String,Any}}
end

_warn!(ctx::_Context, code::String, message::String) =
    push!(ctx.warnings, Dict{String,Any}("code" => code, "message" => message))

_fail!(ctx::_Context, code::String, scope::String, message::String) =
    push!(ctx.failures, Dict{String,Any}("code" => code, "scope" => scope, "message" => message))

"""
    _entry(ctx, scope, f) -> Dict{String,Any}

Build one named entry of a result, converting a numeric refusal into an explicit
unsuccessful entry that names its scope and carries the refusal's stable code.
A per-entry failure does not stop the rest of the table: a survey with one
zero-read sample still reports the others, and the failed sample is visible.
"""
function _entry(ctx::_Context, scope::String, f::Function)
    try
        d = f()
        d = d isa Dict{String,Any} ? d : Dict{String,Any}(String(k) => v for (k, v) in d)
        haskey(d, "status") || (d["status"] = "complete")
        return d
    catch e
        e isa NumericError || rethrow()
        message = sprint(showerror, e)
        _fail!(ctx, error_code(e), scope, message)
        return Dict{String,Any}("status"  => "unsuccessful",
                                "code"    => error_code(e),
                                "message" => message)
    end
end

"""
    _field(ctx, scope, f)

One field of an entry, allowed to fail on its own. A sample whose Shannon index
is unsupported in exact mode still reports its exact richness and Simpson index;
the unsupported field carries its code and message, and the entry's own status
becomes `"partial"`.
"""
function _field(ctx::_Context, scope::String, f::Function)
    try
        return f()
    catch e
        e isa NumericError || rethrow()
        message = sprint(showerror, e)
        _fail!(ctx, error_code(e), scope, message)
        return Dict{String,Any}("status"  => "unsuccessful",
                                "code"    => error_code(e),
                                "message" => message)
    end
end

_is_unsuccessful(x) = x isa AbstractDict && get(x, "status", nothing) == "unsuccessful"

## ---------------------------------------------------------------------------
## Plain-data conversion
## ---------------------------------------------------------------------------

"""
Options travel into a stored record and therefore into a content hash. They are
accepted only in the JSON shapes the API can send back, and anything else is
refused rather than stringified: an option that cannot be represented is a
configuration mistake, not something to paper over.
"""
_plain(::Nothing) = nothing
_plain(x::Bool) = x
_plain(x::Integer) = begin
    x isa Bool && throw(ArgumentError("a Bool is not an integer option"))
    (typemin(Int) <= x <= typemax(Int)) || throw(ArgumentError(
        "the integer option $x is outside the range a stored record can carry"))
    Int(x)
end
_plain(x::AbstractFloat) = begin
    isfinite(x) || throw(ArgumentError("the option $x is not finite"))
    y = Float64(x)
    # A BigFloat beyond binary64's range would become Inf here, so it is refused
    # rather than stored as an infinity a consumer cannot read back.
    isfinite(y) || throw(ArgumentError(
        "the option $x is outside the range a stored binary64 can carry"))
    y
end
_plain(x::AbstractString) = String(x)
_plain(x::AbstractVector) = Any[_plain(v) for v in x]
_plain(x::AbstractDict) = Dict{String,Any}(String(k) => _plain(v) for (k, v) in x)
_plain(x) = throw(ArgumentError("unsupported option type $(typeof(x))"))

# JSON reads objects as JSON3.Object, which is not an AbstractDict; convert the
# stored document back to plain data so the rest of the module has one shape.
_plain_json(::Nothing) = nothing
_plain_json(x::Bool) = x
_plain_json(x::Real) = x
_plain_json(x::AbstractString) = String(x)
_plain_json(x::AbstractVector) = Any[_plain_json(v) for v in x]
_plain_json(x::AbstractDict) = Dict{String,Any}(String(k) => _plain_json(v) for (k, v) in x)
_plain_json(x::JSON3.Object) = Dict{String,Any}(String(k) => _plain_json(v) for (k, v) in x)
_plain_json(x) = string(x)

_sum_big(v) = foldl(+, v; init = BigInt(0))

## ---------------------------------------------------------------------------
## The statistics themselves
## ---------------------------------------------------------------------------

"""
    simpson_index(counts) -> Rational{BigInt}

The Gini-Simpson complement `1 - sum(p_i^2)` on observed relative abundances,
as an exact rational. Throws `ZeroDenominator` when the counts are all zero.
"""
function simpson_index(counts::AbstractVector{<:Integer})
    total = _sum_big(counts)
    total == 0 && throw(ZeroDenominator("Simpson index of a sample with zero reads"))
    squares = foldl(+, (BigInt(c)^2 for c in counts); init = BigInt(0))
    return 1 - squares // (total^2)
end

"""
    proportion_value(count, total) -> Rational{BigInt}

`count/total` exactly. A zero total throws `ZeroDenominator`.
"""
function proportion_value(count::Integer, total::Integer)
    return exact_ratio(count, total; what = "proportion of a zero-read total")
end

# The approximate helpers below are shared by the public functions and the
# per-entry closures. They all refuse a zero total explicitly: in floating point
# 0/0 is NaN, and a NaN arriving at the serialiser is a much worse failure mode
# than a named refusal, because it survives arithmetic and only fails at the
# boundary. Every one of them is called inside an `approximate_value` block, so
# its BigFloats are at the requested precision.

_require_positive_total(total, what::String) =
    total == 0 ? throw(ZeroDenominator(what)) : total

function _simpson_approx(counts, total)
    _require_positive_total(total, "Simpson index of a sample with zero reads")
    n = BigFloat(total)
    s = BigFloat(0)
    for c in counts
        c == 0 && continue
        p = BigFloat(BigInt(c)) / n
        s += p * p
    end
    return 1 - s
end

function _shannon_approx(counts, total)
    _require_positive_total(total, "Shannon index of a sample with zero reads")
    n = BigFloat(total)
    h = BigFloat(0)
    for c in counts
        c == 0 && continue
        p = BigFloat(BigInt(c)) / n
        h -= p * log(p)
    end
    return h
end

function _evenness_approx(counts, total, richness::Integer)
    richness >= 2 || throw(InvalidNumericInput("Pielou evenness",
        "evenness needs at least two observed features, got $richness"))
    _require_positive_total(total, "Pielou evenness of a sample with zero reads")
    return _shannon_approx(counts, total) / log(BigFloat(richness))
end

function _proportion_approx(count::Integer, total; what::String = "proportion of a zero-read total")
    _require_positive_total(total, what)
    return BigFloat(BigInt(count)) / BigFloat(total)
end

function _mean_approx(total, n::Integer)
    n == 0 && throw(ZeroDenominator("mean over zero items"))
    return BigFloat(total) / BigFloat(n)
end

"""
    shannon_index(counts, policy) -> BigFloat

`-sum(p_i log p_i)` at the policy's working precision. Transcendental, so never
exact; in exact mode this throws `UnsupportedNumericMode` rather than returning a
number the caller did not ask for.
"""
function shannon_index(counts::AbstractVector{<:Integer}, policy::NumericPolicy)
    total = _sum_big(counts)
    return approximate_value(policy; what = "Shannon index") do
        _shannon_approx(counts, total)
    end
end

"""
    expected_richness(counts, depth; policy) -> Union{Rational{BigInt},BigFloat}

Hurlbert's (1971) expected number of features in a subsample of `depth` reads
drawn without replacement:

    E[S_m] = sum_i (1 - C(N - n_i, m) / C(N, m))

computed as a product of `m` exact rational factors per feature, so no binomial
coefficient is ever materialised. `depth` must be at least 1 and at most the
library size; a larger depth throws `ArgumentError` (the caller should refuse the
sample explicitly rather than let it be clamped). In exact mode the result is an
exact rational, and exceeding `max_digits` throws `NumericLimit`.
"""
function expected_richness(counts::AbstractVector{<:Integer}, depth::Integer;
                           policy::NumericPolicy = NumericPolicy())
    (depth isa Bool || !(depth isa Integer) || depth < 1) && throw(ArgumentError(
        "rarefaction depth must be an integer of at least 1, not $depth"))
    depth <= MAX_RAREFACTION_DEPTH || throw(ResourceLimit(
        "a rarefaction depth of $depth", MAX_RAREFACTION_DEPTH))
    total = _sum_big(counts)
    depth <= total || throw(ArgumentError(
        "rarefaction depth $depth exceeds the library size $total"))
    m = Int(depth)

    if policy.mode === :exact
        s = zero(Rational{BigInt})
        for c in counts
            c == 0 && continue
            p = one(Rational{BigInt})
            for k in 0:(m - 1)
                p *= (total - BigInt(c) - k) // (total - k)
                # A zero factor (m > N - n_i) makes the probability zero for this
                # feature and stays zero, which is the correct value; the product
                # is checked against the digit bound as it grows.
                k % 128 == 0 && check_limit(p, policy; what = "expected richness")
            end
            s += 1 - p
            check_limit(s, policy; what = "expected richness")
        end
        return s
    end

    return approximate_value(policy; what = "expected richness") do
        n = BigFloat(total)
        s = BigFloat(0)
        for c in counts
            c == 0 && continue
            p = BigFloat(1)
            for k in 0:(m - 1)
                available = n - BigFloat(BigInt(c)) - BigFloat(k)
                if available <= 0
                    p = BigFloat(0)
                    break
                end
                p *= available / (n - BigFloat(k))
            end
            s += 1 - p
        end
        s
    end
end

## ---------------------------------------------------------------------------
## Value rendering: exact in exact mode, approximation otherwise
## ---------------------------------------------------------------------------

# In float64 mode an approximation is reported as binary64 (the type the rest of
# the application uses) but computed at 53 bits first, so the value is the
# correctly-rounded result at that width rather than a differently-rounded one.
_render_approx(x::BigFloat, policy::NumericPolicy) =
    policy.mode === :float64 ? approx_json(Float64(x); policy = policy) : approx_json(x; policy = policy)

"""
    _statistic(ctx, exact_f, approx_f, what)

One derived value, rendered according to the policy. In exact mode the exact
closure runs and its `Rational`/`Integer` is tagged exact. In the approximate
modes the approximate closure runs at the policy's precision, tagged as an
approximation. Neither path is used to rescue the other: an exact-mode refusal
is a refusal, and an approximation is never relabelled exact.
"""
function _statistic(ctx::_Context, exact_f::Function, approx_f::Function, what::String)
    if ctx.policy.mode === :exact
        return exact_json(exact_f(); policy = ctx.policy)
    end
    v = approximate_value(ctx.policy; what = what) do
        approx_f()
    end
    return _render_approx(v, ctx.policy)
end

_exact_count_json(ctx::_Context, x::Integer) = exact_json(BigInt(x); policy = ctx.policy)

## ---------------------------------------------------------------------------
## The methods
## ---------------------------------------------------------------------------

function _sample_entry(ctx::_Context, sample::String, row::AbstractVector{BigInt}, nfeat::Int)
    return _entry(ctx, "sample:$sample", () -> begin
        total = _sum_big(row)
        d = Dict{String,Any}()
        d["total_reads"] = _exact_count_json(ctx, total)
        d["richness"]    = _exact_count_json(ctx, count(!iszero, row))
        d["zero_count_features"] = _exact_count_json(ctx, count(iszero, row))
        d["mean_per_feature"] = _statistic(ctx,
            () -> exact_ratio(total, BigInt(nfeat); policy = ctx.policy,
                              what = "mean reads per feature"),
            () -> _mean_approx(total, nfeat),
            "mean reads per feature")
        d
    end)
end

function _feature_entry(ctx::_Context, feature::String, column::AbstractVector{BigInt})
    return _entry(ctx, "feature:$feature", () -> begin
        total = _sum_big(column)
        ns = length(column)
        d = Dict{String,Any}()
        d["total_reads"] = _exact_count_json(ctx, total)
        d["prevalence"]  = _exact_count_json(ctx, count(!iszero, column))
        d["mean_per_sample"] = _statistic(ctx,
            () -> exact_ratio(total, BigInt(ns); policy = ctx.policy,
                              what = "mean reads per sample"),
            () -> _mean_approx(total, ns),
            "mean reads per sample")
        d
    end)
end

function _describe_counts(ctx::_Context, exact::Matrix{BigInt},
                          samples::Vector{String}, features::Vector{String}, opts)
    ns, nf = size(exact)
    result = Dict{String,Any}()
    result["samples"]  = Any[_sample_entry(ctx, samples[i], view(exact, i, :), nf) for i in 1:ns]
    result["features"] = Any[_feature_entry(ctx, features[j], view(exact, :, j)) for j in 1:nf]
    result["corpus"] = _entry(ctx, "corpus", () -> begin
        total = sum(exact)
        d = Dict{String,Any}()
        d["total_reads"] = _exact_count_json(ctx, total)
        d["observed_features"] = _exact_count_json(ctx, count(!iszero, vec(sum(exact; dims = 1))))
        d["samples"]  = _exact_count_json(ctx, ns)
        d["features"] = _exact_count_json(ctx, nf)
        d
    end)
    return result
end

function _alpha_entry(ctx::_Context, label::String, counts::AbstractVector{BigInt})
    return _entry(ctx, "sample:$label", () -> begin
        total = _sum_big(counts)
        rich = count(!iszero, counts)
        d = Dict{String,Any}()
        d["total_reads"] = _exact_count_json(ctx, total)
        d["richness"]    = _exact_count_json(ctx, rich)
        # A zero-read sample has no index value at all: the fields below throw
        # ZeroDenominator and are stored as unsuccessful, while the exact counts
        # above remain available.
        d["simpson"] = _field(ctx, "sample:$label simpson", () -> _statistic(ctx,
            () -> simpson_index(counts),
            () -> _simpson_approx(counts, total),
            "Simpson index"))
        d["shannon"] = _field(ctx, "sample:$label shannon", () -> _statistic(ctx,
            () -> throw(UnsupportedNumericMode("Shannon index", :exact,
                "the Shannon index involves logarithms and has no exact rational value")),
            () -> _shannon_approx(counts, total),
            "Shannon index"))
        d["evenness"] = _field(ctx, "sample:$label evenness", () -> _statistic(ctx,
            () -> throw(UnsupportedNumericMode("Pielou evenness", :exact,
                "Pielou evenness is a ratio of logarithms and has no exact rational value")),
            () -> _evenness_approx(counts, total, rich),
            "Pielou evenness"))
        d["status"] = any(_is_unsuccessful, (d["simpson"], d["shannon"], d["evenness"])) ?
                      "partial" : "complete"
        d
    end)
end

function _describe_alpha(ctx::_Context, exact::Matrix{BigInt},
                         samples::Vector{String}, features::Vector{String}, opts)
    ns, nf = size(exact)
    result = Dict{String,Any}()
    result["samples"] = Any[_alpha_entry(ctx, samples[i], view(exact, i, :)) for i in 1:ns]
    result["corpus"]  = _alpha_entry(ctx, "corpus (all samples pooled)", vec(sum(exact; dims = 1)))
    result["index_definitions"] = Dict{String,Any}(
        "richness" => "number of features with a non-zero count",
        "simpson"  => "1 - sum(p_i^2) on observed relative abundances (Gini-Simpson complement)",
        "shannon"  => "-sum(p_i log p_i)",
        "evenness" => "Shannon / log(richness), defined only for richness >= 2",
    )
    return result
end

function _describe_proportions(ctx::_Context, exact::Matrix{BigInt},
                               samples::Vector{String}, features::Vector{String}, opts)
    ns, nf = size(exact)
    result = Dict{String,Any}()
    samples_out = Vector{Any}(undef, ns)
    for i in 1:ns
        row = view(exact, i, :)
        samples_out[i] = _entry(ctx, "sample:$(samples[i])", () -> begin
            total = _sum_big(row)
            d = Dict{String,Any}()
            d["total_reads"] = _exact_count_json(ctx, total)
            d["proportions"] = Any[
                _field(ctx, "sample:$(samples[i]) feature:$(features[j])", () -> begin
                    c = BigInt(row[j])
                    _statistic(ctx,
                        () -> exact_ratio(c, total; policy = ctx.policy,
                                          what = "proportion over the zero-read sample " *
                                                 "'$(samples[i])'"),
                        () -> _proportion_approx(c, total),
                        "proportion")
                end) for j in 1:nf
            ]
            d["status"] = any(_is_unsuccessful, d["proportions"]) ? "partial" : "complete"
            d
        end)
    end
    result["samples"] = samples_out
    result["features"] = Any[features[j] for j in 1:nf]
    feature_totals = [sum(view(exact, :, j)) for j in 1:nf]
    corpus_total = sum(exact)
    result["corpus"] = _entry(ctx, "corpus", () -> begin
        d = Dict{String,Any}()
        d["total_reads"] = _exact_count_json(ctx, corpus_total)
        d["proportions"] = Any[
            _field(ctx, "corpus feature:$(features[j])", () -> _statistic(ctx,
                () -> exact_ratio(feature_totals[j], corpus_total; policy = ctx.policy,
                                  what = "corpus proportion of a zero-read corpus"),
                () -> _proportion_approx(feature_totals[j], corpus_total),
                "proportion")) for j in 1:nf
        ]
        d["status"] = any(_is_unsuccessful, d["proportions"]) ? "partial" : "complete"
        d
    end)
    return result
end

function _rarefaction_entry(ctx::_Context, label::String, row::AbstractVector{BigInt}, depth::Int)
    return _entry(ctx, "sample:$label", () -> begin
        total = _sum_big(row)
        if depth > total
            message = "rarefaction depth $depth exceeds the library of $total reads in " *
                      "sample '$label'"
            _fail!(ctx, "depth_exceeds_library", "sample:$label", message)
            return Dict{String,Any}("status"        => "unsuccessful",
                                    "code"          => "depth_exceeds_library",
                                    "message"       => message,
                                    "library_reads" => _exact_count_json(ctx, total),
                                    "depth"         => depth)
        end
        d = Dict{String,Any}()
        d["library_reads"] = _exact_count_json(ctx, total)
        d["depth"] = depth
        d["expected_richness"] = _statistic(ctx,
            () -> expected_richness(row, depth; policy = ctx.policy),
            () -> _expected_richness_approx(row, total, depth),
            "expected richness at depth $depth")
        d
    end)
end

function _expected_richness_approx(counts, total::BigInt, m::Int)
    # Evaluated inside the policy's precision block by `_statistic`; every value
    # here is therefore a BigFloat at the requested precision.
    n = BigFloat(total)
    s = BigFloat(0)
    for c in counts
        c == 0 && continue
        p = BigFloat(1)
        for k in 0:(m - 1)
            available = n - BigFloat(BigInt(c)) - BigFloat(k)
            if available <= 0
                p = BigFloat(0)
                break
            end
            p *= available / (n - BigFloat(k))
        end
        s += 1 - p
    end
    s
end

function _expected_richness_method(ctx::_Context, exact::Matrix{BigInt},
                                   samples::Vector{String}, features::Vector{String}, opts)
    depth = get(opts, "depth", nothing)
    (depth isa Integer && !(depth isa Bool)) || throw(ArgumentError(
        "rarefaction.expected_richness requires an integer option 'depth'"))
    depth >= 1 || throw(ArgumentError("option 'depth' must be at least 1, not $depth"))
    depth <= MAX_RAREFACTION_DEPTH || throw(ResourceLimit(
        "a rarefaction depth of $depth", MAX_RAREFACTION_DEPTH))
    work = BigInt(size(exact, 1)) * BigInt(size(exact, 2)) * BigInt(depth)
    work <= MAX_RAREFACTION_WORK || throw(ResourceLimit(
        "a rarefaction depth of $depth over $(size(exact, 1)) samples and " *
        "$(size(exact, 2)) features ($(work) factor-steps)", MAX_RAREFACTION_WORK))
    ns = size(exact, 1)
    return Dict{String,Any}(
        "depth" => Int(depth),
        "samples" => Any[_rarefaction_entry(ctx, samples[i], view(exact, i, :), Int(depth)) for i in 1:ns],
        "note" => "Exact expectation over subsamples drawn without replacement; no resampling " *
                  "and no seed is involved, so there is no Monte Carlo error to report.",
    )
end

function _taxon_ratio_method(ctx::_Context, exact::Matrix{BigInt},
                             samples::Vector{String}, features::Vector{String}, opts)
    num_name = get(opts, "numerator", nothing)
    den_name = get(opts, "denominator", nothing)
    (num_name isa AbstractString && den_name isa AbstractString) || throw(ArgumentError(
        "compare.taxon_ratio requires string options 'numerator' and 'denominator'"))
    num_name = String(num_name); den_name = String(den_name)
    num_name == den_name && throw(ArgumentError(
        "compare.taxon_ratio needs two different features, both are '$num_name'"))
    ni = findfirst(==(num_name), features)
    di = findfirst(==(den_name), features)
    isnothing(ni) && throw(ArgumentError("feature '$num_name' is not in this table"))
    isnothing(di) && throw(ArgumentError("feature '$den_name' is not in this table"))

    ns = size(exact, 1)
    num_totals = vec(sum(exact; dims = 1))
    ratio_for = (scope, n, d) -> _entry(ctx, scope, () -> Dict{String,Any}(
        "numerator_total"   => _exact_count_json(ctx, n),
        "denominator_total" => _exact_count_json(ctx, d),
        "ratio" => _statistic(ctx,
            () -> exact_ratio(n, d; policy = ctx.policy, what = "ratio in $scope"),
            () -> _proportion_approx(n, d; what = "ratio with a zero denominator"),
            "ratio"),
    ))

    result = Dict{String,Any}()
    result["numerator"]   = num_name
    result["denominator"] = den_name
    result["corpus"] = ratio_for("corpus", num_totals[ni], num_totals[di])
    result["samples"] = Any[
        ratio_for("sample:$(samples[i])", exact[i, ni], exact[i, di]) for i in 1:ns
    ]
    return result
end

const _METHOD_RUNNERS = Dict{String,Function}(
    "summarise.counts"               => _describe_counts,
    "describe.alpha"                 => _describe_alpha,
    "describe.proportions"           => _describe_proportions,
    "rarefaction.expected_richness"  => _expected_richness_method,
    "compare.taxon_ratio"            => _taxon_ratio_method,
)

## ---------------------------------------------------------------------------
## Diagnostics and provenance
## ---------------------------------------------------------------------------

function _diagnostics(exact, samples::Vector{String}, features::Vector{String}, ctx::_Context)
    ns, nf = size(exact)
    sample_totals  = [_sum_big(view(exact, i, :)) for i in 1:ns]
    feature_totals = [_sum_big(view(exact, :, j)) for j in 1:nf]
    largest = isempty(exact) ? BigInt(0) : maximum(exact)
    return Dict{String,Any}(
        "numeric_mode" => String(ctx.policy.mode),
        "arithmetic_precision_bits" => ctx.policy.mode === :exact ? nothing :
                                      arithmetic_bits(ctx.policy),
        "max_digits" => ctx.policy.max_digits,
        "counts" => Dict{String,Any}(
            "samples"  => ns,
            "features" => nf,
            "total_reads" => string(_sum_big(exact)),
            "largest_count" => string(largest),
            "zero_total_samples" => count(iszero, sample_totals),
            "zero_count_features" => count(iszero, feature_totals),
            "singleton_features" => count(==(BigInt(1)), feature_totals),
        ),
        "duplicate_sample_names"  => length(unique(samples)) != ns,
        "duplicate_feature_names" => length(unique(features)) != nf,
        "unsuccessful_entries" => length(ctx.failures),
    )
end

const PACKAGE_VERSION = let v = try
        pkgversion(parentmodule(@__MODULE__))
    catch
        nothing
    end
    isnothing(v) ? "0.0.0+unknown" : string(v)
end

# Recorded defensively: the MPFR version is a Base internal, and a result must
# not fail to be recorded because a Julia release moved or renamed it.
function _mpfr_version_string()
    if isdefined(Base.MPFR, :MPFR_VERSION_STRING)
        return string(Base.MPFR.MPFR_VERSION_STRING)
    elseif isdefined(Base.MPFR, :version)
        return string(Base.MPFR.version())
    end
    return "unknown"
end

const MPFR_VERSION = try
    _mpfr_version_string()
catch
    "unknown"
end

function _provenance(method::String, policy::NumericPolicy, opts::Dict{String,Any},
                     seed::Integer, source::Dict{String,Any}, fingerprint::String,
                     counts::Tuple{Int,Int})
    return Dict{String,Any}(
        "software" => Dict{String,Any}(
            "name" => "MetaManifold",
            "version" => PACKAGE_VERSION,
            "julia" => string(VERSION),
            "mpfr" => MPFR_VERSION,
            "numeric_policy_version" => policy.version,
        ),
        "method" => Dict{String,Any}("name" => method,
                                     "version" => string(METHOD_CATALOGUE[method]["version"])),
        "numeric_policy" => policy_dict(policy),
        "parameters" => opts,
        "seed" => Int(seed),
        "randomness" => Dict{String,Any}(
            "used" => false,
            "note" => "no method in this catalogue draws a random number; the seed is " *
                      "recorded so a future resampling method is comparable, not because " *
                      "it affects this result",
        ),
        "input" => Dict{String,Any}(
            "fingerprint" => fingerprint,
            "fingerprint_algorithm" => "JCS (RFC 8785) canonical JSON, SHA-256",
            "samples" => counts[1],
            "features" => counts[2],
            "source" => source,
        ),
    )
end

"""
    input_fingerprint(counts, samples, features) -> String

Content address of exactly what was analysed: the ordered sample names, the
ordered feature names, and every count as a decimal string, serialized as
canonical JSON (RFC 8785) and hashed with SHA-256.

Counts are strings, so the fingerprint of a table with a count above 2^53-1 is
still well defined and is not silently shortened by a JSON number.
"""
function input_fingerprint(counts::AbstractMatrix{<:Integer},
                           samples::AbstractVector{<:AbstractString},
                           features::AbstractVector{<:AbstractString})
    size(counts) == (length(samples), length(features)) || throw(ArgumentError(
        "count matrix is $(size(counts, 1)) x $(size(counts, 2)), but " *
        "$(length(samples)) sample and $(length(features)) feature names were given"))
    payload = Dict{String,Any}(
        "schema"   => "metamanifold.statistics.input/1",
        "samples"  => collect(String.(samples)),
        "features" => collect(String.(features)),
        # Column-major flattening of a Julia matrix; the names above pin the axes,
        # so the order is unambiguous.
        "counts"   => [string(BigInt(counts[i])) for i in eachindex(counts)],
    )
    return jcs_sha256(payload)
end

## ---------------------------------------------------------------------------
## The entry point
## ---------------------------------------------------------------------------

"""
    analyse(counts, samples, features; method, policy, options, seed, source)

Run one catalogue method over a samples x features count matrix and return a
record: `status`, `failures`, `warnings`, `results`, `diagnostics`,
`limitations`, `provenance`, plus the method's own output.

`status` is one of:

  * `"complete"` - every entry was computed;
  * `"partial"`  - some entries are explicitly unsuccessful (each carries its own
                   code and message) while others are usable;
  * `"unsuccessful"` - the input could not be converted exactly, or the method
                   refused the request outright. `results` is then empty.

An unknown method, a size mismatch between the matrix and its names, or an
option of the wrong type is an `ArgumentError`: those are request errors, and
returning a record for them would suggest an analysis happened. Data-dependent
refusals are never thrown - they are recorded, because they belong to the result.
"""
function analyse(counts::AbstractMatrix{<:Real},
                 samples::AbstractVector{<:AbstractString},
                 features::AbstractVector{<:AbstractString};
                 method::AbstractString,
                 policy::NumericPolicy = NumericPolicy(),
                 options::AbstractDict = Dict{String,Any}(),
                 seed::Integer = 0,
                 source::AbstractDict = Dict{String,Any}())
    name = String(method)
    entry = get(METHOD_CATALOGUE, name, nothing)
    isnothing(entry) && throw(ArgumentError(
        "unknown statistics method '$name' (supported: " *
        join(sort!(collect(keys(METHOD_CATALOGUE))), ", ") * ")"))
    size(counts) == (length(samples), length(features)) || throw(ArgumentError(
        "count matrix is $(size(counts, 1)) x $(size(counts, 2)), but " *
        "$(length(samples)) sample and $(length(features)) feature names were given"))
    seed isa Bool && throw(ArgumentError("seed must be an integer, not a Bool"))
    abs(seed) <= 2^53 - 1 || throw(ArgumentError(
        "seed $seed is outside the exact-integer range a stored record can carry"))

    opts = _plain(options)
    allowed = entry["options"]
    for k in keys(opts)
        haskey(allowed, k) || throw(ArgumentError(
            "method '$name' has no option '$k' (it accepts: " *
            (isempty(allowed) ? "none" : join(sort!(collect(keys(allowed))), ", ")) * ")"))
    end
    for (k, spec) in allowed
        spec["required"] === true && !haskey(opts, k) && throw(ArgumentError(
            "method '$name' requires option '$k'"))
    end

    sample_names = String.(samples)
    feature_names = String.(features)
    ctx = _Context(policy, Dict{String,Any}[], Dict{String,Any}[])
    limitations = String[GLOBAL_LIMITATIONS...]
    for l in entry["limitations"]
        push!(limitations, String(l))
    end

    exact = nothing
    try
        exact = exact_counts(counts)
    catch e
        e isa NumericError || rethrow()
        # The input itself could not be represented exactly. Every field of the
        # analysis is undefined, so the record is unsuccessful as a whole.
        _fail!(ctx, error_code(e), "input", sprint(showerror, e))
    end

    results = Dict{String,Any}()
    if !isnothing(exact)
        if length(unique(sample_names)) != length(sample_names)
            _warn!(ctx, "duplicate_sample_names",
                   "two or more samples share a name; entries are still keyed by position")
        end
        if length(unique(feature_names)) != length(feature_names)
            _warn!(ctx, "duplicate_feature_names",
                   "two or more features share a name; entries are still keyed by position")
        end
        total = sum(exact)
        total == 0 && _warn!(ctx, "zero_reads",
                             "every count is zero; index values are undefined and are reported " *
                             "as unsuccessful rather than as zero")
        runner = _METHOD_RUNNERS[name]
        try
            results = runner(ctx, exact, sample_names, feature_names, opts)
        catch e
            e isa NumericError || rethrow()
            # A method-level refusal (a work bound, for instance): nothing partial
            # is returned as if it were the answer.
            empty!(results)
            _fail!(ctx, error_code(e), "method", sprint(showerror, e))
        end
    end

    status = if isnothing(exact) || isempty(results)
        "unsuccessful"
    elseif isempty(ctx.failures)
        "complete"
    else
        "partial"
    end

    fingerprint = isnothing(exact) ? nothing :
        input_fingerprint(exact, sample_names, feature_names)

    return Dict{String,Any}(
        "record_schema" => RECORD_SCHEMA,
        "method" => Dict{String,Any}("name" => name, "version" => string(entry["version"])),
        "status" => status,
        "failures" => ctx.failures,
        "warnings" => ctx.warnings,
        "results" => results,
        "diagnostics" => isnothing(exact) ?
            Dict{String,Any}("numeric_mode" => String(policy.mode), "conversion_failed" => true) :
            _diagnostics(exact, sample_names, feature_names, ctx),
        "limitations" => limitations,
        "provenance" => isnothing(exact) ?
            Dict{String,Any}("numeric_policy" => policy_dict(policy),
                             "method" => Dict{String,Any}("name" => name,
                                                          "version" => string(entry["version"]))) :
            _provenance(name, policy, opts, seed,
                        _plain(source), fingerprint, size(exact)),
    )
end

## ---------------------------------------------------------------------------
## Immutable, content-addressed records
## ---------------------------------------------------------------------------

const _ID_RE = Regex("\\A[0-9a-f]{64}\\z")

"""
    record_directory(project_dir) -> String

Where a run's statistics records live: `{projects/.../run}/analysis/statistics`.
"""
record_directory(project_dir::AbstractString) =
    joinpath(project_dir, "analysis", "statistics")

struct RecordConflict <: Exception
    id   :: String
    path :: String
end

Base.showerror(io::IO, e::RecordConflict) = print(io,
    "statistics record $(e.id) already exists at $(e.path) with different content; " *
    "records are write-once, so this is a corrupt or partially written file, not a " *
    "reason to replace a stored analysis")

"""
    analysis_id(record) -> String

The record's content address: SHA-256 over its canonical JSON, excluding
`analysis_id` and `created_at`, so the same analysis of the same input under the
same settings hashes identically whenever and wherever it is recomputed, while a
changed setting, input or method version produces a different id.
"""
function analysis_id(record::AbstractDict)
    payload = Dict{String,Any}()
    for (k, v) in record
        key = String(k)
        (key == "analysis_id" || key == "created_at") && continue
        payload[key] = v
    end
    return jcs_sha256(payload)
end

_iso_timestamp(dt::DateTime) =
    Dates.format(dt, "yyyy-mm-dd") * "T" * Dates.format(dt, "HH:MM:SS") * "Z"

"""
    write_record(project_dir, record; created_at=now(UTC))

Store `record` once, under its content address, and return
`(; id, path, created, bytes)`.

Write-once is the point. An existing file at the same id is never replaced: if
the bytes match, the write is a no-op and `created` is false, so re-running an
unchanged analysis is idempotent; if they differ, the stored file is corrupt or
was written by a different schema under the same id, and `RecordConflict` is
raised rather than an analysis being overwritten. New settings produce a new id
and therefore a new, linked record beside the old one.

The bytes written are canonical JSON, so two machines storing the same analysis
produce byte-identical files. The temporary file is renamed into place, so a
reader never sees a half-written record.
"""
function write_record(project_dir::AbstractString, record::AbstractDict;
                      created_at::DateTime = now(UTC))
    dir = record_directory(project_dir)
    mkpath(dir)
    id = analysis_id(record)
    stored = Dict{String,Any}(String(k) => v for (k, v) in record)
    stored["analysis_id"] = id
    stored["created_at"] = _iso_timestamp(created_at)
    bytes = jcs_bytes(stored)
    path = joinpath(dir, id * ".json")
    if isfile(path)
        existing = read(path)
        existing == bytes && return (; id = id, path = path, created = false, bytes = bytes)
        throw(RecordConflict(id, path))
    end
    tmp = path * ".tmp-" * string(getpid()) * "-" * string(Threads.threadid())
    try
        open(tmp, "w") do io
            write(io, bytes)
        end
        mv(tmp, path)
    finally
        isfile(tmp) && rm(tmp; force = true)
    end
    return (; id = id, path = path, created = true, bytes = bytes)
end

"""
    read_record(project_dir, id) -> Union{Dict{String,Any},Nothing}

The stored record, as plain data, or `nothing` when it does not exist. An id
that is not a SHA-256 hex digest is an `ArgumentError` - the id reaches a
filesystem path, so it is validated rather than trusted.
"""
function read_record(project_dir::AbstractString, id::AbstractString)
    occursin(_ID_RE, id) || throw(ArgumentError("'$id' is not a statistics analysis id"))
    path = joinpath(record_directory(project_dir), String(id) * ".json")
    isfile(path) || return nothing
    return _plain_json(JSON3.read(read(path, String)))
end

"""
    list_records(project_dir) -> Vector{Dict{String,Any}}

Every stored record's summary, newest filename order aside (`readdir` sorted),
each with `analysis_id`, `path`, `method`, `version`, `status`, `created_at` and
`fingerprint`. A file that cannot be parsed is listed with
`"unreadable" => true` rather than skipped: a missing record is a different fact
from a damaged one.
"""
function list_records(project_dir::AbstractString)
    dir = record_directory(project_dir)
    isdir(dir) || return Dict{String,Any}[]
    out = Dict{String,Any}[]
    for file in sort(readdir(dir))
        endswith(file, ".json") || continue
        id = file[1:end-5]
        occursin(_ID_RE, id) || continue
        path = joinpath(dir, file)
        summary = Dict{String,Any}("analysis_id" => id, "path" => path)
        try
            rec = _plain_json(JSON3.read(read(path, String)))
            method = get(rec, "method", Dict{String,Any}())
            summary["method"] = get(method, "name", nothing)
            summary["version"] = get(method, "version", nothing)
            summary["status"] = get(rec, "status", nothing)
            summary["created_at"] = get(rec, "created_at", nothing)
            prov = get(rec, "provenance", Dict{String,Any}())
            inp = prov isa AbstractDict ? get(prov, "input", Dict{String,Any}()) : Dict{String,Any}()
            summary["fingerprint"] = inp isa AbstractDict ? get(inp, "fingerprint", nothing) : nothing
            summary["unreadable"] = false
        catch
            summary["unreadable"] = true
        end
        push!(out, summary)
    end
    return out
end

end # module ExactStatistics
