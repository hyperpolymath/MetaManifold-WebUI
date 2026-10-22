# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

## Differential abundance
# Per-taxon models comparing two groups of samples, with Benjamini-Hochberg
# correction across the taxa that produced a p-value. Four methods:
#
# - nb_glm: a negative-binomial GLM per taxon (MASS::glm.nb) on the observed
#   integer read counts, with a library-size offset. There are no pseudocounts.
# - clr_welch: Welch's two-sample t-test per taxon (stats::t.test) on centred
#   log-ratios, over the taxa that pass `min_prevalence`, after their zeros are
#   replaced by zCompositions::cmultRepl (Bayesian GBM/user or multiplicative
#   CZM, for counts). The estimate is a difference in CLR units, not a fold change.
# - multinomial: one multinomial logistic model for the whole composition
#   (softmax over taxa, one coefficient per taxon and covariate, reference
#   taxon fixed at zero). The estimate is a log fold change of relative
#   abundance against the reference taxon; zeros are part of the likelihood and
#   need no replacement. Songbird's model (Morton et al. 2019), in pure Julia.
# - dirichlet_multinomial: the multinomial plus a Dirichlet prior on the
#   composition, which adds the between-sample (overdispersion) variation that
#   the multinomial treats as pure sampling noise (La Rosa et al. 2012).
#
# The two multinomial methods are the count-based, compositionally coherent
# alternative to nb_glm (which models each taxon independently and so ignores
# the constraint the compositions impose) and to clr_welch (which is Gaussian on
# log-ratios and ignores the count likelihood). They are implemented in
# `CompositionalModels`, without R and without a pseudocount.
#
# Count matrices here are samples x taxa, as everywhere else in `Analysis`.
# Anything that is not a non-negative integer count is refused rather than
# rounded. A taxon whose fit fails is reported with its reason and kept out of
# the multiple-testing family; it never receives a stand-in p-value.
module Differential

using DataFrames, RCall
using ..RRuntime: with_r_lock
using ..Analysis: _palette_hex, R_WAIT_SECONDS
using ..CompositionalModels: CompositionalFit, CompositionalRefusal, RuntimeRefusal,
       DM_METHODS, CONCENTRATION_MIN, CONCENTRATION_MAX, fit_multinomial,
       fit_dirichlet_multinomial
export DifferentialConfig, ScalingRefusal, MASSUnavailable, ZCompositionsUnavailable,
       GlmGamPoiUnavailable, CompositionalRefusal, RuntimeRefusal,
       OFFSET_METHODS, METHODS, COMPOSITIONAL_METHODS, DISPERSIONS, REPLACEMENT_METHODS,
       tss_factors, rle_factors, size_factors, bh_adjust, validate_counts,
       replace_zeros, clr_transform, fit_nb, fit_welch, differential_abundance,
       volcano_chart

# Methods accepted under `analysis.differential.method`. The last two are the
# multinomial models; `COMPOSITIONAL_METHODS` names them for the code that has
# to treat them alike (no size factors, no zero replacement, a reference taxon).
const COMPOSITIONAL_METHODS = ("multinomial", "dirichlet_multinomial")
const METHODS = ("nb_glm", "clr_welch", COMPOSITIONAL_METHODS...)

# The per-taxon dispersion `nb_glm` uses: maximum likelihood (MASS::glm.nb's
# own theta) or glmGamPoi's shrinkage estimator, which shares information
# across taxa. `"ml"` is the default and keeps #24's results unchanged.
const DISPERSIONS = ("ml", "glmGamPoi")

# Zero-replacement methods accepted under
# `analysis.differential.replacement_method`. Both are exact calls to
# zCompositions::cmultRepl; the Bayesian default is the existing GBM path.
const REPLACEMENT_METHODS = ("bayesian_multiplicative", "multiplicative_replacement")

# Offset (size factor) methods accepted under `analysis.differential.offset`.
const OFFSET_METHODS = ("tss", "rle")

# Above this the NB dispersion parameter has run to its upper bound: the counts
# show no overdispersion and the model has collapsed to a Poisson. Below the
# lower bound the dispersion is degenerate the other way.
const THETA_UPPER = 1e7
const THETA_LOWER = 1e-8

# zCompositions::cmultRepl's default `frac`, as in Martín-Fernández et al. (2003).
const DEFAULT_DELTA = 0.65

# Optimiser defaults for the two multinomial models, repeated here so the file
# documents every setting it validates; the values must match
# CompositionalModels.DEFAULT_* (asserted in the unit tests).
const COMPOSITIONAL_MAX_ITER    = 500
const COMPOSITIONAL_TOL         = 1e-8
const COMPOSITIONAL_MAX_SECONDS = 300.0
# Canonicalise and validate a public replacement-method name in one place, so
# direct library calls and YAML configuration have identical semantics.
function _replacement_method(method::AbstractString)
    m = lowercase(strip(String(method)))
    m in REPLACEMENT_METHODS || throw(ArgumentError(
        "analysis.differential.replacement_method must be one of " *
        "$(join(REPLACEMENT_METHODS, ", ")), not '$method'"))
    m
end

