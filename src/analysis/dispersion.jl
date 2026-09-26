# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""
    Dispersion — quasi-likelihood dispersion estimation for the negative binomial GLM (issue #21)

A port of the dispersion pipeline of **glmGamPoi** — Ahlmann-Eltze & Huber (2020),
*glmGamPoi: fitting negative binomial generalized linear models with quasi-likelihood*, and
its implementation at `github.com/const-ae/glmGamPoi` — into pure Julia, so that the
dispersion method the v1 catalogue named and aliased is computed here rather than borrowed.

What is ported, function for function, from the reference:

| This module | Reference |
| --- | --- |
| `_nb_log_likelihood` | `conventional_loglikelihood_fast` (`src/overdispersion.cpp`) |
| `_nb_score` | `conventional_score_function_fast` |
| `_nb_score_deriv` | `conventional_deriv_score_function_fast` |
| `overdispersion_mle` | `conventional_overdispersion_mle` (`R/overdispersion.R`) |
| `loc_median_fit` | `loc_median_fit` (`R/loc_median_fit.R`) |
| `variance_prior` | `variance_prior` (`R/quasi_gamma_poisson_shrinkage.R`) |
| `overdispersion_shrinkage` | `overdispersion_shrinkage` |

Constants are the reference's: the Cox-Reid correction factor 0.99, the search interval
`log(1e-16)..log(1e16)`, the `max_iter = 200`, the `1e-6` jitter added to `X'WX` before it is
inverted, the `dnorm(seq(-3,3))` neighbour weights of the trend, and the inverse-chisquare
prior fitted by Nelder-Mead from `c(0, 0)` at `reltol = sqrt(eps)`.

**What is not ported, and is refused by name rather than replaced by a lookalike:** the
natural-spline *abundance trend* of the variance prior (`variance_prior(..., abundance_trend
= TRUE)`), which the reference fits when a table has 100 or more features. A run that would
have used it is refused unless the caller explicitly asks for the reference's own
non-trended form (`abundance_trend = false`), in which case the run records that choice in
provenance. Silently substituting the non-trended prior would change every standard error
under a label that says `glmGamPoi`.

**What this module does not claim.** It estimates dispersions from a mean matrix that the
caller supplies. The reference's `glm_gp()` alternates between estimating coefficients at
fixed dispersion and dispersions at fixed coefficients until convergence; this module is the
dispersion half of that loop, and the documented integration in `src/analysis/estimation.jl`
takes one refinement step (dispersion from the fitted mean, then a refit at fixed
dispersion). Where the numbers are compared against R's `glmGamPoi::overdispersion_mle()` and
`glmGamPoi::overdispersion_shrinkage()` on identical inputs — `test/unit/test_dispersion.jl`
— the agreement is asserted at 1e-6; where the whole fit is compared, the difference is
stated rather than tuned away.

The special functions (`_loggamma`, `_digamma`, `_trigamma`) and the small linear algebra
(`_log_abs_det`, `_sym_inverse`) are implemented here rather than taken from a package: the
project's `Project.toml`/`Manifest.toml` pin is an external contract, and adding a dependency
to fit a formula is not a reason to change it.
"""
module Dispersion

using Logging
using OrderedCollections

export DispersionOutcome, estimate_dispersions, overdispersion_mle, overdispersion_shrinkage,
       loc_median_fit, variance_prior, REFERENCE_GLMGAMPOI, SPLINE_TREND_MIN_FEATURES

"Citation string recorded in provenance by every entry point in this module."
const REFERENCE_GLMGAMPOI = "Ahlmann-Eltze & Huber (2020), glmGamPoi: fitting negative binomial generalized linear models with quasi-likelihood; ported from const-ae/glmGamPoi (R/overdispersion.R, R/quasi_gamma_poisson_shrinkage.R, src/overdispersion.cpp)"

"""
The number of features at which the reference switches the variance prior to the spline
abundance trend (`ql_disp_trend = length(disp_est) >= 100` in `R/glm_gp_impl.R`). At or above
it, a `glmGamPoi` run is refused unless the caller has explicitly asked for the non-trended
prior, because the trend is not ported.
"""
const SPLINE_TREND_MIN_FEATURES = 100

"Reference's Cox-Reid correction factor; keeps `lgamma(1/theta)` and `log|X'WX|` from cancelling into theta = Inf."
const CR_CORRECTION_FACTOR = 0.99

"Tolerance for the invariants and refusals of this module."
const TOLERANCE = 1e-9

# ---------------------------------------------------------------------------
# Special functions (no dependencies: Project.toml's pin is an external contract)
# ---------------------------------------------------------------------------

const _LANCZOS_G = 7.0
const _LANCZOS_COEFS = (
    0.99999999999980993, 676.5203681218851, -1259.1392167224028,
    771.32342877765313, -176.61502916214059, 12.507343278686905,
    -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7,
)

"""
    _loggamma(x) — log Γ(x) for x > 0

Lanczos approximation, g = 7, n = 9 (the standard coefficients), reflection not needed for
this module's arguments (`n + 1/theta` with `n ≥ 0`, `theta > 0`), but implemented for
completeness so the function is total on the positive reals.
"""
function _loggamma(x::Float64)
    if x < 0.5
        # Reflection: Γ(x)Γ(1-x) = π/sin(πx)
        return log(π / sin(π * x)) - _loggamma(1.0 - x)
    end
    z = x - 1.0
    acc = _LANCZOS_COEFS[1]
    for i in 2:length(_LANCZOS_COEFS)
        acc += _LANCZOS_COEFS[i] / (z + Float64(i - 1))
    end
    t = z + _LANCZOS_G + 0.5
    return 0.5 * log(2π) + (z + 0.5) * log(t) - t + log(acc)
end

"""
    _digamma(x) — ψ(x) = d/dx log Γ(x), for x > 0

Recurrence ψ(x) = ψ(x+1) - 1/x pushes the argument to 12, where the asymptotic series
`log x - 1/(2x) - Σ B_{2k}/(2k x^{2k})` is accurate to double precision. R's `Rf_digamma` is
the reference the port is compared against; the two agree to ~1e-15 relative.
"""
function _digamma(x::Float64)
    x <= 0.0 && throw(DomainError(x, "_digamma is only defined for positive arguments here"))
    result = 0.0
    while x < 12.0
        result -= 1.0 / x
        x += 1.0
    end
    inv_x = 1.0 / x
    inv_x2 = inv_x * inv_x
    series = log(x) - 0.5 * inv_x
    series -= inv_x2 * (1.0 / 12.0
                        - inv_x2 * (1.0 / 120.0
                                    - inv_x2 * (1.0 / 252.0
                                                - inv_x2 * (1.0 / 240.0
                                                            - inv_x2 * (1.0 / 132.0
                                                                        - inv_x2 * (691.0 / 32760.0
                                                                                    - inv_x2 * (1.0 / 12.0)))))))
    return result + series
end

"""
    _trigamma(x) — ψ₁(x) = d/dx ψ(x), for x > 0

Recurrence ψ₁(x) = ψ₁(x+1) + 1/x² to 12, then `1/x + 1/(2x²) + 1/(6x³) - 1/(30x⁵) +
1/(42x⁷) - 1/(30x⁹) + 5/(66x¹¹)`. Matches R's `Rf_trigamma` to ~1e-15 relative.
"""
function _trigamma(x::Float64)
    x <= 0.0 && throw(DomainError(x, "_trigamma is only defined for positive arguments here"))
    result = 0.0
    while x < 12.0
        result += 1.0 / (x * x)
        x += 1.0
    end
    inv_x = 1.0 / x
    inv_x2 = inv_x * inv_x
    series = inv_x * (1.0 + inv_x * (0.5 + inv_x * (1.0 / 6.0
                                                     - inv_x2 * (1.0 / 30.0
                                                                 - inv_x2 * (1.0 / 42.0
                                                                             - inv_x2 * (1.0 / 30.0
                                                                                         - inv_x2 * (5.0 / 66.0
                                                                                                     - inv_x2 * (691.0 / 2730.0))))))))
    return result + series
end

# ---------------------------------------------------------------------------
# Small dense linear algebra (p is the number of coefficients: single digits)
# ---------------------------------------------------------------------------

function _eye(n::Int)
    E = zeros(Float64, n, n)
    for i in 1:n
        E[i, i] = 1.0
    end
    return E
end

"""
    _log_abs_det(A) — log|det A| by Gaussian elimination with partial pivoting

With the reference's floor of `1e-50` per pivot, which is what `conventional_loglikelihood_fast`
applies to the diagonal of the LU factor inside its `log(det(b))`.
"""
function _log_abs_det(A::Matrix{Float64})
    n = size(A, 1)
    M = copy(A)
    total = 0.0
    for k in 1:n
        pivot = k
        best = abs(M[k, k])
        for r in (k + 1):n
            candidate = abs(M[r, k])
            if candidate > best
                best = candidate
                pivot = r
            end
        end
        if pivot != k
            for c in 1:n
                M[k, c], M[pivot, c] = M[pivot, c], M[k, c]
            end
        end
        d = abs(M[k, k])
        total += log(d < 1e-50 ? 1e-50 : d)
        for r in (k + 1):n
            f = M[r, k] / M[k, k]
            for c in k:n
                M[r, c] -= f * M[k, c]
            end
        end
    end
    return total
end

"""
    _sym_inverse(A) — inverse of a small symmetric matrix, jittered as the reference jitters it

`inv_sympd(b + eye * 1e-6)`: the jitter is what protects the score and its derivative from a
singular `X'WX` at extreme theta, and it is part of the port rather than an implementation
detail, because it is what the reference's numbers contain.
"""
function _sym_inverse(A::Matrix{Float64})
    n = size(A, 1)
    M = copy(A) + 1e-6 .* _eye(n)
    inv = _eye(n)
    for k in 1:n
        pivot = k
        best = abs(M[k, k])
        for r in (k + 1):n
            candidate = abs(M[r, k])
            if candidate > best
                best = candidate
                pivot = r
            end
        end
        if pivot != k
            for c in 1:n
                M[k, c], M[pivot, c] = M[pivot, c], M[k, c]
                inv[k, c], inv[pivot, c] = inv[pivot, c], inv[k, c]
            end
        end
        d = M[k, k]
        if abs(d) < 1e-300
            # A rank-deficient design at this theta: return what we have rather than Inf.
            return inv
        end
        for c in 1:n
            M[k, c] /= d
            inv[k, c] /= d
        end
        for r in 1:n
            if r != k && M[r, k] != 0.0
                f = M[r, k]
                for c in 1:n
                    M[r, c] -= f * M[k, c]
                    inv[r, c] -= f * inv[k, c]
                end
            end
        end
    end
    return inv
end

function _trace(M::Matrix{Float64})
    n = min(size(M, 1), size(M, 2))
    total = 0.0
    for i in 1:n
        total += M[i, i]
    end
    return total
end

"""
    _weighted_median(values, weights)

The weighted median as the reference's `matrixStats::weightedMedian(x, w, interpolate =
FALSE)` defines it: the value whose cumulative weight first reaches half of the total weight,
scanning the values in the order given (the caller sorts them).
"""
function _weighted_median(values::Vector{Float64}, weights::Vector{Float64})
    n = length(values)
    n == 0 && throw(ArgumentError("_weighted_median: no values"))
    length(weights) == n ||
        throw(ArgumentError("_weighted_median: $(length(weights)) weights for $n values"))
    total = sum(weights)
    half = 0.5 * total
    cumulative = 0.0
    for i in 1:n
        cumulative += weights[i]
        if cumulative >= half
            return values[i]
        end
    end
    return values[n]
end

# ---------------------------------------------------------------------------
# The negative binomial likelihood, score and second derivative
# ---------------------------------------------------------------------------

"""
    _nb_log_likelihood(y, mu, log_theta, design, do_cox_reid) -> Float64

Port of `conventional_loglikelihood_fast`: the negative binomial log likelihood of the counts
`y` given means `mu` and overdispersion `theta = exp(log_theta)`, plus the Cox-Reid
adjustment `-0.5·log|X'WX|·0.99` that removes the first-order bias of the maximum likelihood
estimator of the dispersion (McCarthy et al. 2012).
"""
function _nb_log_likelihood(y::Vector{Float64}, mu::Vector{Float64}, log_theta::Float64,
                            design::Matrix{Float64}, do_cox_reid::Bool)::Float64
    theta = exp(log_theta)
    cr_term = 0.0
    if do_cox_reid
        n_samples, p = size(design)
        b = zeros(Float64, p, p)
        for i in 1:n_samples
            w = 1.0 / (1.0 / mu[i] + theta)
            for r in 1:p
                wr = design[i, r] * w
                for c in 1:p
                    b[r, c] += wr * design[i, c]
                end
            end
        end
        cr_term = -0.5 * _log_abs_det(b) * CR_CORRECTION_FACTOR
    end

    theta_neg1 = 1.0 / theta
    n = length(y)
    lgamma_term = 0.0
    for i in 1:n
        lgamma_term += _loggamma(y[i] + theta_neg1)
    end
    lgamma_term -= n * _loggamma(theta_neg1)

    ll_part = 0.0
    for i in 1:n
        ll_part += (-y[i] - theta_neg1) * log(mu[i] + theta_neg1)
    end
    ll_part -= n * theta_neg1 * log(theta)

    return lgamma_term + ll_part + cr_term
end

"""
    _nb_score(y, mu, log_theta, design, do_cox_reid) -> Float64

