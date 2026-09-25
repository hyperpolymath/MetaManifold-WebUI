# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Catalogue item 2 of docs/statistics/method-catalogue-v1.md — parametric fits with
# explicit constraint, convergence and identifiability reporting.
#
# Conditions were published before this implementation, as the catalogue requires:
#   docs/statistics/method-conditions/parametric-fits.md
#
# This module exists because the layer it replaces did not compute anything. The block
# it replaces in Execution.run_analysis derived its p-values from
# `p_val = 0.01 + (h % 100) / 1000.0` where `h` was the hash of the taxon id — a deterministic
# function of the feature NAME, carrying no information about the counts. The source
# called it a stub; the caller received it as a result. A stub that is returned as a
# result is a wrong answer, so it is gone rather than deprecated.
#
# The rule this module follows: a fit that cannot be performed produces NO number and
# a reason. There is no warn-and-carry-on path in this file that ends in a statistic.
#
# R is the estimator, deliberately. The pinned environment already carries R (RCall
# cannot build without it), renv.lock pins MASS, and the pipeline's other statistical
# work — NMDS, PERMANOVA, alpha significance — already runs there under one shared
# lock. Writing a negative binomial GLM by hand here would add a second, unvalidated
# implementation of a fitted model; docs/statistics/method-conditions/parametric-fits.md
# records why that trade was refused, and what this layer does and does not claim.

module Estimation

using Dates, Logging, OrderedCollections, SHA
using CSV
import JSON3
using RCall
using ..RRuntime: with_r_lock, RBusyError
import ..AnalysisConfig

export EstimationOutcome, estimate_models, bh_adjust, supported_terms, primary_term,
       UnsupportedFormula, ESTIMATE_SCALE, REFUSED_DISPERSION, SUPPORTED_DISPERSION

# ---------------------------------------------------------------------------
# What this module will not do
# ---------------------------------------------------------------------------

"""
    UnsupportedFormula(formula, detail)

Thrown when a formula asks for a model this layer does not implement. Refusing is the
point: a term silently dropped from a design changes every estimate in the table, and a
term silently *added* would do the same.
"""
struct UnsupportedFormula <: Exception
    formula :: String
    detail  :: String
end

Base.showerror(io::IO, e::UnsupportedFormula) =
    print(io, "Unsupported formula '", e.formula, "': ", e.detail)

"""
    REFUSED_DISPERSION

Dispersion methods that are accepted as *configuration strings* — they are named in the
v1 catalogue and in issue #21 — but are not implemented here. Each is refused by name,
with a reason, rather than aliased to the one estimator this release implements.

Why refusal rather than a fallback: dispersion is the parameter that sets every standard
error in a negative binomial fit. A run that asked for `glmGamPoi` and silently received
per-taxon maximum-likelihood theta would report different confidence intervals and
different multiple-testing outcomes under a label that says otherwise. See
`docs/statistics/method-conditions/parametric-fits.md`.
"""
const REFUSED_DISPERSION = Dict{String,String}(
    "glmGamPoi" => "not implemented: the pinned R library (renv.lock) has no glmGamPoi, and the quasi-likelihood estimator that issue #21 asks for has not been written or validated here. Refusing the alias that v1 shipped.",
    "local"     => "not implemented: the trended (local) dispersion fit is not implemented. Refusing to substitute the per-taxon estimator.",
    "mean"      => "not implemented: the mean-dispersion fit is not implemented. Refusing to substitute the per-taxon estimator.",
    "pooled"    => "not implemented: the pooled single-theta fit is not implemented in this release. Refusing to substitute the per-taxon estimator.",
)

const SUPPORTED_DISPERSION = ("parametric",)

"""
The strings R's `write.csv(..., na = "NA")` uses for a missing value. CSV.jl's default
`missingstring` is only `""`, so without this a numeric column holding one `NA` is read as a
string column and every later `isfinite` throws — which turned every fit into `not_run`.
"""
const R_NA_STRINGS = ["NA", ""]

"""
    _refused_dispersion(name) -> Union{Nothing,Pair{String,String}}

Look a dispersion name up in `REFUSED_DISPERSION` without regard to case: the configuration
layer lower-cases what it stores, and a `glmgampoi` has to meet the same refusal, with the
same reason, as `glmGamPoi`.
"""
function _refused_dispersion(name::AbstractString)
    key = lowercase(strip(name))
    for (k, v) in REFUSED_DISPERSION
        lowercase(k) == key && return k => v
    end
    return nothing
end

"""
    ESTIMATE_SCALE

What the `estimate` column is *in*, per method. A number whose units are unstated is not
a result, and "log2 fold change" is the wrong name for a difference in CLR units.
"""
const ESTIMATE_SCALE = Dict{AnalysisConfig.AnalysisMethod,String}(
    AnalysisConfig.NB_GLM   => "log_counts: the log-link coefficient, so log2FoldChange = estimate / log(2)",
    AnalysisConfig.CLR_LM   => "clr_difference: a difference in centred-log-ratio units, not a fold change",
    AnalysisConfig.ILR_LM   => "ilr_balance: a difference in isometric-log-ratio balance units, not a fold change",
    AnalysisConfig.LOGISTIC => "log_odds: the logistic coefficient, so odds_ratio = exp(estimate)",
)

