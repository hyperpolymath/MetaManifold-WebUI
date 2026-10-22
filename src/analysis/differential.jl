# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

## Differential abundance
# Per-taxon and compositional models comparing two groups of samples, with
# mandatory Benjamini-Hochberg correction across the taxa that produced a
# p-value. Five methods:
#
# - nb_glm: a negative-binomial GLM per taxon (MASS::glm.nb) on the observed
#   integer read counts, with a library-size offset. There are no pseudocounts.
# - clr_welch: Welch's two-sample t-test per taxon (stats::t.test) on centred
#   log-ratios, over the taxa that pass `min_prevalence`, after their zeros are
#   replaced by zCompositions::cmultRepl (Bayesian GBM/user or multiplicative
#   CZM, for counts). The estimate is a difference in CLR units, not a fold change.
# - ancom_bc: bias-corrected log-linear model (Lin & Peddada 2020) estimating
#   within-group sample-specific offsets and between-group sampling-fraction
#   bias via a safeguarded SQUAREM 3-component Gaussian mixture. The effect is
#   a bias-corrected log2 fold change.
# - aldex2: Dirichlet(count + 0.5) Monte-Carlo CLR instances with consistent-sign
#   per-instance Welch's t-tests and Fernandes et al. (2014) standardized CLR
#   effect size.
# - songbird: baseline-category compositional multinomial regression with
#   reference-frame invariant CLR-centred differentials (Morton et al. 2019;
#   Zhang et al. 2017) fitted by damped Newton-Raphson with exact O(K)
#   Sherman-Morrison Fisher-information inversion.
#
# Count matrices here are samples x taxa, as everywhere else in `Analysis`.
# Anything that is not a non-negative integer count is refused rather than
# rounded. A taxon whose fit fails is reported with its reason and kept out of
# the multiple-testing family; it never receives a stand-in p-value.
module Differential

using DataFrames, RCall
using ..RRuntime: with_r_lock
using ..Analysis: _palette_hex, R_WAIT_SECONDS
export DifferentialConfig, ScalingRefusal, MASSUnavailable, ZCompositionsUnavailable,
       GlmGamPoiUnavailable, RStatsUnavailable, OFFSET_METHODS, METHODS, DISPERSIONS,
       REPLACEMENT_METHODS, MIN_MC_SAMPLES, MAX_MC_SAMPLES, DEFAULT_MC_SAMPLES,
       tss_factors, rle_factors, size_factors, bh_adjust, validate_counts, replace_zeros,
       clr_transform, fit_nb, fit_welch, fit_ancom_bc, fit_aldex2, fit_songbird,
       differential_abundance, volcano_chart

# Methods accepted under `analysis.differential.method`.
const METHODS = ("nb_glm", "clr_welch", "ancom_bc", "aldex2", "songbird")

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

# Bounds and default for `analysis.differential.mc_samples` (`aldex2` Dirichlet draws).
const MIN_MC_SAMPLES = 16
const MAX_MC_SAMPLES = 4096
const DEFAULT_MC_SAMPLES = 128
const DEFAULT_DA_SEED = 123

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
                       bayesian_alpha=nothing, mc_samples=128)

Settings for one differential abundance analysis, read from
`analysis.differential` in the pipeline config. `method` is one of `"nb_glm"`,
`"clr_welch"`, `"ancom_bc"`, `"aldex2"` or `"songbird"`. `offset` names the
size factor method (`"tss"` or `"rle"`) and is used by `nb_glm` only.
`min_prevalence` is the fraction of samples, in [0, 1], in which a taxon must
have at least one read to be tested. `replacement_delta`, in (0, 1), is the
`frac` passed to `zCompositions::cmultRepl` by `clr_welch`.
`replacement_method` selects `"bayesian_multiplicative"` (GBM) or
`"multiplicative_replacement"` (CZM), with optional positive `bayesian_alpha`
for `"bayesian_multiplicative"`.
`dispersion` names the per-taxon dispersion `nb_glm` uses (`"ml"` or
`"glmGamPoi"`); `"glmGamPoi"` is refused when `method != "nb_glm"`.
`mc_samples`, a whole number in [`MIN_MC_SAMPLES`, `MAX_MC_SAMPLES`], sets the
number of Dirichlet Monte-Carlo instances drawn per sample by `aldex2`.
Throws `ArgumentError` for unsupported names, incompatible method and dispersion
choices, or non-finite or out-of-range settings.
"""
struct DifferentialConfig
    method             :: String
    offset             :: String
    min_prevalence     :: Float64
    replacement_delta  :: Float64
    dispersion         :: String
    replacement_method :: String
    bayesian_alpha     :: Union{Float64,Nothing}
    mc_samples         :: Int
    function DifferentialConfig(offset::AbstractString="tss", min_prevalence::Real=0.0;
                                method::AbstractString="nb_glm",
                                replacement_delta::Real=DEFAULT_DELTA,
                                dispersion::AbstractString="ml",
                                replacement_method::AbstractString="bayesian_multiplicative",
                                bayesian_alpha::Union{Real,Nothing}=nothing,
                                mc_samples::Real=DEFAULT_MC_SAMPLES)
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
        r = _replacement_method(replacement_method)
        (isnothing(bayesian_alpha) ||
         (!(bayesian_alpha isa Bool) && isfinite(bayesian_alpha) && bayesian_alpha > 0)) ||
            throw(ArgumentError("analysis.differential.bayesian_alpha must be empty or a " *
                                "finite number greater than 0, not $bayesian_alpha"))
        (!(mc_samples isa Bool) && isfinite(mc_samples) && isinteger(mc_samples) &&
         MIN_MC_SAMPLES <= mc_samples <= MAX_MC_SAMPLES) || throw(ArgumentError(
            "analysis.differential.mc_samples must be a whole number in " *
            "[$MIN_MC_SAMPLES, $MAX_MC_SAMPLES], not $mc_samples"))
        a = isnothing(bayesian_alpha) ? nothing : Float64(bayesian_alpha)
        new(m, o, Float64(min_prevalence), Float64(replacement_delta), d, r, a, Int(mc_samples))
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
    RStatsUnavailable()

Raised when the embedded R `stats` package cannot be loaded for compositional
differential abundance models (`ancom_bc`, `aldex2`, `songbird`).
"""
struct RStatsUnavailable <: Exception end

Base.showerror(io::IO, ::RStatsUnavailable) = print(io,
    "the R package stats is not available, so compositional differential abundance " *
    "models cannot be fitted; install R with its base packages")

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