"""
    DifferentialConfig(offset="tss", min_prevalence=0.0; method="nb_glm",
                       replacement_delta=0.65, dispersion="ml",
                       replacement_method="bayesian_multiplicative",
                       bayesian_alpha=nothing,
                       mn_reference_taxon=nothing, mn_penalty=0.0,
                       dm_overdispersion_method="mle", max_iter=500, tol=1e-8,
                       max_seconds=300.0)

Settings for one differential abundance analysis, read from
`analysis.differential` in the pipeline config. `method` is `"nb_glm"`,
`"clr_welch"`, `"multinomial"` or `"dirichlet_multinomial"`. `offset` names the
size factor method (`"tss"` or `"rle"`) and is used by `nb_glm` only: a
library-size offset has no meaning for a test on log-ratios, which are already
free of library size, nor for the two multinomial models, which condition on
each sample's total and so already contain the library size.
`min_prevalence` is the fraction of samples, in [0, 1], in which a taxon must
have at least one read to be tested. `replacement_delta`, in (0, 1), is the
`frac` passed to `zCompositions::cmultRepl` by `clr_welch`: an imputed proportion
above its taxon's smallest observed proportion is lowered to this fraction of it.
`replacement_method` selects `"bayesian_multiplicative"` (the default GBM
posterior replacement) or `"multiplicative_replacement"` (CZM). For the Bayesian
method, `bayesian_alpha=nothing` uses GBM's estimated concentration; a finite,
strictly positive value instead uses that Dirichlet concentration with
cmultRepl's `method="user"` and the same leave-one-out prior mean. Alpha is
recorded but not used by CZM.
`dispersion` names the per-taxon dispersion `nb_glm` uses (`"ml"` or
`"glmGamPoi"`): `"ml"` takes the maximum-likelihood theta from `MASS::glm.nb`,
`"glmGamPoi"` uses `overdispersion_shrinkage_list.dispersion_trend` from
`glmGamPoi::glm_gp` for
the taxa passing the prevalence filter, with `theta = 1 / dispersion` fixed
in each negative-binomial GLM. Both options use a Wald test of the group
coefficient with fixed scale 1; `"glmGamPoi"` is refused for `clr_welch`.
The trend is plugged into an NB Wald model; its estimation uncertainty is not
propagated. This option does not implement glmGamPoi's quasi-likelihood test.

The remaining settings belong to the two multinomial models.
`mn_reference_taxon` names the taxon whose log-odds are the denominator of
every reported log ratio; `nothing` (the default) takes the most abundant taxon
that passes the prevalence filter, and the chosen taxon is reported in the
result. `mn_penalty` >= 0 is an L2 (ridge) penalty on the log-odds
coefficients, 0 being maximum likelihood; an L1 penalty is not implemented
(see `CompositionalModels`). `dm_overdispersion_method` is how the
Dirichlet-multinomial estimates its concentration: `"mle"` (default) profiles
the likelihood alternately with the coefficients, `"mom"` takes one moment
estimate (La Rosa et al. 2012) from the multinomial composition. `max_iter`,
`tol` and `max_seconds` are the optimiser's iteration cap, convergence tolerance
and wall-clock budget; they apply to the two multinomial models only and a fit
that exceeds the budget fails loudly rather than hanging.

Method and offset names are stripped and lowercased; dispersion and
overdispersion-method names are stripped and matched without regard to case,
then stored canonically. Throws `ArgumentError` for unsupported names,
incompatible method and setting choices, or non-finite or out-of-range numbers,
including settings unused by the selected method: a negative-binomial
dispersion, a reference taxon or a penalty with `nb_glm` or `clr_welch`, and a
non-default overdispersion method without `dirichlet_multinomial`.
"""
struct DifferentialConfig
    method             :: String
    offset             :: String
    min_prevalence     :: Float64
    replacement_delta  :: Float64
    dispersion         :: String
    replacement_method :: String
    bayesian_alpha     :: Union{Float64,Nothing}
    mn_reference_taxon :: Union{Nothing,String}
    mn_penalty         :: Float64
    dm_overdispersion_method :: String
    max_iter           :: Int
    tol                :: Float64
    max_seconds        :: Float64
    function DifferentialConfig(offset::AbstractString="tss", min_prevalence::Real=0.0;
                                method::AbstractString="nb_glm",
                                replacement_delta::Real=DEFAULT_DELTA,
                                dispersion::AbstractString="ml",
                                replacement_method::AbstractString="bayesian_multiplicative",
                                bayesian_alpha::Union{Real,Nothing}=nothing,
                                mn_reference_taxon::Union{Nothing,AbstractString}=nothing,
                                mn_penalty::Real=0.0,
                                dm_overdispersion_method::AbstractString="mle",
                                max_iter::Integer=COMPOSITIONAL_MAX_ITER,
                                tol::Real=COMPOSITIONAL_TOL,
                                max_seconds::Real=COMPOSITIONAL_MAX_SECONDS)
        m = lowercase(strip(String(method)))
        m in METHODS || throw(ArgumentError(
            "analysis.differential.method must be one of $(join(METHODS, ", ")), not '$method'"))
        o = lowercase(strip(String(offset)))
        o in OFFSET_METHODS || throw(ArgumentError(
            "analysis.differential.offset must be one of $(join(OFFSET_METHODS, ", ")), not '$offset'"))
        d = strip(String(dispersion))
        di = findfirst(s -> lowercase(s) == lowercase(d), DISPERSIONS)
        di === nothing && throw(ArgumentError(
            "analysis.differential.dispersion must be one of $(join(DISPERSIONS, ", ")), not '$dispersion'"))
        d = DISPERSIONS[di]
        (d == "ml" || m == "nb_glm") || throw(ArgumentError(
            "analysis.differential.dispersion is a negative-binomial setting, but method is " *
            "'$m'; only nb_glm has a dispersion to choose"))
        (isfinite(min_prevalence) && 0 <= min_prevalence <= 1) || throw(ArgumentError(
            "analysis.differential.min_prevalence must be a fraction in [0, 1], not $min_prevalence"))
        (isfinite(replacement_delta) && 0 < replacement_delta < 1) || throw(ArgumentError(
            "analysis.differential.replacement_delta must be in (0, 1), not $replacement_delta"))
        ref = if isnothing(mn_reference_taxon) || isempty(strip(String(mn_reference_taxon)))
            nothing
        else
            String(strip(String(mn_reference_taxon)))
        end
        (isfinite(mn_penalty) && mn_penalty >= 0) || throw(ArgumentError(
            "analysis.differential.mn_penalty must be a finite number >= 0, not $mn_penalty"))
        dm = lowercase(strip(String(dm_overdispersion_method)))
        dm in DM_METHODS || throw(ArgumentError(
            "analysis.differential.dm_overdispersion_method must be one of " *
            "$(join(DM_METHODS, ", ")), not '$dm_overdispersion_method'"))
        compositional = m in COMPOSITIONAL_METHODS
        (isnothing(ref) || compositional) || throw(ArgumentError(
            "analysis.differential.mn_reference_taxon applies to method multinomial or " *
            "dirichlet_multinomial, but method is '$m'; only those two models have a reference taxon"))
        (mn_penalty == 0 || compositional) || throw(ArgumentError(
            "analysis.differential.mn_penalty applies to method multinomial or " *
            "dirichlet_multinomial, but method is '$m'; only those two models are penalised"))
        (dm == "mle" || m == "dirichlet_multinomial") || throw(ArgumentError(
            "analysis.differential.dm_overdispersion_method is a Dirichlet-multinomial setting, " *
            "but method is '$m'; set it to mle or select method dirichlet_multinomial"))
        (max_iter >= 1) || throw(ArgumentError(
            "analysis.differential.max_iter must be at least 1, not $max_iter"))
        (isfinite(tol) && tol > 0) || throw(ArgumentError(
            "analysis.differential.tolerance must be positive and finite, not $tol"))
        (isfinite(max_seconds) && max_seconds > 0) || throw(ArgumentError(
            "analysis.differential.max_seconds must be positive and finite, not $max_seconds"))
        r = _replacement_method(replacement_method)
        (isnothing(bayesian_alpha) ||
         (!(bayesian_alpha isa Bool) && isfinite(bayesian_alpha) && bayesian_alpha > 0)) ||
            throw(ArgumentError("analysis.differential.bayesian_alpha must be empty or a " *
                                "finite number greater than 0, not $bayesian_alpha"))
        a = isnothing(bayesian_alpha) ? nothing : Float64(bayesian_alpha)
        new(m, o, Float64(min_prevalence), Float64(replacement_delta), d, r, a, ref,
            Float64(mn_penalty), dm, Int(max_iter), Float64(tol), Float64(max_seconds))
    end
end

"""
    ScalingRefusal(method, reason)

Raised when a size factor method cannot be computed on the data it was given,
for instance total-sum scaling on an empty sample. The reason names the sample
or the property at fault.
"""
struct ScalingRefusal <: Exception
    method :: String
    reason :: String
end

Base.showerror(io::IO, e::ScalingRefusal) =
    print(io, "$(uppercase(e.method)) scaling refused: $(e.reason)")

"""
    MASSUnavailable()

Raised when the R package MASS, which provides `glm.nb`, cannot be loaded.
"""
struct MASSUnavailable <: Exception end

Base.showerror(io::IO, ::MASSUnavailable) = print(io,
    "the R package MASS is not available, so negative-binomial models cannot be " *
    "fitted; install R with its recommended packages (MASS ships with them)")

"""
    ZCompositionsUnavailable()

Raised when the R package zCompositions, which provides `cmultRepl`, cannot be
loaded.
"""
struct ZCompositionsUnavailable <: Exception end

Base.showerror(io::IO, ::ZCompositionsUnavailable) = print(io,
    "the R package zCompositions is not available, so zeros cannot be replaced for " *
    "clr_welch; restore the R library from renv.lock (Rscript -e 'renv::restore()')")

"""
    GlmGamPoiUnavailable()

Raised when the R package glmGamPoi, which provides the shrunken dispersion
`analysis.differential.dispersion: glmGamPoi` asks for, cannot be loaded.
"""
struct GlmGamPoiUnavailable <: Exception end

"""
    Base.showerror(io::IO, ::GlmGamPoiUnavailable)

Write the missing-package error and guidance to restore the pinned R library or select
`dispersion: ml` to `io`, without a trailing newline.
"""
Base.showerror(io::IO, ::GlmGamPoiUnavailable) = print(io,
    "the R package glmGamPoi is not available, so the shrunken dispersion cannot be " *
    "fitted; restore the pinned R library (Rscript -e 'renv::restore()') " *
    "or use analysis.differential.dispersion: ml")

"""
    _geomean(x) -> Float64

Geometric mean of a vector of positive numbers.
"""
_geomean(x) = exp(sum(log.(x)) / length(x))

"""
    _median(x) -> Float64

Median of a non-empty vector, the mean of the two middle values when its length
is even.
"""
function _median(x)
    s = sort(collect(Float64, x))
    m = length(s) ÷ 2
    isodd(length(s)) ? s[m + 1] : (s[m] + s[m + 1]) / 2
end

"""
    tss_factors(counts, samples) -> Vector{Float64}

Total-sum scaling factors, one per row of the samples x taxa matrix `counts`:
each sample's library size divided by the geometric mean of all library sizes,
so the factors have geometric mean 1. Throws `ScalingRefusal` naming the first
sample with no reads.
"""
function tss_factors(counts::AbstractMatrix{<:Real}, samples::AbstractVector{<:AbstractString})
    lib = vec(sum(counts; dims=2))
    for (i, l) in enumerate(lib)
        l > 0 || throw(ScalingRefusal("tss",
            "sample '$(samples[i])' has no reads, so it has no library size to scale by"))
    end
    lib ./ _geomean(lib)
end

"""
    rle_factors(counts, samples) -> Vector{Float64}

Relative log expression (median-of-ratios) scaling factors, one per row of the
samples x taxa matrix `counts`. Each sample's factor is the median, over the
taxa with at least one read in every sample, of its count divided by that
taxon's geometric mean across samples; the factors are then centred to
geometric mean 1. Throws `ScalingRefusal` when no taxon is present in every
sample, since every geometric mean would then be zero.
"""
function rle_factors(counts::AbstractMatrix{<:Real}, samples::AbstractVector{<:AbstractString})
    size(counts, 1) == length(samples) ||
        throw(ArgumentError("$(length(samples)) sample names for $(size(counts, 1)) rows"))
    shared = [j for j in axes(counts, 2) if all(>(0), view(counts, :, j))]
    isempty(shared) && throw(ScalingRefusal("rle",
        "no taxon has reads in every sample, so the per-taxon geometric mean the " *
        "median-of-ratios needs is zero for all of them; use offset: tss"))
    sub = Float64.(counts[:, shared])
    gm = [_geomean(view(sub, :, j)) for j in axes(sub, 2)]
    raw = [_median(view(sub, i, :) ./ gm) for i in axes(sub, 1)]
    raw ./ _geomean(raw)