# ---------------------------------------------------------------------------
# Formula: the supported subset, published and small
# ---------------------------------------------------------------------------

const TERM_PATTERN = r"^[A-Za-z][A-Za-z0-9_.]*$"

# Constructs with meaning that this layer does not implement. Refusing each by name is
# cheaper than explaining later why the design was not the one that was written down.
const REFUSED_CONSTRUCTS = Dict{String,String}(
    "*" => "interaction terms ('*') are not implemented; write main effects only",
    ":" => "interaction terms (':') are not implemented; write main effects only",
    "|" => "random effects ('|') are not implemented",
    "(" => "transformed terms such as I(x) or log(x) are not implemented; precompute the column",
    ")" => "transformed terms such as I(x) or log(x) are not implemented; precompute the column",
    "," => "functions of several arguments are not implemented",
    "^" => "polynomial terms ('^') are not implemented; precompute the column",
    "/" => "nested terms ('/') are not implemented; write main effects only",
    "-" => "'-' both removes a term and appears inside column names; it is refused so that neither reading happens by accident",
    "[" => "indexing is not implemented",
    "]" => "indexing is not implemented",
)

"""
    supported_terms(formula) -> Vector{String}

Parse the right-hand side of an R-style formula into the additive main effects this layer
supports, or throw `UnsupportedFormula`.

Supported: `~ a`, `~ a + b`, `~ a + b + c`, where every term is a plain column name
(`^[A-Za-z][A-Za-z0-9_.]*`). Everything else — interactions, transformations, random
effects, nesting, polynomial terms, functions — is refused with a reason naming the
construct, because the design matrix is the one part of a fit that must never be quietly
not what was asked for.
"""
function supported_terms(formula::AbstractString)::Vector{String}
    text = strip(String(formula))
    occursin("~", text) ||
        throw(UnsupportedFormula(text, "an R-style formula needs a '~', e.g. '~ group'"))
    parts = split(text, "~"; limit = 2)
    rhs = strip(parts[2])
    isempty(rhs) &&
        throw(UnsupportedFormula(text, "the right-hand side is empty; name at least one metadata column"))

    for (token, why) in REFUSED_CONSTRUCTS
        occursin(token, rhs) && throw(UnsupportedFormula(text, why))
    end

    # Defence in depth rather than duplication: AnalysisConfig already refuses these in a
    # formula, and this is the last checkpoint before the text is pasted into an R call, so it
    # refuses them too. A backtick or a newline would otherwise let a formula name something
    # that is not a column at all.
    for (token, why) in [
        ("\$"  => "a '\$' cannot appear in a formula; column names are plain identifiers"),
        ("`"   => "backticks are not permitted in a formula; column names are plain identifiers"),
        (";"   => "';' would run more than one statement; a formula names a model, not a script"),
        ("\n" => "a newline cannot appear in a formula"),
        ("\\" => "a backslash cannot appear in a formula"),
    ]
        occursin(token, rhs) && throw(UnsupportedFormula(text, why))
    end

    terms = String[]
    for raw in split(rhs, "+")
        term = strip(raw)
        isempty(term) &&
            throw(UnsupportedFormula(text, "there is a '+' with no term beside it"))
        occursin(TERM_PATTERN, term) ||
            throw(UnsupportedFormula(text, "term '$term' is not a plain column name (letters, digits, '_', '.'); see context_help('formula')"))
        push!(terms, term)
    end

    length(unique(terms)) == length(terms) ||
        throw(UnsupportedFormula(text, "the same term appears more than once"))

    return terms
end

"""
    primary_term(formula) -> String

The first term on the right-hand side. It is the coefficient the per-feature table reports,
and the coefficient the Benjamini-Hochberg family is built from; every other coefficient is
reported beside it in `all_coefficients`, and the contrast it stands for is recorded in the
provenance. This is a stated convention, not a default that varies with the data: the first
term is the contrast of interest because the caller wrote it first.
"""
primary_term(formula::AbstractString) = first(supported_terms(formula))

# ---------------------------------------------------------------------------
# Multiple testing: BH, implemented here and checked against R's p.adjust
# ---------------------------------------------------------------------------