# Two-group ANCOM-BC (Lin & Peddada 2020, Nat. Commun. 11:3514):
# (1) Estimate within-group sample-specific sampling-fraction offsets on
#     log(counts + 1) by inverse-variance-weighted least squares, centred within
#     each group so group means retain the between-group sampling-fraction shift.
# (2) Estimate the between-group sampling-fraction bias delta across taxa via a
#     safeguarded monotone SQUAREM 3-component heteroscedastic Gaussian mixture
#     (null beta = 0, negative l1 <= 0, positive l2 >= 0).
# (3) Subtract delta from each taxon's raw log-mean difference and propagate
#     Var(delta_hat) into the Wald standard error.
const _FIT_ANCOM_BC_R = raw"""
da_out <- local({
  n <- nrow(da_counts)
  d <- ncol(da_counts)
  n1 <- length(da_idx1)
  n2 <- length(da_idx2)
  ylog <- log(da_counts + 1.0)

  mu1 <- colMeans(ylog[da_idx1, , drop = FALSE])
  mu2 <- colMeans(ylog[da_idx2, , drop = FALSE])
  di <- numeric(n)
  for (it_d in seq_len(50L)) {
    r1 <- sweep(ylog[da_idx1, , drop = FALSE] - di[da_idx1], 2L, mu1, "-")
    r2 <- sweep(ylog[da_idx2, , drop = FALSE] - di[da_idx2], 2L, mu2, "-")
    s1 <- colSums(r1 * r1) / (n1 - 1L)
    s2 <- colSums(r2 * r2) / (n2 - 1L)
    w <- 1.0 / pmax(s1 + s2, 1e-10)
    w <- w / sum(w)
    d_raw <- numeric(n)
    d_raw[da_idx1] <- as.vector(sweep(ylog[da_idx1, , drop = FALSE], 2L, mu1, "-") %*% w)
    d_raw[da_idx2] <- as.vector(sweep(ylog[da_idx2, , drop = FALSE], 2L, mu2, "-") %*% w)
    di_new <- d_raw
    di_new[da_idx1] <- d_raw[da_idx1] - mean(d_raw[da_idx1])
    di_new[da_idx2] <- d_raw[da_idx2] - mean(d_raw[da_idx2])
    if (max(abs(di_new - di)) < 1e-8) {
      di <- di_new
      break
    }
    di <- di_new
  }

  r1 <- sweep(ylog[da_idx1, , drop = FALSE] - di[da_idx1], 2L, mu1, "-")
  r2 <- sweep(ylog[da_idx2, , drop = FALSE] - di[da_idx2], 2L, mu2, "-")
  s1 <- colSums(r1 * r1) / (n1 - 1L)
  s2 <- colSums(r2 * r2) / (n2 - 1L)
  raw_diff <- mu2 - mu1
  nu2 <- s1 / n1 + s2 / n2

  res_df <- data.frame(
    status = rep("ok", d),
    note = rep("", d),
    estimate = rep(NA_real_, d),
    se = rep(NA_real_, d),
    statistic = rep(NA_real_, d),
    pvalue = rep(NA_real_, d),
    stringsAsFactors = FALSE
  )

  ok <- which(is.finite(nu2) & (nu2 > 1e-24))
  bad <- setdiff(seq_len(d), ok)
  if (length(bad) > 0L) {
    res_df[bad, "status"] <- "failed"
    res_df[bad, "note"] <- "within-group log-count variance is zero, so ANCOM-BC cannot form a standard error"
  }
  if (length(ok) < 3L) {
    return(list(
      result = res_df,
      converged = FALSE,
      reason = paste0("fewer than 3 taxa (", length(ok), ") have positive within-group variance for ANCOM-BC bias estimation"),
      delta = NA_real_, delta_se = NA_real_,
      pi0 = NA_real_, pi1 = NA_real_, pi2 = NA_real_,
      em_iterations = 0L
    ))
  }

  raw_ok <- raw_diff[ok]
  vb <- nu2[ok]
  m_ok <- length(ok)

  max_kappa <- function(rk, resid_sq, v_base, k_upper) {
    if (sum(rk) <= 1e-12) return(0.0)
    f <- function(kap) {
      vk <- v_base + kap
      sum(rk * (-0.5 * log(vk) - 0.5 * resid_sq / vk))
    }
    f0 <- f(0.0)
    fu <- f(k_upper)
    opt <- stats::optimize(f, interval = c(0.0, k_upper), maximum = TRUE, tol = 1e-9)
    best_x <- opt[["maximum"]]
    best_v <- opt[["objective"]]
    if (f0 >= best_v) {
      best_x <- 0.0
      best_v <- f0
    }
    if (fu > best_v) {
      best_x <- k_upper
    }
    best_x
  }

  em_loglik <- function(th) {
    pi0 <- th[1]; pi1 <- th[2]; pi2 <- th[3]; delt <- th[4]
    l1 <- th[5]; l2 <- th[6]; k1 <- th[7]; k2 <- th[8]
    v0 <- vb; v1 <- vb + k1; v2 <- vb + k2
    lp0 <- log(pi0) - 0.5 * log(2.0 * pi * v0) - 0.5 * ((raw_ok - delt)^2) / v0
    lp1 <- log(pi1) - 0.5 * log(2.0 * pi * v1) - 0.5 * ((raw_ok - delt - l1)^2) / v1
    lp2 <- log(pi2) - 0.5 * log(2.0 * pi * v2) - 0.5 * ((raw_ok - delt - l2)^2) / v2
    mx <- pmax(lp0, lp1, lp2)
    sum(mx + log(exp(lp0 - mx) + exp(lp1 - mx) + exp(lp2 - mx)))
  }

  em_resp <- function(th) {
    pi0 <- th[1]; pi1 <- th[2]; pi2 <- th[3]; delt <- th[4]
    l1 <- th[5]; l2 <- th[6]; k1 <- th[7]; k2 <- th[8]
    v0 <- vb; v1 <- vb + k1; v2 <- vb + k2
    lp0 <- log(pi0) - 0.5 * log(2.0 * pi * v0) - 0.5 * ((raw_ok - delt)^2) / v0
    lp1 <- log(pi1) - 0.5 * log(2.0 * pi * v1) - 0.5 * ((raw_ok - delt - l1)^2) / v1
    lp2 <- log(pi2) - 0.5 * log(2.0 * pi * v2) - 0.5 * ((raw_ok - delt - l2)^2) / v2
    mx <- pmax(lp0, lp1, lp2)
    e0 <- exp(lp0 - mx); e1 <- exp(lp1 - mx); e2 <- exp(lp2 - mx)
    s <- e0 + e1 + e2
    list(r0 = e0 / s, r1 = e1 / s, r2 = e2 / s)
  }

  em_step <- function(th, k_upper) {
    pi0 <- th[1]; pi1 <- th[2]; pi2 <- th[3]; delt <- th[4]
    l1 <- th[5]; l2 <- th[6]; k1 <- th[7]; k2 <- th[8]
    rs <- em_resp(th)
    r0 <- rs[["r0"]]; r1 <- rs[["r1"]]; r2 <- rs[["r2"]]

    pi0_n <- max(1e-6, sum(r0) / m_ok)
    pi1_n <- max(1e-6, sum(r1) / m_ok)
    pi2_n <- max(1e-6, sum(r2) / m_ok)
    ps <- pi0_n + pi1_n + pi2_n
    pi0_n <- pi0_n / ps; pi1_n <- pi1_n / ps; pi2_n <- pi2_n / ps

    v1 <- vb + k1; v2 <- vb + k2
    num <- sum(r0 * raw_ok / vb + r1 * (raw_ok - l1) / v1 + r2 * (raw_ok - l2) / v2)
    den <- sum(r0 / vb + r1 / v1 + r2 / v2)
    delt_n <- num / den

    w1 <- sum(r1 / v1); w2 <- sum(r2 / v2)
    l1_n <- min(0.0, sum(r1 * (raw_ok - delt_n) / v1) / max(w1, 1e-12))
    l2_n <- max(0.0, sum(r2 * (raw_ok - delt_n) / v2) / max(w2, 1e-12))

    k1_n <- max_kappa(r1, (raw_ok - delt_n - l1_n)^2, vb, k_upper)
    k2_n <- max_kappa(r2, (raw_ok - delt_n - l2_n)^2, vb, k_upper)
    c(pi0_n, pi1_n, pi2_n, delt_n, l1_n, l2_n, k1_n, k2_n)
  }

  proj_theta <- function(th, k_upper) {
    p0 <- max(1e-6, th[1]); p1 <- max(1e-6, th[2]); p2 <- max(1e-6, th[3])
    ps <- p0 + p1 + p2
    c(p0 / ps, p1 / ps, p2 / ps, th[4],
      min(0.0, th[5]), max(0.0, th[6]),
      min(k_upper, max(0.0, th[7])), min(k_upper, max(0.0, th[8])))
  }

  delt0 <- stats::median(raw_ok)
  u <- raw_ok - delt0
  qs <- stats::quantile(u, probs = c(0.25, 0.75), names = FALSE, type = 7)
  low_u <- u[u <= qs[1]]
  high_u <- u[u >= qs[2]]
  l1_0 <- min(-0.05, mean(low_u))
  l2_0 <- max(0.05, mean(high_u))
  u_var <- mean(u * u)
  k_upper <- max(10.0, 4.0 * u_var)
  k1_0 <- max(0.01, mean((low_u - l1_0)^2))
  k2_0 <- max(0.01, mean((high_u - l2_0)^2))
  theta <- c(0.75, 0.125, 0.125, delt0, l1_0, l2_0, k1_0, k2_0)

  converged <- FALSE
  iters_used <- 0L
  for (it in seq_len(as.integer(da_max_iter))) {
    iters_used <- it
    t1 <- em_step(theta, k_upper)
    t2 <- em_step(t1, k_upper)
    rv <- t1 - theta
    vv <- (t2 - t1) - rv
    v_norm <- sqrt(sum(vv * vv))
    r_norm <- sqrt(sum(rv * rv))
    if (is.finite(v_norm) && v_norm > 1e-12) {
      alpha <- -max(1.0, r_norm / v_norm)
      cand <- proj_theta(theta - 2.0 * alpha * rv + alpha * alpha * vv, k_upper)
      cand <- em_step(cand, k_upper)
      theta_next <- if (is.finite(em_loglik(cand)) && em_loglik(cand) >= em_loglik(t2)) cand else t2
    } else {
      theta_next <- t2
    }
    if (abs(theta_next[4] - theta[4]) < da_tol && abs(t2[4] - t1[4]) < da_tol) {
      theta <- theta_next
      converged <- TRUE
      break
    }
    theta <- theta_next
  }

  if (!converged || !all(is.finite(theta))) {
    return(list(
      result = res_df,
      converged = FALSE,
      reason = paste0("ANCOM-BC E-M bias estimator did not converge within ", da_max_iter, " iterations"),
      delta = NA_real_, delta_se = NA_real_,
      pi0 = NA_real_, pi1 = NA_real_, pi2 = NA_real_,
      em_iterations = iters_used
    ))
  }

  rs <- em_resp(theta)
  delt_hat <- theta[4]
  k1_hat <- theta[7]; k2_hat <- theta[8]
  info_delt <- sum(rs[["r0"]] / vb + rs[["r1"]] / (vb + k1_hat) + rs[["r2"]] / (vb + k2_hat))
  var_delt <- 1.0 / info_delt
  est_ok <- raw_ok - delt_hat
  se_ok <- sqrt(vb + var_delt)
  stat_ok <- est_ok / se_ok
  pval_ok <- 2.0 * stats::pnorm(abs(stat_ok), lower.tail = FALSE)

  res_df[ok, "estimate"] <- est_ok
  res_df[ok, "se"] <- se_ok
  res_df[ok, "statistic"] <- stat_ok
  res_df[ok, "pvalue"] <- pval_ok

  list(
    result = res_df,
    converged = TRUE,
    reason = "",
    delta = delt_hat,
    delta_se = sqrt(var_delt),
    pi0 = theta[1], pi1 = theta[2], pi2 = theta[3],
    em_iterations = iters_used
  )
})
"""