Port of `conventional_score_function_fast`: the derivative of the log likelihood with respect
to `log(theta)`. The digamma section reproduces the reference's large-theta handling, where
`lgamma(1/theta)` and `log|X'WX|` would otherwise cancel to give an infinite estimate: the
Laurent-series correction and the `min(..., sum(y) - corr)` cap are the reference's, not
refinements of ours.
"""
function _nb_score(y::Vector{Float64}, mu::Vector{Float64}, log_theta::Float64,
                   design::Matrix{Float64}, do_cox_reid::Bool)::Float64
    theta = exp(log_theta)
    theta_neg1 = 1.0 / theta
    n = length(y)

    cr_term = 0.0
    if do_cox_reid
        n_samples, p = size(design)
        b = zeros(Float64, p, p)
        db = zeros(Float64, p, p)
        for i in 1:n_samples
            w = 1.0 / (1.0 / mu[i] + theta)
            dw = -w * w
            for r in 1:p
                wr = design[i, r] * w
                dwr = design[i, r] * dw
                for c in 1:p
                    b[r, c] += wr * design[i, c]
                    db[r, c] += dwr * design[i, c]
                end
            end
        end
        b_inv = _sym_inverse(b)
        prod = zeros(Float64, p, p)
        for r in 1:p, c in 1:p
            acc = 0.0
            for k in 1:p
                acc += b_inv[r, k] * db[k, c]
            end
            prod[r, c] = acc
        end
        cr_term = -0.5 * _trace(prod) * CR_CORRECTION_FACTOR
    end

    sum_y = sum(y)
    sum_prod_y = 0.0
    max_y = 0.0
    digamma_raw = 0.0
    for i in 1:n
        digamma_raw += _digamma(y[i] + theta_neg1)
        sum_prod_y += (y[i] - 1.0) * y[i]
        max_y = max(max_y, y[i])
    end
    corr = theta_neg1 > 1e5 ? sum_prod_y / (2.0 * theta_neg1) : 0.0
    digamma_term = if max_y * 1e6 < theta_neg1
        sum_y - corr
    else
        min((digamma_raw - n * _digamma(theta_neg1)) * theta_neg1, sum_y - corr)
    end

    ll_part = 0.0
    for i in 1:n
        mu_theta = mu[i] * theta
        if mu_theta < 1e-10
            ll_part += mu_theta * mu_theta * (1.0 / (1.0 + mu_theta) - 0.5)
        elseif mu_theta < 1e-4
            inv = 1.0 / (1.0 + mu_theta)
            upper = mu_theta * mu_theta * inv
            lower = mu_theta * mu_theta * (inv - 0.5)
            suggest = log(1.0 + mu_theta) - mu[i] / (mu[i] + theta_neg1)
            ll_part += max(min(suggest, upper), lower)
        else
            ll_part += log(1.0 + mu_theta) - mu[i] / (mu[i] + theta_neg1)
        end
        ll_part += y[i] / (mu[i] + theta_neg1)
    end
    ll_part *= theta_neg1

    return ll_part - digamma_term + cr_term * theta
end

"""
    _nb_score_deriv(y, mu, log_theta, design, do_cox_reid) -> Float64