"""
    bh_adjust(pvalues) -> Vector{Float64}

Benjamini-Hochberg step-up adjusted p-values, with the monotonicity constraint enforced. A
p-value that is not finite and in `[0, 1]` is a *failed fit*, not a number to adjust: it
raises `ArgumentError` so the caller has to surface it.

`test/unit/test_estimation.jl` compares this against R's `p.adjust(method="BH")` rather than
against a second implementation of the same reasoning.
"""
function bh_adjust(pvalues::AbstractVector{<:Real})::Vector{Float64}
    n = length(pvalues)
    n == 0 && return Float64[]
    for (i, p) in enumerate(pvalues)
        if !(isfinite(p) && 0 <= p <= 1)
            throw(ArgumentError("bh_adjust received a p-value that is not a probability at position $i ($p). A fit that did not produce a testable p-value is an unsuccessful state and must be reported as one, not adjusted."))
        end
    end

    order = sortperm(collect(pvalues))
    sorted = Float64[Float64(pvalues[i]) for i in order]
    adjusted = Vector{Float64}(undef, n)
    running = Inf
    for i in n:-1:1
        running = min(running, sorted[i] * n / i)
        adjusted[i] = min(running, 1.0)
    end

    out = Vector{Float64}(undef, n)
    for (rank, idx) in enumerate(order)
        out[idx] = adjusted[rank]
    end
    return out
end

# ---------------------------------------------------------------------------
# Outcome
# ---------------------------------------------------------------------------

"""
    EstimationOutcome

`status` is one of:

- `:ok`      — every feature in the table produced a testable fit
- `:partial` — some features did not; each one says so in its own row, and the count is in
                `diagnostics["n_failed"]`
- `:not_run` — no fit was attempted, because the design or the runtime was not available.
                `reason` says which, and `results` is empty.

There is no fourth status meaning "something plausible was produced".
"""
struct EstimationOutcome
    status      :: Symbol
    reason      :: String
    method      :: String
    results     :: OrderedDict{String,Any}
    diagnostics :: OrderedDict{String,Any}
    provenance  :: OrderedDict{String,Any}
end

function _not_run(method::String, reason::String; err = nothing)::EstimationOutcome
    @warn "Analysis not run — no statistics were produced" method reason
    diagnostics = OrderedDict{String,Any}("status" => "not_run", "reason" => reason)
    isnothing(err) || (diagnostics["exception_type"] = string(typeof(err)))
    results = OrderedDict{String,Any}()
    provenance = OrderedDict{String,Any}("status" => "not_run", "reason" => reason,
                                         "method" => method)
    return EstimationOutcome(:not_run, reason, method, results, diagnostics, provenance)
end

# `nothing` rather than NaN: a JSON null is visibly absent, while a NaN that reaches a
# browser table renders as "#N/A" or as 0 depending on the reader. Absent must look absent.
_num(x)::Union{Float64,Nothing} = (ismissing(x) || !isfinite(x)) ? nothing : Float64(x)
_str(x)::String = ismissing(x) ? "" : String(x)
_bool(x)::Bool = x === true || (x isa AbstractString && uppercase(String(x)) == "TRUE")

# ---------------------------------------------------------------------------
# Design
# ---------------------------------------------------------------------------

"""
    _column_vectors(sample_metadata) -> Dict{String,Vector}

Accept the shapes callers actually have to hand: a dictionary of column name to per-sample
vector, or a vector of per-sample dictionaries. Anything else is refused rather than guessed
at, and a column with a missing value is refused too — a fit cannot be run on a design that
is partly absent without deciding what the absent entries were, and this layer does not make
that decision for the caller.
"""
function _column_vectors(sample_metadata)::Dict{String,Vector}
    cols = Dict{String,Vector}()

    if sample_metadata isa AbstractDict
        for (k, v) in sample_metadata
            name = String(k)
            v isa AbstractVector ||
                throw(ArgumentError("sample_metadata['$name'] is a $(typeof(v)); this layer needs one value per sample, as a vector, e.g. \"group\" => [\"a\", \"a\", \"b\", \"b\"]."))
            values = collect(v)
            if any(x -> x === missing || x === nothing || (x isa AbstractString && isempty(x)), values)
                throw(ArgumentError("sample_metadata['$name'] has missing value(s). A design with holes in it is not the design the formula describes; refusing rather than dropping samples silently."))
            end
            cols[name] = values
        end
        return cols
    end

    if sample_metadata isa AbstractVector
        for row in sample_metadata
            row isa AbstractDict ||
                throw(ArgumentError("sample_metadata rows must be dictionaries keyed by column name; got $(typeof(row))."))
            for (k, v) in row
                push!(get!(cols, String(k), Vector{Any}()), v)
            end
        end
        return cols
    end

    throw(ArgumentError("sample_metadata must be a dictionary of column => per-sample vector, or a vector of per-sample dictionaries; got $(typeof(sample_metadata))."))
end

# RCall needs a concrete vector type to cross the boundary; a Vector{Any} of strings is not
# one. Non-numeric columns travel as character and are made factors in R.
function _r_vector(values::Vector)::Union{Vector{String},Vector{Float64}}
    if all(v -> v isa Real && !(v isa Bool), values)
        return Float64[Float64(v) for v in values]
    end
    return String[string(v) for v in values]
end

# ---------------------------------------------------------------------------
# Fitting
# ---------------------------------------------------------------------------

