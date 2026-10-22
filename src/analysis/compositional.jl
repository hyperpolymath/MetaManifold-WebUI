# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

## Multinomial and Dirichlet-multinomial regression
#
# Both models treat one sample's vector of taxon counts as a composition and
# condition on its total, so no size factor is needed and no pseudocount is
# added. With taxon `r` as the reference, the mean composition is
#
#     p_ij = exp(x_i' b_j) / (1 + sum_{k != r} exp(x_i' b_k)),   p_ir = 1 / (...)
#
# and `b_j` are the log-odds of taxon j against the reference taxon. A
# coefficient is therefore a log fold change in relative abundance, and every
# reported contrast is a log ratio between two taxa, which stays coherent under
# compositionality: the ratio does not depend on the library size.
#
# - multinomial: y_i ~ Multinomial(N_i, p_i). The likelihood is convex in the
#   coefficients, so Newton's method converges from any start; a zero count is
#   simply part of the likelihood (y_j log p_j contributes nothing) and needs
#   no epsilon. A taxon with no reads at all in one group has no finite
#   maximum-likelihood estimate, so the caller refuses those taxa before the
#   fit rather than reporting a diverged coefficient.
# - Dirichlet-multinomial: p_i ~ Dirichlet(c p_i) with total concentration c,
#   then y_i ~ Multinomial(N_i, p_i). The variance of a count is
#   N_i p_ij (1 - p_ij) (1 + (N_i - 1) theta) with theta = 1 / (1 + c), so
#   theta in (0, 1) measures extra-multinomial (between-sample) variation and
#   theta -> 0 recovers the multinomial. c is either profiled by maximum
#   likelihood (alternating with the coefficients) or estimated once by the
#   method of moments from the multinomial composition.
#
# Inference: a Wald test of each taxon's group coefficient from the observed
# information of the fitted (penalised) model. A sample's information is a
# Kronecker product of a (K-1) x (K-1) composition factor with x_i x_i', so the
# full matrix is ((K-1) q) x ((K-1) q): dense, and capped by `MAX_TAXA`.
# Coefficients are penalised by an L2 (ridge) term only. The L1 sparsity path of
# Songbird is not implemented: a lasso estimate has no valid Wald standard
# error, and the project does not ship the TensorFlow dependency needed to
# reproduce Songbird's own permutation-based inference. The model, the reference
# taxon and the effect scale are Songbird's (Morton et al. 2019).
#
# The special functions are implemented here rather than pulled from
# SpecialFunctions, so the models add no dependency: `_loggamma` and `_digamma`
# are the Stirling series after the recurrence is applied up to x >= 10,
# accurate to about 1e-14 (checked against Julia's `lgamma` and known constants
# in the unit tests).
module CompositionalModels

export CompositionalFit, CompositionalRefusal, RuntimeRefusal, MAX_TAXA,
       DEFAULT_MAX_SECONDS, DEFAULT_MAX_ITER, DEFAULT_TOL, CONCENTRATION_MIN,
       CONCENTRATION_MAX, DM_METHODS, fit_multinomial, fit_dirichlet_multinomial,
       multinomial_loglik, dirichlet_multinomial_loglik, dm_concentration_mle,
       dm_concentration_mom, observed_information, composition_probabilities,
       compositional_loggamma, compositional_digamma

# At most this many taxa are fitted. The observed information is
# ((K-1) q) x ((K-1) q) doubles: 500 taxa with two covariates is about 8 MB,
# 1000 taxa about 32 MB (about 72 MB with three covariates), and the Cholesky
# factorisation grows with the cube of that dimension. A fit converges in a
# handful of Newton steps, each of which assembles this matrix in O(n K^2 q^2)
# and factorises it in O((K q)^3).
const MAX_TAXA = 1000

# Wall-clock budget for one fit, in seconds, and the optimiser's defaults.
const DEFAULT_MAX_SECONDS = 300.0
const DEFAULT_MAX_ITER = 500
const DEFAULT_TOL = 1e-8

# The Dirichlet concentration is bounded. Above the upper bound the model is
# numerically the multinomial (theta = 1 / (1 + c) < 1e-6) and the difference
# between the two Dirichlet-multinomial log-likelihood terms cancels below the
# precision of a double; below the lower bound the composition is degenerate
# (theta > 0.9999) and the estimates are not usable. A fit at either bound is
# reported as a boundary by the caller.
const CONCENTRATION_MIN = 1e-4
const CONCENTRATION_MAX = 1e6

# Accepted `dm_overdispersion_method` names.
const DM_METHODS = ("mle", "mom")

# Alternating fits between the coefficients and the concentration.
const MAX_ALTERNATIONS = 50

# Central-difference step for the Dirichlet-multinomial score, in log-odds.
# Log-odds are O(1)-O(30) here, so an absolute step is appropriate.
const _FD_STEP = 1e-6

"""
    CompositionalRefusal(reason)

Raised when a multinomial or Dirichlet-multinomial fit cannot be made on the
data it was given: a sample with no reads, a reference taxon that is not among
the taxa, a singular information matrix, or more taxa than `MAX_TAXA`.
`reason` names the property at fault and what to change.
"""
struct CompositionalRefusal <: Exception
    reason :: String
end

Base.showerror(io::IO, e::CompositionalRefusal) = print(io, e.reason)

"""
    RuntimeRefusal(seconds, budget)

Raised when a fit runs past its wall-clock budget. The multinomial models cost
a dense matrix per iteration, so a table that is too large for the budget fails
loudly, naming the elapsed time and the budget, instead of hanging a request.
"""
struct RuntimeRefusal <: Exception
    seconds :: Float64
    budget  :: Float64
end