Port of `conventional_deriv_score_function_fast`: the second derivative of the log likelihood
with respect to `log(theta)`, used by the Newton step in `overdispersion_mle`.
"""
function _nb_score_deriv(y::Vector{Float64}, mu::Vector{Float64}, log_theta::Float64,
                         design::Matrix{Float64}, do_cox_reid::Bool)::Float64
    theta = exp(log_theta)
    theta_neg1 = 1.0 / theta
    theta_neg2 = 1.0 / (theta * theta)
    n = length(y)

    cr_term = 0.0
    cr_term2 = 0.0
    if do_cox_reid
        n_samples, p = size(design)
        b = zeros(Float64, p, p)
        db = zeros(Float64, p, p)
        d2b = zeros(Float64, p, p)
        for i in 1:n_samples
            w = 1.0 / (1.0 / mu[i] + theta)
            dw = -w * w
            d2w = -2.0 * dw * w
            for r in 1:p
                wr = design[i, r] * w
                dwr = design[i, r] * dw
                d2wr = design[i, r] * d2w
                for c in 1:p
                    b[r, c] += wr * design[i, c]
                    db[r, c] += dwr * design[i, c]
                    d2b[r, c] += d2wr * design[i, c]
                end
            end
        end
        b_inv = _sym_inverse(b)
        d_i_db = zeros(Float64, p, p)
        for r in 1:p, c in 1:p
            acc = 0.0
            for k in 1:p
                acc += b_inv[r, k] * db[k, c]
            end
            d_i_db[r, c] = acc
        end
        sq = zeros(Float64, p, p)
        for r in 1:p, c in 1:p
            acc = 0.0
            for k in 1:p
                acc += d_i_db[r, k] * d_i_db[k, c]
            end
            sq[r, c] = acc
        end
        binv_d2b = zeros(Float64, p, p)
        for r in 1:p, c in 1:p
            acc = 0.0
            for k in 1:p
                acc += b_inv[r, k] * d2b[k, c]
            end
            binv_d2b[r, c] = acc
        end
        ddetb = _trace(d_i_db)
        d2detb = (ddetb * ddetb) - _trace(sq) + _trace(binv_d2b)
        cr_term = (0.5 * ddetb * ddetb - 0.5 * d2detb) * CR_CORRECTION_FACTOR
        cr_term2 = -0.5 * ddetb * CR_CORRECTION_FACTOR
    end

    digamma_term = 0.0
    trigamma_term = 0.0
    for i in 1:n
        digamma_term += _digamma(y[i] + theta_neg1)
        trigamma_term += _trigamma(y[i] + theta_neg1)
    end
    trigamma_term *= theta_neg2
    digamma_term -= n * _digamma(theta_neg1)
    trigamma_term -= theta_neg2 * n * _trigamma(theta_neg1)

    ll_part_1 = 0.0
    ll_part_2 = 0.0
    for i in 1:n
        ll_part_1 += log(1.0 + mu[i] * theta) + (y[i] - mu[i]) / (mu[i] + theta_neg1)
        ll_part_2 += (mu[i] * mu[i] * theta + y[i]) / (1.0 + mu[i] * theta) / (1.0 + mu[i] * theta)
    end
    ll_part = -2.0 * theta_neg1 * (ll_part_1 - digamma_term) + (ll_part_2 + trigamma_term)

    return ll_part + cr_term * theta * theta + (ll_part_1 - digamma_term) * theta_neg1 +
           cr_term2 * theta
end

# ---------------------------------------------------------------------------
# Per-feature maximum likelihood
# ---------------------------------------------------------------------------

"""
    overdispersion_mle(y, mu; design, do_cox_reid_adjustment, max_iter)
        -> (; estimate, iterations, message, log_likelihood)

