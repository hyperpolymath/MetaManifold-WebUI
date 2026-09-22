# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Catalogue item 1 of docs/statistics/method-catalogue-v1.md: descriptive summaries at
# exact precision.
#
# The conditions this code is held to were published BEFORE it existed
# (docs/statistics/method-conditions/exact-descriptive-summaries.md). Where this file
# and that document disagree, the document is right and this file is the bug.
#
# The module exists to keep two claims apart that a single number cannot distinguish:
#
#   a zero count   is a value. A feature with no reads, in a sample that has reads,
#                  has a relative abundance of exactly 0.
#   a zero total   is not a small composition. A sample with no reads at all has NO
#                  relative abundances. Reporting 0 there does not round the truth, it
#                  invents a measurement -- and it is the kind of default that is only
#                  ever fixed before the code exists, which is why the document came
#                  first.
#
# No inference lives here. There is no p-value, no interval, no model and no comparison
# in this module's vocabulary -- not because they were left out, but because a
# descriptive summary that starts reporting significance is a different method wearing
# this one's name.
module ExactSummaries

using ..NumericPolicy: NumericPolicySpec, numeric_policy, assert_mode, require_count,
                       checked_count_sum, exact_relative_abundance, exact_value,
                       to_storage, to_display, policy_fingerprint,
                       UnsupportedRepresentationError

export ExactSummary, SampleSummary, GroupSummary, exact_summary,
       has_defined_proportions, summary_to_storage, summary_to_display

## Types

"""
    SampleSummary

One sample's exact descriptive summary.

`proportions[i]` is the exact relative abundance of `features[i]`, or `nothing` when
`total` is zero. The `nothing` is load-bearing: it is the difference between "this
feature was not seen" (exactly `0//1`) and "this sample has no composition to divide"
(undefined). They are not the same fact and no float can hold both.

Counts are carried as integers of unbounded width. That is deliberate: the boundary
audit (#52) found real counts past 2^53, which no Float64 can hold, and normalising
them to a fixed width here would undo the audit at the last step.
"""
struct SampleSummary
    label       :: String
    features    :: Vector{String}
    counts      :: Vector{BigInt}
    total       :: BigInt
    proportions :: Vector{Union{Rational{BigInt},Nothing}}
    approximate :: Bool
    warnings    :: Vector{String}
end

"""
    GroupSummary

Several samples aggregated exactly before being summarised.

Aggregation happens in exact integer arithmetic, so a group total is a sum of counts
rather than a sum of proportions. It supports no comparison: a reader looking for a
difference between two of these should notice there is no place to put one.
"""
struct GroupSummary
    label       :: String
    members     :: Vector{String}
    features    :: Vector{String}
    counts      :: Vector{BigInt}
    total       :: BigInt
    proportions :: Vector{Union{Rational{BigInt},Nothing}}
    approximate :: Bool
    warnings    :: Vector{String}
end

"""
    ExactSummary

The result of a descriptive summary: per-sample, per-group, and the policy it ran
under.

The policy travels with the result because a summary that cannot say what numeric
policy produced it cannot be reproduced or compared with another run -- that is what
`policy_fingerprint` is for.
"""
struct ExactSummary
    samples     :: Vector{SampleSummary}
    groups      :: Vector{GroupSummary}
    policy      :: NumericPolicySpec
    approximate :: Bool
    warnings    :: Vector{String}
end

"""
    has_defined_proportions(s::Union{SampleSummary,GroupSummary}) -> Bool

False when the summary's total is zero, in which case its proportions are undefined
rather than zero.
"""
has_defined_proportions(s::Union{SampleSummary,GroupSummary}) = !iszero(s.total)

## Construction

# Reuse NumericPolicy's definition of what a count IS rather than restating it, and add
# the coordinates. "9007199254740994.0 is not a count" is a true sentence that gives a
# caller nothing to act on; naming the feature and sample is what makes it fixable.
function _exact_count(value, feature::AbstractString, sample::AbstractString)
    count = try
        require_count(value)
    catch err
        err isa UnsupportedRepresentationError || err isa ArgumentError || rethrow()
        detail = err isa UnsupportedRepresentationError ? err.value : string(err)
        throw(UnsupportedRepresentationError("an exactly-known count", string(value),
            "feature '$feature', sample '$sample' ($detail)"))
    end
    count < 0 && throw(ArgumentError(
        "negative count $count at feature '$feature', sample '$sample'; counts are " *
        "non-negative, and a negative one here means the input is not a count table"))
    return BigInt(count)
end