end

"""
    size_factors(counts, samples, method) -> Vector{Float64}

Size factors by the named `method` (`"tss"` or `"rle"`).
"""
function size_factors(counts::AbstractMatrix{<:Real}, samples::AbstractVector{<:AbstractString},
                      method::AbstractString)
    method == "tss" && return tss_factors(counts, samples)
    method == "rle" && return rle_factors(counts, samples)
    throw(ArgumentError("unknown offset method '$method'; expected one of $(join(OFFSET_METHODS, ", "))"))
end

"""
    bh_adjust(p) -> Vector{Float64}

Benjamini-Hochberg adjusted p-values, matching R's `p.adjust(p, "BH")`. Every
input must be a finite probability in [0, 1]; anything else throws an
`ArgumentError` rather than being dropped, because dropping it would silently
shrink the family. An empty input gives an empty result.
"""
function bh_adjust(p::AbstractVector{<:Real})
    n = length(p)
    n == 0 && return Float64[]
    for (i, x) in enumerate(p)
        (isfinite(x) && 0 <= x <= 1) || throw(ArgumentError(
            "p-value $i is $x: Benjamini-Hochberg needs finite probabilities in [0, 1]"))
    end
    order = sortperm(p; rev=true)
    out = Vector{Float64}(undef, n)
    running = 1.0
    for (k, idx) in enumerate(order)
        rank = n - k + 1
        running = min(running, n / rank * Float64(p[idx]))
        out[idx] = min(running, 1.0)
    end
    out
end

"""
    validate_counts(counts, samples, taxa) -> Nothing

Check that every entry of the samples x taxa matrix `counts` is a finite,
non-negative integer. Throws an `ArgumentError` naming the first offending
sample and taxon: the models are defined on read counts, and a normalised,
rarefied-and-averaged or pseudocounted value would be silently misfitted.
"""
function validate_counts(counts::AbstractMatrix{<:Real}, samples::AbstractVector{<:AbstractString},
                         taxa::AbstractVector{<:AbstractString})
    size(counts) == (length(samples), length(taxa)) || throw(ArgumentError(
        "count matrix is $(size(counts)) but there are $(length(samples)) samples and $(length(taxa)) taxa"))
    for j in axes(counts, 2), i in axes(counts, 1)
        x = counts[i, j]
        (isfinite(x) && x >= 0 && isinteger(x)) || throw(ArgumentError(
            "the count for taxon '$(taxa[j])' in sample '$(samples[i])' is $x: the " *
            "models are defined on non-negative integer read counts"))
    end
    nothing
end

# The per-taxon fit loop. Variables are prefixed `da_` so they cannot collide
# with another analysis's globals, and are removed afterwards.
const _FIT_R = raw"""
da_g <- factor(da_group, levels = da_levels)
da_term <- paste0("da_g", da_levels[2])
da_n <- ncol(da_counts)
da_result <- data.frame(status = rep("ok", da_n), note = rep("", da_n),
                        estimate = rep(NA_real_, da_n), se = rep(NA_real_, da_n),
                        statistic = rep(NA_real_, da_n), pvalue = rep(NA_real_, da_n),
                        theta = rep(NA_real_, da_n), stringsAsFactors = FALSE)
# glmGamPoi's shrunken dispersion, fitted across all taxa in one call -- its
# genes x samples convention, so the counts are transposed, and size_factors
# is the linear size factor (the per-taxon fits below take its log as the
# offset). A global fit error or missing trend fails the batch. A zero trend
# is a per-taxon Poisson boundary; malformed values fail only their own taxa.
# No fallback to a different dispersion estimator is permitted.
da_phi <- rep(NA_real_, da_n)
da_gp_failed <- ""
if (da_use_gp) {
  da_gp <- tryCatch(
    glmGamPoi::glm_gp(t(da_counts), design = model.matrix(~ da_g),
                      size_factors = exp(da_offset), overdispersion_shrinkage = TRUE),
    error = function(e) e)
  if (inherits(da_gp, "error")) {
    da_gp_failed <- paste("glm_gp stopped with an error:", conditionMessage(da_gp))
  } else {
    # glm_gp's overdispersions retain the unshrunk MLEs. Its NB refit uses
    # dispersion_trend; ql_disp_shrunken is a distinct quasi-likelihood scale.
    da_phi <- as.numeric(da_gp[["overdispersion_shrinkage_list"]][["dispersion_trend"]])
    if (length(da_phi) != da_n) {
      da_gp_failed <- "glm_gp returned no dispersion trend for each taxon"
      da_phi <- rep(NA_real_, da_n)
    }
  }
}
for (da_j in seq_len(da_n)) {
  if (nzchar(da_gp_failed)) {
    da_result[da_j, "status"] <- "failed"
    da_result[da_j, "note"] <- da_gp_failed
    next
  }
  da_y <- da_counts[, da_j]
  if (length(unique(da_y)) < 2L) {
    da_result[da_j, "status"] <- "failed"
    da_result[da_j, "note"] <- "the counts are constant across samples: there is nothing to estimate"
    next
  }
  # Complete separation: with no reads in every sample of one group the group
  # coefficient runs off to infinity, its standard error with it, and the Wald
  # p-value collapses towards 1 although the fit reports convergence. That p is
  # not evidence of no difference, so the taxon is refused with its reason.
  da_absent <- levels(da_g)[vapply(levels(da_g), function(l) all(da_y[da_g == l] == 0), logical(1))]
  if (length(da_absent) > 0L) {
    da_result[da_j, "status"] <- "failed"
    da_result[da_j, "note"] <- paste0("no reads in any '", da_absent[[1]], "' sample (complete ",
                                      "separation): the fold change is unbounded and the Wald test ",
                                      "is undefined, so no p-value is reported")
    next
  }
  da_warns <- character(0)
  # "ml": theta is estimated per taxon by glm.nb's own alternating iterations.
  # "glmGamPoi": theta is TAKEN from the shrunken dispersion fitted above
  # (theta = 1 / phi) and the per-taxon fit goes through glm() with MASS's
  # negative.binomial family, so the Wald test and every check below are the
  # same machinery on a given dispersion instead of an estimated one.
  if (da_use_gp) {
    if (!is.finite(da_phi[da_j]) || da_phi[da_j] < 0) {
      da_result[da_j, "status"] <- "failed"
      da_result[da_j, "note"] <- "the dispersion trend for this taxon is invalid"
      next
    }
    if (da_phi[da_j] == 0) {
      da_result[da_j, "status"] <- "boundary"
      da_result[da_j, "note"] <- "zero dispersion: Poisson boundary; NB Wald inference withheld"
      next
    }
    da_theta <- 1 / da_phi[da_j]
    if (!is.finite(da_theta) || da_theta <= 0) {
      da_result[da_j, "status"] <- "failed"
      da_result[da_j, "note"] <- "the shrunken dispersion for this taxon is not usable"
      next
    }
    da_fit <- tryCatch(
      withCallingHandlers(
        glm(da_y ~ da_g + offset(da_offset),
            family = MASS::negative.binomial(theta = da_theta),
            control = glm.control(maxit = 100)),
        warning = function(w) {
          da_warns <<- c(da_warns, conditionMessage(w))
          invokeRestart("muffleWarning")
        }),
      error = function(e) e)
    if (inherits(da_fit, "error")) {
      da_result[da_j, "status"] <- "failed"
      da_result[da_j, "note"] <- paste("the negative-binomial fit stopped with an error:",
                                       conditionMessage(da_fit))
      next
    }
  } else {
    da_fit <- tryCatch(
      withCallingHandlers(
        MASS::glm.nb(da_y ~ da_g + offset(da_offset), control = glm.control(maxit = 100)),
        warning = function(w) {
          da_warns <<- c(da_warns, conditionMessage(w))
          invokeRestart("muffleWarning")
        }),
      error = function(e) e)
    if (inherits(da_fit, "error")) {
      da_result[da_j, "status"] <- "failed"
      da_result[da_j, "note"] <- paste("glm.nb stopped with an error:", conditionMessage(da_fit))
      next
    }
  }
  da_warns <- unique(da_warns)
  if (!isTRUE(da_fit[["converged"]]) || !is.null(da_fit[["th.warn"]]) ||
      any(grepl("iteration limit|alternation limit|did not converge|NaNs produced", da_warns))) {
    da_result[da_j, "status"] <- "failed"
    da_result[da_j, "note"] <- paste("the fit did not converge:",
                                     paste(c(da_fit[["th.warn"]], da_warns), collapse = "; "))
    next
  }
  da_co <- summary(da_fit, dispersion = 1)[["coefficients"]]
  if (!(da_term %in% rownames(da_co))) {
    da_result[da_j, "status"] <- "failed"
    da_result[da_j, "note"] <- "the group coefficient is not estimable (aliased)"
    next
  }
  da_row <- da_co[da_term, ]
  if (!all(is.finite(da_row)) || da_row[[4]] < 0 || da_row[[4]] > 1) {
    da_result[da_j, "status"] <- "failed"
    da_result[da_j, "note"] <- "the fit returned a non-finite estimate, standard error or p-value"
    next
  }
  # "glmGamPoi" set da_theta before the fit; "ml" takes it from the fit.
  if (!da_use_gp) da_theta <- da_fit[["theta"]]
  da_result[da_j, c("estimate", "se", "statistic", "pvalue")] <- unname(da_row[1:4])
  da_result[da_j, "theta"] <- da_theta
  if (!is.finite(da_theta) || da_theta >= da_theta_upper) {
    da_result[da_j, "status"] <- "boundary"
    da_result[da_j, "note"] <- if (da_use_gp)
      paste("the shrunken dispersion puts these counts at the Poisson end:",
            "no overdispersion is left, so the fit is effectively Poisson")
    else
      "the dispersion parameter theta reached its upper bound: these counts show no overdispersion, so the fit is effectively Poisson"
  } else if (da_theta <= da_theta_lower) {
    da_result[da_j, "status"] <- "boundary"
    da_result[da_j, "note"] <- if (da_use_gp)
      "the shrunken dispersion puts these counts at the extreme-variance end"
    else
      "the dispersion parameter theta reached its lower bound: the variance is extreme relative to the mean"
  } else if (length(da_warns) > 0L) {
    da_result[da_j, "note"] <- paste("R warned:", paste(da_warns, collapse = "; "))
  }
}
"""

