# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Library-size scaling factors and the offsets count models are fitted with.
#
# The conditions this code is held to were published before it existed
# (docs/statistics/method-conditions/scaling-and-offsets.md). Where this file and that
# document disagree, the document is right and this file is the bug.
#
# Three separate things lived under one name before this module, and the configuration
# accepted all three while the execution path did something else:
#
#   TSS          turned counts into proportions for every method but `nb_glm`, which is
#                the compositional transform issue #16 was written to avoid.
#   CSS, RSS     were aliased to `relative` outright. Under `nb_glm` that fed a count
#                model a table of fractions.
#   size_factors was labelled "DESeq2 median-of-ratios" and computed library size
#                divided by its own geometric mean -- TSS wearing another name.
#
# A scaling factor is one positive number per sample. An offset is its logarithm. Neither
# changes the response. That distinction is the whole point of the module.
module Scaling

using Statistics
using OrderedCollections
using JSON3
using SHA

export ScalingOutcome, ScalingRefusal, tss_factors, css_factors, tmm_factors, rle_factors,
       factors_for, factor_checks, factor_provenance, OFFSET_DEFINITIONS

## Definitions, written once and carried into the provenance

const QUANTILE_DEFINITION = "R type-7 quantile (the default in R and in Julia's Statistics): " *
    "h = (n-1)p + 1 with linear interpolation between order statistics"

const OFFSET_DEFINITIONS = Dict{String,String}(
    "tss" => "log(library size), library size = column sum of the counts; " *
             "factors are the library sizes divided by their geometric mean",
    "css" => "log(cumulative sum of the counts at or below the declared per-sample quantile), " *
             "divided by the geometric mean of those sums (Paulson et al. 2013)",
    "rss" => "log(2^(weighted trimmed mean of log2 ratios to the reference sample)), " *
             "divided by the geometric mean of the factors (Robinson & Oshlack 2010, TMM)",
    "size_factors" => "log(median over features of count / feature geometric mean), " *
                      "divided by the geometric mean of the factors (DESeq2/RLE median-of-ratios)",
)

## Types

"""
    ScalingRefusal(kind, reason)

A scaling factor that cannot be computed as declared. Carries the method `kind` and a
`reason` that names the sample and the quantity, so the refusal can be shown to a user
without translating it first. A refused factor is never replaced by a default of 1.
"""
struct ScalingRefusal <: Exception
    kind::String
    reason::String
end

Base.showerror(io::IO, e::ScalingRefusal) = print(io, "ScalingRefusal($(e.kind)): $(e.reason)")

"""
    ScalingOutcome

One scaling computation: the factors, the offset they imply, and everything needed to
reproduce and audit them.

- `kind`: `"tss"`, `"css"`, `"rss"` or `"size_factors"`.
- `definition`: the sentence from `OFFSET_DEFINITIONS` that this run was computed under.
- `factors`: one factor per sample, normalised to geometric mean 1.
- `offset`: `log.(factors)` — what a count model is fitted with.
- `reference`: for TMM, the sample the ratios were taken against (`nothing` otherwise).
- `raw`: the uncentred quantity (library sizes, cumulative sums, TMM factors before
  centring, or RLE medians), so the published numbers are recoverable.
- `geometric_mean`: the centring constant that was divided out.
- `parameters`: the declared settings that changed the answer.
- `warnings`: non-fatal notes that belong in front of the analyst.
"""
struct ScalingOutcome
    kind::String
    definition::String
    factors::Vector{Float64}
    offset::Vector{Float64}
    reference::Union{String,Nothing}
    raw::Vector{Float64}
    geometric_mean::Float64
    parameters::OrderedDict{String,Any}
    warnings::Vector{String}
end

## Helpers

function _labels(n_samples::Int, sample_ids)::Vector{String}
    if isnothing(sample_ids)
        return ["column $j" for j in 1:n_samples]
    end
    length(sample_ids) == n_samples ||
        throw(ArgumentError("sample_ids has $(length(sample_ids)) entries but the counts have $n_samples columns"))
    return String[string(s) for s in sample_ids]
end

function _column_totals(counts::AbstractMatrix{<:Real})::Vector{Float64}
    n = size(counts, 2)
    totals = Vector{Float64}(undef, n)
    for j in 1:n
        totals[j] = sum(Float64(counts[i, j]) for i in 1:size(counts, 1))
    end
    return totals
end