Base.showerror(io::IO, e::RuntimeRefusal) = print(io,
    "the fit ran for $(round(e.seconds; digits=1)) s, past its " *
    "$(round(e.budget; digits=1)) s budget; raise analysis.differential.max_seconds, " *
    "raise analysis.differential.min_prevalence so fewer taxa are fitted, or " *
    "analyse a coarser taxonomic rank")

"""
    CompositionalFit

One fitted multinomial or Dirichlet-multinomial model. `coefficients`,
`standard_errors`, `statistic` and `pvalue` are (K-1) x q matrices in the order
of the non-reference taxa and the columns of the design; the reference taxon has
no row because its coefficients are fixed at zero. `concentration` and
`overdispersion` are `Inf` and `0.0` for the multinomial; for the
Dirichlet-multinomial, `concentration` is c and `overdispersion` is
theta = 1 / (1 + c), the intra-sample correlation of the model. `loglik` is the
unpenalised log-likelihood at the estimate, `objective` the penalised quantity
the optimiser minimised. `iterations` counts Newton steps of the last fit and
`alternations` the coefficient/concentration rounds (0 for the method of
moments). `n_parameters` is (K-1) q, plus one for an estimated concentration.
"""
struct CompositionalFit
    coefficients    :: Matrix{Float64}
    standard_errors :: Matrix{Float64}
    statistic       :: Matrix{Float64}
    pvalue          :: Matrix{Float64}
    loglik          :: Float64
    objective       :: Float64
    iterations      :: Int
    converged       :: Bool
    concentration   :: Float64
    overdispersion  :: Float64
    alternations    :: Int
    n_parameters    :: Int
end

## Special functions
# Both take x > 0 and return a Float64. The recurrence pushes x into [10, Inf),
# where the Stirling series is accurate well past double precision with the
# terms used here; below 10 the recurrence costs a handful of log calls, which
# is what the Dirichlet-multinomial score needs for small c p.

"""
    compositional_loggamma(x) -> Float64

log Gamma(x) for x > 0. Throws `ArgumentError` for x <= 0 or a non-finite x.
"""
function compositional_loggamma(x::Real)
    xf = Float64(x)
    (isfinite(xf) && xf > 0) || throw(ArgumentError("log Gamma needs a positive finite argument, not $x"))
    shift = 0.0
    while xf < 10.0
        shift += log(xf)
        xf += 1.0
    end
    inv = 1.0 / xf
    inv2 = inv * inv
    series = inv * (1 / 12 + inv2 * (-1 / 360 + inv2 * (1 / 1260 +
             inv2 * (-1 / 1680 + inv2 * (1 / 1188 +
             inv2 * (-691 / 360360 + inv2 * (1 / 156)))))))
    (xf - 0.5) * log(xf) - xf + 0.91893853320467274178 + series - shift
end

"""
    compositional_digamma(x) -> Float64

The digamma function psi(x) = d/dx log Gamma(x) for x > 0. Throws
`ArgumentError` for x <= 0 or a non-finite x.
"""
function compositional_digamma(x::Real)
    xf = Float64(x)
    (isfinite(xf) && xf > 0) || throw(ArgumentError("digamma needs a positive finite argument, not $x"))
    shift = 0.0
    while xf < 10.0
        shift += 1.0 / xf
        xf += 1.0
    end
    inv = 1.0 / xf
    inv2 = inv * inv
    log(xf) - 0.5 * inv - inv2 * (1 / 12 - inv2 * (1 / 120 -
        inv2 * (1 / 252 - inv2 * (1 / 240 - inv2 / 132)))) - shift
end

## Geometry

"""
    _free_indices(K, reference) -> Vector{Int}

The indices of the K-1 free (non-reference) categories, in order.
"""
_free_indices(K::Int, reference::Int) = [j for j in 1:K if j != reference]

# Softmax over a full K-vector of logits whose reference entry is zero, written
# into `p`. The zero reference entry keeps the maximum at or above zero, so
# exp cannot overflow for log-odds within a few hundred.
function _softmax!(p::Vector{Float64}, eta::Vector{Float64})
    m = 0.0
    for k in eachindex(eta)
        eta[k] > m && (m = eta[k])
    end
    s = 0.0
    for k in eachindex(eta)
        v = exp(eta[k] - m)
        p[k] = v
        s += v
    end
    for k in eachindex(p)
        p[k] /= s
    end
    p
end

# The per-sample score and probabilities at `eta` (full K-vector, reference
# entry zero). For the multinomial, d_j = y_j / p_j - N and the score is
# u_j = p_j (d_j - dbar) = y_j - N p_j. For the Dirichlet-multinomial,
# d_j = c (psi(y_j + c p_j) - psi(c p_j)) and the score has the same form. Both
# score vectors sum to zero; only the free entries parameterise the model.
function _scores!(u::Vector{Float64}, p::Vector{Float64}, d::Vector{Float64},
                  eta::Vector{Float64}, y::AbstractVector{Float64}, N::Float64, c::Float64)
    _softmax!(p, eta)
    if isinf(c)
        for k in eachindex(p)
            d[k] = (y[k] > 0 ? y[k] / p[k] : 0.0) - N
        end
    else
        for k in eachindex(p)
            d[k] = c * (compositional_digamma(y[k] + c * p[k]) - compositional_digamma(c * p[k]))
        end
    end
    dbar = 0.0
    for k in eachindex(p)
        dbar += p[k] * d[k]
    end
    for k in eachindex(p)
        u[k] = p[k] * (d[k] - dbar)
    end
    u
end