"""
    fit_ancom_bc(counts, groups; levels, samples, max_iter=300, tol=1e-6)
        -> (table=DataFrame, diagnostics=Dict{String,Any})

Two-group ANCOM-BC (Lin & Peddada 2020, *Nat. Commun.* 11:3514) on the
`samples x taxa` count matrix `counts` over the taxa passing `min_prevalence`.
Estimates within-group sample-specific sampling-fraction offsets and the
between-group sampling-fraction shift `delta` via a safeguarded SQUAREM
3-component heteroscedastic Gaussian mixture on `log(counts + 1)`.
`levels` is `(reference, contrast)`, so positive bias-corrected estimates mean
higher absolute abundance in `contrast` relative to `reference`.
"""
function fit_ancom_bc(counts::AbstractMatrix{<:Real},
                      groups::AbstractVector{<:AbstractString};
                      levels::NTuple{2,String},
                      samples::AbstractVector{<:AbstractString}=string.(axes(counts, 1)),
                      max_iter::Integer=300,
                      tol::Real=1e-6)
    size(counts, 1) == length(groups) == length(samples) || throw(ArgumentError(
        "counts ($(size(counts, 1)) rows), groups ($(length(groups))) and samples ($(length(samples))) must match"))
    size(counts, 2) >= 3 || throw(ArgumentError(
        "ancom_bc requires at least 3 taxa to separate sampling-fraction bias from taxon effects; " *
        "there are $(size(counts, 2))"))
    idx_ref = findall(==(levels[1]), groups)
    idx_con = findall(==(levels[2]), groups)
    (length(idx_ref) >= 2 && length(idx_con) >= 2) || throw(ArgumentError(
        "ancom_bc needs at least 2 samples in each group to estimate within-group variance; " *
        "'$(levels[1])' has $(length(idx_ref)) and '$(levels[2])' has $(length(idx_con))"))
    for i in axes(counts, 1)
        sum(view(counts, i, :)) > 0 || throw(ArgumentError(
            "sample '$(samples[i])' has no reads in the $(size(counts, 2)) taxa that pass " *
            "min_prevalence, so its sampling fraction cannot be estimated"))
    end

    raw, meta = with_r_lock(; timeout=R_WAIT_SECONDS[]) do
        RCall.rcopy(RCall.reval("requireNamespace('stats', quietly = TRUE)")) ||
            throw(RStatsUnavailable())
        RCall.globalEnv[:da_counts] = Matrix{Float64}(counts)
        RCall.globalEnv[:da_idx1] = Int.(idx_ref)
        RCall.globalEnv[:da_idx2] = Int.(idx_con)
        RCall.globalEnv[:da_max_iter] = Int(max_iter)
        RCall.globalEnv[:da_tol] = Float64(tol)
        try
            RCall.reval(_FIT_ANCOM_BC_R)
            df = DataFrame(RCall.rcopy(RCall.reval("da_out[['result']]")))
            m = Dict{String,Any}(
                "converged" => Bool(RCall.rcopy(RCall.reval("da_out[['converged']]"))),
                "reason" => String(RCall.rcopy(RCall.reval("da_out[['reason']]"))),
                "delta" => _num(RCall.rcopy(RCall.reval("da_out[['delta']]"))),
                "delta_se" => _num(RCall.rcopy(RCall.reval("da_out[['delta_se']]"))),
                "pi0" => _num(RCall.rcopy(RCall.reval("da_out[['pi0']]"))),
                "pi1" => _num(RCall.rcopy(RCall.reval("da_out[['pi1']]"))),
                "pi2" => _num(RCall.rcopy(RCall.reval("da_out[['pi2']]"))),
                "em_iterations" => Int(RCall.rcopy(RCall.reval("da_out[['em_iterations']]"))),
            )
            (df, m)
        finally
            RCall.reval("rm(list = intersect(ls(), c('da_counts', 'da_idx1', 'da_idx2', " *
                        "'da_max_iter', 'da_tol', 'da_out'))); invisible(gc())")
        end
    end

    meta["converged"] || error(meta["reason"])
    warns = String[]
    size(counts, 2) < 10 && push!(warns,
        "fewer than 10 taxa ($(size(counts, 2))) entered the ANCOM-BC bias estimator; " *
        "sampling-fraction estimation is most reliable across larger communities")
    diag = Dict{String,Any}(
        "delta" => meta["delta"],
        "delta_se" => meta["delta_se"],
        "pi0" => meta["pi0"],
        "pi1" => meta["pi1"],
        "pi2" => meta["pi2"],
        "em_iterations" => meta["em_iterations"],
        "pseudo_count" => 1.0,
        "warnings" => warns,
    )
    tbl = DataFrame(
        status    = String.(raw.status),
        note      = String.(raw.note),
        estimate  = _num.(raw.estimate),
        se        = _num.(raw.se),
        statistic = _num.(raw.statistic),
        pvalue    = _num.(raw.pvalue),
    )
    (table=tbl, diagnostics=diag)