"""
    estimate_models(config, prepared; sample_metadata, offset, taxa_ids, sample_ids,
                    seed, r_wait_seconds) -> EstimationOutcome

Fit the model named by `config.method` to every row of `prepared`, with the design named by
`config.formula`, and return per-feature estimates.

What is supported, and what happens otherwise:

- `formula` — additive main effects over metadata columns. Anything else is refused with
  `UnsupportedFormula`.
- `nb_glm` — `MASS::glm.nb` per feature, with an offset. An offset is **required**: comparing
  counts across samples without one compares library sizes.
- `clr_lm`, `ilr_lm` — `stats::lm` per feature on the transformed table. An offset is refused
  here, because an offset has no meaning for a Gaussian fit on CLR units.
- `logistic` — `stats::glm(family = binomial)` on a 0/1 response. A non-binary response is
  refused: a binomial fit on proportions needs the number of trials, and this layer will not
  invent weights.
- `advanced.dispersion_method` — `parametric` only. Everything else is refused by name; see
  `REFUSED_DISPERSION`.

Unsuccessful states are reported, not smoothed over: a feature whose fit fails gets
`status = "failed"`, a `note` saying why, and `nothing` for every statistic. It is excluded
from the BH family, and the number of exclusions is reported — an exclusion rate high enough
to matter is a finding about the data, not a detail.
"""
function estimate_models(config::AnalysisConfig.AnalysisConfig,
                         prepared::Matrix{Float64};
                         sample_metadata = nothing,
                         offset::Union{Vector{Float64},Nothing} = nothing,
                         taxa_ids::Vector{String} = String[],
                         sample_ids::Vector{String} = String[],
                         seed::Integer = 0,
                         r_wait_seconds::Real = 10.0)::EstimationOutcome

    method = config.method
    method_str = AnalysisConfig.METHOD_TO_STRING[method]
    n_features, n_samples = size(prepared)

    # -- the design ------------------------------------------------------
    terms = supported_terms(config.formula)          # throws on unsupported syntax
    prim = first(terms)

    if isnothing(sample_metadata)
        return _not_run(method_str,
            "no sample metadata was supplied, so the design named by '$(config.formula)' cannot be built. The method catalogue is explicit that a missing design means a descriptive summary: this layer will not guess a grouping. Supplying metadata (column => value per sample) is what turns this into a test.")
    end

    cols = _column_vectors(sample_metadata)
    missing_cols = [t for t in terms if !haskey(cols, t)]
    if !isempty(missing_cols)
        return _not_run(method_str,
            "the formula names $(join(missing_cols, ", ")) but the supplied metadata has only $(join(sort(collect(keys(cols))), ", ")). Refusing rather than dropping a term: a design that is not the one written down is a different study.")
    end
    for t in terms
        length(cols[t]) == n_samples ||
            return _not_run(method_str,
                "metadata column '$t' has $(length(cols[t])) values for $n_samples samples. Refusing.")
    end

    primary_levels = unique(cols[prim])
    if length(primary_levels) < 2
        return _not_run(method_str,
            "the primary term '$prim' has $(length(primary_levels)) distinct value(s) across the samples, so there is no contrast to estimate. This is a property of the data, not a failure of the fit.")
    end

    # -- method preconditions (configuration errors: hard refusals) -------
    if method == AnalysisConfig.NB_GLM
        dispersion = lowercase(strip(config.advanced.dispersion_method))
        refused = _refused_dispersion(dispersion)
        isnothing(refused) ||
            throw(ArgumentError("dispersion_method '$(first(refused))' is $(last(refused)) See issue #21 and docs/statistics/method-conditions/parametric-fits.md."))
        dispersion in SUPPORTED_DISPERSION ||
            throw(ArgumentError("dispersion_method '$dispersion' is not one of $(join(SUPPORTED_DISPERSION, ", ")). Refusing."))

        isnothing(offset) &&
            throw(ArgumentError("nb_glm needs an offset: raw counts are not comparable across samples, and a negative binomial fit without library-size or size-factor offsets would attribute sequencing depth to biology. prepare_analysis_table supplies log library size for 'none'/'TSS'/'CSS'/'RSS' and log size factors for 'size_factors'. Refusing."))
        length(offset) == n_samples ||
            throw(ArgumentError("the offset has $(length(offset)) values for $n_samples samples. Refusing."))
        all(isfinite, offset) ||
            throw(ArgumentError("the offset contains non-finite values; it is a log scale factor, so a non-finite entry means the scaling failed upstream. Refusing."))
    else
        isnothing(offset) ||
            throw(ArgumentError("an offset is only defined for count models (nb_glm); method '$method_str' is not one. Refusing to accept and then ignore a parameter that means something to a different method."))
    end

    if method == AnalysisConfig.LOGISTIC
        binary = all(v -> v == 0.0 || v == 1.0, prepared)
        binary ||
            throw(ArgumentError("logistic regression needs a 0/1 response and this prepared table holds values that are not 0 or 1. Use normalization 'presence_absence': a binomial fit on proportions needs the number of trials per sample, and this layer will not supply invented weights. Refusing."))
    end

    # -- row labels ------------------------------------------------------
    row_labels, label_note = _row_labels(method, n_features, taxa_ids)

    # -- the fit, in R ---------------------------------------------------
    dir = mktempdir()
    fits_path = joinpath(dir, "fits.csv")
    coefs_path = joinpath(dir, "coefficients.csv")
    versions = Ref{Dict{String,String}}(Dict{String,String}())
    fit_rows = Ref{Vector}(Any[])
    coef_rows = Ref{Vector}(Any[])
    fits_hash = Ref{String}("")
    coefs_hash = Ref{String}("")

    try
        with_r_lock(; timeout = r_wait_seconds) do
            RCall.reval("est_cols <- list()")
            for (i, t) in enumerate(terms)
                RCall.globalEnv[Symbol("est_c$i")] = _r_vector(cols[t])
                RCall.reval("est_cols[[\"$t\"]] <- est_c$i")
            end
            if isnothing(offset)
                RCall.reval("est_offset <- NULL")
            else
                RCall.globalEnv[:est_offset] = collect(Float64, offset)
            end
            RCall.globalEnv[:est_counts]     = prepared
            RCall.globalEnv[:est_n]          = n_features
            RCall.globalEnv[:est_ns]         = n_samples
            RCall.globalEnv[:est_rhs]        = join(terms, " + ")
            RCall.globalEnv[:est_primary]    = prim
            RCall.globalEnv[:est_method]     = method_str
            RCall.globalEnv[:est_dispersion] = lowercase(strip(config.advanced.dispersion_method))
            RCall.globalEnv[:est_fits_path]  = fits_path
            RCall.globalEnv[:est_coefs_path] = coefs_path

            RCall.reval(R_ESTIMATION_SETUP)
            RCall.reval(R_ESTIMATION_FIT)

            versions[] = Dict(
                "r"              => RCall.rcopy(String, RCall.reval("est_r_version")),
                "mass"           => RCall.rcopy(String, RCall.reval("est_mass_version")),
                "primary_levels" => RCall.rcopy(String, RCall.reval("est_primary_levels_text")),
            )
            fit_rows[] = collect(CSV.File(fits_path; missingstring = R_NA_STRINGS))
            coef_rows[] = collect(CSV.File(coefs_path; missingstring = R_NA_STRINGS))
            RCall.reval("rm(list = ls(pattern = \"^est_\")); gc()")
            return nothing
        end

        fits_hash[] = bytes2hex(sha256(read(fits_path)))
        coefs_hash[] = bytes2hex(sha256(read(coefs_path)))

        return _assemble(config, method, method_str, terms, prim, row_labels, label_note,
                         fit_rows[], coef_rows[], offset, versions[], fits_hash[], coefs_hash[],
                         seed, n_features, n_samples)
    catch err
        # A runtime that cannot produce a fit produces no number. RBusyError is the
        # documented case (a pipeline stage holds the R lock); anything else is reported
        # with its own exception type so it can be diagnosed rather than guessed at.
        reason = err isa RBusyError ?
            "the embedded R runtime was busy for $(r_wait_seconds)s — another task held it. No statistics were produced; retry when the pipeline run has finished." :
            "the fit could not be run: $(sprint(showerror, err))"
        return _not_run(method_str, reason; err = err)
    finally
        rm(dir; recursive = true, force = true)
    end