"""
    _num(x) -> Union{Float64,Nothing}

A finite number as `Float64`, or `nothing` for R's NA, NaN or an infinity.
"""
_num(x) = (ismissing(x) || isnothing(x) || !isfinite(x)) ? nothing : Float64(x)

"""
    fit_nb(counts, groups, offset; levels, dispersion="ml") -> DataFrame

Fit a negative-binomial GLM with a log link to each column of the samples x
taxa integer matrix `counts`. `offset` contains the natural logarithm of each
sample's size factor. `levels` is `(reference, contrast)`, so the estimate is
the natural-log fold change of `contrast` over `reference`.
`dispersion` names where each taxon's theta comes from: `"ml"` (the default)
takes `MASS::glm.nb`'s maximum-likelihood estimate; `"glmGamPoi"` uses the
`overdispersion_shrinkage_list.dispersion_trend` from `glmGamPoi::glm_gp` on
all supplied taxa in one call, then fits each taxon with `theta = 1 / dispersion` fixed. Both options
use a Wald test of the group coefficient. Names are stripped and matched
without regard to case.

Returns one row per taxon with `status` (`ok`, `boundary` or `failed`), `note`,
`estimate`, `se`, `statistic`, `pvalue` and `theta`; a failed taxon has
`nothing` for every statistic. Boundary fits retain their statistics: theta
at or above 1e7 marks the Poisson end, and theta at or below 1e-8 marks extreme
variance. Constant counts, complete separation, non-convergence and unusable
coefficients produce failed rows. Errors caught from the model-fitting calls
also produce failed rows; a caught `glm_gp` error or an invalid dispersion
vector fails every taxon, with no fallback to `"ml"`. A zero trend marks only
its taxon as a Poisson boundary and withholds NB Wald statistics. Invalid
negative/non-finite trends fail only the affected taxa.

Throws `ArgumentError` for an unsupported dispersion name or mismatched sample,
group and offset lengths, `MASSUnavailable` when MASS cannot be loaded,
`GlmGamPoiUnavailable` when `"glmGamPoi"` is selected and its package cannot be
loaded, and `RBusyError` when the R runtime stays busy. R errors outside the
caught model-fitting calls propagate.
"""
function fit_nb(counts::AbstractMatrix{<:Integer}, groups::AbstractVector{<:AbstractString},
                offset::AbstractVector{<:Real}; levels::NTuple{2,String},
                dispersion::AbstractString="ml")
    d = strip(String(dispersion))
    lowercase(d) in lowercase.(DISPERSIONS) || throw(ArgumentError(
        "dispersion must be one of $(join(DISPERSIONS, ", ")), not '$dispersion'"))
    use_gp = lowercase(d) == "glmgampoi"
    size(counts, 1) == length(groups) == length(offset) || throw(ArgumentError(
        "counts have $(size(counts, 1)) samples, groups $(length(groups)), offset $(length(offset))"))
    raw = with_r_lock(; timeout=R_WAIT_SECONDS[]) do
        RCall.rcopy(RCall.reval("requireNamespace('MASS', quietly = TRUE)")) || throw(MASSUnavailable())
        use_gp && !RCall.rcopy(RCall.reval("requireNamespace('glmGamPoi', quietly = TRUE)")) &&
            throw(GlmGamPoiUnavailable())
        RCall.globalEnv[:da_counts] = Matrix{Int}(counts)
        RCall.globalEnv[:da_group] = String.(groups)
        RCall.globalEnv[:da_levels] = collect(levels)
        RCall.globalEnv[:da_offset] = Float64.(offset)
        RCall.globalEnv[:da_theta_upper] = THETA_UPPER
        RCall.globalEnv[:da_theta_lower] = THETA_LOWER
        RCall.globalEnv[:da_use_gp] = use_gp
        try
            RCall.reval(_FIT_R)
            DataFrame(RCall.rcopy(RCall.reval("da_result")))
        finally
            RCall.reval("rm(list = intersect(ls(), c('da_counts', 'da_group', 'da_levels', " *
                        "'da_offset', 'da_theta_upper', 'da_theta_lower', 'da_use_gp', 'da_g', 'da_term', " *
                        "'da_n', 'da_result', 'da_phi', 'da_gp_failed', 'da_gp', 'da_j', 'da_y', " *
                        "'da_warns', 'da_fit', 'da_co', 'da_row', 'da_theta', 'da_absent'))); invisible(gc())")
        end
    end
    DataFrame(status    = String.(raw.status),
              note      = String.(raw.note),
              estimate  = _num.(raw.estimate),
              se        = _num.(raw.se),
              statistic = _num.(raw.statistic),
              pvalue    = _num.(raw.pvalue),
              theta     = _num.(raw.theta))
end

"""
    clr_transform(x) -> Matrix{Float64}

Centred log-ratio of each row (sample) of the samples x taxa matrix `x`:
`log(x_ij)` minus the mean of `log(x_i·)`, so every row sums to zero. Every
value must be positive; replace zeros first.
"""
function clr_transform(x::AbstractMatrix{<:Real})
    all(v -> isfinite(v) && v > 0, x) || throw(ArgumentError(
        "the centred log-ratio needs positive finite values; replace zeros first"))
    l = log.(Float64.(x))
    l .- sum(l; dims=2) ./ size(l, 2)
end

# zCompositions::cmultRepl on the taxa that will be tested. z.warning = 1 turns
# off its own sparsity screen, and z.delete = FALSE stops it from dropping a
# row or column: either would silently change the taxa or misalign the samples
# with their groups. Which taxa are sparse enough to leave out is decided by
# `min_prevalence` before this runs. Errors and warnings are captured, not raised.
const _REPLACE_R = raw"""
da_warns <- character(0)
da_posterior_t <- NULL
da_posterior_s <- NULL
da_out <- tryCatch({
  da_args <- list(X = da_counts, label = 0, method = da_method, output = "prop",
                  frac = da_frac, z.warning = 1, z.delete = FALSE,
                  suppress.print = TRUE)
  if (da_method != "CZM") {
    # The Dirichlet posterior is parameterised by the observed counts plus
    # s*t. GBM estimates s; method="user" keeps the same leave-one-out t but
    # takes s from the explicitly configured alpha. Returning t and s lets a
    # caller reconstruct that posterior without storing posterior draws.
    da_x <- as.data.frame(da_counts)
    da_x[da_x == 0] <- NA
    da_n <- nrow(da_x)
    da_d <- ncol(da_x)
    da_prior <- matrix(0, nrow = da_n, ncol = da_d)
    for (da_i in seq_len(da_n)) {
      da_prior[da_i, ] <- apply(da_x, 2, function(da_col) sum(da_col[-da_i], na.rm = TRUE))
    }
    da_posterior_t <- da_prior / rowSums(da_prior)
    da_posterior_s <- if (da_method == "user") {
      rep(da_alpha, da_n)
    } else {
      1 / apply(da_posterior_t, 1, function(da_row) exp(mean(log(da_row))))
    }
    if (da_method == "user") {
      da_args$t <- da_posterior_t
      da_args$s <- da_posterior_s
    }
  }
  withCallingHandlers(
    as.matrix(do.call(zCompositions::cmultRepl, da_args)),
    warning = function(w) {
      da_warns <<- c(da_warns, conditionMessage(w))
      invokeRestart("muffleWarning")
    })
}, error = function(e) conditionMessage(e))
"""