end

# Two-group ALDEx2 (Fernandes et al. 2013, 2014; consistent-sign posterior
# predictive Welch/Wilcoxon p-values and standardized CLR effect size):
# (1) Draw `da_mc` Dirichlet(count + 0.5) instances per sample in fixed sample
#     order 1..n and centre each draw in log-space (CLR).
# (2) Compute per-instance Welch t-tests and Mann-Whitney/Wilcoxon tests
#     (contrast minus reference), with consistent-sign directional doubling
#     `we_ep = min(mean(p_greater), mean(p_less))` and expected BH `we_ebh`.
# (3) Compute unpaired between-group CLR difference `diff_btw`, within-group
#     CLR dispersion `diff_win` (using non-self cyclic-shift permutations keyed
#     by canonical group sample order so swapping reference and contrast negates
#     `diff_btw` and `effect` identically), and `effect = median(btw / winmax)`.
const _FIT_ALDEX2_R = raw"""
da_out <- local({
  had_seed <- exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)
  old_seed <- if (had_seed) get(".Random.seed", envir = .GlobalEnv, inherits = FALSE) else NULL
  on.exit({
    if (had_seed) {
      assign(".Random.seed", old_seed, envir = .GlobalEnv)
    } else if (exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)) {
      rm(".Random.seed", envir = .GlobalEnv)
    }
  }, add = TRUE)
  set.seed(as.integer(da_seed))

  n <- nrow(da_counts)
  d <- ncol(da_counts)
  mc <- as.integer(da_mc)
  n1 <- length(da_idx1)
  n2 <- length(da_idx2)
  xmin <- .Machine[["double.xmin"]]

  Z <- array(0.0, dim = c(n, d, mc))
  for (i in seq_len(n)) {
    g_mat <- matrix(
      stats::rgamma(as.integer(d) * mc, shape = rep(da_counts[i, ] + 0.5, times = mc), rate = 1.0),
      nrow = d, ncol = mc
    )
    g_mat[g_mat < xmin] <- xmin
    l_mat <- log(g_mat)
    Z[i, , ] <- sweep(l_mat, 2L, colMeans(l_mat), "-")
  }

  sum_pgt <- numeric(d); sum_plt <- numeric(d)
  sum_qgt <- numeric(d); sum_qlt <- numeric(d)
  sum_wgt <- numeric(d); sum_wlt <- numeric(d)
  sum_wqgt <- numeric(d); sum_wqlt <- numeric(d)
  sum_t <- numeric(d)
  exact_wi <- (n1 < 50L) && (n2 < 50L)

  for (k in seq_len(mc)) {
    X1 <- matrix(Z[da_idx1, , k], nrow = n1, ncol = d)
    X2 <- matrix(Z[da_idx2, , k], nrow = n2, ncol = d)
    m1 <- colMeans(X1)
    m2 <- colMeans(X2)
    v1 <- colSums((X1 - rep(m1, each = n1))^2) / (n1 - 1L)
    v2 <- colSums((X2 - rep(m2, each = n2))^2) / (n2 - 1L)
    s1 <- v1 / n1
    s2 <- v2 / n2
    se2 <- s1 + s2
    se <- sqrt(se2)
    t_stat <- (m2 - m1) / se
    df <- (se2 * se2) / ((s1 * s1) / (n1 - 1L) + (s2 * s2) / (n2 - 1L))
    p_up <- stats::pt(t_stat, df = df, lower.tail = FALSE)
    pgt <- pmin(1.0, 2.0 * p_up)
    plt <- pmin(1.0, 2.0 * (1.0 - p_up))
    sum_pgt <- sum_pgt + pgt
    sum_plt <- sum_plt + plt
    sum_qgt <- sum_qgt + stats::p.adjust(pgt, method = "BH")
    sum_qlt <- sum_qlt + stats::p.adjust(plt, method = "BH")
    sum_t <- sum_t + t_stat

    comb <- rbind(X2, X1)
    rk <- apply(comb, 2L, rank)
    u_stat <- colSums(rk[seq_len(n2), , drop = FALSE]) - (n2 * (n2 + 1.0)) / 2.0
    if (exact_wi) {
      w_up <- stats::pwilcox(u_stat - 1.0, n2, n1, lower.tail = FALSE)
      w_lo <- stats::pwilcox(u_stat, n2, n1, lower.tail = TRUE)
    } else {
      mu_u <- (as.numeric(n1) * as.numeric(n2)) / 2.0
      sd_u <- sqrt((as.numeric(n1) * as.numeric(n2) * (n1 + n2 + 1.0)) / 12.0)
      w_up <- stats::pnorm((u_stat - mu_u - 0.5) / sd_u, lower.tail = FALSE)
      w_lo <- stats::pnorm((u_stat - mu_u + 0.5) / sd_u, lower.tail = TRUE)
    }
    wgt <- pmin(1.0, 2.0 * w_up)
    wlt <- pmin(1.0, 2.0 * w_lo)
    sum_wgt <- sum_wgt + wgt
    sum_wlt <- sum_wlt + wlt
    sum_wqgt <- sum_wqgt + stats::p.adjust(wgt, method = "BH")
    sum_wqlt <- sum_wqlt + stats::p.adjust(wlt, method = "BH")
  }

  we_ep <- pmin(sum_pgt / mc, sum_plt / mc)
  we_ebh <- pmin(sum_qgt / mc, sum_qlt / mc)
  wi_ep <- pmin(sum_wgt / mc, sum_wlt / mc)
  wi_ebh <- pmin(sum_wqgt / mc, sum_wqlt / mc)
  mean_t <- sum_t / mc

  # Canonical group ordering for unpaired effect-size pairing so swapping
  # reference and contrast flips diff_btw and effect by -1 identically.
  ref_is_lo <- min(da_idx1) < min(da_idx2)
  idx_lo <- if (ref_is_lo) da_idx1 else da_idx2
  idx_hi <- if (ref_is_lo) da_idx2 else da_idx1
  n_lo <- length(idx_lo)
  n_hi <- length(idx_hi)
  n_max <- max(n_lo, n_hi)

  pair_group <- function(Z_grp, ng, n_target) {
    val_arr <- array(0.0, dim = c(n_target, d, mc))
    win_arr <- array(0.0, dim = c(n_target, d, mc))
    for (k in seq_len(mc)) {
      perm <- sample.int(ng)
      sh <- if (ng > 2L) sample.int(ng - 1L, size = 1L) else 1L
      perm2 <- perm[((seq_len(ng) + sh - 1L) %% ng) + 1L]
      Xk <- matrix(Z_grp[, , k], nrow = ng, ncol = d)
      vk <- Xk[perm, , drop = FALSE]
      wk <- abs(vk - Xk[perm2, , drop = FALSE])
      if (ng < n_target) {
        pick <- sample.int(ng, size = n_target, replace = TRUE)
        vk <- vk[pick, , drop = FALSE]
        wk <- wk[pick, , drop = FALSE]
      }
      val_arr[, , k] <- vk
      win_arr[, , k] <- wk
    }
    list(val = val_arr, win = win_arr)
  }

  plo <- pair_group(Z[idx_lo, , , drop = FALSE], n_lo, n_max)
  phi <- pair_group(Z[idx_hi, , , drop = FALSE], n_hi, n_max)
  btw_sign <- if (ref_is_lo) 1.0 else -1.0

  diff_btw <- numeric(d)
  diff_win <- numeric(d)
  eff <- numeric(d)
  for (j in seq_len(d)) {
    btw_j <- btw_sign * as.vector(phi[["val"]][, j, ] - plo[["val"]][, j, ])
    win_j <- pmax(as.vector(plo[["win"]][, j, ]), as.vector(phi[["win"]][, j, ]))
    ratio_j <- ifelse(btw_j == 0.0 & win_j == 0.0, 0.0, btw_j / win_j)
    diff_btw[j] <- stats::median(btw_j)
    diff_win[j] <- stats::median(win_j)
    eff[j] <- stats::median(ratio_j)
  }

  ok <- is.finite(eff) & is.finite(we_ep) & (we_ep >= 0.0) & (we_ep <= 1.0)
  status <- ifelse(ok, "ok", "failed")
  note <- ifelse(ok, "", "ALDEx2 returned a non-finite effect size or p-value")
  res_df <- data.frame(
    status = status,
    note = note,
    estimate = ifelse(ok, eff, NA_real_),
    diff_btw = ifelse(ok, diff_btw, NA_real_),
    diff_win = ifelse(ok, diff_win, NA_real_),
    statistic = ifelse(ok, mean_t, NA_real_),
    pvalue = ifelse(ok, we_ep, NA_real_),
    we_ebh = ifelse(ok, we_ebh, NA_real_),
    wi_pvalue = ifelse(ok, wi_ep, NA_real_),
    wi_ebh = ifelse(ok, wi_ebh, NA_real_),
    stringsAsFactors = FALSE
  )
  list(result = res_df)
})
"""