"""
    multinomial_loglik(counts, probabilities) -> Float64

Sum over samples and taxa of y_ij log p_ij, with 0 log 0 taken as 0 (a taxon
counted zero times cannot make the likelihood -Inf). `probabilities` must have
the same shape as `counts` and be a composition in each row.
"""
function multinomial_loglik(counts::AbstractMatrix{<:Real}, probabilities::AbstractMatrix{<:Real})
    size(counts) == size(probabilities) || throw(ArgumentError(
        "counts are $(size(counts)) and probabilities $(size(probabilities))"))
    total = 0.0
    for i in axes(counts, 1), j in axes(counts, 2)
        y = counts[i, j]
        y > 0 && (total += y * log(probabilities[i, j]))
    end
    total
end

"""
    dirichlet_multinomial_loglik(counts, probabilities, concentration) -> Float64

The Dirichlet-multinomial log-likelihood of `counts` with mean composition
`probabilities` and total concentration c > 0:

    sum_i [ log Gamma(c) - log Gamma(N_i + c)
            + sum_j (log Gamma(y_ij + c p_ij) - log Gamma(c p_ij)) ]

plus the constant multinomial coefficients, which do not depend on the model.
"""
function dirichlet_multinomial_loglik(counts::AbstractMatrix{<:Real}, probabilities::AbstractMatrix{<:Real},
                                      concentration::Real)
    size(counts) == size(probabilities) || throw(ArgumentError(
        "counts are $(size(counts)) and probabilities $(size(probabilities))"))
    c = Float64(concentration)
    (isfinite(c) && c > 0) || throw(ArgumentError(
        "the Dirichlet concentration must be finite and positive, not $concentration"))
    total = 0.0
    for i in axes(counts, 1)
        N = 0.0
        for j in axes(counts, 2)
            N += counts[i, j]
        end
        total += compositional_loggamma(c) - compositional_loggamma(N + c)
        for j in axes(counts, 2)
            m = c * Float64(probabilities[i, j])
            total += compositional_loggamma(Float64(counts[i, j]) + m) - compositional_loggamma(m)
        end
    end
    total
end

## Input checks

function _check_fit_input(counts::AbstractMatrix{<:Real}, design::AbstractMatrix{<:Real},
                          reference::Integer)
    K = size(counts, 2)
    K >= 2 || throw(ArgumentError(
        "the models need at least 2 taxa, not $K"))
    size(design, 1) == size(counts, 1) || throw(ArgumentError(
        "the design has $(size(design, 1)) rows for $(size(counts, 1)) samples"))
    size(design, 2) >= 1 || throw(ArgumentError("the design needs at least one column"))
    1 <= reference <= K || throw(ArgumentError(
        "the reference taxon index $reference is outside 1:$K"))
    for i in axes(counts, 1), j in axes(counts, 2)
        x = counts[i, j]
        (isfinite(x) && x >= 0 && isinteger(x)) || throw(ArgumentError(
            "count $x at sample $i, taxon $j is not a non-negative integer: the models " *
            "are defined on read counts"))
    end
    for i in axes(counts, 1)
        N = 0.0
        for j in axes(counts, 2)
            N += counts[i, j]
        end
        N > 0 || throw(ArgumentError(
            "sample $i has no reads, so it has no composition to model"))
    end
    for i in axes(design, 1), k in axes(design, 2)
        isfinite(design[i, k]) || throw(ArgumentError(
            "the design value at row $i, column $k is not finite"))
    end
    nothing
end

function _check_size(K::Int, q::Int)
    n_taxa = K - 1
    n_taxa <= MAX_TAXA || throw(CompositionalRefusal(
        "the fit has $n_taxa non-reference taxa and $q covariate(s), which is " *
        "$(n_taxa * q) coefficients; at most $MAX_TAXA taxa are supported because the " *
        "observed information is a dense $(n_taxa * q) x $(n_taxa * q) matrix " *
        "(about $(round(Int, n_taxa * q * n_taxa * q * 8 / 1e6)) MB). Raise " *
        "analysis.differential.min_prevalence so fewer taxa are fitted, or analyse a " *
        "coarser taxonomic rank"))
    nothing
end

struct _Workspace
    eta :: Vector{Float64}
    p   :: Vector{Float64}
    d   :: Vector{Float64}
    u   :: Vector{Float64}
    up  :: Vector{Float64}
    um  :: Vector{Float64}
    y   :: Vector{Float64}
    M   :: Matrix{Float64}
end

_workspace(K::Int) = _Workspace(zeros(K), zeros(K), zeros(K), zeros(K), zeros(K),
                                zeros(K), zeros(K), zeros(K - 1, K - 1))

# Full logit vector of sample `i` into `ws.eta`, reference entry zero.
function _eta!(ws::_Workspace, design::AbstractMatrix{<:Real}, B::Matrix{Float64},
               i::Int, free::Vector{Int})
    fill!(ws.eta, 0.0)
    q = size(B, 2)
    for (l, j) in enumerate(free)
        s = 0.0
        @inbounds for k in 1:q
            s += design[i, k] * B[l, k]
        end
        ws.eta[j] = s
    end
    ws.eta
end

# log-likelihood of one sample given its probabilities (and counts) in `ws`.
function _sample_loglik(ws::_Workspace, y::Vector{Float64}, N::Float64, c::Float64)
    K = length(ws.p)
    if isinf(c)
        s = 0.0
        @inbounds for k in 1:K
            y[k] > 0 && (s += y[k] * log(ws.p[k]))
        end
        return s
    end
    s = compositional_loggamma(c) - compositional_loggamma(N + c)
    @inbounds for k in 1:K
        m = c * ws.p[k]
        s += compositional_loggamma(y[k] + m) - compositional_loggamma(m)
    end
    s
end