end

"""
    _row_labels(method, n_features, taxa_ids) -> (Vector{String}, String)

Label rows by feature id when the ids line up with the rows. For ILR the prepared table has
one row per balance, which is not one per taxon, so those rows are named as balances and the
mismatch is recorded rather than papered over with a taxon name that does not describe them.
"""
function _row_labels(method::AnalysisConfig.AnalysisMethod, n_features::Int,
                     taxa_ids::Vector{String})
    if length(taxa_ids) == n_features && !isempty(taxa_ids)
        return (copy(taxa_ids), "row labels are the feature ids supplied by the caller")
    end
    if method == AnalysisConfig.ILR_LM
        return (["balance_$i" for i in 1:n_features],
                "row labels are balances: an ILR table has one row per balance, not one per taxon, so no taxon id is attached to these numbers")
    end
    return (["feature_$i" for i in 1:n_features],
            "no feature ids were supplied; rows are numbered in the order of the prepared table")
end

# ---------------------------------------------------------------------------
# Assembly: R's output -> one outcome, with the BH family stated
# ---------------------------------------------------------------------------

function _assemble(config, method, method_str, terms, prim, row_labels, label_note,
                   fit_rows::Vector, coef_rows::Vector, offset, versions,
                   fits_hash, coefs_hash, seed, n_features, n_samples)
    by_feature = Dict{Int,Vector{Any}}()
    for row in coef_rows
        push!(get!(by_feature, Int(row.taxon_index), Any[]), row)
    end

    statuses = [_str(row.status) for row in fit_rows]
    n_failed = count(==("failed"), statuses)
    n_boundary = count(==("boundary"), statuses)

    # The BH family is the set of features whose fit produced a p-value. Exclusions are
    # counted and reported; they are never replaced by 1.0, which would look like a negative
    # result rather than like a fit that did not happen.
    testable = Int[]
    raw_p = Float64[]
    for (i, row) in enumerate(fit_rows)
        statuses[i] == "failed" && continue
        p = _num(row.pvalue)
        isnothing(p) && continue
        push!(testable, i)
        push!(raw_p, p)
    end

    bh_disabled = config.correction.allow_no_correction
    adjusted = (bh_disabled || isempty(raw_p)) ? Float64[] : bh_adjust(raw_p)

    results = OrderedDict{String,Any}()
    for (i, row) in enumerate(fit_rows)
        status = statuses[i]
        p_raw = _num(row.pvalue)
        padj = nothing
        if !bh_disabled && !isnothing(p_raw) && !isempty(adjusted)
            pos = findfirst(==(i), testable)
            isnothing(pos) || (padj = _num(adjusted[pos]))
        end

        estimate = _num(row.estimate)
        theta = _num(row.dispersion_theta)

        all_coefs = OrderedDict{String,Any}()
        for c in get(by_feature, i, Any[])
            all_coefs[_str(c.term)] = OrderedDict{String,Any}(
                "estimate"       => _num(c.estimate),
                "standard_error" => _num(c.standard_error),
                "statistic"      => _num(c.statistic),
                "pvalue"         => _num(c.pvalue),
                "is_primary"     => _bool(c.is_primary),
            )
        end

        entry = OrderedDict{String,Any}(
            "status"           => status,
            "note"             => _str(row.note),
            "estimate"         => estimate,
            "estimate_scale"   => ESTIMATE_SCALE[method],
            "standard_error"   => _num(row.standard_error),
            "statistic"        => _num(row.statistic),
            "statistic_name"   => _str(row.statistic_name),
            "pvalue"           => p_raw,
            "padj"             => padj,
            "ci_low"           => _num(row.ci_low),
            "ci_high"          => _num(row.ci_high),
            "ci_method"        => "Wald, 95%",
            "residual_df"      => _num(row.residual_df),
            "n_observations"   => _num(row.n_observations),
            "primary_term"     => prim,
            "all_coefficients" => all_coefs,
        )
        if method == AnalysisConfig.NB_GLM
            entry["log2FoldChange"] = isnothing(estimate) ? nothing : estimate / log(2)
            entry["dispersion_theta"] = theta
        elseif method == AnalysisConfig.LOGISTIC
            entry["odds_ratio"] = isnothing(estimate) ? nothing : exp(estimate)
        end
        results[row_labels[i]] = entry
    end

    overall = n_failed == 0 ? :ok : :partial
    reason = n_failed == 0 ? "" :
        "$n_failed of $n_features features did not produce a testable fit; each one says why in its own row. They are excluded from the multiple-testing family, and the exclusions are counted here rather than replaced by a p-value of 1."

    offset_kind = if isnothing(offset)
        "none"
    elseif method == AnalysisConfig.NB_GLM && lowercase(strip(config.normalization.method)) == "size_factors"
        "log(size factor) per sample (median-of-ratios, from the prepared manifest)"
    elseif method == AnalysisConfig.NB_GLM
        "log(library size) per sample (from the prepared manifest)"
    else
        "none"
    end

    diagnostics = OrderedDict{String,Any}(
        "status"        => string(overall),
        "reason"        => reason,
        "method"        => method_str,
        "n_features"    => n_features,
        "n_samples"     => n_samples,
        "n_tested"      => length(testable),
        "n_failed"      => n_failed,
        "n_boundary"    => n_boundary,
        "family"        => bh_disabled ? "BH explicitly disabled by the acknowledging caller (DANGER)" :
                                         "BH (Benjamini-Hochberg) over the $(length(testable)) features with a testable fit",
        "alpha"         => config.correction.alpha,
        "terms"         => terms,
        "primary_term"  => prim,
        "offset"        => offset_kind,
        "row_labels"    => label_note,
        "failure_note"  => n_failed == 0 ? "no failures" :
            "features whose fit failed are excluded from the BH family, which changes what the family is: if a large share failed, the adjusted p-values describe the features that fitted, and whoever reports them has to say so.",
    )

    provenance = OrderedDict{String,Any}(
        "status"                  => string(overall),
        "method"                  => method_str,
        "engine"                  => "R through RCall, serialised on the shared runtime lock",
        "formula"                 => config.formula,
        "terms"                   => terms,
        "primary_term"            => prim,
        "primary_contrast"        => "coefficient of the first term; for a factor this is the contrast between the first two levels of $(get(versions, "primary_levels", "")) (R's default treatment coding)",
        "estimate_scale"          => ESTIMATE_SCALE[method],
        "dispersion_method"       => method == AnalysisConfig.NB_GLM ? lowercase(strip(config.advanced.dispersion_method)) : "not applicable to $method_str",
        "offset"                  => offset_kind,
        "offset_sha256"           => isnothing(offset) ? nothing : bytes2hex(sha256(join(string.(offset), ","))),
        "correction"              => bh_disabled ? "NONE (acknowledged override; DANGER)" : "BH",
        "alpha"                   => config.correction.alpha,
        "r_version"               => get(versions, "r", "unknown"),
        "mass_version"            => get(versions, "mass", "unknown"),
        "fits_csv_sha256"         => fits_hash,
        "coefficients_csv_sha256" => coefs_hash,
        "randomness"              => "none — these fits are deterministic (IRLS / least squares; no permutations or resampling). seed=$seed was supplied by the caller and is not a parameter of any number here.",
        "interval_method"         => "Wald (estimate ± 1.96·SE for z-based fits, t quantile for the Gaussian fits). Profile intervals are not computed: they cost orders of magnitude more per feature and would not change which features are reported.",
    )

    return EstimationOutcome(overall, reason, method_str, results, diagnostics, provenance)