"""
    fit_aldex2(counts, groups; levels, samples, mc_samples=DEFAULT_MC_SAMPLES, seed=DEFAULT_DA_SEED)
        -> (table=DataFrame, diagnostics=Dict{String,Any})

Two-group ALDEx2 (Fernandes et al. 2013 *PLoS ONE* 8:e67019; Fernandes et al.
2014 *Microbiome* 2:15) on the `samples x taxa` count matrix `counts` over the
taxa passing `min_prevalence`. Draws `mc_samples` Dirichlet(count + 0.5)
instances per sample seeded by `seed` (saving and restoring R's `.Random.seed`),
transforms each draw to centred log-ratios, and computes consistent-sign
posterior predictive Welch's t-test p-values (`pvalue`), expected BH (`we_ebh`),
Wilcoxon expected p-values (`wi_pvalue`, `wi_ebh`), median between-group CLR
difference (`diff_btw`, contrast minus reference), median within-group CLR
dispersion (`diff_win`), and standardized ALDEx2 effect size (`estimate`).
"""
function fit_aldex2(counts::AbstractMatrix{<:Real},
                    groups::AbstractVector{<:AbstractString};
                    levels::NTuple{2,String},
                    samples::AbstractVector{<:AbstractString}=string.(axes(counts, 1)),
                    mc_samples::Integer=DEFAULT_MC_SAMPLES,
                    seed::Integer=DEFAULT_DA_SEED)
    size(counts, 1) == length(groups) == length(samples) || throw(ArgumentError(
        "counts ($(size(counts, 1)) rows), groups ($(length(groups))) and samples ($(length(samples))) must match"))
    size(counts, 2) >= 2 || throw(ArgumentError(
        "aldex2 requires at least 2 taxa to form centred log-ratios; there are $(size(counts, 2))"))
    (MIN_MC_SAMPLES <= mc_samples <= MAX_MC_SAMPLES) || throw(ArgumentError(
        "mc_samples must be in [$MIN_MC_SAMPLES, $MAX_MC_SAMPLES], not $mc_samples"))
    idx_ref = findall(==(levels[1]), groups)
    idx_con = findall(==(levels[2]), groups)
    (length(idx_ref) >= 2 && length(idx_con) >= 2) || throw(ArgumentError(
        "aldex2 needs at least 2 samples in each group to estimate within-group variance; " *
        "'$(levels[1])' has $(length(idx_ref)) and '$(levels[2])' has $(length(idx_con))"))
    for i in axes(counts, 1)
        sum(view(counts, i, :)) > 0 || throw(ArgumentError(
            "sample '$(samples[i])' has no reads in the $(size(counts, 2)) taxa that pass " *
            "min_prevalence, so its ALDEx2 Dirichlet posterior would be the uninformative prior alone"))
    end

    raw = with_r_lock(; timeout=R_WAIT_SECONDS[]) do
        RCall.rcopy(RCall.reval("requireNamespace('stats', quietly = TRUE)")) ||
            throw(RStatsUnavailable())
        RCall.globalEnv[:da_counts] = Matrix{Float64}(counts)
        RCall.globalEnv[:da_idx1] = Int.(idx_ref)
        RCall.globalEnv[:da_idx2] = Int.(idx_con)
        RCall.globalEnv[:da_mc] = Int(mc_samples)
        RCall.globalEnv[:da_seed] = Int(seed)
        try
            RCall.reval(_FIT_ALDEX2_R)
            DataFrame(RCall.rcopy(RCall.reval("da_out[['result']]")))
        finally
            RCall.reval("rm(list = intersect(ls(), c('da_counts', 'da_idx1', 'da_idx2', " *
                        "'da_mc', 'da_seed', 'da_out'))); invisible(gc())")
        end
    end

    diag = Dict{String,Any}(
        "mc_samples" => Int(mc_samples),
        "seed" => Int(seed),
        "dirichlet_prior" => 0.5,
        "test" => "welch_consistent_sign",
    )
    tbl = DataFrame(
        status    = String.(raw.status),
        note      = String.(raw.note),
        estimate  = _num.(raw.estimate),
        diff_btw  = _num.(raw.diff_btw),
        diff_win  = _num.(raw.diff_win),
        statistic = _num.(raw.statistic),
        pvalue    = _num.(raw.pvalue),
        we_ebh    = _num.(raw.we_ebh),
        wi_pvalue = _num.(raw.wi_pvalue),
        wi_ebh    = _num.(raw.wi_ebh),
    )
    (table=tbl, diagnostics=diag)
end