"""
    _check_compositions(out, zero_mask, samples) -> out

Check that cmultRepl's output `out` is one valid composition per sample: the
same shape as the input whose zeros `zero_mask` marks, and every row finite,
positive and summing to 1. Throws `ArgumentError` naming the first sample that
fails, pointing at `min_prevalence`.
"""
function _check_compositions(out::AbstractMatrix{<:Real}, zero_mask::AbstractMatrix{Bool},
                             samples::AbstractVector{<:AbstractString})
    size(out) == size(zero_mask) || error(
        "cmultRepl returned a $(size(out)) table for $(size(zero_mask)) input; a row or column was dropped")
    for i in axes(out, 1)
        row = view(out, i, :)
        if !all(v -> isfinite(v) && v > 0, row) || abs(sum(row) - 1) > 1e-8
            throw(ArgumentError(
                "zero replacement left sample '$(samples[i])' without a valid composition: " *
                "its $(count(view(zero_mask, i, :))) replaced zeros would take the whole sample. " *
                "Raise analysis.differential.min_prevalence so fewer rare taxa are tested"))
        end
    end
    out
end

# Heuristic numerical cautions, not claims that a particular delta is
# biologically correct. They travel with the result so exported provenance does
# not separate the warning from the parameter that caused it.
function _delta_warnings(frac::Real)
    warnings = String[]
    frac < 0.01 && push!(warnings,
        "replacement_delta < 0.01 can underflow or make imputed proportions numerically indistinguishable from zero")
    frac >= 0.9 && push!(warnings,
        "replacement_delta >= 0.9 can give replaced zeros substantial mass relative to observed parts")
    warnings
end

"""
    replace_zeros(counts; method="bayesian_multiplicative", frac=DEFAULT_DELTA,
                  alpha=nothing, samples, taxa) -> NamedTuple

Replace zeros in the samples x taxa read-count matrix `counts` through
`zCompositions::cmultRepl`. `method="multiplicative_replacement"` selects its
CZM replacement (`frac * 0.5 / sample_total`, followed by the reference's cap
and multiplicative closure). `method="bayesian_multiplicative"` selects GBM by
default; a finite, strictly positive `alpha` instead selects `method="user"`
with the same leave-one-out Dirichlet prior mean and `s=alpha`.

Returns `(proportions, zeros_replaced, imputed_mass, warnings, posterior,
method, delta, alpha)`. Every output row is a positive composition summing to
1, and ratios among observed parts are preserved. `warnings` combines R's
warnings with delta's numerical cautions. For Bayesian replacement with at
least one zero, `posterior=(prior_mean, concentration)` parameterises each
sample's pre-adjustment Dirichlet posterior exactly:
`Dirichlet(counts[i, :] + concentration[i] * prior_mean[i, :])`. It is not a
posterior draw, and cmultRepl's subsequent `frac` cap and multiplicative closure
are not part of that Dirichlet distribution. Posterior is `nothing` for CZM or
when there are no zeros to replace.

The caller chooses the taxa: everything passed in is replaced and kept, none is
dropped. Throws `ArgumentError` for invalid delta/alpha/method values, fewer
than 2 taxa, an empty sample, a never-observed taxon, or a taxon seen in fewer
than 2 samples for Bayesian replacement (whose leave-one-out prior is then
undefined). Errors name the affected taxon or sample and point at
`min_prevalence`. Throws `ZCompositionsUnavailable` when zCompositions cannot
be loaded and `RBusyError` when the R runtime stays busy.
"""
function replace_zeros(counts::AbstractMatrix{<:Real};
                       method::AbstractString="bayesian_multiplicative",
                       frac::Real=DEFAULT_DELTA,
                       alpha::Union{Real,Nothing}=nothing,
                       samples::AbstractVector{<:AbstractString}=["sample $i" for i in axes(counts, 1)],
                       taxa::AbstractVector{<:AbstractString}=["taxon $j" for j in axes(counts, 2)])
    m = _replacement_method(method)
    (isfinite(frac) && 0 < frac < 1) || throw(ArgumentError(
        "replacement delta must be in (0, 1), not $frac"))
    (isnothing(alpha) || (!(alpha isa Bool) && isfinite(alpha) && alpha > 0)) ||
        throw(ArgumentError("Bayesian alpha must be empty or a finite number greater than 0, not $alpha"))
    a = isnothing(alpha) ? nothing : Float64(alpha)
    size(counts) == (length(samples), length(taxa)) || throw(ArgumentError(
        "the table is $(size(counts)) but there are $(length(samples)) samples and $(length(taxa)) taxa"))
    size(counts, 2) >= 2 || throw(ArgumentError(
        "the centred log-ratio needs at least 2 taxa; there are $(size(counts, 2))"))
    validate_counts(counts, samples, taxa)
    n = size(counts, 1)
    zero_mask = counts .== 0
    n_zero = count(zero_mask)
    n_zero > 0 && n < 2 && throw(ArgumentError(
        "zCompositions::cmultRepl needs at least 2 samples for zero replacement"))

    minimum_present = m == "bayesian_multiplicative" ? 2 : 1
    sparse = [j for j in axes(counts, 2) if count(>(0), view(counts, :, j)) < minimum_present]
    if !isempty(sparse)
        reason = m == "bayesian_multiplicative" ?
            "cmultRepl's Bayesian-multiplicative leave-one-out prior cannot be estimated for them" :
            "cmultRepl's CZM method has no observed proportion for them"
        throw(ArgumentError(
            "$(length(sparse)) taxa have reads in fewer than $minimum_present sample" *
            (minimum_present == 1 ? "" : "s") * ", so $reason (" *
            join(("'$(taxa[j])'" for j in first(sparse, 5)), ", ") *
            (length(sparse) > 5 ? ", ..." : "") * "); raise analysis.differential.min_prevalence " *
            "to at least $(round(minimum_present / n; digits=3)) so that only adequately observed taxa are tested"))
    end
    for i in axes(counts, 1)
        sum(view(counts, i, :)) > 0 || throw(ArgumentError(
            "sample '$(samples[i])' has no reads in the $(size(counts, 2)) taxa that pass " *
            "min_prevalence, so it has no composition to transform"))
    end

    r_method = m == "multiplicative_replacement" ? "CZM" : isnothing(a) ? "GBM" : "user"
    out, warns, posterior = with_r_lock(; timeout=R_WAIT_SECONDS[]) do
        RCall.rcopy(RCall.reval("requireNamespace('zCompositions', quietly = TRUE)")) ||
            throw(ZCompositionsUnavailable())
        # cmultRepl stops when there is no zero to replace; the closure of the
        # data is then the whole answer and no posterior replacement is needed.
        n_zero == 0 && return (Float64.(counts) ./ sum(counts; dims=2), String[], nothing)
        RCall.globalEnv[:da_counts] = Matrix{Float64}(counts)
        RCall.globalEnv[:da_frac] = Float64(frac)
        RCall.globalEnv[:da_method] = r_method
        RCall.globalEnv[:da_alpha] = something(a, 0.0)
        try
            RCall.reval(_REPLACE_R)
            res = RCall.rcopy(RCall.reval("da_out"))
            res isa AbstractString && throw(ArgumentError(
                "zCompositions::cmultRepl refused the table: $res. Raising " *
                "analysis.differential.min_prevalence leaves fewer, better-observed taxa"))
            post = m == "bayesian_multiplicative" ? (
                prior_mean=Matrix{Float64}(RCall.rcopy(RCall.reval("da_posterior_t"))),
                concentration=Float64.(RCall.rcopy(RCall.reval("da_posterior_s")))) : nothing
            (Matrix{Float64}(res), String.(RCall.rcopy(Vector{String}, RCall.reval("da_warns"))), post)
        finally
            RCall.reval("rm(list = intersect(ls(), c('da_counts', 'da_frac', 'da_method', 'da_alpha', " *
                        "'da_out', 'da_warns', 'da_posterior_t', 'da_posterior_s', 'da_args', 'da_x', " *
                        "'da_n', 'da_d', 'da_prior', 'da_i', 'da_col', 'da_row'))); invisible(gc())")
        end
    end
    _check_compositions(out, zero_mask, samples)
    mass = [sum(out[i, j] for j in axes(out, 2) if zero_mask[i, j]; init=0.0) for i in axes(out, 1)]
    append!(warns, _delta_warnings(frac))
    (proportions=out, zeros_replaced=n_zero, imputed_mass=mass, warnings=unique(warns),
     posterior=posterior, method=m, delta=Float64(frac), alpha=a)
end