function _summarise(label::String, features::Vector{String}, counts::Vector{BigInt},
                    policy::NumericPolicySpec, approximate::Bool,
                    warnings::Vector{String})
    # `:widen` is defensive rather than load-bearing here: counts arrive from
    # `_exact_count`, which already leaves them as BigInt, so this accumulator cannot
    # overflow. It is kept because the alternative -- a future refactor that carries
    # Int64 for speed -- would otherwise wrap silently, and a wrapped total is a wrong
    # number no downstream check can detect. Mutation testing confirmed the flag is not
    # exercised today; the test that matters asserts the total, not the mechanism.
    total = checked_count_sum(counts; on_overflow = :widen)
    proportions = Vector{Union{Rational{BigInt},Nothing}}(undef, length(counts))
    if iszero(total)
        # every feature's proportion is undefined, and each one says so by being nothing
        fill!(proportions, nothing)
        push!(warnings, "'$label' has a total of zero reads: its relative abundances " *
                        "are undefined and are carried as nothing, never as 0 -- a " *
                        "proportion that does not exist is not a proportion of zero")
    else
        for (i, count) in enumerate(counts)
            proportions[i] = exact_relative_abundance(count, total; policy)
        end
    end
    return (total, proportions, warnings)
end

function _sample_summary(label::String, features::Vector{String},
                         counts::Vector{BigInt}, policy::NumericPolicySpec,
                         approximate::Bool)
    warnings = String[]
    approximate && push!(warnings,
        "'$label' was supplied as floating point: its values are carried as " *
        "approximations and labelled as such, because a Float64 above 2^53 cannot say " *
        "which integer it holds and that history cannot be inspected")
    total, proportions, warnings = _summarise(label, features, counts, policy,
                                              approximate, warnings)
    return SampleSummary(label, features, counts, total, proportions, approximate, warnings)
end

function _group_summary(label::String, members::Vector{String}, features::Vector{String},
                        row_counts::Vector{Vector{BigInt}}, policy::NumericPolicySpec,
                        approximate::Bool)
    warnings = String[]
    approximate && push!(warnings,
        "'$label' aggregates samples supplied as floating point: its values are " *
        "carried as approximations and labelled as such")
    # Sums, not averaged proportions: a proportion averaged across unequal depths
    # weights a shallow sample the same as a deep one, which is a different (and
    # usually unintended) statement.
    counts = BigInt[checked_count_sum(row; on_overflow = :widen) for row in row_counts]
    total, proportions, warnings = _summarise(label, features, counts, policy,
                                              approximate, warnings)
    return GroupSummary(label, members, features, counts, total, proportions,
                        approximate, warnings)
end

"""
    exact_summary(counts; sample_labels, feature_labels, groups, policy) -> ExactSummary

Exactly-summarise a features-by-samples count table.

Rows are features and columns are samples, matching the rest of the analysis layer. The
table's values must be counts: integers, or floats that are finite, integral and within
2^53 (a float beyond that is refused, because it cannot say which integer it holds).
Float input is accepted but the result is marked `approximate` and says so in its
warnings -- approximate input is not hidden, it is labelled.

`groups`, when given, names one group per sample; the group summary aggregates the
member samples in exact integer arithmetic first.

The policy must be `:exact_counts`. `:ordinary` is refused by name, because a caller
who asks for an exact summary under an ordinary policy would otherwise receive
Float64s that look exactly like the exact answer until someone checks; and
`:high_precision` is refused too, since higher precision is not exactness -- it moves
the rounding error rather than abolishing it (see `numeric-contracts.md`).

    julia> s = exact_summary([4 6; 0 3];
                             sample_labels = ["a", "b"],
                             feature_labels = ["f1", "f2"]);

    julia> s.samples[2].proportions
    2-element Vector{Union{Nothing, Rational{BigInt}}}:
     2//3
     1//3
"""
function exact_summary(counts::AbstractMatrix{<:Real};
                      sample_labels::AbstractVector{<:AbstractString},
                      feature_labels::AbstractVector{<:AbstractString} =
                          ["feature $i" for i in 1:size(counts, 1)],
                      groups::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
                      policy::NumericPolicySpec = numeric_policy(:exact_counts))
    assert_mode(policy, :exact_counts)

    n_features, n_samples = size(counts)
    length(sample_labels) == n_samples || throw(ArgumentError(
        "expected $n_samples sample labels for $n_samples columns, got " *
        "$(length(sample_labels))"))
    length(feature_labels) == n_features || throw(ArgumentError(
        "expected $n_features feature labels for $n_features rows, got " *
        "$(length(feature_labels))"))

    features = String[String(f) for f in feature_labels]
    labels   = String[String(s) for s in sample_labels]

    approximate = !(eltype(counts) <: Integer)
    warnings = String[]

    columns = Vector{Vector{BigInt}}(undef, n_samples)
    for j in 1:n_samples
        columns[j] = BigInt[_exact_count(counts[i, j], features[i], labels[j])
                            for i in 1:n_features]
    end

    samples = [_sample_summary(labels[j], features, columns[j], policy, approximate)
               for j in 1:n_samples]

    group_summaries = GroupSummary[]
    if !isnothing(groups)
        length(groups) == n_samples || throw(ArgumentError(
            "expected $n_samples group labels (one per sample), got $(length(groups))"))
        group_labels = String[String(g) for g in groups]
        for label in unique(group_labels)
            members = [labels[j] for j in 1:n_samples if group_labels[j] == label]
            row_counts = [BigInt[columns[j][i] for j in 1:n_samples
                                 if group_labels[j] == label] for i in 1:n_features]
            push!(group_summaries, _group_summary(String(label), members, features,
                                                  row_counts, policy, approximate))
        end
    end

    return ExactSummary(samples, group_summaries, policy, approximate, warnings)