# Two-group Songbird-style compositional multinomial regression
# (Morton et al. 2019 Nat. Commun. 10:2719; Zhang et al. 2017 MGLM):
# Fits the baseline-category multinomial logit model on the identifiable
# subcomposition by damped Newton-Raphson with Armijo backtracking and exact
# O(K) Sherman-Morrison inversion of the block Fisher information, then maps
# log-ratio slopes to reference-frame invariant CLR-centred differentials
# `gamma_j = beta_j - mean(beta)` (summing to zero across fitted taxa) with
# exact O(K) delta-method standard errors and two-sided Wald z-tests.
const _FIT_SONGBIRD_R = raw"""
da_out <- local({
  K <- ncol(da_counts)
  ref_pos <- as.integer(da_ref_pos)
  free <- setdiff(seq_len(K), ref_pos)

  S1 <- colSums(da_counts[da_idx1, , drop = FALSE])
  S2 <- colSums(da_counts[da_idx2, , drop = FALSE])
  M1 <- sum(S1)
  M2 <- sum(S2)

  softmax_lse <- function(th_free) {
    eta <- numeric(K)
    eta[free] <- th_free
    mx <- max(eta)
    lse <- mx + log(sum(exp(eta - mx)))
    log_p <- eta - lse
    list(p = exp(log_p), log_p = log_p)
  }

  loglik_fn <- function(t1, t2) {
    sm1 <- softmax_lse(t1)
    sm2 <- softmax_lse(t2)
    sum(S1 * sm1[["log_p"]]) + sum(S2 * sm2[["log_p"]])
  }

  th1 <- numeric(K - 1L)
  th2 <- numeric(K - 1L)
  ll <- loglik_fn(th1, th2)
  converged <- FALSE
  iters_used <- 0L
  max_grad <- Inf
  ndec <- Inf

  for (it in seq_len(as.integer(da_max_iter))) {
    iters_used <- it
    p1 <- softmax_lse(th1)[["p"]]
    p2 <- softmax_lse(th2)[["p"]]
    if (min(p1) <= 0.0 || min(p2) <= 0.0 || !all(is.finite(p1)) || !all(is.finite(p2))) {
      return(list(converged = FALSE, reason = "multinomial Fisher information became singular during Newton updates"))
    }
    g1 <- S1[free] - M1 * p1[free]
    g2 <- S2[free] - M2 * p2[free]
    max_grad <- max(abs(c(g1, g2)))

    # Exact Sherman-Morrison inverse of M_g * (diag(p_free) - p_free %*% t(p_free)).
    step1 <- (g1 / p1[free] + (sum(g1) / p1[ref_pos])) / M1
    step2 <- (g2 / p2[free] + (sum(g2) / p2[ref_pos])) / M2
    slope <- sum(g1 * step1) + sum(g2 * step2)
    ndec <- 0.5 * slope
    if (!is.finite(ndec) || slope < -1e-12) {
      return(list(converged = FALSE, reason = "multinomial observed Fisher information was not positive definite"))
    }
    if (max_grad < da_tol && ndec < da_tol) {
      converged <- TRUE
      break
    }

    step_scale <- 1.0
    accepted <- FALSE
    for (ls_it in seq_len(40L)) {
      cand1 <- th1 + step_scale * step1
      cand2 <- th2 + step_scale * step2
      if (max(abs(c(cand1, cand2))) <= 40.0) {
        ll_cand <- loglik_fn(cand1, cand2)
        if (is.finite(ll_cand) && ll_cand >= ll + 1e-4 * step_scale * slope) {
          th1 <- cand1
          th2 <- cand2
          ll <- ll_cand
          accepted <- TRUE
          break
        }
      }
      step_scale <- 0.5 * step_scale
    }
    if (!accepted) {
      return(list(converged = FALSE, reason = "backtracking line search failed to improve multinomial log-likelihood"))
    }
    p1_chk <- softmax_lse(th1)[["p"]]
    p2_chk <- softmax_lse(th2)[["p"]]
    max_grad <- max(abs(c(S1[free] - M1 * p1_chk[free], S2[free] - M2 * p2_chk[free])))
    if (max_grad < da_tol && step_scale * ndec < da_tol) {
      converged <- TRUE
      break
    }
  }

  if (!converged) {
    return(list(
      converged = FALSE,
      reason = paste0("multinomial regression did not converge within ", da_max_iter, " Newton iterations")
    ))
  }

  p1 <- softmax_lse(th1)[["p"]]
  p2 <- softmax_lse(th2)[["p"]]
  beta_full <- numeric(K)
  beta_full[free] <- th2 - th1
  gamma <- beta_full - mean(beta_full)

  inv_p1_sum <- sum(1.0 / p1)
  inv_p2_sum <- sum(1.0 / p2)
  v1 <- ((1.0 - 2.0 / K) / p1 + inv_p1_sum / (as.numeric(K) * as.numeric(K))) / M1
  v2 <- ((1.0 - 2.0 / K) / p2 + inv_p2_sum / (as.numeric(K) * as.numeric(K))) / M2
  se <- sqrt(v1 + v2)
  z <- gamma / se
  pval <- 2.0 * stats::pnorm(abs(z), lower.tail = FALSE)

  res_df <- data.frame(
    estimate = gamma,
    se = se,
    statistic = z,
    pvalue = pval,
    stringsAsFactors = FALSE
  )
  list(
    converged = TRUE,
    reason = "",
    result = res_df,
    iterations = iters_used,
    loglik = ll,
    max_abs_gradient = max_grad,
    newton_decrement = ndec
  )
})
"""