# Objective (penalised negative log-likelihood) and its gradient into `G`.
function _objective_gradient!(G::Matrix{Float64}, counts::AbstractMatrix{<:Real},
                              design::AbstractMatrix{<:Real}, B::Matrix{Float64},
                              free::Vector{Int}, c::Float64, penalty::Float64,
                              ws::_Workspace)
    fill!(G, 0.0)
    n = size(counts, 1)
    K = size(counts, 2)
    q = size(design, 2)
    total = 0.0
    @inbounds for i in 1:n
        N = 0.0
        for j in 1:K
            ws.y[j] = Float64(counts[i, j])
            N += ws.y[j]
        end
        eta = _eta!(ws, design, B, i, free)
        _scores!(ws.u, ws.p, ws.d, eta, ws.y, N, c)
        total += _sample_loglik(ws, ws.y, N, c)
        for (l, j) in enumerate(free)
            uj = ws.u[j]
            for k in 1:q
                G[l, k] += uj * design[i, k]
            end
        end
    end
    obj = -total
    for l in axes(B, 1), k in axes(B, 2)
        obj += 0.5 * penalty * B[l, k] * B[l, k]
        G[l, k] = -G[l, k] + penalty * B[l, k]
    end
    obj
end

# The observed information of the penalised objective, i.e. minus its Hessian,
# at the coefficients `B` and concentration `c`. For the multinomial the
# per-sample factor is analytic, -N (diag(p) - p p'); for the
# Dirichlet-multinomial it is a central difference of the analytic score, which
# costs O(K^2) digamma evaluations per sample and keeps the model's own
# curvature rather than a quasi-likelihood approximation.
function _information!(info::Matrix{Float64}, counts::AbstractMatrix{<:Real},
                       design::AbstractMatrix{<:Real}, B::Matrix{Float64},
                       free::Vector{Int}, c::Float64, penalty::Float64,
                       ws::_Workspace)
    fill!(info, 0.0)
    n = size(counts, 1)
    K = size(counts, 2)
    q = size(design, 2)
    km1 = K - 1
    xx = Matrix{Float64}(undef, q, q)
    @inbounds for i in 1:n
        N = 0.0
        for j in 1:K
            ws.y[j] = Float64(counts[i, j])
            N += ws.y[j]
        end
        eta = _eta!(ws, design, B, i, free)
        _scores!(ws.u, ws.p, ws.d, eta, ws.y, N, c)
        M = ws.M
        if isinf(c)
            for b in 1:km1
                pb = ws.p[free[b]]
                for a in 1:km1
                    pa = ws.p[free[a]]
                    M[b, a] = -N * ((a == b ? pa : 0.0) - pa * pb)
                end
            end
        else
            for (b, jb) in enumerate(free)
                keep = eta[jb]
                eta[jb] = keep + _FD_STEP
                _scores!(ws.up, ws.p, ws.d, eta, ws.y, N, c)
                eta[jb] = keep - _FD_STEP
                _scores!(ws.um, ws.p, ws.d, eta, ws.y, N, c)
                eta[jb] = keep
                for a in 1:km1
                    M[a, b] = (ws.up[free[a]] - ws.um[free[a]]) / (2 * _FD_STEP)
                end
            end
            # `ws.p` and `ws.d` hold the last perturbation; recompute the score
            # at the unperturbed logits so callers can rely on them.
            eta = _eta!(ws, design, B, i, free)
            _scores!(ws.u, ws.p, ws.d, eta, ws.y, N, c)
        end
        # info -= kron(M, x x'), one rank-1 block per pair of taxa. The outer
        # product x x' is shared by every block, and each block pair (b, a)
        # with b >= a is written once and mirrored into (a, b): the exact
        # Hessian is symmetric, so mirroring halves the arithmetic and the
        # memory traffic of the O(K^2 q^2) assembly that dominates a large fit.
        # The upper triangle is filled as well, so the matrix this function
        # returns (and `observed_information` exposes) is symmetric and can be
        # inverted by a caller without knowing about the internal triangle.
        for k in 1:q, mm in 1:q
            xx[k, mm] = design[i, k] * design[i, mm]
        end
        for b in 1:km1
            row = (b - 1) * q
            m = M[b, b]
            if m != 0.0
                for k in 1:q
                    for mm in 1:k
                        v = m * xx[k, mm]
                        info[row + k, row + mm] -= v
                        mm != k && (info[row + mm, row + k] -= v)
                    end
                end
            end
            for a in 1:(b - 1)
                m = M[b, a]
                m == 0.0 && continue
                col = (a - 1) * q
                for k in 1:q
                    for mm in 1:q
                        v = m * xx[k, mm]
                        info[row + k, col + mm] -= v
                        info[col + mm, row + k] -= v
                    end
                end
            end
        end
    end
    for l in 1:(km1 * q)
        info[l, l] += penalty
    end
    info
end

"""
    observed_information(counts, design, coefficients; reference, concentration=Inf,
                         penalty=0.0) -> Matrix{Float64}

The observed information of the penalised model at `coefficients` (a
(K-1) x q matrix in the order of the non-reference taxa), i.e. minus the
Hessian of the negative log-likelihood plus `penalty` on the diagonal. Its
inverse is the covariance of the coefficients and the square roots of its
diagonal are the standard errors `fit_*` reports. Exposed so tests can compare
it against a numerical Hessian of the log-likelihood.
"""
function observed_information(counts::AbstractMatrix{<:Real}, design::AbstractMatrix{<:Real},
                              coefficients::AbstractMatrix{<:Real};
                              reference::Integer=1, concentration::Real=Inf,
                              penalty::Real=0.0)
    _check_fit_input(counts, design, reference)
    K = size(counts, 2)
    q = size(design, 2)
    size(coefficients) == (K - 1, q) || throw(ArgumentError(
        "coefficients are $(size(coefficients)), expected $((K - 1, q))"))
    c = Float64(concentration)
    (isinf(c) || (isfinite(c) && c > 0)) || throw(ArgumentError(
        "the Dirichlet concentration must be positive, not $concentration"))
    B = Matrix{Float64}(coefficients)
    free = _free_indices(K, Int(reference))
    ws = _workspace(K)
    info = zeros((K - 1) * q, (K - 1) * q)
    _information!(info, counts, design, B, free, c, Float64(penalty), ws)
    info