function _require_positive(values::Vector{Float64}, kind::String, labels::Vector{String}, what::String)
    for j in eachindex(values)
        v = values[j]
        if !(isfinite(v) && v > 0)
            throw(ScalingRefusal(kind,
                "$what for sample '$(labels[j])' (column $j) is $(v); a scaling factor needs a " *
                "positive finite quantity, and neither 0 nor 1 is a defensible stand-in. " *
                "Refused — see docs/statistics/method-conditions/scaling-and-offsets.md"))
        end
    end
    return nothing
end

function _centre(raw::Vector{Float64}, kind::String)::Tuple{Vector{Float64},Float64}
    g = exp(sum(log, raw) / length(raw))
    return raw ./ g, g
end

"""
    _first_ranks(v)

Ranks of `v` ascending, ties broken by first occurrence — the ordering R's
`ties.method = "first"` gives, and the one edgeR's trimming assumes. Implemented by
sorting `(value, index)` pairs rather than relying on the stability of `sortperm`.
"""
function _first_ranks(v::Vector{Float64})::Vector{Int}
    order = sort!(collect(1:length(v)); by = i -> (v[i], i))
    ranks = Vector{Int}(undef, length(v))
    for (position, index) in enumerate(order)
        ranks[index] = position
    end
    return ranks
end

## TSS

"""
    tss_factors(counts; sample_ids) -> ScalingOutcome

Total sum scaling in its offset form: `log(library size)`, centred to geometric mean 1.

Library sizes are column sums. Zeros are untouched. A sample with a zero (or non-finite)
total has no library size to divide by and is refused by name.
"""
function tss_factors(counts::AbstractMatrix{<:Real};
                     sample_ids::Union{Nothing,AbstractVector}=nothing)
    labels = _labels(size(counts, 2), sample_ids)
    totals = _column_totals(counts)
    _require_positive(totals, "tss", labels, "total count")
    factors, g = _centre(totals, "tss")
    return ScalingOutcome("tss", OFFSET_DEFINITIONS["tss"], factors, log.(factors), nothing,
                          totals, g,
                          OrderedDict{String,Any}("library_sizes" => totals,
                                                  "definition_reference" => "McMurdie & Holmes 2014"),
                          String[])
end

## CSS

"""
    css_factors(counts; quantile, sample_ids) -> ScalingOutcome

Cumulative sum scaling (Paulson et al. 2013). Per sample: the sum of counts at or below
that sample's `quantile`-th quantile, centred to geometric mean 1; the offset is its log.

The quantile must be declared by the caller — `metagenomeSeq`'s data-driven choice of it
(`cumNormStatFast`) is deliberately not implemented, because a parameter chosen from the
data has to be recorded as a modelling decision rather than a default.

Refused when the cumulative sum is not positive for every sample: on a mostly-zero sample
at a low quantile it is zero, and `log(0)` is not a small number.
"""
function css_factors(counts::AbstractMatrix{<:Real};
                     quantile::Real=0.75,
                     sample_ids::Union{Nothing,AbstractVector}=nothing)
    kind = "css"
    p = Float64(quantile)
    (0.0 < p < 1.0) || throw(ArgumentError(
        "css_quantile must be in (0,1), got $p — see docs/statistics/method-conditions/scaling-and-offsets.md"))
    labels = _labels(size(counts, 2), sample_ids)
    n_samples = size(counts, 2)
    thresholds = Vector{Float64}(undef, n_samples)
    sums = Vector{Float64}(undef, n_samples)
    for j in 1:n_samples
        column = [Float64(counts[i, j]) for i in 1:size(counts, 1)]
        threshold = Statistics.quantile(column, p)
        thresholds[j] = threshold
        sums[j] = sum(v for v in column if v <= threshold)
    end
    for j in eachindex(sums)
        if !(isfinite(sums[j]) && sums[j] > 0)
            throw(ScalingRefusal(kind,
                "the cumulative sum up to the $p quantile is $(sums[j]) for sample " *
                "'$(labels[j])' (column $j): no count at or below the threshold is positive, " *
                "so the CSS factor would be log(0). Raise css_quantile or exclude the " *
                "sample. Refused rather than substituted."))
        end
    end
    factors, g = _centre(sums, kind)
    warnings = String[]
    if p < 0.5
        push!(warnings, "css_quantile=$p is below the median: the cumulative sum then covers " *
                        "less than half of each sample's counts and is dominated by how many " *
                        "features are zero. Paulson et al. (2013) use 0.5-0.75 on real data.")
    end
    return ScalingOutcome(kind, OFFSET_DEFINITIONS["css"], factors, log.(factors), nothing,
                          sums, g,
                          OrderedDict{String,Any}("quantile" => p,
                                                  "quantile_definition" => QUANTILE_DEFINITION,
                                                  "cumulative_sums" => sums,
                                                  "thresholds" => thresholds,
                                                  "definition_reference" => "Paulson et al. 2013"),
                          warnings)