"""
    fit_songbird(counts, groups; levels, samples, taxa, max_iter=100, tol=1e-10)
        -> (table=DataFrame, diagnostics=Dict{String,Any})

Two-group compositional multinomial regression with reference-frame invariant
CLR-centred differentials (Morton et al. 2019 *Nat. Commun.* 10:2719; Zhang et
al. 2017 `MGLM`). Taxa with zero reads across an entire group (complete
separation in unpenalized multinomial regression) are marked `status = "failed"`
with an explicit note and kept out of the subcomposition so they do not diverge
or shift the CLR mean of identifiable taxa. Requires at least 2 identifiable
taxa and at least one reference taxon with prevalence >= 0.5 across samples.
"""
function fit_songbird(counts::AbstractMatrix{<:Real},
                      groups::AbstractVector{<:AbstractString};
                      levels::NTuple{2,String},
                      samples::AbstractVector{<:AbstractString}=string.(axes(counts, 1)),
                      taxa::AbstractVector{<:AbstractString}=string.(axes(counts, 2)),
                      max_iter::Integer=100,
                      tol::Real=1e-10)
    n, d = size(counts)
    (n == length(groups) == length(samples) && d == length(taxa)) || throw(ArgumentError(
        "counts ($n x $d), groups ($(length(groups))), samples ($(length(samples))) and taxa ($(length(taxa))) must match"))
    d >= 2 || throw(ArgumentError(
        "songbird requires at least 2 taxa to form compositional differentials; there are $d"))
    idx_ref = findall(==(levels[1]), groups)
    idx_con = findall(==(levels[2]), groups)
    (length(idx_ref) >= 2 && length(idx_con) >= 2) || throw(ArgumentError(
        "songbird needs at least 2 samples in each group; " *
        "'$(levels[1])' has $(length(idx_ref)) and '$(levels[2])' has $(length(idx_con))"))
    for i in axes(counts, 1)
        sum(view(counts, i, :)) > 0 || throw(ArgumentError(
            "sample '$(samples[i])' has no reads in the $d taxa that pass min_prevalence, " *
            "so multinomial proportions are undefined"))
    end

    statuses = fill("ok", d)
    notes = fill("", d)
    estimates = Union{Float64,Nothing}[nothing for _ in 1:d]
    ses = Union{Float64,Nothing}[nothing for _ in 1:d]
    stats = Union{Float64,Nothing}[nothing for _ in 1:d]
    pvals = Union{Float64,Nothing}[nothing for _ in 1:d]

    ident = Int[]
    for j in 1:d
        pref = count(>(0), view(counts, idx_ref, j))
        pcon = count(>(0), view(counts, idx_con, j))
        if pref == 0 || pcon == 0
            absent_grp = pref == 0 ? levels[1] : levels[2]
            statuses[j] = "failed"
            notes[j] = "no reads in any '$absent_grp' sample (complete separation): " *
                       "the multinomial log-ratio is unbounded and the Wald test is undefined, " *
                       "so no p-value is reported"
        else
            push!(ident, j)
        end
    end

    if length(ident) < 2
        diag_empty = Dict{String,Any}(
            "reference_taxon" => nothing,
            "n_identifiable_taxa" => length(ident),
            "n_separated_taxa" => d - length(ident),
        )
        return (table=DataFrame(status=statuses, note=notes, estimate=estimates,
                                se=ses, statistic=stats, pvalue=pvals),
                diagnostics=diag_empty)
    end

    nonempty_ref = count(i -> sum(view(counts, i, ident)) > 0, idx_ref)
    nonempty_con = count(i -> sum(view(counts, i, ident)) > 0, idx_con)
    (nonempty_ref >= 2 && nonempty_con >= 2) || throw(ArgumentError(
        "fewer than 2 samples per group retain positive counts across the $(length(ident)) " *
        "identifiable (non-separated) taxa ('$(levels[1])' has $nonempty_ref, '$(levels[2])' has $nonempty_con)"))

    # Deterministic reference-frame taxon: highest prevalence across samples,
    # breaking ties by total read count and then first appearance.
    best_pos = 1
    best_key = (-1.0, -1.0, 0)
    for (pos, j) in enumerate(ident)
        prev_j = count(>(0), view(counts, :, j)) / n
        tot_j = Float64(sum(view(counts, :, j)))
        key = (prev_j, tot_j, -pos)
        if key > best_key
            best_key = key
            best_pos = pos
        end
    end
    best_prev = best_key[1]
    best_prev >= 0.5 || throw(ArgumentError(
        "songbird requires at least one identifiable reference taxon present in >= 50% of samples; " *
        "highest prevalence is $(round(best_prev; digits=3))"))

    fit_df, meta = with_r_lock(; timeout=R_WAIT_SECONDS[]) do
        RCall.rcopy(RCall.reval("requireNamespace('stats', quietly = TRUE)")) ||
            throw(RStatsUnavailable())
        RCall.globalEnv[:da_counts] = Matrix{Float64}(counts[:, ident])
        RCall.globalEnv[:da_idx1] = Int.(idx_ref)
        RCall.globalEnv[:da_idx2] = Int.(idx_con)
        RCall.globalEnv[:da_ref_pos] = Int(best_pos)
        RCall.globalEnv[:da_max_iter] = Int(max_iter)
        RCall.globalEnv[:da_tol] = Float64(tol)
        try
            RCall.reval(_FIT_SONGBIRD_R)
            conv = Bool(RCall.rcopy(RCall.reval("da_out[['converged']]")))
            reason = String(RCall.rcopy(RCall.reval("da_out[['reason']]")))
            conv || error(reason)
            df = DataFrame(RCall.rcopy(RCall.reval("da_out[['result']]")))
            m = Dict{String,Any}(
                "iterations" => Int(RCall.rcopy(RCall.reval("da_out[['iterations']]"))),
                "loglik" => Float64(RCall.rcopy(RCall.reval("da_out[['loglik']]"))),
                "max_abs_gradient" => Float64(RCall.rcopy(RCall.reval("da_out[['max_abs_gradient']]"))),
                "newton_decrement" => Float64(RCall.rcopy(RCall.reval("da_out[['newton_decrement']]"))),
            )
            (df, m)
        finally
            RCall.reval("rm(list = intersect(ls(), c('da_counts', 'da_idx1', 'da_idx2', " *
                        "'da_ref_pos', 'da_max_iter', 'da_tol', 'da_out'))); invisible(gc())")
        end
    end

    for (pos, j) in enumerate(ident)
        est_j = _num(fit_df.estimate[pos])
        se_j  = _num(fit_df.se[pos])
        st_j  = _num(fit_df.statistic[pos])
        pv_j  = _num(fit_df.pvalue[pos])
        if isnothing(est_j) || isnothing(se_j) || se_j <= 0 || isnothing(st_j) || isnothing(pv_j)
            statuses[j] = "failed"
            notes[j] = "multinomial regression produced a non-finite or zero standard error"
        else
            estimates[j] = est_j
            ses[j]       = se_j
            stats[j]     = st_j
            pvals[j]     = pv_j
        end
    end

    ref_taxon = String(taxa[ident[best_pos]])
    diag = Dict{String,Any}(
        "reference_taxon" => ref_taxon,
        "reference_prevalence" => best_prev,
        "n_identifiable_taxa" => length(ident),
        "n_separated_taxa" => d - length(ident),
        "iterations" => meta["iterations"],
        "loglik" => meta["loglik"],
        "max_abs_gradient" => meta["max_abs_gradient"],
        "newton_decrement" => meta["newton_decrement"],
        "caveat" => "Multinomial likelihood conditions on sample read totals without an extra-multinomial overdispersion parameter; inspect CLR differentials alongside ANCOM-BC or ALDEx2 when biological dispersion is high.",
    )
    tbl = DataFrame(status=statuses, note=notes, estimate=estimates,
                    se=ses, statistic=stats, pvalue=pvals)
    (table=tbl, diagnostics=diag)
end