end

"""
    composition_probabilities(design, coefficients; reference) -> Matrix{Float64}

The fitted mean composition of each row of `design` (n x K), with taxon
`reference` as the denominator of the log-odds.
"""
function composition_probabilities(design::AbstractMatrix{<:Real},
                                   coefficients::AbstractMatrix{<:Real};
                                   reference::Integer=1)
    K = size(coefficients, 1) + 1
    1 <= reference <= K || throw(ArgumentError(
        "the reference taxon index $reference is outside 1:$K"))
    size(coefficients, 2) == size(design, 2) || throw(ArgumentError(
        "coefficients have $(size(coefficients, 2)) columns for a design of $(size(design, 2))"))
    free = _free_indices(K, Int(reference))
    B = Matrix{Float64}(coefficients)
    out = zeros(size(design, 1), K)
    for i in axes(design, 1)
        for (l, j) in enumerate(free)
            s = 0.0
            for k in axes(design, 2)
                s += design[i, k] * B[l, k]
            end
            out[i, j] = s
        end
        m = 0.0
        for j in 1:K
            out[i, j] > m && (m = out[i, j])
        end
        total = 0.0
        for j in 1:K
            out[i, j] = exp(out[i, j] - m)
            total += out[i, j]
        end
        for j in 1:K
            out[i, j] /= total
        end
    end
    out
end

# Start the log-odds at the mean composition when the first design column is an
# intercept, so Newton begins near the right scale even for a 1e4-fold range of
# relative abundances; otherwise start at zero (the uniform composition).
function _initial_coefficients(counts::AbstractMatrix{<:Real}, design::AbstractMatrix{<:Real},
                               reference::Int)
    K = size(counts, 2)
    n = size(counts, 1)
    q = size(design, 2)
    B = zeros(K - 1, q)
    intercept = true
    for i in 1:n
        design[i, 1] == 1.0 || (intercept = false)
    end
    intercept || return B
    mean = zeros(K)
    for i in 1:n, j in 1:K
        mean[j] += Float64(counts[i, j])
    end
    for j in 1:K
        mean[j] /= n
    end
    free = _free_indices(K, reference)
    for (l, j) in enumerate(free)
        B[l, 1] = log((mean[j] + 0.5) / (mean[reference] + 0.5))
    end
    B
end

_deadline(max_seconds::Real) = time() + Float64(max_seconds)

function _check_deadline(deadline::Float64, max_seconds::Real)
    now = time()
    now < deadline && return nothing
    throw(RuntimeRefusal(now - (deadline - Float64(max_seconds)), Float64(max_seconds)))
end

## Linear algebra
# The module needs one symmetric positive-definite factorisation and the
# diagonal of its inverse (for Wald standard errors). It implements both here
# rather than importing LinearAlgebra: a package can only `using` a module that
# is declared in Project.toml, and keeping the numerical core dependency-free
# keeps the pinned Manifest untouched. Only the lower triangle is read or
# written, so the upper triangle of the information matrix is ignored.

"""
    _cholesky_lower!(A) -> Bool

Factor the symmetric matrix `A` in place as ``A = L L'`` with `L` lower
triangular, storing `L` in the lower triangle of `A`. Returns `false` as soon as
a pivot is not positive, which is how a singular or indefinite information
matrix is detected.
"""
function _cholesky_lower!(A::Matrix{Float64})
    n = size(A, 1)
    # Right-looking (outer-product) form: after each column is scaled, the
    # trailing submatrix is updated by a rank-1 term. Every inner loop walks
    # down a column, so the accesses are contiguous in Julia's column-major
    # layout, which matters at 1000 taxa where the factor is 1998 x 1998.
    @inbounds for k in 1:n
        akk = A[k, k]
        akk > 0.0 || return false
        d = sqrt(akk)
        A[k, k] = d
        for i in (k + 1):n
            A[i, k] /= d
        end
        for j in (k + 1):n
            l = A[j, k]
            l == 0.0 && continue
            for i in j:n
                A[i, j] -= A[i, k] * l
            end
        end
    end
    true
end

"""
    _cholesky_solve!(x, L, b) -> x

Solve ``L L' x = b`` for a lower-triangular `L` from `_cholesky_lower!`, in
place in `x`.
"""
function _cholesky_solve!(x::Vector{Float64}, L::Matrix{Float64}, b::Vector{Float64})
    n = length(b)
    @inbounds for i in 1:n
        s = b[i]
        for k in 1:(i - 1)
            s -= L[i, k] * x[k]
        end
        x[i] = s / L[i, i]
    end
    @inbounds for i in n:-1:1
        s = x[i]
        for k in (i + 1):n
            s -= L[k, i] * x[k]
        end
        x[i] = s / L[i, i]
    end
    x
end

"""
    _cholesky_inverse_diagonal(L) -> Vector{Float64}

The diagonal of ``(L L')^{-1}``: the squared norms of the columns of ``L^{-1}``,
each obtained by forward substitution, so no full inverse is formed.
"""
function _cholesky_inverse_diagonal(L::Matrix{Float64})
    n = size(L, 1)
    col = zeros(n)
    out = zeros(n)
    @inbounds for i in 1:n
        for r in 1:n
            col[r] = 0.0
        end
        col[i] = 1.0
        for r in 1:n
            s = col[r]
            for k in 1:(r - 1)
                s -= L[r, k] * col[k]
            end
            col[r] = s / L[r, r]
        end
        t = 0.0
        for r in 1:n
            t += col[r] * col[r]
        end
        out[i] = t
    end
    out