end

## RSS / TMM

function _tmm_pair(x::Vector{Float64}, r::Vector{Float64}, lib_x::Float64, lib_r::Float64,
                   log_ratio_trim::Float64, sum_trim::Float64)
    idx = [k for k in eachindex(x) if x[k] > 0.0 && r[k] > 0.0]
    n = length(idx)
    n == 0 && return (NaN, 0, 0, false)
    m = Vector{Float64}(undef, n)
    a = Vector{Float64}(undef, n)
    w = Vector{Float64}(undef, n)
    for (slot, k) in enumerate(idx)
        m[slot] = log2(x[k] / r[k])
        a[slot] = 0.5 * log2(x[k] * r[k])
        w[slot] = (1.0 - x[k] / lib_x) / x[k] + (1.0 - r[k] / lib_r) / r[k]
    end
    lo_l = floor(Int, n * log_ratio_trim) + 1
    hi_l = n + 1 - lo_l
    lo_s = floor(Int, n * sum_trim) + 1
    hi_s = n + 1 - lo_s
    rank_m = _first_ranks(m)
    rank_a = _first_ranks(a)
    keep = [ (lo_l <= rank_m[k] <= hi_l) && (lo_s <= rank_a[k] <= hi_s) for k in 1:n ]
    any(keep) || return (NaN, 0, n, false)
    if all(w[k] <= 0.0 for k in 1:n if keep[k])
        # Every kept feature has x == library size or the reference does, so the weights
        # carry no information. Fall back to the unweighted trimmed mean and say so.
        return (sum(m[k] for k in 1:n if keep[k]) / count(keep), count(keep), n, false)
    end
    numerator = sum(m[k] * w[k] for k in 1:n if keep[k] && w[k] > 0.0)
    denominator = sum(w[k] for k in 1:n if keep[k] && w[k] > 0.0)
    return (numerator / denominator, count(keep), n, true)
end