Maximum likelihood estimate of the overdispersion `alpha` of a negative binomial model with
variance `mu + alpha·mu²`, from one feature's counts.

The reference's structure is kept step for step (`conventional_overdispersion_mle`):

- all counts zero → `alpha = 0`, "All counts y are 0."
- means of zero are replaced by `1e-6`, as the reference does before optimising;
- if the score at `theta = 1e-8` is already negative, no maximum exists above the interval,
  and the estimate is 0 with the reference's message *"Even for very small theta, no maximum
  identified"*;
- start from the method-of-moments value `(var(y) - mean(y))/mean(y)²`, or 0.5 when that is
  not positive, and search `log(theta) ∈ [log(1e-16), log(1e16)]`;
- `max_iter` is 200 by default, the reference's `nlminb` budget.

The search is a safeguarded Newton iteration on `log(theta)` using the analytic score and its
derivative, falling back to bisection whenever a Newton step would leave the bracket or the
curvature is not negative — the reference hands the same three functions to `nlminb`, so the
stationary point is the same and only the path to it differs.
"""
function overdispersion_mle(y::AbstractVector{<:Real}, mu::AbstractVector{<:Real};
                            design::Union{AbstractMatrix{<:Real},Nothing} = nothing,
                            do_cox_reid_adjustment::Bool = true,
                            max_iter::Integer = 200)
    n = length(y)
    length(mu) == n ||
        throw(ArgumentError("overdispersion_mle: $(length(mu)) means for $n counts. Refusing."))
    n > 0 || throw(ArgumentError("overdispersion_mle: no counts. Refusing."))
    yy = Float64[Float64(v) for v in y]
    mm = Float64[Float64(v) for v in mu]
    for v in yy
        isfinite(v) && v >= 0 ||
            throw(ArgumentError("overdispersion_mle: the counts contain $v; counts are finite and non-negative. Refusing."))
    end
    for v in mm
        isfinite(v) && v >= 0 ||
            throw(ArgumentError("overdispersion_mle: the means contain $v; means are finite and non-negative. Refusing."))
    end

    X = isnothing(design) ? reshape(ones(Float64, n), n, 1) : Matrix{Float64}(design)
    size(X, 1) == n ||
        throw(ArgumentError("overdispersion_mle: the design has $(size(X, 1)) rows for $n samples. Refusing."))

    if all(==(0.0), yy)
        return (; estimate = 0.0, iterations = 0, message = "All counts y are 0.",
                log_likelihood = 0.0)
    end

    for i in 1:n
        if mm[i] == 0.0
            mm[i] = 1e-6
        end
    end

    lo = log(1e-16)
    hi = log(1e16)

    score_lo = _nb_score(yy, mm, lo, X, do_cox_reid_adjustment)
    if score_lo < 0.0
        return (; estimate = 0.0, iterations = 0,
                message = "Even for very small theta, no maximum identified",
                log_likelihood = _nb_log_likelihood(yy, mm, lo, X, do_cox_reid_adjustment))
    end
    score_hi = _nb_score(yy, mm, hi, X, do_cox_reid_adjustment)
    if score_hi > 0.0
        return (; estimate = exp(hi), iterations = 0,
                message = "the score is still positive at the upper bound log(theta) = log(1e16); theta is reported at that bound rather than extrapolated",
                log_likelihood = _nb_log_likelihood(yy, mm, hi, X, do_cox_reid_adjustment))
    end

    ybar = sum(yy) / n
    if n > 1
        v = sum((yy .- ybar) .^ 2) / (n - 1)
    else
        v = 0.0
    end
    start_value = (v - ybar) / (ybar * ybar)
    if !isfinite(start_value) || start_value <= 0.0
        start_value = 0.5
    end
    log_theta = min(max(log(start_value), lo), hi)

    iterations = 0
    message = ""
    step_prev = Inf
    while iterations < max_iter
        iterations += 1
        score = _nb_score(yy, mm, log_theta, X, do_cox_reid_adjustment)
        deriv = _nb_score_deriv(yy, mm, log_theta, X, do_cox_reid_adjustment)
        if score > 0.0
            lo = log_theta
        else
            hi = log_theta
        end
        step = deriv < 0.0 ? -score / deriv : (hi - lo) / 2.0
        next_log_theta = log_theta + step
        if !isfinite(next_log_theta) || next_log_theta <= lo || next_log_theta >= hi
            next_log_theta = 0.5 * (lo + hi)
        end
        converged = abs(next_log_theta - log_theta) <= 1e-12 * max(1.0, abs(log_theta))
        log_theta = next_log_theta
        step_prev = step
        if converged
            break
        end
    end
    if iterations >= max_iter
        message = "the Newton iteration reached max_iter = $max_iter without meeting the step tolerance; the estimate is reported where the iteration stopped"
    end

    return (; estimate = exp(log_theta), iterations = iterations, message = message,
            log_likelihood = _nb_log_likelihood(yy, mm, log_theta, X, do_cox_reid_adjustment))
end

# ---------------------------------------------------------------------------
# The dispersion trend and the variance prior
# ---------------------------------------------------------------------------

"""
    loc_median_fit(x, y; fraction = 0.1, npoints, weighted = true) -> Vector{Float64}