end

# Solve the information system for one Newton step: the penalised information is
# positive definite, but an unpenalised fit of taxa with near-degenerate counts
# can be numerically singular, so a Levenberg term is added only when the
# factorisation fails and the caller is told the step was damped.
function _info_solve(info::Matrix{Float64}, rhs::Vector{Float64})
    L = copy(info)
    if _cholesky_lower!(L)
        return (_cholesky_solve!(zeros(length(rhs)), L, rhs), false)
    end
    scale = 0.0
    for l in axes(info, 1)
        scale = max(scale, info[l, l])
    end
    rho = max(scale, 1.0) * 1e-10
    for _ in 1:12
        L = copy(info)
        for l in axes(L, 1)
            L[l, l] += rho
        end
        _cholesky_lower!(L) && return (_cholesky_solve!(zeros(length(rhs)), L, rhs), true)
        rho *= 10.0
    end
    throw(CompositionalRefusal(
        "the observed information of this model is not positive definite, so the " *
        "coefficients cannot be estimated; raise analysis.differential.mn_penalty above 0, " *
        "raise min_prevalence, or test at a coarser rank"))
end

# One Newton fit at a fixed concentration. Returns the coefficients, their
# covariance, the log-likelihood, the number of steps, and whether it converged.
function _newton_fit(counts::AbstractMatrix{<:Real}, design::AbstractMatrix{<:Real},
                     start::Matrix{Float64}, free::Vector{Int}, c::Float64,
                     penalty::Float64, max_iter::Int, tol::Float64, deadline::Float64,
                     max_seconds::Real)
    K = size(counts, 2)
    q = size(design, 2)
    B = copy(start)
    ws = _workspace(K)
    G = zeros(K - 1, q)
    obj = _objective_gradient!(G, counts, design, B, free, c, penalty, ws)
    iterations = 0
    converged = false
    damped = false
    # Convergence is judged against the gradient at the start, so the tolerance
    # means the same thing on a table of thousands of reads and on one of
    # millions, and against the size of the Newton step itself.
    gscale = max(1.0, maximum(abs.(G)))
    for it in 1:max_iter
        _check_deadline(deadline, max_seconds)
        iterations = it
        gmax = 0.0
        for v in G
            gmax = max(gmax, abs(v))
        end
        gmax <= tol * gscale && (converged = true; break)
        info = zeros((K - 1) * q, (K - 1) * q)
        _information!(info, counts, design, B, free, c, penalty, ws)
        rhs = [-G[l, k] for l in 1:(K - 1) for k in 1:q]
        step, damped_now = _info_solve(info, rhs)
        damped |= damped_now
        biggest = 0.0
        for v in step
            biggest = max(biggest, abs(v))
        end
        biggest <= tol * (1.0 + maximum(abs.(B))) && (converged = true; break)
        # Step halving: accept the first step that lowers the objective. A
        # Newton step on a convex objective always does for a small enough
        # alpha; if none does, the fit is at a numerical stationary point.
        stepmat = Matrix{Float64}(undef, K - 1, q)
        for l in 1:(K - 1), k in 1:q
            stepmat[l, k] = step[(l - 1) * q + k]
        end
        accepted = false
        alpha = 1.0
        for _ in 1:40
            trial = B .+ alpha .* stepmat
            objt = _objective_gradient!(G, counts, design, trial, free, c, penalty, ws)
            if objt < obj
                B = trial
                obj = objt
                accepted = true
                break
            end
            alpha /= 2
        end
        if !accepted
            # No step lowered the objective: the fit is at a stationary point to
            # the precision of the arithmetic when the step it wanted was tiny,
            # and is reported as converged; a large step that cannot descend is
            # a genuine failure and is reported as such.
            converged = biggest <= sqrt(tol) * (1.0 + maximum(abs.(B)))
            break
        end
    end
    info = zeros((K - 1) * q, (K - 1) * q)
    _information!(info, counts, design, B, free, c, penalty, ws)
    # The variances are only reported when the undamped information is positive
    # definite; damping is a step device, not a variance estimator.
    variances = if _cholesky_lower!(info)
        _cholesky_inverse_diagonal(info)
    else
        throw(CompositionalRefusal(
            "the observed information at the estimate is singular, so the standard " *
            "errors are not defined; raise analysis.differential.mn_penalty above 0, " *
            "raise min_prevalence, or test at a coarser rank"))
    end
    # Recompute the log-likelihood from the final composition.
    ll = 0.0
    for i in axes(counts, 1)
        N = 0.0
        for j in 1:K
            ws.y[j] = Float64(counts[i, j])
            N += ws.y[j]
        end
        eta = _eta!(ws, design, B, i, free)
        _scores!(ws.u, ws.p, ws.d, eta, ws.y, N, c)
        ll += _sample_loglik(ws, ws.y, N, c)
    end
    (coefficients=B, variances=variances, loglik=ll, objective=obj, iterations=iterations,
     converged=converged, damped=damped)
end

# Wald statistics from the diagonal of the covariance (in the (taxon, covariate)
# parameter order used throughout this module).
function _wald(coefficients::Matrix{Float64}, variances::Vector{Float64})
    km1, q = size(coefficients)
    se = Matrix{Float64}(undef, km1, q)
    z = Matrix{Float64}(undef, km1, q)
    p = Matrix{Float64}(undef, km1, q)
    for l in 1:km1, k in 1:q
        idx = (l - 1) * q + k
        v = variances[idx]
        s = sqrt(max(v, 0.0))
        se[l, k] = s
        if s > 0.0 && isfinite(s)
            z[l, k] = coefficients[l, k] / s
            p[l, k] = erfc(abs(z[l, k]) / sqrt(2.0))
        else
            z[l, k] = NaN
            p[l, k] = NaN
        end
    end
    (se=se, statistic=z, pvalue=p)