# The per-taxon Welch t-test loop, with the same `da_` naming and statuses as
# `_FIT_R` but no `boundary`: a t-test has no dispersion parameter to run to a bound.
const _FIT_WELCH_R = raw"""
da_g <- factor(da_group, levels = da_levels)
da_n <- ncol(da_values)
da_result <- data.frame(status = rep("ok", da_n), note = rep("", da_n),
                        estimate = rep(NA_real_, da_n), se = rep(NA_real_, da_n),
                        statistic = rep(NA_real_, da_n), pvalue = rep(NA_real_, da_n),
                        stringsAsFactors = FALSE)
for (da_j in seq_len(da_n)) {
  da_y <- da_values[, da_j]
  if (length(unique(da_y)) < 2L) {
    da_result[da_j, "status"] <- "failed"
    da_result[da_j, "note"] <- "the values are constant across samples: there is nothing to estimate"
    next
  }
  da_warns <- character(0)
  da_tt <- tryCatch(
    withCallingHandlers(
      stats::t.test(da_y[da_g == da_levels[2]], da_y[da_g == da_levels[1]], var.equal = FALSE),
      warning = function(w) {
        da_warns <<- c(da_warns, conditionMessage(w))
        invokeRestart("muffleWarning")
      }),
    error = function(e) e)
  if (inherits(da_tt, "error")) {
    da_result[da_j, "status"] <- "failed"
    da_result[da_j, "note"] <- paste("t.test stopped with an error:", conditionMessage(da_tt))
    next
  }
  da_row <- c(unname(da_tt[["estimate"]][1] - da_tt[["estimate"]][2]), unname(da_tt[["stderr"]]),
              unname(da_tt[["statistic"]]), da_tt[["p.value"]])
  if (!all(is.finite(da_row)) || da_row[[2]] <= 0 || da_row[[4]] < 0 || da_row[[4]] > 1) {
    da_result[da_j, "status"] <- "failed"
    da_result[da_j, "note"] <- paste(c("the test returned a non-finite or zero standard error, so there is no test (both groups have zero variance)",
                                       unique(da_warns)), collapse = "; ")
    next
  }
  da_result[da_j, c("estimate", "se", "statistic", "pvalue")] <- da_row
  if (length(da_warns) > 0L) {
    da_result[da_j, "note"] <- paste("R warned:", paste(unique(da_warns), collapse = "; "))
  }
}
"""

"""
    fit_welch(values, groups; levels) -> DataFrame

Welch's two-sample t-test, `stats::t.test(contrast, reference, var.equal =
FALSE)`, on each column of the samples x taxa matrix `values` (for `clr_welch`,
centred log-ratios). `levels` is `(reference, contrast)`, so the estimate is
the mean of `contrast` minus the mean of `reference`; the variances of the two
groups are not assumed equal, since the groups often differ in size. Returns
one row per taxon with `status` (`ok` or `failed`), `note`, `estimate`, `se`,
`statistic` (Welch's t) and `pvalue`; a failed taxon has `nothing` for every
statistic. Throws `RBusyError` when the R runtime stays busy.
"""
function fit_welch(values::AbstractMatrix{<:Real}, groups::AbstractVector{<:AbstractString};
                   levels::NTuple{2,String})
    size(values, 1) == length(groups) || throw(ArgumentError(
        "values have $(size(values, 1)) samples and groups $(length(groups))"))
    raw = with_r_lock(; timeout=R_WAIT_SECONDS[]) do
        RCall.globalEnv[:da_values] = Matrix{Float64}(values)
        RCall.globalEnv[:da_group] = String.(groups)
        RCall.globalEnv[:da_levels] = collect(levels)
        try
            RCall.reval(_FIT_WELCH_R)
            DataFrame(RCall.rcopy(RCall.reval("da_result")))
        finally
            RCall.reval("rm(list = intersect(ls(), c('da_values', 'da_group', 'da_levels', " *
                        "'da_g', 'da_n', 'da_result', 'da_j', 'da_y', 'da_warns', 'da_tt', " *
                        "'da_row'))); invisible(gc())")
        end
    end
    DataFrame(status    = String.(raw.status),
              note      = String.(raw.note),
              estimate  = _num.(raw.estimate),
              se        = _num.(raw.se),
              statistic = _num.(raw.statistic),
              pvalue    = _num.(raw.pvalue))
end

"""
    _row(taxon, prevalence, note) -> Dict{String,Any}

A results row with no statistics, as for a taxon that was not fitted.
"""
_row(taxon, prevalence, note) = Dict{String,Any}(
    "taxon" => String(taxon), "status" => "filtered", "note" => note,
    "estimate" => nothing, "log2_fold_change" => nothing,
    "standard_error" => nothing, "statistic" => nothing,
    "pvalue" => nothing, "padj" => nothing, "dispersion_theta" => nothing,
    "prevalence" => prevalence)