Port of the reference's `loc_median_fit`: a running weighted median of `y` along the order of
`x`, over a window of `npoints` (at least one), with weights `dnorm(seq(-3, 3))` across the
window, and both tails filled from the nearest fitted value.

`glm_gp_impl.R` calls it with `npoints = max(0.1·n_features, 100)`, which for fewer than 1000
features collapses the window onto the whole vector: the trend is then one weighted median
per table, not a curve. That is the reference's behaviour and it is reproduced here — including
its two branches, which use different weight vectors for the whole-vector case and the
windowed case.
"""
function loc_median_fit(x::AbstractVector{<:Real}, y::AbstractVector{<:Real};
                        fraction::Real = 0.1,
                        npoints::Union{Integer,Nothing} = nothing,
                        weighted::Bool = true)::Vector{Float64}
    n = length(x)
    length(y) == n ||
        throw(ArgumentError("loc_median_fit: $(length(y)) y values for $n x values. Refusing."))
    n == 0 && return Float64[]

    npts = isnothing(npoints) ? max(1, round(Int, n * Float64(fraction))) : Int(npoints)
    npts = max(1, npts)
    npts = min(n, npts)

    order_idx = sortperm(Float64[Float64(v) for v in x])
    ordered_y = Float64[Float64(y[i]) for i in order_idx]

    half = div(npts, 2)
    start = half + 1
    stop = n - half

    res = fill(NaN, n)

    if stop < start
        if weighted
            w = _dnorm_weights(n)
            res .= _weighted_median(ordered_y, w)
        else
            res .= _median(ordered_y)
        end
    else
        window_weights = _dnorm_weights(2 * half + 1)
        idx = start
        while idx <= stop
            selection = ordered_y[(idx - half):(idx + half)]
            if weighted
                res[idx] = _weighted_median(selection, window_weights)
            else
                res[idx] = _median(selection)
            end
            idx += 1
        end
    end

    # Fill the tails from the nearest fitted value, as the reference does.
    if stop < start
        # res is already filled everywhere
    else
        for k in 1:(start - 1)
            res[k] = res[start]
        end
        last_fitted = res[stop]
        for k in (stop + 1):n
            res[k] = last_fitted
        end
    end

    out = zeros(Float64, n)
    for (position, original_index) in enumerate(order_idx)
        out[original_index] = res[position]
    end
    return out
end

function _dnorm_weights(n::Int)::Vector{Float64}
    n == 1 && return [1.0]
    return Float64[exp(-0.5 * t * t) for t in range(-3.0, 3.0, length = n)]
end

function _median(values::Vector{Float64})::Float64
    n = length(values)
    n > 0 || throw(ArgumentError("_median: no values"))
    sorted = sort(values)
    if isodd(n)
        return sorted[(n + 1) ÷ 2]
    end
    return 0.5 * (sorted[n ÷ 2] + sorted[n ÷ 2 + 1])
end

"""
    _log_f_density(x, df1, df2) — log density of Snedecor's F at x

The scaled-F likelihood of Smyth (2004), which the reference maximises to fit the
inverse-chisquare prior of the variance shrinkage (`variance_prior`).
"""
function _log_f_density(x::Float64, df1::Float64, df2::Float64)::Float64
    log_beta = _loggamma(0.5 * df1) + _loggamma(0.5 * df2) - _loggamma(0.5 * (df1 + df2))
    return -log_beta + 0.5 * df1 * log(df1 / df2) + (0.5 * df1 - 1.0) * log(x) -
           0.5 * (df1 + df2) * log(1.0 + (df1 / df2) * x)
end

"""
    _nelder_mead(f, x0; reltol, maxit) -> (x, fvalue, iterations, converged)

Nelder-Mead with the defaults of R's `optim`: initial simplex `x0 ± 5%` (or `± 0.00025` at
zero), reflection/expansion/contraction/shrink coefficients 1/2/0.5/0.5, and the convergence
test `|f_worst - f_best| ≤ reltol·(|f_best| + reltol)`. Small, dependency-free and only ever
asked to minimise the two-parameter prior likelihood; the port must reproduce the reference's
optimum, and Nelder-Mead on a smooth two-parameter problem does.
"""
function _nelder_mead(f::Function, x0::Vector{Float64};
                      reltol::Float64 = sqrt(eps(Float64)),
                      maxit::Integer = 500)
    n = length(x0)
    simplex = Vector{Vector{Float64}}(undef, n + 1)
    simplex[1] = copy(x0)
    for i in 1:n
        p = copy(x0)
        p[i] = p[i] == 0.0 ? 0.00025 : p[i] + 0.05 * abs(p[i])
        simplex[i + 1] = p
    end
    fvals = Float64[f(p) for p in simplex]

    iterations = 0
    converged = false
    while iterations < maxit
        iterations += 1
        perm = sortperm(fvals)
        simplex = simplex[perm]
        fvals = fvals[perm]

        if abs(fvals[end] - fvals[1]) <= reltol * (abs(fvals[1]) + reltol)
            converged = true
            break
        end

        centroid = zeros(Float64, n)
        for i in 1:n, k in 1:n
            centroid[k] += simplex[i][k] / n
        end
        worst = simplex[end]
        reflected = Float64[centroid[k] + 1.0 * (centroid[k] - worst[k]) for k in 1:n]
        f_reflected = f(reflected)

        if f_reflected < fvals[1]
            expanded = Float64[centroid[k] + 2.0 * (reflected[k] - centroid[k]) for k in 1:n]
            f_expanded = f(expanded)
            if f_expanded < f_reflected
                simplex[end], fvals[end] = expanded, f_expanded
            else
                simplex[end], fvals[end] = reflected, f_reflected
            end
        elseif f_reflected < fvals[n]
            simplex[end], fvals[end] = reflected, f_reflected
        else
            if f_reflected < fvals[end]
                contracted = Float64[centroid[k] + 0.5 * (reflected[k] - centroid[k]) for k in 1:n]
            else
                contracted = Float64[centroid[k] + 0.5 * (worst[k] - centroid[k]) for k in 1:n]
            end
            f_contracted = f(contracted)
            if f_contracted < min(f_reflected, fvals[end])
                simplex[end], fvals[end] = contracted, f_contracted
            else
                for i in 2:(n + 1)
                    simplex[i] = Float64[simplex[1][k] + 0.5 * (simplex[i][k] - simplex[1][k]) for k in 1:n]
                    fvals[i] = f(simplex[i])
                end
            end
        end
    end

    perm = sortperm(fvals)
    return (; x = simplex[perm][1], value = fvals[perm][1], iterations = iterations,
            converged = converged)
end

"""
    variance_prior(s2, df; covariate, abundance_trend)
        -> (; variance0, df0, var_post, log_likelihood, converged)