end

"""
    fit_multinomial(counts, design; reference, penalty=0.0, max_iter=DEFAULT_MAX_ITER,
                    tol=DEFAULT_TOL, max_seconds=DEFAULT_MAX_SECONDS) -> CompositionalFit

Fit `counts` (samples x taxa integer matrix) with a multinomial logistic model
whose linear predictor is `design` (samples x q), with taxon `reference` fixed
at zero log-odds. `penalty` >= 0 is an L2 (ridge) term on every non-reference
coefficient, including the intercept; 0 is maximum likelihood. Newton steps run
until the largest coefficient update is at most `tol` (relative to the size of
the coefficients), `max_iter` is reached, or the wall-clock budget
`max_seconds` is exhausted (`RuntimeRefusal`). Standard errors come from the
observed information, so a ridge fit reports ridge (penalised) standard errors.

Throws `ArgumentError` for unusable input, `CompositionalRefusal` for more than
`MAX_TAXA` taxa or a singular information matrix, and `RuntimeRefusal` when the
budget is exhausted. A fit that stops at `max_iter` or at a numerical
stationary point reports `converged = false` rather than raising; callers decide
whether to withhold inference.
"""
function fit_multinomial(counts::AbstractMatrix{<:Real}, design::AbstractMatrix{<:Real};
                         reference::Integer=1, penalty::Real=0.0,
                         max_iter::Integer=DEFAULT_MAX_ITER, tol::Real=DEFAULT_TOL,
                         max_seconds::Real=DEFAULT_MAX_SECONDS)
    _check_fit_input(counts, design, reference)
    (isfinite(penalty) && penalty >= 0) || throw(ArgumentError(
        "the penalty must be a finite number >= 0, not $penalty"))
    (max_iter >= 1) || throw(ArgumentError("max_iter must be at least 1, not $max_iter"))
    (isfinite(tol) && tol > 0) || throw(ArgumentError("tol must be positive and finite, not $tol"))
    (isfinite(max_seconds) && max_seconds > 0) || throw(ArgumentError(
        "max_seconds must be positive and finite, not $max_seconds"))
    K = size(counts, 2)
    q = size(design, 2)
    _check_size(K, q)
    free = _free_indices(K, Int(reference))
    start = _initial_coefficients(counts, design, Int(reference))
    fit = _newton_fit(counts, design, start, free, Inf, Float64(penalty),
                      Int(max_iter), Float64(tol), _deadline(max_seconds), max_seconds)
    wald = _wald(fit.coefficients, fit.variances)
    CompositionalFit(fit.coefficients, wald.se, wald.statistic, wald.pvalue,
                     fit.loglik, fit.objective, fit.iterations, fit.converged,
                     Inf, 0.0, 0, (K - 1) * q)
end

"""
    dm_concentration_mle(counts, probabilities; lower=CONCENTRATION_MIN,
                         upper=CONCENTRATION_MAX) -> Float64

Maximum-likelihood Dirichlet concentration for the mean composition
`probabilities`, by bisection on the derivative of the Dirichlet-multinomial
log-likelihood. That derivative is monotone decreasing in c, so the profile is
concave and bisection cannot wander; it runs in log c between `lower` and
`upper` (the bounds at which the model is indistinguishable from the
multinomial and degenerate). A result at either bound is reported as is;
callers mark that as a boundary.
"""
function dm_concentration_mle(counts::AbstractMatrix{<:Real}, probabilities::AbstractMatrix{<:Real};
                              lower::Real=CONCENTRATION_MIN, upper::Real=CONCENTRATION_MAX)
    size(counts) == size(probabilities) || throw(ArgumentError(
        "counts are $(size(counts)) and probabilities $(size(probabilities))"))
    (lower > 0 && upper > lower) || throw(ArgumentError(
        "the concentration bounds must satisfy 0 < lower < upper, not $lower and $upper"))
    n, K = size(counts)
    Y = Matrix{Float64}(counts)
    N = [sum(view(Y, i, :)) for i in 1:n]
    a = log(Float64(lower))
    b = log(Float64(upper))
    for _ in 1:200
        m = (a + b) / 2
        c = exp(m)
        score = 0.0
        for i in 1:n
            score += compositional_digamma(c) - compositional_digamma(N[i] + c)
            for j in 1:K
                p = Float64(probabilities[i, j])
                score += p * (compositional_digamma(Y[i, j] + c * p) -
                              compositional_digamma(c * p))
            end
        end
        if score > 0
            a = m
        else
            b = m
        end
        b - a <= 1e-11 && break
    end
    exp((a + b) / 2)
end

"""
    dm_concentration_mom(counts, probabilities) -> Float64

Method-of-moments Dirichlet concentration (La Rosa et al. 2012) for the mean
composition `probabilities`:

    theta = sum_ij [(y_ij - N_i p_ij)^2 - N_i p_ij (1 - p_ij)]
            / sum_i N_i (N_i - 1) (1 - sum_j p_ij^2),    c = 1 / theta - 1

with theta clipped to (1e-6, 1 - 1e-6). Returns `Inf` when no sample has two or
more reads, since the denominator is then zero and the data carry no
information about overdispersion.
"""
function dm_concentration_mom(counts::AbstractMatrix{<:Real}, probabilities::AbstractMatrix{<:Real})
    size(counts) == size(probabilities) || throw(ArgumentError(
        "counts are $(size(counts)) and probabilities $(size(probabilities))"))
    n, K = size(counts)
    num = 0.0
    den = 0.0
    for i in 1:n
        N = 0.0
        for j in 1:K
            N += Float64(counts[i, j])
        end
        ss = 0.0
        for j in 1:K
            p = Float64(probabilities[i, j])
            d = Float64(counts[i, j]) - N * p
            num += d * d - N * p * (1.0 - p)
            ss += p * p
        end
        den += N * (N - 1.0) * (1.0 - ss)
    end
    den > 0 || return Inf
    theta = num / den
    theta = min(max(theta, 1e-6), 1.0 - 1e-6)
    1.0 / theta - 1.0