end

# ---------------------------------------------------------------------------
# The R that does the work
#
# Held to the repository's boundary rule: values cross through CSV rather than as R objects,
# so an NA arrives in Julia as a missing value and never as a zero or a NaN that a downstream
# reader would render as a number. R list elements are reached with [[ ]] rather than with $,
# which keeps the embeddable-R lint (config/ci/lint_source.jl, check 2) honest instead of
# having to exempt this file.
# ---------------------------------------------------------------------------

const R_ESTIMATION_SETUP = """
    suppressPackageStartupMessages(library(MASS))
    options(stringsAsFactors = FALSE)

    est_meta <- as.data.frame(est_cols, stringsAsFactors = FALSE, check.names = FALSE)
    if (nrow(est_meta) != est_ns) {
        stop("metadata has ", nrow(est_meta), " rows for ", est_ns, " samples")
    }
    for (nm in names(est_meta)) {
        if (is.character(est_meta[[nm]])) est_meta[[nm]] <- factor(est_meta[[nm]])
    }
    if (is.factor(est_meta[[est_primary]])) {
        est_primary_levels_text <- paste(levels(est_meta[[est_primary]]), collapse = " then ")
    } else {
        est_primary_levels_text <- paste0("a numeric column: ", est_primary)
    }

    est_r_version <- paste(R.version[["major"]], R.version[["minor"]], sep = ".")
    est_mass_version <- tryCatch(as.character(utils::packageVersion("MASS")),
                                 error = function(e) "unavailable")

    est_form <- if (est_method == "nb_glm") {
        as.formula(paste("y ~", est_rhs, "+ offset(off)"))
    } else {
        as.formula(paste("y ~", est_rhs))
    }
"""