Port of the reference's `variance_prior`: Smyth's (2004) empirical-Bayes shrinkage of a vector
of variances toward a scaled inverse-chisquare prior whose scale and degrees of freedom are
fitted by maximising the sum of scaled-F log densities.

`abundance_trend = true` is the reference's natural-spline trend in the prior scale and is
**not ported**: it is refused by name, with the message naming the option that runs the
reference's own non-trended form instead.
"""
function variance_prior(s2::AbstractVector{<:Real}, df::AbstractVector{<:Real};
                        covariate::Union{AbstractVector{<:Real},Nothing} = nothing,
                        abundance_trend::Union{Bool,Nothing} = nothing)
    n = length(s2)
    length(df) == n ||
        throw(ArgumentError("variance_prior: $(length(df)) degrees of freedom for $n variances. Refusing."))
    if isequal(abundance_trend, true)
        throw(ArgumentError(
            "variance_prior: abundance_trend = true asks for the natural-spline trend in the " *
            "prior scale, which glmGamPoi applies when a table has " *
            "$(SPLINE_TREND_MIN_FEATURES) or more features. That spline fit is not ported " *
            "here, and substituting the non-trended prior under the same label would change " *
            "every standard error without saying so. Pass abundance_trend = false to run the " *
            "reference's own non-trended form, which the run then records. See " *
            "docs/statistics/method-conditions/dispersion-glmGamPoi.md."))
    end
    if !isnothing(covariate) && length(covariate) != n
        throw(ArgumentError("variance_prior: $(length(covariate)) covariate values for $n variances. Refusing."))
    end

    for v in s2
        isfinite(v) && v > 0 ||
            throw(ArgumentError("variance_prior: the variances contain $v; all variances must be finite and positive (the reference stops on the same condition). Refusing."))
    end
    for v in df
        isfinite(v) && v > 0 ||
            throw(ArgumentError("variance_prior: the degrees of freedom contain $v; all must be finite and positive. Refusing."))
    end

    s2v = Float64[Float64(v) for v in s2]
    dfv = Float64[Float64(v) for v in df]

    if all(==(1.0), s2v)
        # The reference's Poisson case: overdispersion fixed at 0 gives s2 = 1 everywhere and
        # the prior is degenerate.
        return (; variance0 = ones(Float64, n), df0 = Inf, var_post = copy(s2v),
                log_likelihood = 0.0, converged = true)
    end

    objective = function (par::Vector{Float64})::Float64
        log_variance0 = par[1]
        df0 = exp(par[2])
        total = 0.0
        for i in 1:n
            total += _log_f_density(s2v[i] / exp(log_variance0), dfv[i], df0) - log_variance0
        end
        return -total
    end

    opt = _nelder_mead(objective, [0.0, 0.0])
    variance0 = fill(exp(opt.x[1]), n)
    df0 = exp(opt.x[2])
    var_post = Float64[(df0 * variance0[i] + dfv[i] * s2v[i]) / (df0 + dfv[i]) for i in 1:n]

    return (; variance0 = variance0, df0 = df0, var_post = var_post,
            log_likelihood = -opt.value, converged = opt.converged)
end

"""
    overdispersion_shrinkage(disp_est, gene_means, df; disp_trend, ql_disp_trend, npoints)
        -> (; dispersion_trend, ql_disp_estimate, ql_disp_trend, ql_disp_shrunken, ql_df0)

Port of the reference's `overdispersion_shrinkage`:

- `disp_trend = true` (default) fits the dispersion trend with `loc_median_fit`; `false`
  replaces the trend by the mean of the estimates, which is the reference's behaviour for a
  numeric `overdispersion_shrinkage` argument;
- the quasi-likelihood dispersion is the variance ratio
  `ql_disp = (1 + mean·disp_est) / (1 + mean·trend)` — the reference's conversion between the
  quasi-likelihood and the "normal representation" of Lund et al. (2012);
- the shrunken values come from `variance_prior` on `ql_disp`, and `ql_disp_shrunken` is what
  the reference reports and uses for its quasi-likelihood F-test.