"""
    tmm_factors(counts; ref_column, log_ratio_trim, sum_trim, sample_ids) -> ScalingOutcome

The TMM estimator (Robinson & Oshlack 2010) — what the configuration calls `RSS`.

One sample is the reference: named by `ref_column`, or, when that is `nothing`, the sample
whose upper-quartile-scaled counts are closest to the mean of those values across samples
(edgeR's default). Each other sample's factor is `2` to the power of the weighted,
trimmed mean of its log2 ratios to the reference, then all factors are centred.

Trimming drops the tails of the log-ratios (`log_ratio_trim`, default 0.3) and of the mean
abundances (`sum_trim`, default 0.05), ranked with ties by first occurrence.

Refused when a sample shares no positive feature with the reference, or when a sample's
treated factor is not positive and finite.
"""
function tmm_factors(counts::AbstractMatrix{<:Real};
                     ref_column::Union{String,Nothing}=nothing,
                     log_ratio_trim::Real=0.3,
                     sum_trim::Real=0.05,
                     sample_ids::Union{Nothing,AbstractVector}=nothing)
    kind = "rss"
    lrt = Float64(log_ratio_trim)
    st = Float64(sum_trim)
    (0.0 <= lrt < 0.5) || throw(ArgumentError(
        "tmm_log_ratio_trim must be in [0, 0.5), got $lrt — a trim of 0.5 or more removes at " *
        "least half of the log-ratios in each tail. See docs/statistics/method-conditions/scaling-and-offsets.md"))
    (0.0 <= st < 0.5) || throw(ArgumentError(
        "tmm_sum_trim must be in [0, 0.5), got $st — see docs/statistics/method-conditions/scaling-and-offsets.md"))
    labels = _labels(size(counts, 2), sample_ids)
    n = size(counts, 2)
    libs = _column_totals(counts)
    _require_positive(libs, kind, labels, "total count")

    chosen_from_data = isnothing(ref_column)
    reference = ""
    if chosen_from_data
        upper_quartile = Vector{Float64}(undef, n)
        for j in 1:n
            column = [Float64(counts[i, j]) for i in 1:size(counts, 1)]
            upper_quartile[j] = Statistics.quantile(column, 0.75) / libs[j]
        end
        target = sum(upper_quartile) / n
        distances = [abs(upper_quartile[j] - target) for j in 1:n]
        ref_index = argmin(distances)
        reference = labels[ref_index]
    else
        ref_index = findfirst(==(String(ref_column)), labels)
        isnothing(ref_index) && throw(ScalingRefusal(kind,
            "tmm_ref_column='$(ref_column)' is not a sample in this run. Samples are: " *
            "$(join(labels, ", ")). Refused — a reference chosen by a typo is not a reference."))
        reference = labels[ref_index]
    end

    raw = ones(n)
    kept_counts = zeros(Int, n)
    pair_counts = zeros(Int, n)
    weighted_mean_used = falses(n)
    for i in 1:n
        i == ref_index && continue
        x = [Float64(counts[k, i]) for k in 1:size(counts, 1)]
        r = [Float64(counts[k, ref_index]) for k in 1:size(counts, 1)]
        mean_log_ratio, kept, pairs, weighted = _tmm_pair(x, r, libs[i], libs[ref_index], lrt, st)
        kept_counts[i] = kept
        pair_counts[i] = pairs
        weighted_mean_used[i] = weighted
        if !isfinite(mean_log_ratio)
            throw(ScalingRefusal(kind,
                "sample '$(labels[i])' (column $i) shares no positive-count feature with the " *
                "reference sample '$(reference)', or its trimmed set is empty " *
                "($kept of $pairs features kept). A TMM factor cannot be computed; refused " *
                "rather than set to 1."))
        end
        raw[i] = 2.0^mean_log_ratio
    end

    _require_positive(raw, kind, labels, "TMM factor")
    factors, g = _centre(raw, kind)
    warnings = String[]
    if any(!weighted_mean_used[i] for i in 1:n if i != ref_index)
        affected = [labels[i] for i in 1:n if i != ref_index && !weighted_mean_used[i]]
        push!(warnings, "the weighted trimmed mean was undefined for $(join(affected, ", ")) " *
                        "(every kept feature is a whole library). The unweighted trimmed mean " *
                        "was used for those samples; the factors are still reported, and the " *
                        "difference is recorded here rather than hidden.")
    end
    if any(kept_counts[i] < 2 for i in 1:n if i != ref_index)
        push!(warnings, "fewer than two log-ratios survived trimming for at least one sample; " *
                        "a trimmed mean over one value is that value. Recorded, not suppressed.")
    end
    return ScalingOutcome(kind, OFFSET_DEFINITIONS["rss"], factors, log.(factors), reference,
                          raw, g,
                          OrderedDict{String,Any}(
                              "log_ratio_trim" => lrt,
                              "sum_trim" => st,
                              "reference_sample" => reference,
                              "reference_chosen_from_data" => chosen_from_data,
                              "reference_selection" => chosen_from_data ?
                                  "sample whose upper-quartile-scaled counts are closest to the mean of those values (edgeR default)" :
                                  "declared by tmm_ref_column",
                              "kept_log_ratios" => kept_counts,
                              "available_pairs" => pair_counts,
                              "weighted" => [weighted_mean_used[i] for i in 1:n],
                              "definition_reference" => "Robinson & Oshlack 2010"),
                          warnings)
end

## size_factors: median-of-ratios (RLE)