"""
    differential_abundance(counts, samples, taxa, groups; reference, contrast,
                           config=DifferentialConfig()) -> Dict{String,Any}

Test every taxon (column) of the samples x taxa read-count matrix for a
difference in abundance between the samples labelled `contrast` and those
labelled `reference` in `groups`, by `config.method`.

`nb_glm`: size factors are computed on the full matrix by `config.offset` and
enter each negative-binomial model as `log(factor)`; the estimate is a
natural-log fold change. `config.dispersion` selects per-taxon maximum-likelihood
theta (`"ml"`) or fixed theta from `glmGamPoi::glm_gp`'s cross-taxon dispersion trend
(`"glmGamPoi"`), fitted in one call on the taxa passing the prevalence filter.
The result's `config` includes the selected dispersion name.

`clr_welch`, in this order: (1) `min_prevalence` chooses the taxa, and taxa with
no reads in any sample are always left out; (2) the zeros of those taxa only
are replaced by `zCompositions::cmultRepl` using `config.replacement_method`,
`frac=config.replacement_delta`, and optional `config.bayesian_alpha`, so rare
taxa that are not tested contribute no imputed values; (3) each sample is
transformed to centred log-ratios over the same taxa; (4) each taxon is tested
by Welch's t-test. Replacing zeros across
every observed taxon first would let imputed values for rare taxa take over
the samples of a sparse table. The estimate is the difference in mean CLR,
contrast minus reference: a difference in centred-log-ratio units, not a fold
change, relative to the geometric mean of the tested taxa. Replaced zeros are
not measurements; `diagnostics.zero_replacement` reports their share of each
sample. Each group needs at least 2 samples.

`multinomial` and `dirichlet_multinomial` fit one model to the whole
composition of the taxa that pass `min_prevalence` and have reads in both
groups (a taxon with no reads in one group has an unbounded log fold change and
is reported as `failed`, with its reason, instead of dragging the joint fit
away). Both condition on each sample's total, so there is no size factor and no
zero replacement, and zeros need no epsilon: `CompositionalModels` carries the
likelihood. The reference taxon is `config.mn_reference_taxon`, or the most
abundant fitted taxon; it must have reads in at least half the samples, because
every reported ratio is anchored on it, and its row is returned with status
`reference` and no test. The estimate is the log fold change of taxon j's
relative abundance against the reference taxon, contrast over reference -- a log
ratio of two taxa, so it is coherent under compositionality and does not depend
on the library size. `multinomial` uses an L2 penalty of `config.mn_penalty`
(0 is maximum likelihood) and `dirichlet_multinomial` estimates the Dirichlet
concentration by `config.dm_overdispersion_method` (`mle` or `mom`); its
`diagnostics.overdispersion` reports the concentration c and theta = 1 / (1 + c),
and a concentration at either bound marks every fitted taxon `boundary`. Both
report `diagnostics.model` (reference taxon, penalty, parameters, iterations,
log-likelihood, runtime). A fit that does not converge, or whose observed
information is singular, is refused with `CompositionalRefusal` rather than
reporting estimates; one that exceeds `config.max_seconds` raises
`RuntimeRefusal`.

For every method, taxa present in fewer than `config.min_prevalence` of the
samples are reported as `filtered` and not fitted, and the Benjamini-Hochberg
family is the fitted taxa that produced a p-value; failed, filtered and
reference taxa carry `padj = nothing`. The result's `effect` names the row key
that holds the effect size and its label.

Throws `ArgumentError` for unusable input (including a zero replacement that
cannot be made, a reference taxon that is absent or too sparse, and settings
unused by the selected method), `ScalingRefusal` when the offset cannot be
computed, `MASSUnavailable`, `GlmGamPoiUnavailable` or `ZCompositionsUnavailable`
when a required R package is missing, `RBusyError` when the R runtime stays
busy, `CompositionalRefusal` when a multinomial fit cannot be estimated and
`RuntimeRefusal` when it exceeds its budget, and an `ErrorException` when no
taxon could be fitted at all, including when the `glm_gp` fit fails. Uncaught R
errors from the fitting and zero-replacement helpers propagate.
"""
function differential_abundance(counts::AbstractMatrix{<:Real},
                                samples::AbstractVector{<:AbstractString},
                                taxa::AbstractVector{<:AbstractString},
                                groups::AbstractVector{<:AbstractString};
                                reference::AbstractString, contrast::AbstractString,
                                config::DifferentialConfig=DifferentialConfig())
    reference == contrast && throw(ArgumentError(
        "the two groups must differ, but both are '$reference'"))
    length(groups) == length(samples) || throw(ArgumentError(
        "$(length(groups)) group labels for $(length(samples)) samples"))
    isempty(taxa) && throw(ArgumentError("there are no taxa to test"))
    validate_counts(counts, samples, taxa)
    unknown = setdiff(unique(groups), (reference, contrast))
    isempty(unknown) || throw(ArgumentError(
        "samples belong to groups other than '$reference' and '$contrast': $(join(unknown, ", "))"))
    n_ref = count(==(reference), groups)
    n_con = count(==(contrast), groups)
    (n_ref >= 1 && n_con >= 1) || throw(ArgumentError(
        "each group needs at least one sample; '$reference' has $n_ref and '$contrast' has $n_con"))
    n_ref + n_con >= 3 || throw(ArgumentError(
        "a group effect and a variance cannot be estimated from $(n_ref + n_con) samples; at least 3 are needed"))

    n = length(samples)
    present = [count(>(0), view(counts, :, j)) for j in axes(counts, 2)]
    prevalence = present ./ n
    rows = [_row(taxa[j], prevalence[j],
                 "present in $(present[j]) of $n samples, below " *
                 "analysis.differential.min_prevalence = $(config.min_prevalence)")
            for j in axes(counts, 2)]
    levels = (String(reference), String(contrast))
    diagnostics = Dict{String,Any}()

    if config.method == "nb_glm"
        factors = size_factors(counts, samples, config.offset)
        tested = findall(>=(config.min_prevalence), prevalence)
        fits = isempty(tested) ? nothing :
            fit_nb(Int.(counts[:, tested]), groups, log.(factors); levels,
                   dispersion=config.dispersion)
        if !isnothing(fits)
            for (k, j) in enumerate(tested)
                f = fits[k, :]
                merge!(rows[j], Dict{String,Any}(
                    "status" => f.status, "note" => f.note, "estimate" => f.estimate,
                    "log2_fold_change" => isnothing(f.estimate) ? nothing : f.estimate / log(2),
                    "standard_error" => f.se, "statistic" => f.statistic,
                    "pvalue" => f.pvalue, "dispersion_theta" => f.theta))
            end
        end
        nb_fit = config.dispersion == "ml" ? "MASS::glm.nb" :
                 "MASS::negative.binomial with dispersion trend from glmGamPoi::glm_gp"
        method_text = "Negative-binomial GLM per taxon ($nb_fit, log link) with a " *
                      "$(uppercase(config.offset)) size-factor offset; Wald test of the group " *
                      "coefficient; Benjamini-Hochberg adjustment over the fitted taxa"
        effect = Dict("key" => "log2_fold_change", "label" => "log2 fold change")
        size_factor_rows = [Dict("sample" => String(samples[i]), "group" => String(groups[i]),
                                 "factor" => factors[i]) for i in eachindex(samples)]
        config_echo = Dict{String,Any}("method" => config.method, "offset" => config.offset,
                                       "min_prevalence" => config.min_prevalence,
                                       "dispersion" => config.dispersion)
    elseif config.method in COMPOSITIONAL_METHODS
        # The multinomial models condition on each sample's total: they need no
        # size factor, and a zero count is part of the likelihood rather than a
        # value to replace. Two things still have to be settled before the fit.
        #
        # First, a taxon with no reads at all in one group has no finite log
        # fold change, and because the model is fitted jointly its coefficient
        # would drag the whole fit towards -Inf. Such taxa are refused by name
        # and left out of the composition, exactly like taxa below the
        # prevalence threshold; the note says which and why.
        tested = findall(>=(config.min_prevalence), prevalence)
        separated = Int[]
        for j in tested
            absent = [lvl for lvl in levels
                      if all(i -> counts[i, j] == 0, findall(==(lvl), groups))]
            if !isempty(absent)
                push!(separated, j)
                rows[j]["status"] = "failed"
                rows[j]["note"] = "no reads in any '$(absent[1])' sample (complete " *
                    "separation): the log fold change against the reference is unbounded, " *
                    "so the taxon is left out of the composition"
            end
        end
        tested = [j for j in tested if !(j in separated)]
        isempty(tested) && throw(ArgumentError(
            "no taxon passes analysis.differential.min_prevalence = $(config.min_prevalence) " *
            "and has reads in both '$reference' and '$contrast' samples, so there is no " *
            "composition to model; raise analysis.differential.min_prevalence or use " *
            "method nb_glm"))

        # Second, the reference taxon: the denominator of every reported ratio.
        # An explicit choice must be a taxon at this rank and must be fitted.
        ref_name = config.mn_reference_taxon
        ref_pos = 0
        if isnothing(ref_name)
            totals = [sum(view(counts, :, j)) for j in tested]
            ref_pos = argmax(totals)
            ref_name = String(taxa[tested[ref_pos]])
        else
            j = findfirst(==(ref_name), taxa)
            isnothing(j) && throw(ArgumentError(
                "analysis.differential.mn_reference_taxon = '$(ref_name)' is not a taxon " *
                "at this rank"))
            pos = findfirst(==(j), tested)
            isnothing(pos) && throw(ArgumentError(
                "the reference taxon '$(ref_name)' is not fitted: it has reads in " *
                "$(count(>(0), view(counts, :, j))) of $n samples, below " *
                "analysis.differential.min_prevalence = $(config.min_prevalence), or no " *
                "reads in one group. Choose another reference taxon, or lower min_prevalence"))
            ref_pos = pos
        end
        # A reference seen in fewer than half the samples makes every ratio it
        # anchors unstable, so it is refused rather than silently used.
        ref_prevalence = prevalence[tested[ref_pos]]
        ref_prevalence >= 0.5 || throw(ArgumentError(
            "the reference taxon '$(ref_name)' has reads in only " *
            "$(round(Int, ref_prevalence * n)) of $n samples; the log ratios it anchors " *
            "would be unstable. Choose a reference present in at least half the samples " *
            "(analysis.differential.mn_reference_taxon), or use method nb_glm or clr_welch"))

        # The design is the group indicator with an intercept: the intercept is
        # the log-odds against the reference in the reference group, the slope
        # the difference in those log-odds between the groups.
        design = Matrix{Float64}(undef, n, 2)
        for i in 1:n
            design[i, 1] = 1.0
            design[i, 2] = groups[i] == contrast ? 1.0 : 0.0
        end
        sub = Matrix{Int}(counts[:, tested])
        started = time()
        fit = config.method == "multinomial" ?
            fit_multinomial(sub, design; reference=ref_pos, penalty=config.mn_penalty,
                            max_iter=config.max_iter, tol=config.tol,
                            max_seconds=config.max_seconds) :
            fit_dirichlet_multinomial(sub, design; reference=ref_pos, penalty=config.mn_penalty,
                                      overdispersion_method=config.dm_overdispersion_method,
                                      max_iter=config.max_iter, tol=config.tol,
                                      max_seconds=config.max_seconds)
        elapsed = time() - started
        # A joint fit that has not converged describes neither taxon: there is
        # no per-taxon rescue, so it is refused rather than reported.
        fit.converged || throw(CompositionalRefusal(
            "the $(config.method == "multinomial" ? "multinomial" : "Dirichlet-multinomial") " *
            "fit did not converge in $(config.max_iter) Newton steps on $(length(tested)) taxa; " *
            "raise analysis.differential.max_iter, raise min_prevalence so fewer taxa are " *
            "fitted, or analyse a coarser taxonomic rank"))
        c = fit.concentration
        at_bound = config.method == "dirichlet_multinomial" &&
                   !(c > CONCENTRATION_MIN * (1 + 1e-6) && c < CONCENTRATION_MAX * (1 - 1e-6))
        boundary_note = c >= CONCENTRATION_MAX * (1 - 1e-6) ?
            "the Dirichlet concentration reached its upper bound: no overdispersion is " *
            "detectable, so the model is effectively multinomial" :
            "the Dirichlet concentration reached its lower bound: the composition is nearly " *
            "degenerate and the standard errors are not trustworthy"
        for (l, j) in enumerate(tested)
            if l == ref_pos
                rows[j]["status"] = "reference"
                rows[j]["note"] = "reference taxon: the denominator of every log ratio; its " *
                    "coefficient is fixed at zero, so it carries no test"
                rows[j]["estimate"] = 0.0
                rows[j]["log2_fold_change"] = 0.0
                continue
            end
            k = l < ref_pos ? l : l - 1
            est = fit.coefficients[k, 2]
            se = fit.standard_errors[k, 2]
            zz = fit.statistic[k, 2]
            pv = fit.pvalue[k, 2]
            if isnan(est) || isnan(se) || isnan(pv)
                rows[j]["status"] = "failed"
                rows[j]["note"] = "the fit returned a non-finite estimate or standard error"
                continue
            end
            merge!(rows[j], Dict{String,Any}(
                "status" => at_bound ? "boundary" : "ok",
                "note" => at_bound ? boundary_note : "",
                "estimate" => est,
                "log2_fold_change" => est / log(2),
                "standard_error" => se, "statistic" => zz, "pvalue" => pv,
                "dispersion_theta" => nothing))
        end
        model = config.method == "multinomial" ? "multinomial logistic" :
                "Dirichlet-multinomial"
        method_text = "$model regression over $(length(tested)) taxa with " *
            "'$(ref_name)' as the reference taxon (softmax link, each sample's read " *
            "composition, no size factor and no zero replacement); " *
            (config.method == "multinomial" ?
             "Wald test of the group coefficient from the observed information, with a " *
             "ridge penalty of $(config.mn_penalty); " :
             "concentration estimated by $(uppercase(config.dm_overdispersion_method)), " *
             "theta = $(round(fit.overdispersion; sigdigits=3)), Wald test of the group " *
             "coefficient from the observed information; ") *
            "Benjamini-Hochberg adjustment over the fitted taxa. Estimates are log fold " *
            "changes in relative abundance against '$(ref_name)' (a log ratio of two taxa, " *
            "so coherent under compositionality): " *
            (config.method == "multinomial" ?
             "Songbird's model, Morton et al. 2019" :
             "La Rosa et al. 2012 for the Dirichlet-multinomial")
        effect = Dict("key" => "log2_fold_change",
                      "label" => "log2 fold change vs $(ref_name)")
        size_factor_rows = Dict{String,Any}[]
        config_echo = Dict{String,Any}("method" => config.method,
                                       "min_prevalence" => config.min_prevalence,
                                       "mn_reference_taxon" => ref_name,
                                       "mn_penalty" => config.mn_penalty,
                                       "tolerance" => config.tol,
                                       "max_iter" => config.max_iter,
                                       "max_seconds" => config.max_seconds)
        config.method == "dirichlet_multinomial" &&
            (config_echo["dm_overdispersion_method"] = config.dm_overdispersion_method)
        diagnostics["model"] = Dict{String,Any}(
            "reference_taxon" => ref_name, "penalty" => config.mn_penalty,
            "n_parameters" => fit.n_parameters, "iterations" => fit.iterations,
            "converged" => fit.converged, "log_likelihood" => fit.loglik,
            "runtime_seconds" => elapsed, "n_taxa_fitted" => length(tested))
        if config.method == "dirichlet_multinomial"
            diagnostics["overdispersion"] = Dict{String,Any}(
                "method" => config.dm_overdispersion_method,
                "concentration" => c, "theta" => fit.overdispersion,
                "at_bound" => at_bound)
        end
    else
        (n_ref >= 2 && n_con >= 2) || throw(ArgumentError(
            "Welch's t-test needs at least 2 samples in each group to estimate its variance; " *
            "'$reference' has $n_ref and '$contrast' has $n_con"))
        for j in findall(==(0), present)
            rows[j]["note"] = "no reads in any sample of either group, so it is not part of the composition"
        end
        tested = findall(j -> present[j] > 0 && prevalence[j] >= config.min_prevalence, axes(counts, 2))
        length(tested) >= 2 || throw(ArgumentError(
            "the centred log-ratio needs at least 2 taxa with reads at or above " *
            "analysis.differential.min_prevalence = $(config.min_prevalence); there are $(length(tested))"))
        replaced = replace_zeros(counts[:, tested]; method=config.replacement_method,
                                 frac=config.replacement_delta, alpha=config.bayesian_alpha,
                                 samples, taxa=taxa[tested])
        clr = clr_transform(replaced.proportions)
        fits = fit_welch(clr, groups; levels)
        for (k, j) in enumerate(tested)
            f = fits[k, :]
            merge!(rows[j], Dict{String,Any}(
                "status" => f.status, "note" => f.note, "estimate" => f.estimate,
                "standard_error" => f.se, "statistic" => f.statistic,
                "pvalue" => f.pvalue))
        end
        r_fit = config.replacement_method == "multiplicative_replacement" ? "CZM" :
                isnothing(config.bayesian_alpha) ? "GBM" : "user"
        alpha_text = r_fit == "user" ? ", alpha = $(config.bayesian_alpha)" : ""
        method_text = "Welch's two-sample t-test per taxon (stats::t.test, var.equal = FALSE) on " *
                      "centred log-ratios over the taxa passing min_prevalence, after their zeros " *
                      "were replaced by zCompositions::cmultRepl ($r_fit, frac = $(config.replacement_delta)$alpha_text); " *
                      "Benjamini-Hochberg adjustment over the fitted taxa. Estimates are " *
                      "differences in CLR units, not fold changes, and replaced zeros are not measurements"
        effect = Dict("key" => "estimate", "label" => "CLR difference")
        size_factor_rows = Dict{String,Any}[]
        config_echo = Dict{String,Any}("method" => config.method,
                                       "min_prevalence" => config.min_prevalence,
                                       "replacement_method" => config.replacement_method,
                                       "replacement_delta" => config.replacement_delta,
                                       "bayesian_alpha" => config.bayesian_alpha)
        sorted_mass = sort(replaced.imputed_mass)
        zero_diagnostics = Dict{String,Any}(
            "method" => "zCompositions::cmultRepl ($r_fit)",
            "replacement_method" => config.replacement_method,
            "delta" => config.replacement_delta, "alpha" => config.bayesian_alpha,
            "zeros_replaced" => replaced.zeros_replaced,
            "n_taxa_in_composition" => length(tested),
            "n_taxa_unobserved" => count(==(0), present),
            "median_imputed_fraction" => _median(sorted_mass),
            "max_imputed_fraction" => last(sorted_mass),
            "warnings" => replaced.warnings)
        if !isnothing(replaced.posterior)
            zero_diagnostics["posterior"] = Dict{String,Any}(
                "family" => "Dirichlet",
                "prior_mean" => "leave-one-out taxon profile of the other samples",
                "shape" => "observed counts + concentration * prior_mean",
                "adjustments" => "The frac cap and multiplicative closure are applied after this posterior; no posterior draws are used",
                "concentration" => [Dict("sample" => String(samples[i]), "value" => s)
                                    for (i, s) in enumerate(replaced.posterior.concentration)])
        end
        diagnostics["zero_replacement"] = zero_diagnostics
    end

    family = findall(r -> r["status"] in ("ok", "boundary") && !isnothing(r["pvalue"]), rows)
    if isempty(family)
        notes = unique(r["note"] for r in rows)
        error("no taxon could be fitted: " * join(first(notes, 5), " | "))
    end
    padj = bh_adjust([rows[j]["pvalue"] for j in family])
    for (k, j) in enumerate(family)
        rows[j]["padj"] = padj[k]
    end

    sort!(rows; by = r -> (isnothing(r["padj"]) ? 2.0 : r["padj"],
                           isnothing(r["pvalue"]) ? 2.0 : r["pvalue"], r["taxon"]))

    n_failed = count(r -> r["status"] == "failed", rows)
    merge!(diagnostics, Dict{String,Any}(
        "n_taxa" => length(taxa), "n_tested" => length(family), "n_failed" => n_failed,
        "n_boundary" => count(r -> r["status"] == "boundary", rows),
        "n_filtered" => count(r -> r["status"] == "filtered", rows)))
    Dict{String,Any}(
        "status" => n_failed == 0 ? "ok" : "partial",
        "method" => method_text,
        "effect" => effect,
        "groups" => Dict("reference" => String(reference), "contrast" => String(contrast)),
        "n_samples" => Dict(String(reference) => n_ref, String(contrast) => n_con),
        "size_factors" => size_factor_rows,
        "config" => config_echo,
        "diagnostics" => diagnostics,
        "rows" => rows,
    )