Note for callers: the reference's *final coefficient fit* at fixed dispersion uses
`dispersion_trend` (see `R/glm_gp_impl.R`, `disp_latest <- dispersion_shrinkage$dispersion_trend`),
not `ql_disp_shrunken`. Both are returned here, labelled, so the integration cannot confuse
them.
"""
function overdispersion_shrinkage(disp_est::AbstractVector{<:Real},
                                  gene_means::AbstractVector{<:Real},
                                  df::Real;
                                  disp_trend::Bool = true,
                                  ql_disp_trend::Union{Bool,Nothing} = nothing,
                                  npoints::Union{Integer,Nothing} = nothing)
    n = length(disp_est)
    length(gene_means) == n ||
        throw(ArgumentError("overdispersion_shrinkage: $(length(gene_means)) gene means for $n dispersions. Refusing."))
    n > 0 || throw(ArgumentError("overdispersion_shrinkage: no dispersions. Refusing."))

    d = Float64[Float64(v) for v in disp_est]
    means = Float64[Float64(v) for v in gene_means]
    for v in d
        isfinite(v) && v >= 0 ||
            throw(ArgumentError("overdispersion_shrinkage: the dispersions contain $v; estimates must be finite and non-negative. Refusing."))
    end
    for v in means
        isfinite(v) && v >= 0 ||
            throw(ArgumentError("overdispersion_shrinkage: the gene means contain $v. Refusing."))
    end

    trend = if disp_trend
        loc_median_fit(means, d; npoints = npoints)
    else
        fill(sum(d) / n, n)
    end

    ql_disp = Float64[(1.0 + means[i] * d[i]) / (1.0 + means[i] * trend[i]) for i in 1:n]

    var_pr = variance_prior(ql_disp, fill(Float64(df), n);
                            covariate = means, abundance_trend = ql_disp_trend)

    return (; dispersion_trend = trend, ql_disp_estimate = ql_disp,
            ql_disp_trend = var_pr.variance0, ql_disp_shrunken = var_pr.var_post,
            ql_df0 = var_pr.df0, variance_prior_converged = var_pr.converged)
end

# ---------------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------------

"""
    DispersionOutcome

The dispersions a run used, with the intermediate quantities the reference reports, so that a
reader can check the pipeline rather than only its output.