"""
    differential_abundance(counts, samples, taxa, groups; reference, contrast,
                           config=DifferentialConfig(), seed=DEFAULT_DA_SEED) -> Dict{String,Any}

Test every taxon (column) of the samples x taxa read-count matrix for a
difference in abundance between the samples labelled `contrast` and those
labelled `reference` in `groups`, by `config.method` (`"nb_glm"`, `"clr_welch"`,
`"ancom_bc"`, `"aldex2"` or `"songbird"`).

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
by Welch's t-test. The estimate is the difference in mean CLR, contrast minus
reference, relative to the geometric mean of the tested taxa. Replaced zeros are
not measurements; `diagnostics.zero_replacement` reports their share of each
sample. Each group needs at least 2 samples.

`ancom_bc`: filters by `min_prevalence` (excluding unobserved taxa; requires at
least 3 tested taxa), estimates sample-specific and between-group
sampling-fraction shifts via Lin & Peddada (2020)'s E-M Gaussian mixture on
`log(counts + 1)`, and reports bias-corrected log2 fold changes with propagated
bias-estimation variance.

`aldex2`: filters by `min_prevalence` (excluding unobserved taxa; requires at
least 2 tested taxa), draws `config.mc_samples` Dirichlet(count + 0.5) CLR
instances seeded by `seed`, and reports Fernandes et al. (2014)'s standardized
CLR effect size alongside consistent-sign posterior predictive Welch p-values.

`songbird`: filters by `min_prevalence` (excluding unobserved taxa; requires at
least 2 identifiable taxa present in both groups and at least one reference
taxon with prevalence >= 0.5), fits the baseline-category multinomial logit
model (Morton et al. 2019; Zhang et al. 2017) by damped Newton-Raphson, and
reports reference-frame invariant CLR-centred differentials (`sum == 0`) with
exact delta-method standard errors and two-sided Wald z-tests.

For every method, taxa present in fewer than `config.min_prevalence` of the
samples are reported as `filtered` and not fitted, and the Benjamini-Hochberg
family is the fitted taxa that produced a p-value; failed and filtered taxa
carry `padj = nothing`. The result's `effect` names the row key that holds the
effect size and its label.

Throws `ArgumentError` for unusable input (including a zero replacement that
cannot be made), `ScalingRefusal` when the offset cannot be computed,
`MASSUnavailable`, `GlmGamPoiUnavailable`, `ZCompositionsUnavailable` or
`RStatsUnavailable` when a required R package is missing, `RBusyError` when the
R runtime stays busy, and an `ErrorException` when no taxon could be fitted at
all, including when the `glm_gp` fit fails. Uncaught R errors from the fitting
and zero-replacement helpers propagate.
"""
function differential_abundance(counts::AbstractMatrix{<:Real},
                                samples::AbstractVector{<:AbstractString},
                                taxa::AbstractVector{<:AbstractString},
                                groups::AbstractVector{<:AbstractString};
                                reference::AbstractString, contrast::AbstractString,
                                config::DifferentialConfig=DifferentialConfig(),
                                seed::Integer=DEFAULT_DA_SEED)
    !(seed isa Bool) || throw(ArgumentError("seed must be an integer, not Bool"))
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
    elseif config.method == "clr_welch"
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
    elseif config.method == "ancom_bc"
        (n_ref >= 2 && n_con >= 2) || throw(ArgumentError(
            "ANCOM-BC needs at least 2 samples in each group to estimate within-group variance; " *
            "'$reference' has $n_ref and '$contrast' has $n_con"))
        for j in findall(==(0), present)
            rows[j]["note"] = "no reads in any sample of either group, so it is not part of the composition"
        end
        tested = findall(j -> present[j] > 0 && prevalence[j] >= config.min_prevalence, axes(counts, 2))
        length(tested) >= 3 || throw(ArgumentError(
            "ancom_bc needs at least 3 taxa with reads at or above " *
            "analysis.differential.min_prevalence = $(config.min_prevalence) to separate " *
            "sampling-fraction bias from taxon effects; there are $(length(tested))"))
        bc = fit_ancom_bc(counts[:, tested], groups; levels, samples)
        for (k, j) in enumerate(tested)
            f = bc.table[k, :]
            merge!(rows[j], Dict{String,Any}(
                "status" => f.status, "note" => f.note, "estimate" => f.estimate,
                "log2_fold_change" => isnothing(f.estimate) ? nothing : f.estimate / log(2),
                "standard_error" => f.se, "statistic" => f.statistic,
                "pvalue" => f.pvalue))
        end
        method_text = "ANCOM-BC bias-corrected log-linear model (Lin & Peddada 2020) over the taxa " *
                      "passing min_prevalence: within-group sample offsets and between-group " *
                      "sampling-fraction bias estimated via an E-M Gaussian mixture on log(counts + 1), " *
                      "with bias variance propagated into two-sided Wald tests and Benjamini-Hochberg " *
                      "adjustment over the fitted taxa. Assumes fewer than half of the tested taxa " *
                      "are differentially abundant"
        effect = Dict("key" => "log2_fold_change", "label" => "Bias-corrected log2 FC")
        size_factor_rows = Dict{String,Any}[]
        config_echo = Dict{String,Any}("method" => config.method,
                                       "min_prevalence" => config.min_prevalence)
        diagnostics["ancom_bc"] = merge(bc.diagnostics, Dict{String,Any}(
            "n_taxa_in_composition" => length(tested),
            "n_taxa_unobserved" => count(==(0), present)))
    elseif config.method == "aldex2"
        (n_ref >= 2 && n_con >= 2) || throw(ArgumentError(
            "ALDEx2 needs at least 2 samples in each group to estimate within-group variance; " *
            "'$reference' has $n_ref and '$contrast' has $n_con"))
        for j in findall(==(0), present)
            rows[j]["note"] = "no reads in any sample of either group, so it is not part of the composition"
        end
        tested = findall(j -> present[j] > 0 && prevalence[j] >= config.min_prevalence, axes(counts, 2))
        length(tested) >= 2 || throw(ArgumentError(
            "ALDEx2 needs at least 2 taxa with reads at or above " *
            "analysis.differential.min_prevalence = $(config.min_prevalence); there are $(length(tested))"))
        ax = fit_aldex2(counts[:, tested], groups; levels, samples,
                        mc_samples=config.mc_samples, seed=Int(seed))
        for (k, j) in enumerate(tested)
            f = ax.table[k, :]
            merge!(rows[j], Dict{String,Any}(
                "status" => f.status, "note" => f.note, "estimate" => f.estimate,
                "standard_error" => nothing, "statistic" => f.statistic,
                "pvalue" => f.pvalue))
        end
        method_text = "ALDEx2 Dirichlet(count + 0.5) Monte-Carlo CLR model (Fernandes et al. 2014; " *
                      "$(config.mc_samples) instances, seed = $(Int(seed))) over the taxa passing " *
                      "min_prevalence: consistent-sign posterior predictive Welch's t-test p-values " *
                      "with Benjamini-Hochberg adjustment over the fitted taxa. Estimates are " *
                      "standardized CLR effect sizes (between-group difference over max within-group " *
                      "dispersion), not absolute fold changes"
        effect = Dict("key" => "estimate", "label" => "ALDEx2 effect size")
        size_factor_rows = Dict{String,Any}[]
        config_echo = Dict{String,Any}("method" => config.method,
                                       "min_prevalence" => config.min_prevalence,
                                       "mc_samples" => config.mc_samples,
                                       "seed" => Int(seed))
        diagnostics["aldex2"] = merge(ax.diagnostics, Dict{String,Any}(
            "n_taxa_in_composition" => length(tested),
            "n_taxa_unobserved" => count(==(0), present)))
    elseif config.method == "songbird"
        (n_ref >= 2 && n_con >= 2) || throw(ArgumentError(
            "songbird needs at least 2 samples in each group; " *
            "'$reference' has $n_ref and '$contrast' has $n_con"))
        for j in findall(==(0), present)
            rows[j]["note"] = "no reads in any sample of either group, so it is not part of the composition"
        end
        tested = findall(j -> present[j] > 0 && prevalence[j] >= config.min_prevalence, axes(counts, 2))
        length(tested) >= 2 || throw(ArgumentError(
            "songbird needs at least 2 taxa with reads at or above " *
            "analysis.differential.min_prevalence = $(config.min_prevalence); there are $(length(tested))"))
        sb = fit_songbird(counts[:, tested], groups; levels, samples, taxa=taxa[tested])
        for (k, j) in enumerate(tested)
            f = sb.table[k, :]
            merge!(rows[j], Dict{String,Any}(
                "status" => f.status, "note" => f.note, "estimate" => f.estimate,
                "standard_error" => f.se, "statistic" => f.statistic,
                "pvalue" => f.pvalue))
        end
        ref_tax = something(sb.diagnostics["reference_taxon"], "none")
        method_text = "Songbird-style compositional multinomial regression (Morton et al. 2019; " *
                      "Zhang et al. 2017; reference taxon '$ref_tax') over the identifiable taxa " *
                      "passing min_prevalence: CLR-centred differentials (summing to zero across " *
                      "fitted taxa) with delta-method standard errors, two-sided Wald z-tests, and " *
                      "Benjamini-Hochberg adjustment. Differentials are relative log-ratios, not " *
                      "absolute fold changes, and multinomial likelihood conditions on read totals " *
                      "without extra-multinomial overdispersion"
        effect = Dict("key" => "estimate", "label" => "Differential (CLR log-ratio)")
        size_factor_rows = Dict{String,Any}[]
        config_echo = Dict{String,Any}("method" => config.method,
                                       "min_prevalence" => config.min_prevalence)
        diagnostics["songbird"] = merge(sb.diagnostics, Dict{String,Any}(
            "n_taxa_in_composition" => length(tested),
            "n_taxa_unobserved" => count(==(0), present)))
    else
        throw(ArgumentError("unsupported differential method '$(config.method)'"))
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