end

## Boundaries

# Storage and display are separated deliberately: what is written down must round-trip
# exactly, and what a person reads may be rendered. The rendered form is never the
# stored one, which is the whole reason `to_storage` exists on the numeric layer.
function _counts_to_storage(x::Union{SampleSummary,GroupSummary})
    return Dict{String,Any}(
        "label"               => x.label,
        "total"               => to_storage(exact_value(x.total)),
        "counts"              => [to_storage(exact_value(c)) for c in x.counts],
        "proportions"         => [isnothing(p) ? nothing : to_storage(exact_value(p))
                                  for p in x.proportions],
        "proportions_defined" => has_defined_proportions(x),
        "approximate"         => x.approximate,
        "warnings"            => x.warnings,
    )
end

"""
    summary_to_storage(s::ExactSummary) -> Dict{String,Any}

The summary as it should be written down: exact counts and proportions as integers or
as `"numerator/denominator"` strings, `nothing` where a proportion is undefined, and
the policy fingerprint so the run can be compared with another.

A proportion stored here parses back with `parse_exact_rational` to the identical
rational; a rounded decimal never appears in this structure.
"""
function summary_to_storage(s::ExactSummary)
    out = Dict{String,Any}(
        "kind"               => "descriptive summary",
        "claim"              => "counts and proportions are exact; no comparison, test or " *
                                "significance is claimed",
        "policy_fingerprint" => policy_fingerprint(s.policy),
        "mode"               => String(s.policy.mode),
        "approximate"        => s.approximate,
        "samples"            => [_counts_to_storage(x) for x in s.samples],
        "groups"             => [_counts_to_storage(x) for x in s.groups],
        "warnings"           => s.warnings,
    )
    for (i, x) in enumerate(s.samples)
        out["samples"][i]["features"] = x.features
    end
    for (i, x) in enumerate(s.groups)
        out["groups"][i]["features"] = x.features
        out["groups"][i]["members"]  = x.members
    end
    return out
end

"""
    summary_to_display(s::ExactSummary; digits=6) -> String

The summary as a person reads it: exact fractions, with a rounded decimal offered
beside them and marked as a rendering.

The first line states what the numbers are not. A table of per-group counts is the
shape most often misread as a comparison, so the text says once, plainly, that no
comparison was made.
"""
function summary_to_display(s::ExactSummary; digits::Integer = 6)
    digits >= 0 || throw(ArgumentError("digits must not be negative, got $digits"))
    io = IOBuffer()
    println(io, "Descriptive summary — counts and proportions are exact. No comparison, " *
                "no test and no significance is claimed.")
    if s.approximate
        println(io, "  ⚠ some input was floating point: those values are approximations, " *
                    "not exact counts")
    end
    for (heading, entries) in (("sample", s.samples), ("group", s.groups))
        for x in entries
            println(io, "  $heading ", x.label, " — total ",
                    to_display(exact_value(x.total); digits = digits))
            if !has_defined_proportions(x)
                println(io, "    proportions: undefined (zero total) — not zero")
                continue
            end
            for (feature, proportion) in zip(x.features, x.proportions)
                println(io, "    ", feature, ": ",
                        to_display(exact_value(proportion); digits = digits))
            end
        end
    end
    # Built by hand rather than vcat'ed with a generator: `vcat` treats a generator as a
    # scalar here, and the note line printed the iterator's own type instead of a warning.
    notes = copy(s.warnings)
    for entry in vcat(s.samples, s.groups), warning in entry.warnings
        push!(notes, warning)
    end
    for warning in notes
        println(io, "  note: ", warning)
    end
    return String(take!(io))
end

end # module ExactSummaries
