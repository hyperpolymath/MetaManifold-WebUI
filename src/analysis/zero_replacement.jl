# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""
    ZeroReplacement — exact zero replacement for compositional data (issue #21)

Implements the two replacement policies that `AnalysisConfig.ZeroPolicy` has named since
v1 and that this repository previously only half-implemented:

- `multiplicative_replacement` — Martín-Fernández, Barceló-Vidal & Pawlowsky-Glahn (2003),
  *Dealing with zeros and missing values in compositional data sets using nonparametric
  imputation*, Mathematical Geology 35(3):253-278. A zero in part *i* is replaced by
  `delta × DL_i`, where `DL_i` is the detection limit of part *i* (by default the smallest
  observed value of that part anywhere in the table), and every observed part in the same
  sample is multiplied by `1 - Δ_j`, with `Δ_j` the imputed mass of sample *j* as a
  fraction of that sample's total.
- `bayesian_multiplicative` — Martín-Fernández, Hron, Templ, Filzmoser &
  Palarea-Albaladejo (2015), *Bayesian-multiplicative treatment of count zeros in
  compositional data sets*, Statistical Modelling 15(2):134-158, in the parameterisation
  of `zCompositions::cmultRepl(method = "GBM")`: the Dirichlet prior mean `t` is the
  compositional profile of the *other* samples' counts (leave-one-out), the prior
  concentration `s` is `1 / gmean(t)` unless the caller supplies `alpha`, and a zero is
  replaced by the posterior mean `t_i · s / (S_j + s)` of the same Dirichlet-multinomial
  model, then observed parts are rescaled to close the sample.

Both operators are defined so that three things hold exactly, and are asserted at runtime
because a silent violation would be a wrong number in a results table:

1. **the sample total is preserved** (`Σ_i x̃_ij = Σ_i x_ij`), so a count-scale response
   keeps the same depth and the same offset it had before;
2. **the ratios among observed parts are preserved exactly** (`x̃_ij / x̃_kj = x_ij / x_kj`
   whenever `x_ij > 0` and `x_kj > 0`) — this is the property pseudocounts do not have, and
   the reason the methods exist;
3. **every replaced value is strictly positive and strictly below the smallest observed
   value of its own part** for multiplicative replacement with `delta < 1` (i.e. below the
   detection limit), which is what keeps a zero from being reported as if it were an
   abundant feature.

These are machine-checked in `proofs/agda/ZeroReplacement.agda`; the runtime checks here are
cheap sanity checks on the same statements, not a substitute for the proofs.

What this module does not do, stated plainly because the alternative is a user believing
otherwise: **every zero replacement is biased.** A replacement value is not a measurement.
The composition with a zero *displaced* is a different composition from the one that would
have been observed had the taxon been sequenced more deeply, and no imputation can recover
the difference — `proofs/agda/NoRigidReplacement.agda` proves that no rule determined by the
observed data can be faithful on both of two datasets that agree on which entries are zero.
For sparse data the alternatives that do not insert values are occupancy models and
zero-inflated or hurdle count models (see `docs/statistics/zero-handling.md`).

Refusals are by name, with the number that would make the request admissible:

- a sample whose imputed mass would reach or exceed its total (`Δ_j ≥ 1`), which is exactly
  the case `zCompositions::multRepl` stops on;
- a part with no observed value anywhere, whose detection limit the data cannot supply;
- `bayesian_multiplicative` when a part is observed in fewer than two samples, where the
  reference's leave-one-out prior mean `t` is zero and `cmultRepl(method = "GBM")` stops;
- a non-positive or non-finite supplied detection limit.
"""
module ZeroReplacement

using Logging
using OrderedCollections

export ZeroReplacementOutcome,
       multiplicative_replacement, bayesian_multiplicative,
       DEFAULT_MULTIPLICATIVE_DELTA, DEFAULT_BAYESIAN_THRESHOLD,
       replacement_invariants_hold, describe_zero_policy

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

"""
Default `delta` of multiplicative replacement: the value `zCompositions::multRepl` uses for
its `frac` argument (0.65) and the value issue #21 names (`delta = 0.65 × detection limit`).
"""
const DEFAULT_MULTIPLICATIVE_DELTA = 0.65

"""
Default cap of `bayesian_multiplicative`: the reference's `frac`, multiplying the smallest
observed proportion of a part when the posterior mean would exceed it.
"""
const DEFAULT_BAYESIAN_THRESHOLD = 0.65

"""
Tolerance for the runtime invariants. `1e-9` relative is far above double-precision rounding
for the arithmetic these operators perform (a handful of multiplications and one
subtraction per sample) and far below any difference that could matter scientifically.
"""
const INVARIANT_TOLERANCE = 1e-9

# ---------------------------------------------------------------------------
# Result type
# ---------------------------------------------------------------------------

"""
    ZeroReplacementOutcome

What a replacement did, in full: the replaced table, the parameter actually used, any notes
raised, a per-sample diagnostic table, and the provenance a DOI bundle needs.

- `counts` — the replaced table, same shape and same sample totals as the input
- `method` — `"multiplicative_replacement"` or `"bayesian_multiplicative"`
- `delta` / `alpha` — the parameter used, or `nothing` where the method has none
- `notes` — human-readable notes, also logged
- `diagnostics` — per-sample detail (zeros replaced, imputed mass, detection limits)
- `provenance` — the citation, the parameter, and the bias warning, ready for the manifest
"""
struct ZeroReplacementOutcome
    counts::Matrix{Float64}
    method::String
    delta::Union{Float64,Nothing}
    alpha::Union{Float64,Nothing}
    notes::Vector{String}
    diagnostics::OrderedDict{String,Any}
    provenance::OrderedDict{String,Any}
end

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function _as_float_matrix(counts::AbstractMatrix{<:Real}, what::String)
    isempty(counts) &&
        throw(ArgumentError("$what: the count table is empty. Refusing."))
    X = Matrix{Float64}(counts)
    n_taxa, n_samples = size(X)
    (n_taxa >= 1 && n_samples >= 1) ||
        throw(ArgumentError("$what: the count table has shape $(size(X)); at least one taxon and one sample are required. Refusing."))
    for v in X
        isfinite(v) ||
            throw(ArgumentError("$what: the count table holds a non-finite value ($v). Refusing to impute from counts that are not counts."))
        v >= 0 ||
            throw(ArgumentError("$what: the count table holds a negative value ($v). Counts are non-negative; refusing."))
    end
    return X
end

function _ids(given::AbstractVector{<:AbstractString}, n::Int, kind::String, what::String)
    if isempty(given)
        return ["$(kind)_$i" for i in 1:n]
    end
    length(given) == n ||
        throw(ArgumentError("$what: $(length(given)) $(kind)_ids were supplied for $n $(kind)s. Refusing rather than labelling the output with the wrong names."))
    return String[String(s) for s in given]
end

"""
    _per_taxon_detection_limits(X, ids; supplied) -> (dl, source)

Detection limit per taxon, in the units of the table.

Default: the smallest observed value of that taxon — the same rule as
`zCompositions` (`dl = min(x[x != label])` per part, with the warning that no `dl` was
supplied). A taxon with no observed value anywhere has no detection limit to estimate, and
is refused by name rather than given a borrowed number: the smallest observed value *of
another taxon* is not this taxon's detection limit, and a silently borrowed one would end up
in a published table.
"""
function _per_taxon_detection_limits(X::Matrix{Float64}, ids::Vector{String}, what::String)
    n_taxa = size(X, 1)
    dl = zeros(Float64, n_taxa)
    for i in 1:n_taxa
        observed = Float64[]
        for j in 1:size(X, 2)
            X[i, j] > 0 && push!(observed, X[i, j])
        end
        if isempty(observed)
            throw(ArgumentError(
                "$what: taxon '$(ids[i])' has no observed value in any sample, so its " *
                "detection limit is not estimable from this table. Either drop the taxon " *
                "(raise advanced.min_prevalence, which is 0.1 by default and removes " *
                "all-zero taxa) or declare detection_limits explicitly. " *
                "Refusing rather than borrowing another taxon's smallest value."))
        end
        dl[i] = minimum(observed)
    end
    return dl
end

function _checked_supplied_limits(supplied::AbstractVector{<:Real}, n_taxa::Int,
                                  ids::Vector{String}, what::String)
    length(supplied) == n_taxa ||
        throw(ArgumentError("$what: $(length(supplied)) detection limits were supplied for $n_taxa taxa. Refusing."))
    dl = Float64[]
    for (i, v) in enumerate(supplied)
        f = Float64(v)
        isfinite(f) ||
            throw(ArgumentError("$what: the detection limit supplied for taxon '$(ids[i])' is $f, which is not finite. Refusing."))
        f > 0 ||
            throw(ArgumentError("$what: the detection limit supplied for taxon '$(ids[i])' is $f; a detection limit must be strictly positive, because a detection limit of zero states that a value below any positive number was observed. The reference requires the same (`Detection limits for censored values must be strictly positive`). Refusing."))
        push!(dl, f)
    end
    return dl
end

"""
    _verify_invariants(original, replaced, method, taxa_ids, sample_ids)

Assert the three statements the module docstring makes, on the actual numbers.

These are runtime checks on statements that are proved in `proofs/agda/`: if one of them ever
fires, either the implementation and the proof have diverged, or a caller has handed this
module a table with a NaN in it. Both are bugs, and neither is something to average over, so
the failure is an `error` naming the sample and the quantities involved rather than a warning.
"""
function _verify_invariants(original::Matrix{Float64}, replaced::Matrix{Float64},
                            method::String, taxa_ids::Vector{String},
                            sample_ids::Vector{String})
    size(original) == size(replaced) ||
        error("INTERNAL: $method returned a table of shape $(size(replaced)) for an input of shape $(size(original)). This is a bug in ZeroReplacement; please report it with the configuration id.")

    n_taxa, n_samples = size(original)
    for j in 1:n_samples
        s_before = sum(original[:, j])
        s_after = sum(replaced[:, j])
        s_before > 0 ||
            error("INTERNAL: $method received sample '$(sample_ids[j])' (column $j) with a total of $s_before. Samples are healed before zero replacement, so reaching here means the healing was bypassed; please report this with the configuration id.")
        abs(s_after - s_before) <= INVARIANT_TOLERANCE * s_before ||
            error("INTERNAL: $method changed the total of sample '$(sample_ids[j])' from $s_before to $s_after, which is outside the $INVARIANT_TOLERANCE relative tolerance. Proved to be impossible; please report this with the configuration id.")

        # Ratios among the observed parts must be untouched: every observed part in a sample
        # is scaled by the same factor, so the ratio to the first observed part is the check.
        first_observed = 0
        for i in 1:n_taxa
            if original[i, j] > 0
                first_observed = i
                break
            end
        end
        if first_observed != 0
            base_ratio = replaced[first_observed, j] / original[first_observed, j]
            for i in 1:n_taxa
                if original[i, j] > 0
                    ratio = replaced[i, j] / original[i, j]
                    abs(ratio - base_ratio) <= INVARIANT_TOLERANCE * max(1.0, abs(base_ratio)) ||
                        error("INTERNAL: $method scaled taxon '$(taxa_ids[i])' in sample '$(sample_ids[j])' by $ratio while taxon '$(taxa_ids[first_observed])' was scaled by $base_ratio. Subcompositional ratios are proved to be preserved exactly; please report this with the configuration id.")
                else
                    replaced[i, j] > 0 ||
                        error("INTERNAL: $method left taxon '$(taxa_ids[i])' at $(replaced[i, j]) in sample '$(sample_ids[j])'. A zero that no replacement covers is a log(0) waiting for the transform; please report this with the configuration id.")
                end
            end
        end
    end
    return true
end

"""
    replacement_invariants_hold(original, replaced) -> Bool

Check the invariants without throwing: total preserved per sample, ratios among observed
parts preserved, no zeros left. Exposed for tests and for callers that want to check a table
the module did not produce.
"""
function replacement_invariants_hold(original::AbstractMatrix{<:Real},
                                     replaced::AbstractMatrix{<:Real})::Bool
    size(original) == size(replaced) || return false
    n_taxa, n_samples = size(original)
    for j in 1:n_samples
        s_before = sum(original[:, j])
        s_after = sum(replaced[:, j])
        s_before > 0 || return false
        abs(s_after - s_before) <= INVARIANT_TOLERANCE * s_before || return false
        first_observed = 0
        for i in 1:n_taxa
            if original[i, j] > 0
                first_observed = i
                break
            end
        end
        first_observed == 0 && return false
        base_ratio = replaced[first_observed, j] / original[first_observed, j]
        for i in 1:n_taxa
            if original[i, j] > 0
                ratio = replaced[i, j] / original[i, j]
                abs(ratio - base_ratio) <= INVARIANT_TOLERANCE * max(1.0, abs(base_ratio)) || return false
            else
                replaced[i, j] > 0 || return false
            end
        end
    end
    return true
end

# ---------------------------------------------------------------------------
# Multiplicative replacement — Martín-Fernández et al. (2003)
# ---------------------------------------------------------------------------

"""
    multiplicative_replacement(counts; delta, detection_limits, sample_ids, taxa_ids)
        -> ZeroReplacementOutcome

Exact multiplicative replacement over the columns (samples) of `counts`, whose rows are
taxa.

For each sample *j* with total `S_j`, let `Z_j` be the taxa with a zero count and `DL_i` the
detection limit of taxon *i* (in the same units as `counts`). With `Δ_j = Σ_{i∈Z_j} δ·DL_i / S_j`:

    x̃_ij = δ · DL_i                    for i ∈ Z_j
    x̃_ij = (1 - Δ_j) · x_ij            for i ∉ Z_j

This is the operator of Martín-Fernández et al. (2003) in the count scale. Relation to
`zCompositions::multRepl(X, label = 0, dl, frac = δ)`, stated exactly because the difference
matters: the reference forms `est = frac * dl`, stops on `rowSums(est) >= rowSums(X)`, divides
the proposed values by `adjustment = 1 - rowSums(est)/rowSums(X)`, and closes the result to the
common row total *only when the input is already closed*
(`all(abs(c_base - mean(c_base)) < .Machine$double.eps^0.3)`). On a closed table — which
includes any table expressed as proportions, and therefore the reference's own denominators —
the division and the closure cancel and the reference's result is `x̃_zero = frac*dl`,
`x̃_observed = x*(1 - sum_est/c)`: identical to this function, sample for sample. On a count
table whose samples have different totals the reference leaves each total inflated by the
imputed counts, while this function preserves it exactly, which is the property issue #21
requires; dividing this function's result by the sample total gives the reference's
proportional output either way, and that is what the tests compare.

Refusals, each naming what would make the request admissible:

- `delta ∉ (0, 1)` (the issue's criterion; `delta = 1` is refused because it imputes the
  detection limit itself as if it had been observed at the limit, and the ordering property
  below is stated for `delta < 1`).
- a taxon with no observed value anywhere and no supplied detection limit;
- a sample for which `Δ_j ≥ 1` — the imputed values would consume the sample and the
  observed parts would be scaled by a non-positive factor. The refusal names the largest
  `delta` that sample admits, `S_j / Σ_{i∈Z_j} DL_i`, which is the number a user needs.

Notes (logged and recorded, never silent): `delta < 0.01` puts imputed values three or more
orders of magnitude below the detection limit, which produces extreme log-ratios in the
opposite direction; `delta ≥ 0.9` puts them within 10% of it, which for a sparse table makes
the imputed values look like observations.
"""
function multiplicative_replacement(counts::AbstractMatrix{<:Real};
                                    delta::Real = DEFAULT_MULTIPLICATIVE_DELTA,
                                    detection_limits::Union{AbstractVector{<:Real},Nothing} = nothing,
                                    sample_ids::AbstractVector{<:AbstractString} = String[],
                                    taxa_ids::AbstractVector{<:AbstractString} = String[])
    what = "multiplicative_replacement"
    X = _as_float_matrix(counts, what)
    n_taxa, n_samples = size(X)
    ids_s = _ids(sample_ids, n_samples, "sample", what)
    ids_t = _ids(taxa_ids, n_taxa, "taxon", what)

    δ = Float64(delta)
    if !(0.0 < δ < 1.0)
        throw(ArgumentError(
            "$what: delta must be in (0,1), got $δ. delta is the fraction of the detection " *
            "limit that a replaced zero receives; 0 replaces a zero with a zero and 1 " *
            "replaces it with the detection limit itself. The reference's frac argument and " *
            "issue #21 both put the default at 0.65. See context_help('advanced.zero_policy')."))
    end

    notes = String[]
    if δ < 0.01
        msg = "$what: delta = $δ is below 0.01: replaced values sit more than two orders of magnitude below the detection limit, which exaggerates every log-ratio that involves a replaced zero. 0.65 is the published default."
        push!(notes, msg)
        @warn msg delta = δ
    elseif δ >= 0.9
        msg = "$what: delta = $δ is at or above 0.9: replaced values sit within 10% of the detection limit, so a zero and an observed minimum are hard to tell apart in the transformed table. 0.65 is the published default."
        push!(notes, msg)
        @warn msg delta = δ
    end

    dl_source = if isnothing(detection_limits)
        "minimum observed value per taxon (the reference's default when no dl is supplied)"
    else
        "supplied by the caller"
    end
    dl = isnothing(detection_limits) ?
        _per_taxon_detection_limits(X, ids_t, what) :
        _checked_supplied_limits(detection_limits, n_taxa, ids_t, what)

    replaced = copy(X)
    per_sample = Vector{OrderedDict{String,Any}}(undef, n_samples)
    total_imputed = 0.0
    total_replaced_entries = 0

    for j in 1:n_samples
        sample_total = sum(X[:, j])
        zero_rows = Int[i for i in 1:n_taxa if X[i, j] == 0.0]
        detail = OrderedDict{String,Any}(
            "sample" => ids_s[j],
            "total" => sample_total,
            "zeros" => length(zero_rows),
        )
        if isempty(zero_rows)
            detail["imputed_mass"] = 0.0
            detail["delta_used"] = δ
            per_sample[j] = detail
            continue
        end
        sample_total > 0 ||
            throw(ArgumentError(
                "$what: sample '$(ids_s[j])' (column $j) has a total of 0 counts. Every " *
                "value in it is zero, so there is no observed subcomposition to preserve and " *
                "nothing for the replacement to be relative to. All-zero samples are healed " *
                "before zero replacement (drop, impute or refuse, per drop_policy), so " *
                "reaching here means the healing was bypassed. Refusing."))
        limit_sum = sum(dl[i] for i in zero_rows)
        Δ = δ * limit_sum / sample_total
        if Δ >= 1.0
            delta_max = sample_total / limit_sum
            throw(ArgumentError(
                "$what: sample '$(ids_s[j])' has $(length(zero_rows)) zeros whose detection " *
                "limits sum to $(limit_sum) against a total of $(sample_total), so delta = " *
                "$δ would place $(Δ) of the sample's mass in replaced values — at or beyond " *
                "the whole sample. The observed parts could only be scaled by " *
                "$(1 - Δ), which is not positive. The largest delta this sample admits is " *
                "$(delta_max); the reference stops on the same condition " *
                "(\"Estimated replacement values exceed or equal the row total\"). " *
                "Options: lower delta, raise advanced.min_prevalence so that sparse taxa " *
                "are filtered rather than imputed, or use the pseudocount policy."))
        end

        replaced[zero_rows, j] .= δ .* dl[zero_rows]
        observed_rows = Int[i for i in 1:n_taxa if !(i in zero_rows)]
        for i in observed_rows
            replaced[i, j] = (1.0 - Δ) * X[i, j]
        end

        total_imputed += Δ * sample_total
        total_replaced_entries += length(zero_rows)
        detail["imputed_mass"] = Δ
        detail["imputed_mass_counts"] = Δ * sample_total
        detail["delta_used"] = δ
        detail["scale_factor_for_observed"] = 1.0 - Δ
        detail["smallest_replaced_value"] = δ * minimum(dl[i] for i in zero_rows)
        detail["largest_replaced_value"] = δ * maximum(dl[i] for i in zero_rows)
        per_sample[j] = detail
    end

    _verify_invariants(X, replaced, what, ids_t, ids_s)

    diagnostics = OrderedDict{String,Any}(
        "method" => what,
        "delta" => δ,
        "detection_limits_source" => dl_source,
        "detection_limits" => dl,
        "taxa_ids" => ids_t,
        "zeros_replaced" => total_replaced_entries,
        "imputed_mass_total" => total_imputed,
        "per_sample" => per_sample,
    )

    provenance = OrderedDict{String,Any}(
        "zero_replacement_method" => what,
        "multiplicative_replacement_delta" => δ,
        "multiplicative_replacement_detection_limits" =>
            dl_source == "supplied by the caller" ? "supplied per taxon by the caller" :
            "minimum observed value per taxon",
        "multiplicative_replacement_definition" =>
            "x̃_ij = delta*DL_i for zeros; x̃_ij = (1 - Delta_j)*x_ij otherwise, with " *
            "Delta_j the imputed mass of sample j as a fraction of its total; " *
            "totals and observed-part ratios preserved exactly",
        "zero_replacement_is_biased" =>
            "true, and not a defect: a replaced value is not a measurement. No rule " *
            "determined by the observed data can be faithful for both of two datasets that " *
            "agree on which entries are zero (proofs/agda/NoRigidReplacement.agda). Occupancy " *
            "models and zero-inflated/hurdle count models are the alternatives that insert " *
            "nothing; see docs/statistics/zero-handling.md.",
        "zero_replacement_reference" =>
            "Martín-Fernández, Barceló-Vidal & Pawlowsky-Glahn (2003), Math Geol 35(3):253-278; " *
            "as implemented in zCompositions::multRepl (frac = delta, dl per part). Identical to " *
            "the reference on closed tables (divisor and closure cancel there); on count tables " *
            "with differing totals this implementation preserves each total and the reference " *
            "does not. Dividing the result by the sample total gives the reference's " *
            "proportional output in both regimes.",
        "zero_replacement_invariants" =>
            "checked at runtime and proved in proofs/agda/ZeroReplacement.agda: sample totals " *
            "preserved, observed-part ratios preserved, no zero left, replaced values strictly " *
            "positive and below their own part's detection limit",
    )

    return ZeroReplacementOutcome(replaced, what, δ, nothing, notes, diagnostics, provenance)
end

# ---------------------------------------------------------------------------
# Bayesian multiplicative replacement — Martín-Fernández et al. (2015), GBM
# ---------------------------------------------------------------------------

function _weighted_gmean(values::Vector{Float64})
    n = length(values)
    n > 0 || throw(ArgumentError("cannot take a geometric mean of no values"))
    for v in values
        v > 0 || return 0.0
    end
    return exp(sum(log, values) / n)
end

"""
    bayesian_multiplicative(counts; alpha, threshold, adjust, sample_ids, taxa_ids)
        -> ZeroReplacementOutcome

Bayesian multiplicative replacement (the "GBM" of Martín-Fernández et al. 2015), over the
columns (samples) of `counts`.

For sample *j* with total `S_j`, form the leave-one-out counts `A_i = Σ_{k≠j} x_ik`, the
prior mean `t_i = A_i / Σ_i A_i`, and the prior concentration `s = 1 / gmean(t)` — the
reference's own estimate, `s = 1/apply(t,1,function(x) exp(mean(log(x))))`. The value
inserted for a zero is the posterior mean of the Dirichlet-multinomial model with that prior,

    p̃_ij = t_i · s / (S_j + s),

the same quantity `cmultRepl(method = "GBM")` computes as `repl <- t*(s/(n+s))`. Observed
parts are then multiplied by `1 - Σ_{i∈Z_j} p̃_ij`, which closes the sample.

`alpha` overrides `s` with a concentration the caller supplies. It is *not* part of the
reference's GBM: the reference always estimates `s` from the data. Supplying it is therefore
recorded in provenance as a deviation, and validated: `alpha > 0`, with notes below 0.01
(the prior is nearly improper and replaced values collapse toward zero, whatever the data
says) and at or above the largest sample total (the prior outweighs every sample's own
counts).

`adjust` (default `true`) reproduces the reference's `adjust = TRUE` step: a replaced value
that would exceed `threshold × (smallest observed proportion of that part)` is capped there,
and the number of capped entries is reported. Uncapped posterior means are kept when
`adjust = false`.

Refusals:

- a part observed in fewer than two samples, where some leave-one-out count `A_i` is zero
  and the reference stops with "not enough information to compute t hyper-parameter";
- a sample whose replaced mass would reach or exceed its total (`Σ p̃ ≥ 1`);
- `alpha ≤ 0` or non-finite, `threshold ∉ (0,1)`.

The concentration `s` is a *model* quantity: it is estimated from the rest of the table, so a
`bayesian_multiplicative` replacement is a posterior mean, not a measurement. The provenance
says so in the same words as the multiplicative one.
"""
function bayesian_multiplicative(counts::AbstractMatrix{<:Real};
                                 alpha::Union{Real,Nothing} = nothing,
                                 threshold::Real = DEFAULT_BAYESIAN_THRESHOLD,
                                 adjust::Bool = true,
                                 sample_ids::AbstractVector{<:AbstractString} = String[],
                                 taxa_ids::AbstractVector{<:AbstractString} = String[])
    what = "bayesian_multiplicative"
    X = _as_float_matrix(counts, what)
    n_taxa, n_samples = size(X)
    ids_s = _ids(sample_ids, n_samples, "sample", what)
    ids_t = _ids(taxa_ids, n_taxa, "taxon", what)

    thr = Float64(threshold)
    (0.0 < thr < 1.0) ||
        throw(ArgumentError("$what: threshold must be in (0,1), got $thr. It caps a replaced value at threshold × the smallest observed proportion of its part; 0.65 is the reference's default."))

    α = isnothing(alpha) ? nothing : Float64(alpha)
    if !isnothing(α)
        isfinite(α) ||
            throw(ArgumentError("$what: alpha = $α is not finite. Refusing."))
        α > 0.0 ||
            throw(ArgumentError("$what: alpha must be > 0, got $α; it is the concentration of the Dirichlet prior, and a concentration of zero is not a prior. See context_help('advanced.bayesian_multiplicative_alpha')."))
    end

    notes = String[]
    if !isnothing(α) && α < 0.01
        msg = "$what: alpha = $α is below 0.01: the Dirichlet prior carries almost no mass, so replaced values collapse toward zero regardless of what the rest of the table shows, and log-ratios involving them become extreme. The reference estimates s from the data; omit alpha to do the same."
        push!(notes, msg)
        @warn msg alpha = α
    elseif !isnothing(α) && α >= maximum(sum(X, dims = 1))
        msg = "$what: alpha = $α is at or above the largest sample total ($(maximum(sum(X, dims = 1)))), so the prior outweighs every sample's own counts and the data barely moves the posterior mean. The reference estimates s from the data; omit alpha to do the same."
        push!(notes, msg)
        @warn msg alpha = α
    end

    # Per-part smallest observed proportion, the cap the reference's adjust step applies.
    col_mins = fill(Inf, n_taxa)
    for i in 1:n_taxa
        row_total = sum(X[i, :])
        row_total > 0 || continue
        for j in 1:n_samples
            X[i, j] > 0 && (col_mins[i] = min(col_mins[i], X[i, j] / sum(X[:, j])))
        end
    end

    observed_in = [count(>(0), X[i, :]) for i in 1:n_taxa]
    thin = Int[i for i in 1:n_taxa if 0 < observed_in[i] < 2]
    if !isempty(thin)
        thin_names = join(["'" * ids_t[i] * "'" for i in thin], ", ")
        throw(ArgumentError(
            "$what: taxa $thin_names are observed in " *
            "fewer than two samples, so the leave-one-out prior mean t has a zero entry for " *
            "them and the Dirichlet prior is not defined on those parts. " *
            "zCompositions::cmultRepl(method = \"GBM\") stops on the same condition " *
            "(\"not enough information to compute t hyper-parameter\"). " *
            "Options: raise advanced.min_prevalence so that these taxa are filtered, or use " *
            "multiplicative_replacement, which needs only the smallest observed value of " *
            "each part and does not pool information across samples."))
    end

    replaced = copy(X)
    per_sample = Vector{OrderedDict{String,Any}}(undef, n_samples)
    total_capped = 0
    total_replaced_entries = 0

    for j in 1:n_samples
        sample_total = sum(X[:, j])
        zero_rows = Int[i for i in 1:n_taxa if X[i, j] == 0.0]
        detail = OrderedDict{String,Any}(
            "sample" => ids_s[j],
            "total" => sample_total,
            "zeros" => length(zero_rows),
        )
        if isempty(zero_rows)
            detail["imputed_mass"] = 0.0
            per_sample[j] = detail
            continue
        end
        sample_total > 0 ||
            throw(ArgumentError(
                "$what: sample '$(ids_s[j])' (column $j) has a total of 0 counts, so the " *
                "count scale the posterior mean is computed in does not exist. All-zero " *
                "samples are healed before zero replacement. Refusing."))

        leave_one_out = Float64[sum(X[i, :]) - X[i, j] for i in 1:n_taxa]
        total_other = sum(leave_one_out)
        if total_other <= 0
            throw(ArgumentError(
                "$what: sample '$(ids_s[j])' is the only sample with any counts, so the " *
                "leave-one-out prior has nothing to average over and no prior mean can be " *
                "formed. Refusing; multiplicative_replacement needs no other samples."))
        end
        t = leave_one_out ./ total_other
        if any(==(0.0), t)
            bad = String[ids_t[i] for i in 1:n_taxa if t[i] == 0.0]
            bad_names = join(bad, ", ")
            throw(ArgumentError(
                "$what: for sample '$(ids_s[j])' the leave-one-out prior mean is zero for " *
                "taxa $bad_names, which the reference refuses as well. Raise " *
                "advanced.min_prevalence or use multiplicative_replacement."))
        end

        s = isnothing(α) ? 1.0 / _weighted_gmean(t) : α
        p̃ = Float64[t[i] * (s / (sample_total + s)) for i in zero_rows]

        capped = 0
        if adjust
            for (k, i) in enumerate(zero_rows)
                cap = thr * col_mins[i]
                if isfinite(cap) && p̃[k] > cap
                    p̃[k] = cap
                    capped += 1
                end
            end
        end

        imputed_mass = sum(p̃)
        if imputed_mass >= 1.0
            throw(ArgumentError(
                "$what: sample '$(ids_s[j])' would place $(imputed_mass) of its mass in " *
                "replaced values, leaving no mass for the observed parts. The posterior mean " *
                "is t_i·s/(S_j+s) with s = $(s) and S_j = $(sample_total); lower alpha, " *
                "raise advanced.min_prevalence, or use multiplicative_replacement. Refusing."))
        end

        # The posterior means are proportions; the reference returns p-counts by converting
        # them back with the sample total (`X[i,zero] <- (X[i,pos]/X2[i,pos])*X2[i,zero]`,
        # where `X[i,pos]/X2[i,pos]` is the row total). The observed parts are rescaled in the
        # proportion scale and then converted the same way, which is why the table below is
        # multiplied by the sample total exactly once.
        for (k, i) in enumerate(zero_rows)
            replaced[i, j] = p̃[k] * sample_total
        end
        for i in 1:n_taxa
            if X[i, j] > 0
                replaced[i, j] = (1.0 - imputed_mass) * X[i, j]
            end
        end

        total_capped += capped
        total_replaced_entries += length(zero_rows)
        detail["imputed_mass"] = imputed_mass
        detail["imputed_mass_counts"] = imputed_mass * sample_total
        detail["prior_concentration_s"] = s
        detail["prior_concentration_source"] = isnothing(α) ? "estimated as 1/gmean(t) (the reference's GBM)" : "supplied as alpha (deviation from the reference)"
        detail["capped_imputations"] = capped
        per_sample[j] = detail
    end

    _verify_invariants(X, replaced, what, ids_t, ids_s)

    diagnostics = OrderedDict{String,Any}(
        "method" => what,
        "alpha" => α,
        "threshold" => thr,
        "adjust" => adjust,
        "taxa_observed_in_fewer_than_two_samples" => length(thin),
        "zeros_replaced" => total_replaced_entries,
        "capped_imputations" => total_capped,
        "per_sample" => per_sample,
    )

    provenance = OrderedDict{String,Any}(
        "zero_replacement_method" => what,
        "bayesian_multiplicative_alpha" => isnothing(α) ? "estimated from the data as 1/gmean(t) (the reference's GBM)" : α,
        "bayesian_multiplicative_threshold" => thr,
        "bayesian_multiplicative_adjust" => adjust,
        "bayesian_multiplicative_definition" =>
            "posterior mean of a Dirichlet-multinomial model with prior mean t (leave-one-out " *
            "compositional profile of the other samples) and prior concentration " *
            "s = 1/gmean(t) unless alpha is supplied; p̃_i = t_i*s/(S_j+s) for zeros, observed " *
            "parts rescaled by 1 - Σp̃; totals and observed-part ratios preserved exactly. " *
            "Equal to cmultRepl output=\"prop\" times the sample total: the reference computes " *
            "the same proportions and its p-counts output converts them back with the row " *
            "total (X[i,pos]/X2[i,pos]) without rescaling the observed parts, so its count " *
            "output does not preserve the total while this one does.",
        "zero_replacement_is_biased" =>
            "true, and not a defect: the posterior mean of a prior estimated from the other " *
            "samples is a model quantity, not a measurement. See " *
            "docs/statistics/zero-handling.md and proofs/agda/NoRigidReplacement.agda.",
        "zero_replacement_reference" =>
            "Martín-Fernández, Hron, Templ, Filzmoser & Palarea-Albaladejo (2015), " *
            "Stat Modelling 15(2):134-158; as implemented in zCompositions::cmultRepl " *
            "method=\"GBM\" (t leave-one-out, s = 1/gmean(t), repl = t*(s/(n+s)), adjust caps " *
            "at frac*colmins)",
        "zero_replacement_invariants" =>
            "checked at runtime and proved in proofs/agda/ZeroReplacement.agda: sample totals " *
            "preserved, observed-part ratios preserved, no zero left, replaced values strictly " *
            "positive",
    )

    return ZeroReplacementOutcome(replaced, what, α, α, notes, diagnostics, provenance)
end

# ---------------------------------------------------------------------------
# Help text
# ---------------------------------------------------------------------------

"""
    describe_zero_policy(policy::AbstractString) -> String

The comparison a user needs before choosing a zero policy: what each one does to the numbers,
what it costs, and when it is the wrong tool. Used by the API's context help and by the
frontend, so the two cannot drift apart.
"""
function describe_zero_policy(policy::AbstractString)
    key = lowercase(strip(policy))
    if key == "pseudocount"
        return """
        pseudocount — add a constant (default 0.5) to counts, so a zero becomes 0.5 and an \
        observed 1 becomes 1.5. Simple, and the ratio is wrong: 0:1 is reported as 0.5:1.5 = \
        1:3. The distortion shrinks with the constant in absolute terms and grows in relative \
        terms for rare features, which is exactly where low-abundance biology lives. Use it \
        when the transform needs strictly positive values and nothing better is available."""
    elseif key == "multiplicative_replacement"
        return """
        multiplicative_replacement (Martín-Fernández, Barceló-Vidal & Pawlowsky-Glahn 2003) — \
        replace a zero with delta × its detection limit (delta in (0,1), default 0.65, the \
        detection limit being the smallest observed value of that feature), and multiply the \
        observed features of the same sample by 1 - Δ so the sample total and every observed \
        ratio are preserved exactly. Better than a pseudocount wherever the ratios matter \
        (CLR/ILR, ANCOM-BC-style analyses), because the observed parts keep their relative \
        sizes. Still an insertion: the replaced value is a statement about the detection \
        limit, not about the feature. Setting delta is a research decision — record it, and \
        do not try several values and report one (provenance keeps the value, and this \
        repository raises a DANGER banner if a run is compared across more than three \
        deltas)."""
    elseif key == "bayesian_multiplicative"
        return """
        bayesian_multiplicative (Martín-Fernández, Hron, Templ, Filzmoser & \
        Palarea-Albaladejo 2015, the "GBM" of zCompositions) — replace a zero with the \
        posterior mean of a Dirichlet-multinomial model whose prior mean is the compositional \
        profile of the *other* samples and whose concentration is estimated as 1/gmean(t), \
        then rescale the observed parts to close the sample. Totals and observed ratios are \
        preserved exactly. It borrows strength across samples, which suits sparse tables, and \
        it is a model quantity: the prior comes from the rest of the data, so the replaced \
        value moves when the other samples move. It refuses when a feature is observed in \
        fewer than two samples, where the prior mean is zero. advanced.bayesian_multiplicative_alpha \
        overrides the estimated concentration (recorded as a deviation from the reference), \
        which is the parameter to touch when the posterior means look implausibly large."""
    elseif key == "refuse"
        return """
        refuse — do not replace zeros at all. Valid for a count model that handles zeros \
        (nb_glm), where inserting counts into the response is a modelling choice rather than \
        a requirement. Mathematically invalid for CLR/ILR, where log(0) is undefined: the \
        configuration layer refuses it there regardless of the acknowledgement token."""
    end
    throw(ArgumentError("unknown zero policy '$policy'; expected one of pseudocount, multiplicative_replacement, bayesian_multiplicative, refuse"))
end

end # module ZeroReplacement