const R_ESTIMATION_FIT = """
    est_status <- character(est_n)
    est_note <- character(est_n)
    est_estimate <- rep(NA_real_, est_n)
    est_se <- rep(NA_real_, est_n)
    est_stat <- rep(NA_real_, est_n)
    est_stat_name <- rep(NA_character_, est_n)
    est_p <- rep(NA_real_, est_n)
    est_df <- rep(NA_real_, est_n)
    est_theta <- rep(NA_real_, est_n)
    est_nobs <- rep(NA_real_, est_n)
    est_ci_low <- rep(NA_real_, est_n)
    est_ci_high <- rep(NA_real_, est_n)
    est_meta[["y"]] <- rep(0, est_ns)
    if (!is.null(est_offset)) est_meta[["off"]] <- as.numeric(est_offset)

    est_one_fit <- function() {
        if (est_method == "nb_glm") {
            if (est_dispersion != "parametric") {
                stop("dispersion method '", est_dispersion, "' has no implementation here")
            }
            return(MASS::glm.nb(est_form, data = est_meta, control = glm.control(maxit = 100)))
        } else if (est_method == "logistic") {
            return(stats::glm(est_form, data = est_meta, family = stats::binomial()))
        }
        return(stats::lm(est_form, data = est_meta))
    }

    est_coef_rows <- list()
    est_k <- 0

    for (i in seq_len(est_n)) {
        y <- as.numeric(est_counts[i, ])
        est_nobs[i] <- sum(is.finite(y))
        if (sum(is.finite(y)) < 3 || length(unique(y[is.finite(y)])) < 2) {
            est_status[i] <- "failed"
            est_note[i] <- "the response is constant or has fewer than three finite values: there is nothing to estimate"
            next
        }
        est_meta[["y"]] <- y
        warns <- character(0)
        fit <- tryCatch(
            withCallingHandlers(est_one_fit(), warning = function(w) {
                warns <<- c(warns, conditionMessage(w))
                invokeRestart("muffleWarning")
            }),
            error = function(e) e
        )
        if (inherits(fit, "error")) {
            est_status[i] <- "failed"
            est_note[i] <- conditionMessage(fit)
            next
        }
        cf <- tryCatch(summary(fit)[["coefficients"]], error = function(e) NULL)
        if (is.null(cf) || is.null(dim(cf))) {
            est_status[i] <- "failed"
            est_note[i] <- "the fit produced no coefficient table"
            next
        }
        coef_name <- est_primary
        if (!(coef_name %in% rownames(cf))) {
            cand <- setdiff(rownames(cf), "(Intercept)")
            cand <- cand[startsWith(cand, est_primary)]
            if (length(cand) == 0) {
                est_status[i] <- "failed"
                est_note[i] <- paste("the fit has no coefficient for the primary term", est_primary)
                next
            }
            coef_name <- cand[1]
        }

        status <- "ok"
        notes <- character(0)
        if (est_method == "nb_glm") {
            if (!isTRUE(fit[["converged"]])) {
                status <- "failed"
                notes <- c(notes, "the fit did not converge")
            } else if (fit[["theta"]] >= 1e7) {
                status <- "boundary"
                notes <- c(notes, "theta >= 1e7: dispersion is indistinguishable from Poisson at this precision, so the negative binomial model adds nothing here")
            } else if (fit[["theta"]] <= 1e-8) {
                status <- "boundary"
                notes <- c(notes, "theta <= 1e-8: the dispersion estimate is at its boundary and the standard error of this coefficient is not trustworthy")
            }
            est_theta[i] <- fit[["theta"]]
        }
        if (est_method == "logistic" && any(grepl("numerically 0 or 1", warns))) {
            status <- "boundary"
            notes <- c(notes, "complete or quasi-complete separation: fitted probabilities reached 0 or 1, so this Wald test is not a valid p-value")
        }
        if (any(grepl("iteration limit|alternation limit|did not converge|NaNs produced", warns))) {
            status <- "failed"
            notes <- c(notes, paste(unique(warns), collapse = "; "))
        }

        est_stat_name[i] <- if (est_method == "logistic" || est_method == "nb_glm") "z" else "t"
        est_df[i] <- fit[["df.residual"]]
        est_note[i] <- paste(c(notes, unique(warns)), collapse = "; ")

        if (status == "failed") {
            est_status[i] <- "failed"
            next
        }

        est_estimate[i] <- cf[coef_name, 1]
        est_se[i] <- cf[coef_name, 2]
        est_stat[i] <- cf[coef_name, 3]
        est_p[i] <- cf[coef_name, 4]

        q <- if (est_method == "logistic" || est_method == "nb_glm") stats::qnorm(0.975) else stats::qt(0.975, fit[["df.residual"]])
        est_ci_low[i] <- cf[coef_name, 1] - q * cf[coef_name, 2]
        est_ci_high[i] <- cf[coef_name, 1] + q * cf[coef_name, 2]

        if (!is.finite(est_p[i]) || est_p[i] < 0 || est_p[i] > 1) {
            est_status[i] <- "failed"
            est_note[i] <- paste(est_note[i], "the fit produced a p-value that is not a probability; refused rather than reported")
            est_estimate[i] <- NA_real_
            est_se[i] <- NA_real_
            est_stat[i] <- NA_real_
            est_p[i] <- NA_real_
            est_ci_low[i] <- NA_real_
            est_ci_high[i] <- NA_real_
            next
        }
        est_status[i] <- status

        for (term in setdiff(rownames(cf), "(Intercept)")) {
            est_k <- est_k + 1
            est_coef_rows[[est_k]] <- data.frame(
                taxon_index = i,
                term = term,
                estimate = cf[term, 1],
                standard_error = cf[term, 2],
                statistic = cf[term, 3],
                pvalue = cf[term, 4],
                is_primary = identical(term, coef_name),
                stringsAsFactors = FALSE
            )
        }
    }

    est_fits <- data.frame(
        taxon_index = seq_len(est_n),
        status = est_status,
        note = est_note,
        estimate = est_estimate,
        standard_error = est_se,
        statistic = est_stat,
        statistic_name = est_stat_name,
        pvalue = est_p,
        residual_df = est_df,
        dispersion_theta = est_theta,
        n_observations = est_nobs,
        ci_low = est_ci_low,
        ci_high = est_ci_high,
        stringsAsFactors = FALSE
    )
    utils::write.csv(est_fits, est_fits_path, row.names = FALSE, na = "NA")

    est_coefs <- if (est_k > 0) {
        do.call(rbind, est_coef_rows)
    } else {
        data.frame(
            taxon_index = integer(0), term = character(0), estimate = numeric(0),
            standard_error = numeric(0), statistic = numeric(0), pvalue = numeric(0),
            is_primary = logical(0), stringsAsFactors = FALSE
        )
    }
    utils::write.csv(est_coefs, est_coefs_path, row.names = FALSE, na = "NA")
"""

end # module Estimation