end

"""
    volcano_chart(result; alpha=0.05) -> Dict

A Plotly volcano plot of a `differential_abundance` result: the effect named by
`result["effect"]` (log2 fold change, or CLR difference) against -log10 of the
raw p-value, coloured by whether the BH-adjusted p-value is below `alpha`. Taxa
without a p-value are omitted here; they remain in the results table with their
reason.
"""
function volcano_chart(result::AbstractDict; alpha::Real=0.05)
    ref = result["groups"]["reference"]
    con = result["groups"]["contrast"]
    effect = get(result, "effect", Dict("key" => "log2_fold_change", "label" => "log2 fold change"))
    fitted = filter(r -> !isnothing(r["padj"]), result["rows"])
    colours = _palette_hex(2)
    traces = Any[]
    for (sig, name, colour) in ((false, "padj ≥ $alpha", colours[2]),
                                (true,  "padj < $alpha", colours[1]))
        sel = filter(r -> (r["padj"] < alpha) == sig, fitted)
        isempty(sel) && continue
        # A p-value that underflowed to 0 is drawn at the smallest positive
        # double and says so in its hover text.
        y = [-log10(max(r["pvalue"], floatmin(Float64))) for r in sel]
        text = [string(r["taxon"], "<br>padj = ", round(r["padj"]; sigdigits=3),
                       r["pvalue"] == 0 ? "<br>p underflowed to 0" : "") for r in sel]
        push!(traces, Dict{String,Any}(
            "type" => "scatter", "mode" => "markers", "name" => name,
            "x" => [r[effect["key"]] for r in sel], "y" => y,
            "text" => text, "hoverinfo" => "text+x+y",
            "marker" => Dict("color" => colour, "size" => 8),
        ))
    end
    layout = Dict{String,Any}(
        "title" => Dict("text" => "Differential abundance: $con vs $ref"),
        "xaxis" => Dict("title" => "$(effect["label"]) ($con vs $ref)", "zeroline" => true),
        "yaxis" => Dict("title" => "-log10 p"),
    )
    Dict("data" => traces, "layout" => layout)
end

end # module Differential