end

"""
    fit_dirichlet_multinomial(counts, design; reference, penalty=0.0,
                              overdispersion_method="mle", max_iter=DEFAULT_MAX_ITER,
                              tol=DEFAULT_TOL, max_seconds=DEFAULT_MAX_SECONDS) -> CompositionalFit

Fit the Dirichlet-multinomial model of `fit_multinomial` plus a concentration.

`overdispersion_method = "mle"` alternates the profile maximum-likelihood
concentration with Newton steps for the coefficients, starting from the
multinomial fit, until both stop changing (at most `MAX_ALTERNATIONS` rounds).
`"mom"` takes one moment estimate of the concentration from the multinomial
composition (La Rosa et al. 2012) and fits the coefficients once at that fixed
concentration, so no hyperparameter is updated in the loop. Both report Wald
standard errors from the observed information of the fitted model.

The concentration is bounded by `CONCENTRATION_MIN` and `CONCENTRATION_MAX`;
an estimate at either bound means the model is, respectively, degenerate or
indistinguishable from the multinomial, and callers mark it as a boundary.
Throws the exceptions of `fit_multinomial`; also `ArgumentError` for an
unknown `overdispersion_method`.
"""
function fit_dirichlet_multinomial(counts::AbstractMatrix{<:Real}, design::AbstractMatrix{<:Real};
                                   reference::Integer=1, penalty::Real=0.0,
                                   overdispersion_method::AbstractString="mle",
                                   max_iter::Integer=DEFAULT_MAX_ITER, tol::Real=DEFAULT_TOL,
                                   max_seconds::Real=DEFAULT_MAX_SECONDS)
    _check_fit_input(counts, design, reference)
    method = lowercase(strip(String(overdispersion_method)))
    method in DM_METHODS || throw(ArgumentError(
        "dm_overdispersion_method must be one of $(join(DM_METHODS, ", ")), not '$overdispersion_method'"))
    (isfinite(penalty) && penalty >= 0) || throw(ArgumentError(
        "the penalty must be a finite number >= 0, not $penalty"))
    (max_iter >= 1) || throw(ArgumentError("max_iter must be at least 1, not $max_iter"))
    (isfinite(tol) && tol > 0) || throw(ArgumentError("tol must be positive and finite, not $tol"))
    (isfinite(max_seconds) && max_seconds > 0) || throw(ArgumentError(
        "max_seconds must be positive and finite, not $max_seconds"))
    K = size(counts, 2)
    q = size(design, 2)
    _check_size(K, q)
    free = _free_indices(K, Int(reference))
    deadline = _deadline(max_seconds)
    reference_index = Int(reference)

    start = _initial_coefficients(counts, design, reference_index)
    mn = _newton_fit(counts, design, start, free, Inf, Float64(penalty),
                     Int(max_iter), Float64(tol), deadline, max_seconds)
    mn_probs = composition_probabilities(design, mn.coefficients; reference=reference_index)

    concentration = 0.0
    alternations = 0
    fit = mn
    B = mn.coefficients
    converged = mn.converged
    # At the upper bound the Dirichlet prior is flat at the precision of a
    # double and the model is the multinomial, so the multinomial fit is the
    # answer and the caller reports a boundary rather than a Dirichlet fit that
    # the data cannot tell from it.
    at_limit(c) = c >= CONCENTRATION_MAX * (1 - 1e-9)
    if method == "mom"
        concentration = min(max(dm_concentration_mom(counts, mn_probs),
                                CONCENTRATION_MIN), CONCENTRATION_MAX)
        if !at_limit(concentration)
            fit = _newton_fit(counts, design, B, free, concentration,
                              Float64(penalty), Int(max_iter), Float64(tol),
                              deadline, max_seconds)
            B = fit.coefficients
            converged = fit.converged
        end
    else
        concentration = dm_concentration_mle(counts, mn_probs)
        if !at_limit(concentration)
            previous = -Inf
            converged = false
            for alt in 1:MAX_ALTERNATIONS
                _check_deadline(deadline, max_seconds)
                alternations = alt
                fit = _newton_fit(counts, design, B, free, concentration,
                                  Float64(penalty), Int(max_iter), Float64(tol),
                                  deadline, max_seconds)
                B = fit.coefficients
                probs = composition_probabilities(design, B; reference=reference_index)
                cnew = dm_concentration_mle(counts, probs)
                ll = fit.loglik
                if at_limit(cnew)
                    fit = mn
                    B = mn.coefficients
                    concentration = cnew
                    converged = mn.converged
                    break
                end
                stable = abs(cnew - concentration) <= Float64(tol) * (1.0 + concentration) &&
                         abs(ll - previous) <= Float64(tol) * (1.0 + abs(ll))
                concentration = cnew
                previous = ll
                if stable
                    converged = fit.converged
                    break
                end
            end
        end
    end
    wald = _wald(B, fit.variances)
    CompositionalFit(B, wald.se, wald.statistic, wald.pvalue, fit.loglik, fit.objective,
                     fit.iterations, converged, concentration,
                     isfinite(concentration) ? 1.0 / (1.0 + concentration) : 0.0,
                     alternations, (K - 1) * q + 1)
end

end # module CompositionalModels