"""
    rle_factors(counts; sample_ids) -> ScalingOutcome

Median-of-ratios size factors, the estimator `size_factors` claimed to be and was not.

Per sample: the median over features of `count / feature geometric mean`, using only
features whose counts are positive in **every** sample (a feature with a zero has no
finite geometric mean, so it cannot contribute a ratio). Centred to geometric mean 1.

Refused when no feature is positive in every sample, and when a median ratio is not
positive.
"""
function rle_factors(counts::AbstractMatrix{<:Real};
                     sample_ids::Union{Nothing,AbstractVector}=nothing)
    kind = "size_factors"
    labels = _labels(size(counts, 2), sample_ids)
    n_features = size(counts, 1)
    n_samples = size(counts, 2)
    usable = Int[]
    log_geo_mean = Float64[]
    for i in 1:n_features
        row = [Float64(counts[i, j]) for j in 1:n_samples]
        if all(>(0.0), row)
            push!(usable, i)
            push!(log_geo_mean, sum(log, row) / n_samples)
        end
    end
    isempty(usable) && throw(ScalingRefusal(kind,
        "no feature has a positive count in every sample, so no feature has a finite " *
        "geometric mean and the median-of-ratios size factor is undefined. Refused rather " *
        "than falling back to library size, which is a different estimator."))
    ratios = Vector{Float64}(undef, n_samples)
    for j in 1:n_samples
        ratios[j] = Statistics.median([Float64(counts[usable[k], j]) / exp(log_geo_mean[k])
                                       for k in eachindex(usable)])
    end
    _require_positive(ratios, kind, labels, "median-of-ratios size factor")
    factors, g = _centre(ratios, kind)
    warnings = String[]
    if length(usable) < n_features
        push!(warnings, "$(n_features - length(usable)) of $n_features features contain a zero " *
                        "in at least one sample and cannot contribute a ratio to the median " *
                        "(no finite geometric mean). The estimate rests on the other " *
                        "$(length(usable)).")
    end
    if length(usable) < n_samples
        push!(warnings, "only $(length(usable)) features are positive in every sample; " *
                        "the median of a small set of ratios is a noisy size factor.")
    end
    return ScalingOutcome(kind, OFFSET_DEFINITIONS["size_factors"], factors, log.(factors),
                          nothing, ratios, g,
                          OrderedDict{String,Any}("features_used" => length(usable),
                                                  "features_total" => n_features,
                                                  "log_geometric_means" =>
                                                      Dict(string(k) => log_geo_mean[k]
                                                           for k in eachindex(usable)),
                                                  "definition_reference" =>
                                                      "Anders & Huber 2010; DESeq2/RLE"),
                          warnings)
end

## Dispatch

"""
    factors_for(kind, counts; kwargs...) -> ScalingOutcome

Dispatch on the normalisation method name, case-insensitively: `none` and `tss` to
[`tss_factors`](@ref), `css` to [`css_factors`](@ref), `rss`/`tmm` to
[`tmm_factors`](@ref), `size_factors` to [`rle_factors`](@ref).

`none` means "no scaling": the offset is the plain log library size, which is what
[`tss_factors`](@ref) returns. The two names are kept distinct in the configuration
because one declares a transform and the other declares its absence, and both are
recorded as what they are.
"""
function factors_for(kind::AbstractString, counts::AbstractMatrix{<:Real}; kwargs...)
    key = lowercase(strip(kind))
    if key in ("none", "tss")
        return tss_factors(counts; kwargs...)
    elseif key == "css"
        return css_factors(counts; kwargs...)
    elseif key in ("rss", "tmm")
        return tmm_factors(counts; kwargs...)
    elseif key == "size_factors"
        return rle_factors(counts; kwargs...)
    end
    throw(ArgumentError("no scaling factors are defined for method '$kind' — see " *
                        "docs/statistics/method-conditions/scaling-and-offsets.md"))
end

## What the run records

"""
    factor_checks(outcome) -> OrderedDict

The entry written to `diagnostics.checks["scaling"]`: what was computed, under which
definition, with which declared parameters, and what the analyst should be told.
"""
function factor_checks(o::ScalingOutcome)::OrderedDict{String,Any}
    return OrderedDict{String,Any}(
        "kind" => o.kind,
        "definition" => o.definition,
        "offset_definition" => "log(factor), factors centred to geometric mean 1",
        "factors" => o.factors,
        "raw" => o.raw,
        "centring_geometric_mean" => o.geometric_mean,
        "reference_sample" => o.reference,
        "parameters" => o.parameters,
        "warnings" => o.warnings,
    )
end

"""
    factor_provenance(outcome) -> OrderedDict

The entry written to the manifest provenance: the same facts as [`factor_checks`](@ref)
plus a SHA-256 of the offset vector, so two runs that agree on the offset can be shown to
agree and a run whose offset changed is detectable from the manifest alone.
"""
function factor_provenance(o::ScalingOutcome)::OrderedDict{String,Any}
    return OrderedDict{String,Any}(
        "kind" => o.kind,
        "definition" => o.definition,
        "factors" => o.factors,
        "offset" => o.offset,
        "offset_sha256" => bytes2hex(sha256(JSON3.write(o.offset))),
        "centring_geometric_mean" => o.geometric_mean,
        "reference_sample" => o.reference,
        "parameters" => o.parameters,
        "warnings" => o.warnings,
    )
end

end # module Scaling