- `overdispersion` — α per feature, the value the negative binomial fit uses
  (the reference's `dispersion_trend`; `theta = 1/α` is what `MASS::negative.binomial` takes)
- `theta` — `1/α`, `Inf` where α is 0 (a Poisson-equivalent fit)
- `raw_mle` — the per-feature maximum likelihood estimates before shrinkage
- `gene_means`, `df` — the means and residual degrees of freedom the estimates were formed at
- `trend`, `ql_dispersion`, `ql_trend`, `ql_df0` — the shrinkage intermediates
- `messages` — per-feature notes from the estimator (boundary cases, non-convergence)
"""
struct DispersionOutcome
    overdispersion::Vector{Float64}
    theta::Vector{Float64}
    raw_mle::Vector{Float64}
    gene_means::Vector{Float64}
    df::Float64
    trend::Union{Vector{Float64},Nothing}
    ql_dispersion::Union{Vector{Float64},Nothing}
    ql_trend::Union{Vector{Float64},Nothing}
    ql_df0::Union{Float64,Nothing}
    messages::Vector{String}
    notes::Vector{String}
    diagnostics::OrderedDict{String,Any}
    provenance::OrderedDict{String,Any}
end

"""
    estimate_dispersions(counts, means; design, do_cox_reid_adjustment, shrinkage,
                         disp_trend, abundance_trend, npoints, max_iter, feature_ids)
        -> DispersionOutcome

Estimate one overdispersion per feature (row) of `counts`, from the means in `means`, by the
glmGamPoi quasi-likelihood pipeline.

- `counts`, `means` — features × samples, as everywhere else in this repository
- `design` — samples × coefficients, the model matrix of the declared formula
- `do_cox_reid_adjustment` — the Cox-Reid bias adjustment (`TRUE` in the reference whenever a
  model matrix is given)
- `shrinkage` — run `overdispersion_shrinkage`; `false` returns the raw maximum likelihood
  estimates and records that they were not shrunk
- `disp_trend` — `true` for the reference's local-median trend, `false` for its
  mean-of-estimates form
- `abundance_trend` — `nothing` (the reference's default: refuse at
  `$(SPLINE_TREND_MIN_FEATURES)` or more features, where the reference would fit the
  unported spline), `false` (the reference's non-trended prior, recorded), or `true`
  (refused)

Refusals are named, and provenance records which form ran: that is the whole point of the
module, because a dispersion sets every standard error in the table below it.
"""
function estimate_dispersions(counts::AbstractMatrix{<:Real}, means::AbstractMatrix{<:Real};
                              design::Union{AbstractMatrix{<:Real},Nothing} = nothing,
                              do_cox_reid_adjustment::Bool = true,
                              shrinkage::Bool = true,
                              disp_trend::Bool = true,
                              abundance_trend::Union{Bool,Nothing} = nothing,
                              npoints::Union{Integer,Nothing} = nothing,
                              max_iter::Integer = 200,
                              feature_ids::AbstractVector{<:AbstractString} = String[])
    size(counts) == size(means) ||
        throw(ArgumentError("estimate_dispersions: the counts have shape $(size(counts)) and the means $(size(means)). Refusing."))
    n_features, n_samples = size(counts)
    n_features > 0 ||
        throw(ArgumentError("estimate_dispersions: no features. Refusing."))
    X = isnothing(design) ? reshape(ones(Float64, n_samples), n_samples, 1) :
        Matrix{Float64}(design)
    size(X, 1) == n_samples ||
        throw(ArgumentError("estimate_dispersions: the design has $(size(X, 1)) rows for $n_samples samples. Refusing."))

    ids = isempty(feature_ids) ? ["feature_$i" for i in 1:n_features] :
        _feature_ids(feature_ids, n_features)

    if isequal(abundance_trend, true)
        throw(ArgumentError(
            "estimate_dispersions: abundance_trend = true asks for the natural-spline trend " *
            "of the variance prior, which is not ported from glmGamPoi. Pass false to run the " *
            "reference's own non-trended prior (recorded in provenance), or use " *
            "dispersion_method = \"parametric\". See issue #21 and " *
            "docs/statistics/method-conditions/dispersion-glmGamPoi.md."))
    end
    if isnothing(abundance_trend) && n_features >= SPLINE_TREND_MIN_FEATURES
        throw(ArgumentError(
            "estimate_dispersions: this table has $n_features features, at or above the " *
            "$(SPLINE_TREND_MIN_FEATURES) at which glmGamPoi switches the variance prior to " *
            "its natural-spline abundance trend, which is not ported here. Running the " *
            "non-trended prior at this size would change the standard errors under a label " *
            "that says glmGamPoi. Pass glmgampoi_abundance_trend = false to run the " *
            "reference's own non-trended form explicitly (the run records it), or use " *
            "dispersion_method = \"parametric\". See issue #21."))
    end

    raw = zeros(Float64, n_features)
    messages = String[]
    iterations = zeros(Int, n_features)
    boundary_zero = 0
    boundary_upper = 0
    for i in 1:n_features
        y = Float64[counts[i, j] for j in 1:n_samples]
        mu = Float64[means[i, j] for j in 1:n_samples]
        if all(==(0.0), y)
            raw[i] = 0.0
            iterations[i] = 0
            boundary_zero += 1
            continue
        end
        # A table the estimator cannot use is refused by name, not turned into a NaN that a
        # downstream reader would render as a number.
        result = overdispersion_mle(y, mu; design = X,
                                    do_cox_reid_adjustment = do_cox_reid_adjustment,
                                    max_iter = max_iter)
        raw[i] = result.estimate
        iterations[i] = result.iterations
        if !isempty(result.message)
            push!(messages, "$(ids[i]): $(result.message)")
            result.estimate == 0.0 && (boundary_zero += 1)
            occursin("upper bound", result.message) && (boundary_upper += 1)
        end
    end

    df = Float64(n_samples - size(X, 2))
    gene_means = Float64[sum(means[i, :]) / n_samples for i in 1:n_features]

    notes = String[]
    if df <= 0
        throw(ArgumentError(
            "estimate_dispersions: the residual degrees of freedom are $df " *
            "($n_samples samples, $(size(X, 2)) coefficients), so there is nothing left to " *
            "estimate a dispersion from. Refusing rather than reporting a dispersion with no " *
            "residual information."))
    end

    if !shrinkage
        msg = "shrinkage was disabled: the dispersions are the per-feature maximum likelihood estimates. glmGamPoi's default is to shrink them toward the trend, and the unshrunk values are the noisiest part of this pipeline for small numbers of samples."
        push!(notes, msg)
        outcome = (; overdispersion = raw, trend = nothing, ql_dispersion = nothing,
                   ql_trend = nothing, ql_df0 = nothing, variance_prior_converged = true)
    else
        shrunk = overdispersion_shrinkage(raw, gene_means, df;
                                          disp_trend = disp_trend,
                                          ql_disp_trend = abundance_trend === false ? false : nothing,
                                          npoints = npoints)
        outcome = (; overdispersion = shrunk.dispersion_trend,
                   trend = shrunk.dispersion_trend,
                   ql_dispersion = shrunk.ql_disp_estimate,
                   ql_trend = shrunk.ql_disp_trend,
                   ql_df0 = shrunk.ql_df0,
                   variance_prior_converged = shrunk.variance_prior_converged)
        if !shrunk.variance_prior_converged
            msg = "the Nelder-Mead fit of the inverse-chisquare prior did not meet its convergence tolerance within the reference's iteration budget; the prior it stopped at is reported, and the dispersion shrinking is the reference's (which warns in the same case)."
            push!(notes, msg)
            @warn msg
        end
    end

    α = Float64[max(0.0, v) for v in outcome.overdispersion]
    theta = Float64[v == 0.0 ? Inf : 1.0 / v for v in α]

    diagnostics = OrderedDict{String,Any}(
        "method" => "glmGamPoi (ported quasi-likelihood dispersion pipeline)",
        "n_features" => n_features,
        "n_samples" => n_samples,
        "coefficients" => size(X, 2),
        "residual_df" => df,
        "overdispersion_raw" => raw,
        "overdispersion_final" => α,
        "theta" => theta,
        "gene_means" => gene_means,
        "iterations" => iterations,
        "features_at_zero_dispersion" => count(==(0.0), α),
        "features_at_poisson_equivalence" => count(v -> v <= 1e-8, α),
        "boundary_messages" => messages,
        "shrinkage" => shrinkage,
        "disp_trend" => disp_trend,
        "abundance_trend" => abundance_trend === false ? "false (the reference's non-trended prior; its spline trend is not ported)" :
                            (isnothing(abundance_trend) ? "the reference does not use a spline trend below $(SPLINE_TREND_MIN_FEATURES) features" :
                             "true (refused)"),
    )

    provenance = OrderedDict{String,Any}(
        "dispersion_method" => "glmGamPoi",
        "dispersion_implementation" =>
            "pure Julia port of the glmGamPoi quasi-likelihood dispersion pipeline " *
            "(Cox-Reid adjusted per-feature maximum likelihood, local-median dispersion trend, " *
            "quasi-likelihood conversion, inverse-chisquare variance shrinkage)",
        "dispersion_reference" => REFERENCE_GLMGAMPOI,
        "dispersion_cox_reid_adjustment" => do_cox_reid_adjustment,
        "dispersion_shrinkage" => shrinkage,
        "dispersion_shrinkage_trend" => disp_trend ? "local weighted median (loc_median_fit)" :
                                        "mean of the per-feature estimates",
        "dispersion_abundance_trend" => abundance_trend === false ?
            "not used: the run asked for the reference's non-trended variance prior, which is a documented deviation from glmGamPoi's default at $(SPLINE_TREND_MIN_FEATURES)+ features" :
            "not applicable below $(SPLINE_TREND_MIN_FEATURES) features, where the reference does not fit its spline trend either",
        "dispersion_quasi_likelihood_df0" => isnothing(outcome.ql_df0) ? nothing : outcome.ql_df0,
        "dispersion_final_definition" =>
            "the value passed to the fit is glmGamPoi's dispersion_trend, the same quantity it " *
            "passes to estimate_betas; the shrunken quasi-likelihood dispersion it reports " *
            "alongside is in diagnostics as overdispersion_final/ql_* and is not silently " *
            "swapped in",
        "not_claimed" =>
            "the reference's glm_gp() alternates between coefficient and dispersion estimates " *
            "until convergence; this port takes the dispersion from one fitted mean and the " *
            "documented integration refits once at fixed dispersion. The spline abundance " *
            "trend and the quasi-likelihood F-test of test_de() are not ported.",
    )

    return DispersionOutcome(α, theta, raw, gene_means, df, outcome.trend,
                             outcome.ql_dispersion, outcome.ql_trend, outcome.ql_df0,
                             messages, notes, diagnostics, provenance)
end

function _feature_ids(given::AbstractVector{<:AbstractString}, n::Int)
    length(given) == n ||
        throw(ArgumentError("estimate_dispersions: $(length(given)) feature ids for $n features. Refusing."))
    return String[String(s) for s in given]
end

end # module Dispersion
