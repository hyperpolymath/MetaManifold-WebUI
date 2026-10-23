# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

module Ordination

using DataFrames, OrderedCollections, YAML, RCall
using ..RRuntime: with_r_lock, RBusyError
using ..Analysis: R_WAIT_SECONDS, r_available
using ..CladeCumulus: PhyloNode, parse_newick, unifrac_matrix
using ..DiversityMetrics: transform_counts
using ..Differential: clr_transform, replace_zeros

export OrdinationConfig, ParsedFormula, VeganUnavailable, vegan_available,
       ORDINATION_METHODS, ORDINATION_DISTANCES, ORDINATION_SCALINGS,
       MIN_ORDINATION_PERMUTATIONS, MAX_ORDINATION_PERMUTATIONS, DEFAULT_ORDINATION_PERMUTATIONS,
       compatible_distances, default_distance_for_method, validate_method_distance!,
       validate_formula_syntax, parse_ordination_formula, ordination_config_from_dict,
       load_ordination_contract, estimate_ordination_seconds,
       pure_linear_rda, pure_ezekiel_adj_r2, pure_varpart_two_way,
       run_constrained_ordination, ordination_biplot_chart

const ORDINATION_METHODS = (:none, :rda, :cca, :cap, :dbrda)
const ACTIVE_ORDINATION_METHODS = (:rda, :cca, :cap, :dbrda)
const ORDINATION_DISTANCES = (
    :bray, :jaccard, :euclidean, :aitchison, :chisq,
    :unweighted_unifrac, :weighted_unifrac,
)
const ORDINATION_SCALINGS = (1, 2)
const MIN_ORDINATION_PERMUTATIONS = 99
const MAX_ORDINATION_PERMUTATIONS = 9999
const DEFAULT_ORDINATION_PERMUTATIONS = 999
const REPLACEMENT_METHODS = ("bayesian_multiplicative", "multiplicative_replacement")
const DEFAULT_REPLACEMENT_DELTA = 0.65

const _METHOD_DISTANCES = Dict{Symbol,Tuple{Vararg{Symbol}}}(
    :none  => ORDINATION_DISTANCES,
    :rda   => (:aitchison, :euclidean),
    :cca   => (:chisq,),
    :cap   => (:bray, :jaccard, :euclidean, :aitchison, :unweighted_unifrac, :weighted_unifrac),
    :dbrda => (:bray, :jaccard, :euclidean, :aitchison, :unweighted_unifrac, :weighted_unifrac),
)

const _DEFAULT_DISTANCE = Dict{Symbol,Symbol}(
    :none  => :bray,
    :rda   => :aitchison,
    :cca   => :chisq,
    :cap   => :bray,
    :dbrda => :bray,
)

const _R_FORMULA_RESERVED_NAMES = Set([
    "if", "else", "repeat", "while", "function", "for", "in", "next", "break",
    "TRUE", "FALSE", "NULL", "Inf", "NaN", "NA", "NA_integer_", "NA_real_",
    "NA_complex_", "NA_character_", ".", "...", "Condition",
])

"""
Thrown when R's `vegan` package cannot be loaded inside the shared R runtime.
"""
struct VeganUnavailable <: Exception end

Base.showerror(io::IO, ::VeganUnavailable) = print(io,
    "the R package vegan is not available, so constrained ordinations cannot be fitted; " *
    "run install.sh or renv::restore() to install the pinned vegan release")

_string_keyed(d::AbstractDict) = Dict{String,Any}(string(k) => _string_keyed(v) for (k, v) in d)
_string_keyed(v::AbstractVector) = Any[_string_keyed(x) for x in v]
_string_keyed(x) = x

"""
    load_ordination_contract() -> Dict{String,Any}

Load the canonical KYAML capability and citation contract from
`config/defaults/ordination.kyaml`. File access and YAML parsing errors propagate.
"""
function load_ordination_contract()::Dict{String,Any}
    contract_path = normpath(joinpath(@__DIR__, "..", "..", "config", "defaults", "ordination.kyaml"))
    _string_keyed(YAML.load_file(contract_path))
end

"""Trim and lowercase a setting; throw `ArgumentError` labelled with `label` if empty."""
function _norm_symbol(val::Union{Symbol,AbstractString}, label::AbstractString)::Symbol
    s = lowercase(strip(String(val)))
    isempty(s) && throw(ArgumentError("$label cannot be empty"))
    Symbol(s)
end

"""
    compatible_distances(method) -> Tuple{Vararg{Symbol}}

Return the allowed dissimilarity/geometry symbols for `method`, ignoring case
and surrounding whitespace. Throw `ArgumentError` for an unknown or empty method.
"""
function compatible_distances(method::Union{Symbol,AbstractString})
    m = _norm_symbol(method, "ordination_method")
    haskey(_METHOD_DISTANCES, m) || throw(ArgumentError(
        "ordination_method must be one of $(join(string.(ORDINATION_METHODS), ", ")), not '$method'"))
    _METHOD_DISTANCES[m]
end

"""
    default_distance_for_method(method) -> Symbol

Return the canonical default distance for `method`, ignoring case and surrounding
whitespace. Throw `ArgumentError` for an unknown or empty method.
"""
function default_distance_for_method(method::Union{Symbol,AbstractString})::Symbol
    m = _norm_symbol(method, "ordination_method")
    haskey(_DEFAULT_DISTANCE, m) || throw(ArgumentError(
        "ordination_method must be one of $(join(string.(ORDINATION_METHODS), ", ")), not '$method'"))
    _DEFAULT_DISTANCE[m]
end

"""
    validate_method_distance!(method, distance) -> (Symbol, Symbol)

Enforce method/distance geometric compatibility, throwing `ArgumentError` on
unknown settings or incompatible combinations (such as linear RDA with raw
Bray-Curtis or CCA with non-chi-square distances). Return the normalised method
and distance symbols without mutating either argument.
"""
function validate_method_distance!(method::Union{Symbol,AbstractString},
                                   distance::Union{Symbol,AbstractString})
    m = _norm_symbol(method, "ordination_method")
    m in ORDINATION_METHODS || throw(ArgumentError(
        "analysis.ordination.method must be one of $(join(string.(ORDINATION_METHODS), ", ")), not '$method'"))
    d = _norm_symbol(distance, "ordination_distance")
    d in ORDINATION_DISTANCES || throw(ArgumentError(
        "analysis.ordination.distance must be one of $(join(string.(ORDINATION_DISTANCES), ", ")), not '$distance'"))
    allowed = _METHOD_DISTANCES[m]
    if !(d in allowed)
        hint = m === :rda ?
            "RDA operates in linear Euclidean space (use 'aitchison' for CLR-transformed compositions or 'euclidean', or switch method to 'dbrda'/'cap' for '$d')" :
            m === :cca ?
            "CCA uses unimodal chi-square geometry exclusively (set distance to 'chisq')" :
            "method '$m' accepts $(join(string.(allowed), ", "))"
        throw(ArgumentError(
            "analysis.ordination.distance='$d' is incompatible with analysis.ordination.method='$m': $hint"))
    end
    (m, d)
end

"""
    OrdinationConfig(; kwargs...)

Validated configuration for constrained ordination (`rda`, `cca`, `cap`, `dbrda`,
or `:none` when disabled).

The constructor rejects incompatible method/distance pairs, invalid formula
syntax, scaling outside `1:2`, permutations outside `99:9999`, an unknown
replacement method or a replacement fraction that is non-finite or outside
`(0, 1)` with `ArgumentError`. Scaling 1 is distance scaling; scaling 2 is
correlation scaling. An empty formula becomes `nothing` for automatic selection
later; metadata are not checked here. The distance defaults to `:bray` even when
another method is selected.
"""
struct OrdinationConfig
    ordination_method     :: Symbol
    ordination_formula    :: Union{String,Nothing}
    ordination_distance   :: Symbol
    ordination_scaling    :: Int
    permutations          :: Int
    variance_partitioning :: Bool
    replacement_method    :: String
    replacement_delta     :: Float64
    seed                  :: Int

    function OrdinationConfig(;
        ordination_method::Union{Symbol,AbstractString} = :none,
        ordination_formula::Union{Nothing,AbstractString} = nothing,
        ordination_distance::Union{Symbol,AbstractString} = :bray,
        ordination_scaling::Integer = 2,
        permutations::Integer = DEFAULT_ORDINATION_PERMUTATIONS,
        variance_partitioning::Bool = false,
        replacement_method::AbstractString = "bayesian_multiplicative",
        replacement_delta::Real = DEFAULT_REPLACEMENT_DELTA,
        seed::Integer = 42,
    )
        ordination_scaling isa Bool && throw(ArgumentError(
            "analysis.ordination.scaling must be integer 1 or 2, not Bool"))
        permutations isa Bool && throw(ArgumentError(
            "analysis.ordination.permutations must be an integer in [$MIN_ORDINATION_PERMUTATIONS, $MAX_ORDINATION_PERMUTATIONS], not Bool"))
        seed isa Bool && throw(ArgumentError("seed must be an integer, not Bool"))

        m, d = validate_method_distance!(ordination_method, ordination_distance)

        sc = Int(ordination_scaling)
        sc in ORDINATION_SCALINGS || throw(ArgumentError(
            "analysis.ordination.scaling must be 1 (distance) or 2 (correlation), not $ordination_scaling"))

        nperm = Int(permutations)
        (MIN_ORDINATION_PERMUTATIONS <= nperm <= MAX_ORDINATION_PERMUTATIONS) || throw(ArgumentError(
            "analysis.ordination.permutations must be in [$MIN_ORDINATION_PERMUTATIONS, $MAX_ORDINATION_PERMUTATIONS], not $permutations"))

        rmeth = lowercase(strip(String(replacement_method)))
        rmeth in REPLACEMENT_METHODS || throw(ArgumentError(
            "analysis.ordination.replacement_method must be one of $(join(REPLACEMENT_METHODS, ", ")), not '$replacement_method'"))

        (isfinite(replacement_delta) && 0.0 < replacement_delta < 1.0) || throw(ArgumentError(
            "analysis.ordination.replacement_delta must be finite and strictly in (0, 1), not $replacement_delta"))

        form_clean = if isnothing(ordination_formula) || isempty(strip(String(ordination_formula)))
            nothing
        else
            s = String(strip(String(ordination_formula)))
            validate_formula_syntax(s)
            s
        end

        new(m, form_clean, d, sc, nperm, variance_partitioning, rmeth, Float64(replacement_delta), Int(seed))
    end
end

## Formula grammar parser and R-injection safety boundary
#
# R's `as.formula` + `model.frame` evaluates arbitrary call expressions embedded
# in a formula string. User-supplied formulas are therefore parsed strictly in
# Julia into an explicit identifier/interaction/Condition(...) AST, and the
# string handed to R is reconstructed exclusively from validated tokens.

"""Return a trimmed ASCII covariate name, or throw `ArgumentError` for invalid or reserved names."""
function _check_identifier(ident::AbstractString)
    s = strip(String(ident))
    occursin(r"\A[A-Za-z][A-Za-z0-9_.]*\z", s) || throw(ArgumentError(
        "Invalid covariate identifier '$ident' in ordination formula; " *
        "only plain ASCII R identifiers starting with a letter are permitted"))
    if s in _R_FORMULA_RESERVED_NAMES || occursin(r"\A\.\.[0-9]+\z", s)
        throw(ArgumentError(
            "Reserved identifier '$s' cannot be used as a covariate in an ordination formula"))
    end
    String(s)
end

"""Split additive terms outside parentheses; throw `ArgumentError` for empty terms or unbalanced parentheses."""
function _split_top_level_plus(rhs::AbstractString)::Vector{String}
    parts = String[]
    depth = 0
    start_idx = firstindex(rhs)
    i = firstindex(rhs)
    while i <= lastindex(rhs)
        c = rhs[i]
        if c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
            depth < 0 && throw(ArgumentError("Unbalanced ')' in ordination formula '$rhs'"))
        elseif c == '+' && depth == 0
            seg = strip(rhs[start_idx:prevind(rhs, i)])
            isempty(seg) && throw(ArgumentError("Empty '+' term in ordination formula '$rhs'"))
            push!(parts, String(seg))
            start_idx = nextind(rhs, i)
        end
        i = nextind(rhs, i)
    end
    depth == 0 || throw(ArgumentError("Unbalanced '(' in ordination formula '$rhs'"))
    tail = strip(rhs[start_idx:lastindex(rhs)])
    isempty(tail) && throw(ArgumentError("Trailing '+' in ordination formula '$rhs'"))
    push!(parts, String(tail))
    parts
end

"""
    ParsedFormula

Validated AST representation of a constrained-ordination RHS formula.
"""
struct ParsedFormula
    canonical_rhs      :: String
    constrained_terms  :: Vector{String}
    condition_terms    :: Vector{String}
    referenced_columns :: Vector{String}
    df_constrained     :: Int
    df_conditioned     :: Int
end

"""
    validate_formula_syntax(formula) -> NamedTuple

Validate an ordination formula string against the safe identifier, interaction
(`:` / `*`), and `Condition(...)` grammar without requiring sample metadata.
Throws `ArgumentError` on malformed syntax, disallowed characters, LHS
expressions, arbitrary function calls, or missing constraining terms.
Return `canonical_rhs` without a leading `~`, deduplicated constrained and
condition terms, and referenced column names. Expand `a*b` to `a + b + a:b`;
only two-way interactions are accepted. A column cannot be both constrained
and conditioned.
"""
function validate_formula_syntax(formula::AbstractString)
    raw_str = String(formula)
    occursin(r"\A[A-Za-z0-9_.+*:()~ \t]+\z", raw_str) || throw(ArgumentError(
        "Ordination formula contains disallowed characters; only covariate names, '+', ':', '*', and Condition(...) are allowed"))
    s = strip(raw_str)
    isempty(s) && throw(ArgumentError("Ordination formula cannot be empty"))

    if occursin('~', s)
        tilde_parts = split(s, '~'; keepempty=true)
        length(tilde_parts) == 2 || throw(ArgumentError(
            "Ordination formula may contain at most one '~'"))
        isempty(strip(tilde_parts[1])) || throw(ArgumentError(
            "Ordination formula must be right-hand-side only (e.g. '~ group + Condition(run)'); left-hand side '$(strip(tilde_parts[1]))' is not permitted"))
        s = strip(tilde_parts[2])
        isempty(s) && throw(ArgumentError("Ordination formula right-hand side cannot be empty"))
    end

    raw_terms = _split_top_level_plus(s)
    constrained = String[]
    conditioned = String[]
    referenced = OrderedSet{String}()

    for raw_t in raw_terms
        m_cond = match(r"\ACondition\s*\((.*)\)\z", raw_t)
        if !isnothing(m_cond)
            inner = strip(m_cond.captures[1])
            isempty(inner) && throw(ArgumentError("Condition() in ordination formula cannot be empty"))
            if occursin('(', inner) || occursin(')', inner)
                throw(ArgumentError("Nested parentheses inside Condition(...) are not permitted"))
            end
            for sub in split(inner, '+')
                id = _check_identifier(sub)
                id in conditioned || push!(conditioned, id)
                push!(referenced, id)
            end
        elseif occursin('(', raw_t) || occursin(')', raw_t)
            throw(ArgumentError(
                "Only Condition(...) calls are permitted in ordination formulas; rejected '$raw_t'"))
        elseif occursin('*', raw_t) || occursin(':', raw_t)
            op = occursin('*', raw_t) ? '*' : ':'
            other = op == '*' ? ':' : '*'
            occursin(other, raw_t) && throw(ArgumentError(
                "Mixed '*' and ':' in single term '$raw_t' is not supported; expand terms explicitly"))
            pieces = split(raw_t, op)
            length(pieces) == 2 || throw(ArgumentError(
                "Only two-way interactions ('a:b' or 'a*b') are supported in ordination formulas; got '$raw_t'"))
            a = _check_identifier(pieces[1])
            b = _check_identifier(pieces[2])
            a == b && throw(ArgumentError("Self-interaction '$raw_t' is invalid"))
            for id in (a, b)
                push!(referenced, id)
            end
            if op == '*'
                a in constrained || push!(constrained, a)
                b in constrained || push!(constrained, b)
                inter = "$a:$b"
                inter in constrained || push!(constrained, inter)
            else
                inter = "$a:$b"
                inter in constrained || push!(constrained, inter)
            end
        else
            id = _check_identifier(raw_t)
            id in constrained || push!(constrained, id)
            push!(referenced, id)
        end
    end

    isempty(constrained) && throw(ArgumentError(
        "Constrained ordination formula must include at least one constraining covariate outside Condition(...)"))

    # Reject covariates appearing both as constrained predictors and inside Condition(...)
    cond_set = Set(conditioned)
    for t in constrained
        for part in split(t, ':')
            if part in cond_set
                throw(ArgumentError(
                    "Covariate '$part' appears both as a constraining predictor and inside Condition(...), making the partial model aliased"))
            end
        end
    end

    rhs_pieces = copy(constrained)
    if !isempty(conditioned)
        push!(rhs_pieces, "Condition(" * join(conditioned, " + ") * ")")
    end
    (; canonical_rhs = join(rhs_pieces, " + "),
       constrained_terms = constrained,
       condition_terms = conditioned,
       referenced_columns = collect(referenced))
end

"""
Return 0 for a constant column, 1 for a varying numeric column, or levels minus
1 for categorical values. Throw `ArgumentError` for missing
values, non-finite numeric entries or empty categorical labels.
"""
function _column_df(col::AbstractVector)::Int
    if eltype(col) <: Union{Real,Missing} && !(eltype(col) <: Bool)
        vals = Float64[]
        for v in col
            ismissing(v) && throw(ArgumentError("Missing values are not allowed in ordination metadata"))
            isfinite(v) || throw(ArgumentError("Non-finite numeric values are not allowed in ordination metadata"))
            push!(vals, Float64(v))
        end
        length(unique(vals)) >= 2 || return 0
        return 1
    else
        vals = String[]
        for v in col
            (ismissing(v) || isnothing(v)) && throw(ArgumentError("Missing values are not allowed in ordination metadata"))
            s = strip(string(v))
            isempty(s) && throw(ArgumentError("Empty categorical labels are not allowed in ordination metadata"))
            push!(vals, s)
        end
        k = length(unique(vals))
        return max(0, k - 1)
    end
end

"""Estimate a term's degrees of freedom, multiplying column degrees of freedom for an interaction."""
function _term_df(term::String, metadata::DataFrame)::Int
    if occursin(':', term)
        parts = split(term, ':')
        return _column_df(metadata[!, parts[1]]) * _column_df(metadata[!, parts[2]])
    end
    _column_df(metadata[!, term])
end

"""
    parse_ordination_formula(formula, metadata) -> ParsedFormula

Resolve and validate `formula` (or auto-construct a default formula over varying
metadata columns except `sample` when the formula is `nothing` or blank,
deduplicating identical numeric columns and equivalent categorical partitions)
against `metadata` (`DataFrame` with one row per sample). Verifies column
existence, non-constancy, absence of missing/non-finite entries, and positive
residual degrees of freedom (`df_total < n_samples - 1`).
Throw `ArgumentError` when fewer than three samples are supplied or any formula
or metadata check fails. Degrees of freedom are estimated from individual
columns and interactions; this does not establish full design-matrix rank.
"""
function parse_ordination_formula(formula::Union{Nothing,AbstractString},
                                  metadata::DataFrame)::ParsedFormula
    n_samples = nrow(metadata)
    n_samples >= 3 || throw(ArgumentError(
        "Constrained ordination requires at least 3 samples (got $n_samples)"))

    avail = Set(names(metadata))
    if isnothing(formula) || isempty(strip(String(formula)))
        auto_cols = String[]
        seen_signatures = Set{Any}()
        for col_name in names(metadata)
            lowercase(col_name) == "sample" && continue
            _check_identifier(col_name)
            col_vec = metadata[!, col_name]
            _column_df(col_vec) >= 1 || continue
            sig = if eltype(col_vec) <: Union{Real,Missing} && !(eltype(col_vec) <: Bool)
                (:num, Float64[Float64(v) for v in col_vec])
            else
                # Canonical partition signature (relabelled 1..k in order of first appearance)
                lbl_map = Dict{String,Int}()
                (:cat, Int[get!(lbl_map, strip(string(v)), length(lbl_map) + 1) for v in col_vec])
            end
            sig in seen_signatures && continue
            push!(seen_signatures, sig)
            push!(auto_cols, col_name)
        end
        isempty(auto_cols) && throw(ArgumentError(
            "No metadata covariate has at least 2 distinct values across the $n_samples samples"))
        formula = "~ " * join(auto_cols, " + ")
    end

    syn = validate_formula_syntax(String(formula))
    for col_name in syn.referenced_columns
        col_name in avail || throw(ArgumentError(
            "Formula covariate '$col_name' is not in sample metadata (available: $(join(sort(collect(avail)), ", ")))"))
        df_c = _column_df(metadata[!, col_name])
        df_c >= 1 || throw(ArgumentError(
            "Covariate '$col_name' is constant across all $n_samples samples and has 0 degrees of freedom"))
    end

    df_con = sum(_term_df(t, metadata) for t in syn.constrained_terms; init=0)
    df_cnd = sum(_term_df(t, metadata) for t in syn.condition_terms; init=0)
    if df_con + df_cnd >= n_samples - 1
        throw(ArgumentError(
            "Ordination model is saturated (constrained df=$df_con + conditioned df=$df_cnd >= n_samples - 1 = $(n_samples - 1)), leaving 0 residual degrees of freedom for permutation testing"))
    end

    ParsedFormula(
        syn.canonical_rhs,
        syn.constrained_terms,
        syn.condition_terms,
        syn.referenced_columns,
        df_con,
        df_cnd,
    )
end

"""
    ordination_config_from_dict(cfg; overrides=Dict()) -> OrdinationConfig

Construct a validated `OrdinationConfig` from a merged `pipeline.yml` config
dictionary, applying optional request-level `overrides`.
Both dictionaries use string keys; override keys are names such as `"method"`.
Null overrides inherit configured values, except a null `"formula"` explicitly
requests automatic selection. The seed comes from the top-level config unless
overridden. An inherited distance is retained and checked for compatibility;
the method's default is used only when no distance is supplied in either scope.
Configuration validation and conversion errors propagate.
"""
function ordination_config_from_dict(cfg::AbstractDict;
                                     overrides::AbstractDict = Dict{String,Any}())::OrdinationConfig
    analysis_blk = get(cfg, "analysis", Dict{String,Any}())
    ord_blk = analysis_blk isa AbstractDict ? get(analysis_blk, "ordination", Dict{String,Any}()) : Dict{String,Any}()
    ord_blk = ord_blk isa AbstractDict ? ord_blk : Dict{String,Any}()

    pick(k, default) = haskey(overrides, k) && !isnothing(overrides[k]) ? overrides[k] :
                       haskey(ord_blk, k) && !isnothing(ord_blk[k]) ? ord_blk[k] : default

    raw_formula = haskey(overrides, "formula") ? overrides["formula"] : get(ord_blk, "formula", nothing)
    top_seed = haskey(overrides, "seed") && !isnothing(overrides["seed"]) ? overrides["seed"] : get(cfg, "seed", 42)

    method_val = pick("method", "none")
    # If the caller overrides `method` without explicitly overriding `distance`,
    # and the inherited config distance was left on a different method's default,
    # only auto-select when `distance` was not explicitly supplied in `overrides`.
    dist_val = if haskey(overrides, "distance") && !isnothing(overrides["distance"])
        overrides["distance"]
    elseif haskey(ord_blk, "distance") && !isnothing(ord_blk["distance"])
        ord_blk["distance"]
    else
        string(default_distance_for_method(string(method_val)))
    end

    OrdinationConfig(;
        ordination_method     = string(method_val),
        ordination_formula    = isnothing(raw_formula) ? nothing : string(raw_formula),
        ordination_distance   = string(dist_val),
        ordination_scaling    = pick("scaling", 2),
        permutations          = pick("permutations", DEFAULT_ORDINATION_PERMUTATIONS),
        variance_partitioning = pick("variance_partitioning", false),
        replacement_method    = string(pick("replacement_method", "bayesian_multiplicative")),
        replacement_delta     = pick("replacement_delta", DEFAULT_REPLACEMENT_DELTA),
        seed                  = top_seed,
    )
end

"""
    estimate_ordination_seconds(; method, distance, n_samples, n_features, permutations, n_terms=1, variance_partitioning=false) -> NamedTuple

Analytical wall-clock cost heuristic for progressive-disclosure UI feedback and
preflight warnings. Returns `(; estimated_seconds, tier, warn_five_minutes)`.
Clamp each count to at least 1. Tiers are `"fast"` below 5 seconds, `"moderate"`
below 60 seconds and `"heavy"` otherwise; warn only above 300 seconds. This does
not measure execution time or validate method/distance compatibility.
"""
function estimate_ordination_seconds(;
    method::Union{Symbol,AbstractString} = :dbrda,
    distance::Union{Symbol,AbstractString} = :bray,
    n_samples::Integer,
    n_features::Integer,
    permutations::Integer = DEFAULT_ORDINATION_PERMUTATIONS,
    n_terms::Integer = 1,
    variance_partitioning::Bool = false,
)
    m = _norm_symbol(method, "method")
    d = _norm_symbol(distance, "distance")
    n = max(1, Int(n_samples))
    p = max(1, Int(n_features))
    b = max(1, Int(permutations))
    k = max(1, Int(n_terms))

    # Base R/RCall dispatch + matrix marshalling overhead (~0.06s)
    base_s = 0.06
    # Distance / CLR preparation cost
    prep_s = if d in (:unweighted_unifrac, :weighted_unifrac)
        4.5e-7 * n * n * p
    elseif d === :aitchison
        2.5e-7 * n * p
    else
        1.2e-7 * n * n * p
    end
    # Eigendecomposition / SVD cost (Gower N x N for cap/dbrda vs N x min(N, P) for rda/cca)
    decomp_s = (m in (:cap, :dbrda)) ? (2.2e-9 * n^3) : (1.5e-9 * n * p * min(n, p))
    # Permutation passes (omnibus + by="terms" + optional by="margin")
    passes = k >= 2 ? 3 : 2
    perm_unit = (m in (:cap, :dbrda)) ? (2.8e-8 * n * n) : (1.8e-8 * n * min(p, 250))
    perm_s = passes * b * perm_unit
    vp_s = (variance_partitioning && k >= 2) ? (0.35 * (decomp_s + (m === :cca ? b * perm_unit : 0.02))) : 0.0

    est = round(base_s + prep_s + decomp_s + perm_s + vp_s; digits=2)
    tier = est >= 60.0 ? "heavy" : est >= 5.0 ? "moderate" : "fast"
    (; estimated_seconds = est, tier, warn_five_minutes = est > 300.0)
end

## Pure-Julia mathematical building blocks (zero extra stdlibs; cross-checkable without R)

"""
    pure_ezekiel_adj_r2(r2, n_samples, df_model; df_conditioned=0) -> Float64

Analytical Ezekiel (1930) / Peres-Neto et al. (2006) adjusted R²:
`1 - (1 - r2) * (n - 1 - df_cond) / (n - 1 - df_cond - df_model)` when
conditioning removes `df_cond` degrees of freedom. With `df_cond == 0`, this
matches `vegan::RsquareAdj` for unconditioned linear RDA, CAP and dbRDA:
`1 - (1 - r2) * (n - 1) / (n - 1 - df_model)`.
For `df_conditioned > 0`, `r2` is the fraction of inertia remaining after
conditioning; this is not vegan's partial-model R² relative to total inertia.
Throw `ArgumentError` when residual degrees of freedom are not positive.
"""
function pure_ezekiel_adj_r2(r2::Real, n_samples::Integer, df_model::Integer;
                             df_conditioned::Integer = 0)::Float64
    n = Int(n_samples)
    k = Int(df_model)
    q = Int(df_conditioned)
    df_res = n - 1 - q - k
    df_res > 0 || throw(ArgumentError("Residual degrees of freedom must be positive (got $df_res)"))
    df_tot = n - 1 - q
    1.0 - (1.0 - Float64(r2)) * (Float64(df_tot) / Float64(df_res))
end

"""
    pure_varpart_two_way(adj_r2_a, adj_r2_b, adj_r2_ab) -> NamedTuple

Exact two-table Peres-Neto et al. (2006) adjusted-R² variance partitioning into
unique `[a]` (`X1 | X2`), shared `[b]`, unique `[c]` (`X2 | X1`), and `[d]`
(unexplained residual `1 - adj_r2_ab`).
Return `unique_x1`, `shared`, `unique_x2` and `residual` without clamping negative
fractions.
"""
function pure_varpart_two_way(adj_r2_a::Real, adj_r2_b::Real, adj_r2_ab::Real)
    a_tot = Float64(adj_r2_a)
    b_tot = Float64(adj_r2_b)
    ab_tot = Float64(adj_r2_ab)
    uniq_a = ab_tot - b_tot
    uniq_b = ab_tot - a_tot
    shared = a_tot + b_tot - ab_tot
    resid  = 1.0 - ab_tot
    (; unique_x1 = uniq_a, shared = shared, unique_x2 = uniq_b, residual = resid)
end

"""
Approximate eigenvalues of the symmetric part of square `S` in descending order,
retaining only values above the absolute/relative cutoff. Stop after
`max_sweeps` even if off-diagonal entries still exceed `tol`; leave `S` unchanged.
"""
function _sym_eigenvalues_desc(S::Matrix{Float64}; tol::Float64 = 1e-13, max_sweeps::Int = 80)::Vector{Float64}
    m = size(S, 1)
    m == 0 && return Float64[]
    m == 1 && return S[1, 1] > tol ? [S[1, 1]] : Float64[]
    A = 0.5 .* (S .+ permutedims(S))
    for _ in 1:max_sweeps
        max_off = 0.0
        for q in 2:m, p in 1:(q - 1)
            v = abs(A[p, q])
            v > max_off && (max_off = v)
        end
        max_off <= tol && break
        for p in 1:(m - 1), q in (p + 1):m
            apq = A[p, q]
            abs(apq) <= tol && continue
            tau = (A[q, q] - A[p, p]) / (2.0 * apq)
            t = tau >= 0.0 ? (1.0 / (tau + sqrt(1.0 + tau * tau))) : (-1.0 / (-tau + sqrt(1.0 + tau * tau)))
            c = 1.0 / sqrt(1.0 + t * t)
            s = t * c
            app = A[p, p]
            aqq = A[q, q]
            A[p, p] = app - t * apq
            A[q, q] = aqq + t * apq
            A[p, q] = 0.0
            A[q, p] = 0.0
            for r in 1:m
                (r == p || r == q) && continue
                arp = A[r, p]
                arq = A[r, q]
                A[r, p] = c * arp - s * arq
                A[p, r] = A[r, p]
                A[r, q] = s * arp + c * arq
                A[q, r] = A[r, q]
            end
        end
    end
    vals = [A[i, i] for i in 1:m]
    sort!(vals; rev=true)
    cutoff = isempty(vals) ? tol : max(tol, 1e-12 * max(1.0, vals[1]))
    [v for v in vals if v > cutoff]
end

"""Return retained positive Gram eigenvalues of `M`, divided by `scale_dof`, in descending order."""
function _gram_eigenvalues(M::Matrix{Float64}, scale_dof::Float64)::Vector{Float64}
    n, p = size(M)
    G = n <= p ? ((M * permutedims(M)) ./ scale_dof) : ((permutedims(M) * M) ./ scale_dof)
    _sym_eigenvalues_desc(G)
end

"""Return an orthonormal column basis without changing `X`, dropping residual columns of norm at most `tol`."""
function _modified_gram_schmidt(X::Matrix{Float64}; tol::Float64 = 1e-11)::Matrix{Float64}
    n, m = size(X)
    cols = Vector{Float64}[]
    for j in 1:m
        v = copy(X[:, j])
        # Two-pass MGS for numerical orthogonality
        for _ in 1:2
            for q in cols
                proj = 0.0
                for i in 1:n
                    proj += q[i] * v[i]
                end
                for i in 1:n
                    v[i] -= proj * q[i]
                end
            end
        end
        nrm = sqrt(sum(x * x for x in v; init=0.0))
        if nrm > tol
            push!(cols, v ./ nrm)
        end
    end
    isempty(cols) && return zeros(Float64, n, 0)
    Q = zeros(Float64, n, length(cols))
    for (j, col) in enumerate(cols)
        Q[:, j] = col
    end
    Q
end

"""Return a floating-point copy with each column's mean removed."""
function _center_columns(M::AbstractMatrix{<:Real})::Matrix{Float64}
    n, p = size(M)
    out = zeros(Float64, n, p)
    for j in 1:p
        mu = sum(Float64(M[i, j]) for i in 1:n; init=0.0) / n
        for i in 1:n
            out[i, j] = Float64(M[i, j]) - mu
        end
    end
    out
end

"""
    pure_linear_rda(Y, X; Z=nothing) -> NamedTuple

Pure-Julia linear Redundancy Analysis (with optional partial conditioning matrix
`Z`) using two-pass modified Gram-Schmidt projection and Ezekiel adjusted R².
Used as an independent in-Julia algebraic cross-check of total, conditioned,
constrained, and residual inertia (`tot.chi`, `pCCA\$tot.chi`, `CCA\$tot.chi`,
`CA\$tot.chi`), `R2`, `adj_r2`, and pseudo-F without invoking R.

Rows are samples in the same order in `Y` (responses), `X` (constraints) and
`Z` (conditioning covariates); columns are centred internally. Return these
statistics, positive eigenvalues in descending order and model/condition/residual
degrees of freedom. For partial models, R² uses total inertia and adjusted R²
subtracts the adjusted conditioning-only fit from the joint fit. Pseudo-F is
`Inf` when residual inertia is zero. Throw `ArgumentError` for mismatched row
counts, fewer than three samples, rank-zero constraints after conditioning or
non-positive residual degrees of freedom.
"""
function pure_linear_rda(Y::AbstractMatrix{<:Real}, X::AbstractMatrix{<:Real};
                         Z::Union{Nothing,AbstractMatrix{<:Real}} = nothing)
    n, p = size(Y)
    size(X, 1) == n || throw(ArgumentError("X row count ($(size(X, 1))) != Y row count ($n)"))
    n >= 3 || throw(ArgumentError("pure_linear_rda requires at least 3 samples"))

    Yc = _center_columns(Y)
    scale_dof = Float64(n - 1)
    ss_total = sum(x * x for x in Yc; init=0.0) / scale_dof

    ss_cond = 0.0
    q_rank = 0
    Y_work = copy(Yc)
    X_work = _center_columns(X)

    if !isnothing(Z)
        size(Z, 1) == n || throw(ArgumentError("Z row count ($(size(Z, 1))) != Y row count ($n)"))
        Zc = _center_columns(Z)
        Qz = _modified_gram_schmidt(Zc)
        q_rank = size(Qz, 2)
        if q_rank > 0
            # Project Y_work and X_work onto orthogonal complement of Qz
            Y_hat_z = zeros(Float64, n, p)
            for k in 1:q_rank, j in 1:p
                dot_val = sum(Qz[i, k] * Y_work[i, j] for i in 1:n; init=0.0)
                for i in 1:n
                    Y_hat_z[i, j] += Qz[i, k] * dot_val
                end
            end
            ss_cond = sum(x * x for x in Y_hat_z; init=0.0) / scale_dof
            Y_work .-= Y_hat_z

            for k in 1:q_rank, j in 1:size(X_work, 2)
                dot_val = sum(Qz[i, k] * X_work[i, j] for i in 1:n; init=0.0)
                for i in 1:n
                    X_work[i, j] -= Qz[i, k] * dot_val
                end
            end
        end
    end

    Qx = _modified_gram_schmidt(X_work)
    k_rank = size(Qx, 2)
    k_rank > 0 || throw(ArgumentError("Constraining design matrix has rank 0 after centring/conditioning"))
    df_res = n - 1 - q_rank - k_rank
    df_res > 0 || throw(ArgumentError("Model is saturated (residual df = $df_res)"))

    Y_hat = zeros(Float64, n, p)
    for k in 1:k_rank, j in 1:p
        dot_val = sum(Qx[i, k] * Y_work[i, j] for i in 1:n; init=0.0)
        for i in 1:n
            Y_hat[i, j] += Qx[i, k] * dot_val
        end
    end
    Y_res = Y_work .- Y_hat

    ss_constrained = sum(x * x for x in Y_hat; init=0.0) / scale_dof
    ss_residual    = sum(x * x for x in Y_res; init=0.0) / scale_dof

    # vegan defines RsquareAdj(rda)$r.squared = CCA$tot.chi / tot.chi even in
    # partial RDA, and adjusts against the unconditioned proportion via Ezekiel
    r2 = ss_total > 0 ? (ss_constrained / ss_total) : 0.0
    adj_r2 = if q_rank == 0
        pure_ezekiel_adj_r2(r2, n, k_rank)
    else
        # vegan:::RsquareAdj.rda for partial RDA:
        # RsquareAdj(tot_XZ) - RsquareAdj(cond_Z)
        r2_xz = ss_total > 0 ? ((ss_constrained + ss_cond) / ss_total) : 0.0
        r2_z  = ss_total > 0 ? (ss_cond / ss_total) : 0.0
        pure_ezekiel_adj_r2(r2_xz, n, k_rank + q_rank) - pure_ezekiel_adj_r2(r2_z, n, q_rank)
    end
    f_stat = ss_residual > 0 ? ((ss_constrained / k_rank) / (ss_residual / df_res)) : Inf
    con_eigs = _gram_eigenvalues(Y_hat, scale_dof)
    unc_eigs = _gram_eigenvalues(Y_res, scale_dof)

    (; total_inertia = ss_total,
       conditioned_inertia = ss_cond,
       constrained_inertia = ss_constrained,
       unconstrained_inertia = ss_residual,
       constrained_eigenvalues = con_eigs,
       unconstrained_eigenvalues = unc_eigs,
       r2 = r2,
       adj_r2 = adj_r2,
       f_statistic = f_stat,
       df_model = k_rank,
       df_conditioned = q_rank,
       df_residual = df_res)
end

## Block-permutation testability helper (mirrors Analysis._varies_within_any_block)

"""Return whether any block contains differing values; paired inputs are traversed with `zip`."""
function _varies_within_any_block(values::AbstractVector, blocks::AbstractVector)::Bool
    first_seen = Dict{Any,Any}()
    for (v, b) in zip(values, blocks)
        isequal(get!(first_seen, b, v), v) || return true
    end
    false
end

"""Return whether every constituent column of `term` is constant within every block."""
function _term_untestable_in_blocks(term::String, metadata::DataFrame,
                                    blocks::AbstractVector)::Bool
    for part in split(term, ':')
        _varies_within_any_block(metadata[!, part], blocks) && return false
    end
    true
end

_num_or_nothing(x) = (ismissing(x) || isnothing(x) || !(x isa Real) || !isfinite(x)) ? nothing : Float64(x)

_as_str_vec(x::AbstractVector) = String[String(v) for v in x]
_as_str_vec(x::AbstractString) = String[String(x)]
_as_str_vec(::Nothing)         = String[]
_as_str_vec(::Missing)         = String[]

_as_f64_vec(x::AbstractVector) = Float64[Float64(v) for v in x]
_as_f64_vec(x::Real)           = Float64[Float64(x)]
_as_f64_vec(::Nothing)         = Float64[]
_as_f64_vec(::Missing)         = Float64[]

_as_int_vec(x::AbstractVector) = Int[Int(v) for v in x]
_as_int_vec(x::Integer)        = Int[Int(x)]
_as_int_vec(::Nothing)         = Int[]
_as_int_vec(::Missing)         = Int[]

_as_bool_vec(x::AbstractVector) = Bool[Bool(v) for v in x]
_as_bool_vec(x::Bool)           = Bool[x]
_as_bool_vec(::Nothing)         = Bool[]
_as_bool_vec(::Missing)         = Bool[]

_as_any_vec(x::AbstractVector) = collect(x)
_as_any_vec(x)                 = (ismissing(x) || isnothing(x)) ? Any[] : Any[x]

"""
    vegan_available() -> Bool

Return `true` when R can be initialised and `vegan` can be loaded under `with_r_lock`.
Return `false` if R is unavailable or checking the package raises an error,
including a timeout waiting for the shared runtime.
"""
function vegan_available()::Bool
    r_available() || return false
    try
        with_r_lock(; timeout=R_WAIT_SECONDS[]) do
            Bool(RCall.rcopy(RCall.reval("requireNamespace('vegan', quietly = TRUE)")))
        end
    catch
        false
    end
end

"""
Return `nothing` for an `n × n` finite distance matrix with diagonal magnitudes
at most `1e-10`, upper-triangle values at least `-1e-12` and symmetry within
`1e-8`; otherwise throw `ArgumentError`. The matrix is not changed.
"""
function _validate_distance_matrix!(D::AbstractMatrix{<:Real}, n::Int)
    size(D) == (n, n) || throw(ArgumentError(
        "Distance matrix must have shape ($n, $n) matching sample count, got $(size(D))"))
    for i in 1:n
        d_ii = Float64(D[i, i])
        isfinite(d_ii) || throw(ArgumentError("Distance matrix contains non-finite diagonal at ($i, $i)"))
        abs(d_ii) <= 1e-10 || throw(ArgumentError(
            "Distance matrix diagonal must be 0 (got $d_ii at ($i, $i))"))
        for j in (i + 1):n
            d_ij = Float64(D[i, j])
            d_ji = Float64(D[j, i])
            (isfinite(d_ij) && isfinite(d_ji)) || throw(ArgumentError(
                "Distance matrix contains non-finite entry at ($i, $j)"))
            d_ij >= -1e-12 || throw(ArgumentError(
                "Distance matrix contains negative dissimilarity $d_ij at ($i, $j)"))
            abs(d_ij - d_ji) <= 1e-8 || throw(ArgumentError(
                "Distance matrix is not symmetric at ($i, $j): $d_ij != $d_ji"))
        end
    end
    nothing
end

"""
Copy selected, already validated columns for R and return `(clean, factor_cols)`.
Numeric columns become floats; categorical columns become
trimmed strings and are listed for conversion to R factors.
"""
function _prepare_metadata_for_r(metadata::DataFrame, cols::Vector{String})
    clean = DataFrame()
    factor_cols = String[]
    for c in cols
        raw_col = metadata[!, c]
        if eltype(raw_col) <: Union{Real,Missing} && !(eltype(raw_col) <: Bool)
            clean[!, c] = Float64[Float64(v) for v in raw_col]
        else
            clean[!, c] = String[String(strip(string(v))) for v in raw_col]
            push!(factor_cols, c)
        end
    end
    (clean, factor_cols)
end

const _ORD_R = raw"""
ord_vegan_ver <- as.character(utils::packageDescription("vegan", fields = "Version"))
rownames(ord_mat) <- ord_sample_ids
if (ncol(ord_mat) == length(ord_feature_ids)) {
    colnames(ord_mat) <- ord_feature_ids
}
for (col_nm in ord_factor_cols) {
    ord_meta[[col_nm]] <- factor(ord_meta[[col_nm]], levels = unique(ord_meta[[col_nm]]))
}
rownames(ord_meta) <- ord_sample_ids

ord_seed_reset <- function() {
    set.seed(ord_seed, kind = "Mersenne-Twister", normal.kind = "Inversion", sample.kind = "Rejection")
}

ord_perm_ctrl <- if (length(ord_blocks) > 0L) {
    permute::how(blocks = factor(ord_blocks, levels = unique(ord_blocks)), nperm = ord_nperm)
} else {
    ord_nperm
}

ord_vegan_dist <- if (ord_distance %in% c("aitchison", "euclidean")) "euclidean" else ord_distance

ord_seed_reset()
if (ord_use_dist) {
    rownames(ord_dist_mat) <- ord_sample_ids
    colnames(ord_dist_mat) <- ord_sample_ids
    ord_d <- stats::as.dist(ord_dist_mat)
    ord_form <- stats::as.formula(paste("ord_d ~", ord_formula_rhs), env = globalenv())
    if (ord_method == "cap") {
        ord_fit <- if (ncol(ord_mat) > 0L) {
            vegan::capscale(ord_form, data = ord_meta, comm = ord_mat)
        } else {
            vegan::capscale(ord_form, data = ord_meta)
        }
    } else {
        ord_fit <- vegan::dbrda(ord_form, data = ord_meta)
    }
} else {
    ord_form <- stats::as.formula(paste("ord_mat ~", ord_formula_rhs), env = globalenv())
    if (ord_method == "rda") {
        ord_fit <- vegan::rda(ord_form, data = ord_meta)
    } else if (ord_method == "cca") {
        ord_fit <- vegan::cca(ord_form, data = ord_meta)
    } else if (ord_method == "cap") {
        ord_fit <- vegan::capscale(ord_form, data = ord_meta, distance = ord_vegan_dist)
    } else {
        ord_fit <- vegan::dbrda(ord_form, data = ord_meta, distance = ord_vegan_dist)
    }
}

ord_tot_chi  <- as.numeric(ord_fit$tot.chi)
ord_cond_chi <- if (!is.null(ord_fit$pCCA) && !is.null(ord_fit$pCCA$tot.chi)) as.numeric(ord_fit$pCCA$tot.chi) else 0.0
ord_cca_chi  <- if (!is.null(ord_fit$CCA)  && !is.null(ord_fit$CCA$tot.chi))  as.numeric(ord_fit$CCA$tot.chi)  else 0.0
ord_ca_chi   <- if (!is.null(ord_fit$CA)   && !is.null(ord_fit$CA$tot.chi))   as.numeric(ord_fit$CA$tot.chi)   else 0.0

ord_cca_raw_eig   <- if (!is.null(ord_fit$CCA) && !is.null(ord_fit$CCA$eig)) as.numeric(ord_fit$CCA$eig) else numeric(0)
ord_cca_raw_names <- if (!is.null(ord_fit$CCA) && !is.null(ord_fit$CCA$eig)) as.character(names(ord_fit$CCA$eig)) else character(0)
ord_ca_raw_eig    <- if (!is.null(ord_fit$CA)  && !is.null(ord_fit$CA$eig))  as.numeric(ord_fit$CA$eig)  else numeric(0)
ord_ca_raw_names  <- if (!is.null(ord_fit$CA)  && !is.null(ord_fit$CA$eig))  as.character(names(ord_fit$CA$eig))  else character(0)

ord_cca_pos   <- ord_cca_raw_eig > 0
ord_ca_pos    <- ord_ca_raw_eig > 0
ord_cca_eig   <- ord_cca_raw_eig[ord_cca_pos]
ord_cca_names <- ord_cca_raw_names[ord_cca_pos]
ord_ca_eig    <- ord_ca_raw_eig[ord_ca_pos]
ord_ca_names  <- ord_ca_raw_names[ord_ca_pos]

ord_imag_chi <- if (!is.null(ord_fit$CA) && !is.null(ord_fit$CA$imaginary.chi)) {
    abs(as.numeric(ord_fit$CA$imaginary.chi))
} else {
    abs(sum(c(ord_cca_raw_eig[!ord_cca_pos], ord_ca_raw_eig[!ord_ca_pos])))
}

ord_seed_reset()
ord_r2_obj <- if (ord_method == "cca") {
    tryCatch(vegan::RsquareAdj(ord_fit, permutations = ord_perm_ctrl),
             error = function(e) vegan::RsquareAdj(ord_fit, permutations = ord_nperm))
} else {
    vegan::RsquareAdj(ord_fit)
}
ord_r2     <- if (is.null(ord_r2_obj$r.squared)     || length(ord_r2_obj$r.squared) == 0L)     NA_real_ else as.numeric(ord_r2_obj$r.squared[1])
ord_adj_r2 <- if (is.null(ord_r2_obj$adj.r.squared) || length(ord_r2_obj$adj.r.squared) == 0L) NA_real_ else as.numeric(ord_r2_obj$adj.r.squared[1])

ord_n_cca_u <- if (!is.null(ord_fit$CCA) && !is.null(ord_fit$CCA$u)) ncol(as.matrix(ord_fit$CCA$u)) else 0L
ord_n_ca_u  <- if (!is.null(ord_fit$CA)  && !is.null(ord_fit$CA$u))  ncol(as.matrix(ord_fit$CA$u))  else 0L
ord_n_avail <- ord_n_cca_u + ord_n_ca_u
ord_choices <- seq_len(min(2L, max(1L, ord_n_avail)))

ord_pad2 <- function(m) {
    m <- as.matrix(m)
    if (ncol(m) >= 2L) {
        matrix(as.numeric(m[, 1:2, drop = FALSE]), nrow = nrow(m), ncol = 2L)
    } else if (ncol(m) == 1L) {
        matrix(c(as.numeric(m[, 1]), rep(0.0, nrow(m))), nrow = nrow(m), ncol = 2L)
    } else {
        matrix(0.0, nrow = nrow(m), ncol = 2L)
    }
}

ord_sites_raw <- as.matrix(vegan::scores(ord_fit, choices = ord_choices, display = "sites", scaling = ord_scaling))
ord_site_scores <- ord_pad2(ord_sites_raw)
ord_axis_names <- colnames(ord_sites_raw)
if (is.null(ord_axis_names)) ord_axis_names <- paste0("Axis", seq_len(ncol(ord_sites_raw)))
if (length(ord_axis_names) < 2L) ord_axis_names <- c(ord_axis_names, "Axis2")
ord_axis_names <- as.character(ord_axis_names[1:2])

if (ord_n_cca_u >= 1L && !is.null(ord_fit$CCA$biplot) && nrow(as.matrix(ord_fit$CCA$biplot)) > 0L) {
    ord_bp_choices <- seq_len(min(2L, ord_n_cca_u))
    ord_bp_raw <- as.matrix(vegan::scores(ord_fit, choices = ord_bp_choices, display = "bp", scaling = ord_scaling))
    ord_bp_scores <- ord_pad2(ord_bp_raw)
    ord_bp_names <- as.character(rownames(ord_bp_raw))
} else {
    ord_bp_scores <- matrix(0.0, nrow = 0L, ncol = 2L)
    ord_bp_names <- character(0)
}

if (ord_n_cca_u >= 1L && !is.null(ord_fit$CCA$centroids) && nrow(as.matrix(ord_fit$CCA$centroids)) > 0L) {
    ord_cn_choices <- seq_len(min(2L, ord_n_cca_u))
    ord_cn_raw <- tryCatch(
        as.matrix(vegan::scores(ord_fit, choices = ord_cn_choices, display = "cn", scaling = ord_scaling)),
        error = function(e) NULL
    )
    if (!is.null(ord_cn_raw) && nrow(ord_cn_raw) > 0L) {
        ord_cn_scores <- ord_pad2(ord_cn_raw)
        ord_cn_names <- as.character(rownames(ord_cn_raw))
    } else {
        ord_cn_scores <- matrix(0.0, nrow = 0L, ncol = 2L)
        ord_cn_names <- character(0)
    }
} else {
    ord_cn_scores <- matrix(0.0, nrow = 0L, ncol = 2L)
    ord_cn_names <- character(0)
}

ord_sp_raw <- tryCatch(
    vegan::scores(ord_fit, choices = ord_choices, display = "species", scaling = ord_scaling),
    error = function(e) NULL
)
if (!is.null(ord_sp_raw) && length(ord_sp_raw) > 0L && !all(is.na(ord_sp_raw))) {
    ord_sp_mat <- as.matrix(ord_sp_raw)
    ord_sp_keep <- stats::complete.cases(ord_sp_mat)
    ord_sp_mat <- ord_sp_mat[ord_sp_keep, , drop = FALSE]
    if (nrow(ord_sp_mat) > 0L) {
        ord_sp_scores <- ord_pad2(ord_sp_mat)
        ord_sp_names <- as.character(rownames(ord_sp_mat))
        if (length(ord_sp_names) == 0L) ord_sp_names <- paste0("feature_", seq_len(nrow(ord_sp_mat)))
    } else {
        ord_sp_scores <- matrix(0.0, nrow = 0L, ncol = 2L)
        ord_sp_names <- character(0)
    }
} else {
    ord_sp_scores <- matrix(0.0, nrow = 0L, ncol = 2L)
    ord_sp_names <- character(0)
}

ord_extract_aov <- function(aov_obj) {
    if (is.null(aov_obj)) {
        return(list(terms = character(0), df = integer(0), var = numeric(0),
                    f = numeric(0), p = numeric(0), nperm = ord_nperm, text = ""))
    }
    rn <- as.character(rownames(aov_obj))
    df_col <- as.integer(aov_obj[["Df"]])
    var_col <- as.numeric(aov_obj[[2]])
    f_col <- as.numeric(aov_obj[["F"]])
    p_col <- as.numeric(aov_obj[["Pr(>F)"]])
    ctrl <- attr(aov_obj, "control")
    np <- if (!is.null(ctrl) && !is.null(ctrl[["nperm"]])) as.integer(ctrl[["nperm"]]) else as.integer(ord_nperm)
    txt <- paste(utils::capture.output(print(aov_obj)), collapse = "\n")
    list(terms = rn, df = df_col, var = var_col, f = f_col, p = p_col, nperm = np, text = txt)
}

ord_seed_reset()
ord_aov_overall <- ord_extract_aov(vegan::anova.cca(ord_fit, permutations = ord_perm_ctrl, parallel = 1L))

ord_seed_reset()
ord_aov_terms <- ord_extract_aov(vegan::anova.cca(ord_fit, permutations = ord_perm_ctrl, by = "terms", parallel = 1L))

ord_aov_margin <- if (ord_test_margin) {
    ord_seed_reset()
    ord_extract_aov(tryCatch(vegan::anova.cca(ord_fit, permutations = ord_perm_ctrl, by = "margin", parallel = 1L),
                             error = function(e) NULL))
} else {
    ord_extract_aov(NULL)
}

ord_aov_axes <- if (ord_test_axes) {
    ord_seed_reset()
    ord_extract_aov(tryCatch(vegan::anova.cca(ord_fit, permutations = ord_perm_ctrl, by = "axis", parallel = 1L),
                             error = function(e) NULL))
} else {
    ord_extract_aov(NULL)
}

ord_vp_ok <- FALSE
ord_vp_ind_labels <- character(0)
ord_vp_ind_df <- integer(0)
ord_vp_ind_r2 <- numeric(0)
ord_vp_ind_adj <- numeric(0)
ord_vp_ind_testable <- logical(0)
ord_vp_gross_labels <- character(0)
ord_vp_gross_df <- integer(0)
ord_vp_gross_r2 <- numeric(0)
ord_vp_gross_adj <- numeric(0)
ord_vp_err <- ""

if (ord_do_varpart) {
    tryCatch({
        vp_formulas <- lapply(ord_vp_terms, function(tm) stats::as.formula(paste("~", tm), env = globalenv()))
        vp_y <- if (ord_use_dist) {
            ord_d
        } else if (ord_method %in% c("cap", "dbrda")) {
            vegan::vegdist(ord_mat, method = ord_vegan_dist)
        } else {
            ord_mat
        }
        ord_seed_reset()
        vp_args <- c(list(vp_y), vp_formulas, list(data = ord_meta))
        if (ord_method == "cca") {
            vp_args$chisquare <- TRUE
            vp_args$permutations <- ord_perm_ctrl
        }
        vp_obj <- do.call(vegan::varpart, vp_args)
        vp_ind <- vp_obj$part$indfract
        vp_gr  <- vp_obj$part$fract
        r2_col <- function(df) {
            if ("R.squared" %in% colnames(df)) as.numeric(df[["R.squared"]])
            else if ("R.square" %in% colnames(df)) as.numeric(df[["R.square"]])
            else rep(NA_real_, nrow(df))
        }
        adj_col <- function(df) {
            if ("Adj.R.squared" %in% colnames(df)) as.numeric(df[["Adj.R.squared"]])
            else if ("Adj.R.square" %in% colnames(df)) as.numeric(df[["Adj.R.square"]])
            else rep(NA_real_, nrow(df))
        }
        ord_vp_ind_labels   <- as.character(rownames(vp_ind))
        ord_vp_ind_df       <- ifelse(is.na(vp_ind[["Df"]]), 0L, as.integer(vp_ind[["Df"]]))
        ord_vp_ind_r2       <- r2_col(vp_ind)
        ord_vp_ind_adj      <- adj_col(vp_ind)
        ord_vp_ind_testable <- ifelse(is.na(vp_ind[["Testable"]]), FALSE, as.logical(vp_ind[["Testable"]]))
        ord_vp_gross_labels <- as.character(rownames(vp_gr))
        ord_vp_gross_df     <- ifelse(is.na(vp_gr[["Df"]]), 0L, as.integer(vp_gr[["Df"]]))
        ord_vp_gross_r2     <- r2_col(vp_gr)
        ord_vp_gross_adj    <- adj_col(vp_gr)
        ord_vp_ok <- TRUE
    }, error = function(e) {
        ord_vp_err <<- conditionMessage(e)
    })
}
"""

const _ORD_CLEANUP_R =
    "rm(list = intersect(ls(), c(" *
    "'ord_method', 'ord_distance', 'ord_use_dist', 'ord_mat', 'ord_dist_mat', " *
    "'ord_sample_ids', 'ord_feature_ids', 'ord_meta', 'ord_factor_cols', " *
    "'ord_formula_rhs', 'ord_scaling', 'ord_nperm', 'ord_seed', 'ord_blocks', " *
    "'ord_test_margin', 'ord_test_axes', 'ord_do_varpart', 'ord_vp_terms', " *
    "'ord_vegan_ver', 'col_nm', 'ord_seed_reset', 'ord_perm_ctrl', 'ord_vegan_dist', " *
    "'ord_d', 'ord_form', 'ord_fit', 'ord_tot_chi', 'ord_cond_chi', 'ord_cca_chi', " *
    "'ord_ca_chi', 'ord_cca_raw_eig', 'ord_cca_raw_names', 'ord_ca_raw_eig', 'ord_ca_raw_names', " *
    "'ord_cca_pos', 'ord_ca_pos', 'ord_cca_eig', 'ord_cca_names', 'ord_ca_eig', 'ord_ca_names', " *
    "'ord_imag_chi', 'ord_r2_obj', 'ord_r2', 'ord_adj_r2', 'ord_n_cca_u', " *
    "'ord_n_ca_u', 'ord_n_avail', 'ord_choices', 'ord_pad2', 'ord_sites_raw', " *
    "'ord_site_scores', 'ord_axis_names', 'ord_bp_choices', 'ord_bp_raw', " *
    "'ord_bp_scores', 'ord_bp_names', 'ord_cn_choices', 'ord_cn_raw', " *
    "'ord_cn_scores', 'ord_cn_names', 'ord_sp_raw', 'ord_sp_mat', 'ord_sp_keep', 'ord_sp_scores', " *
    "'ord_sp_names', 'ord_extract_aov', 'ord_aov_overall', 'ord_aov_terms', " *
    "'ord_aov_margin', 'ord_aov_axes', 'ord_vp_ok', 'ord_vp_ind_labels', " *
    "'ord_vp_ind_df', 'ord_vp_ind_r2', 'ord_vp_ind_adj', 'ord_vp_ind_testable', " *
    "'ord_vp_gross_labels', 'ord_vp_gross_df', 'ord_vp_gross_r2', " *
    "'ord_vp_gross_adj', 'ord_vp_err', 'vp_formulas', 'vp_y', 'vp_args', " *
    "'vp_obj', 'vp_ind', 'vp_gr', 'r2_col', 'adj_col'))); invisible(gc())"

"""
Convert an extracted vegan ANOVA table into term rows plus residual statistics,
permutation count and printed text. Omit total/residual rows from the term list,
replace non-finite statistics with `nothing`, and withhold p-values for terms
in `untestable`, retaining their F statistics and an explanatory reason.
"""
function _parse_aov_list(d, untestable::Set{String})
    terms = _as_str_vec(d[:terms])
    dfs   = _as_any_vec(d[:df])
    vars  = _as_any_vec(d[:var])
    fs    = _as_any_vec(d[:f])
    ps    = _as_any_vec(d[:p])
    nperm = first(_as_int_vec(d[:nperm]))
    txt   = first(_as_str_vec(d[:text]))

    rows = NamedTuple[]
    res_df = 0
    res_var = 0.0
    for k in eachindex(terms)
        t = strip(terms[k])
        df_val = ismissing(dfs[k]) ? 0 : Int(dfs[k])
        v_val  = _num_or_nothing(vars[k])
        if t in ("Residual", "Residuals")
            res_df = df_val
            res_var = isnothing(v_val) ? 0.0 : v_val
            continue
        end
        t == "Total" && continue
        is_untest = t in untestable
        f_val = _num_or_nothing(fs[k])
        p_raw = _num_or_nothing(ps[k])
        p_val = is_untest ? nothing : p_raw
        reason = is_untest ?
            "'$t' is constant within every permutation block, so within-block permutations never exchange its labels" :
            nothing
        push!(rows, (;
            term = t,
            df = df_val,
            variance = v_val,
            f_statistic = f_val,
            p_value = p_val,
            untestable_reason = reason,
        ))
    end
    (; rows, residual_df = res_df, residual_variance = res_var, nperm, text = txt)
end

"""
    run_constrained_ordination(counts, metadata, cfg; kwargs...) -> NamedTuple

Fit a constrained ordination (`:rda`, `:cca`, `:cap`, or `:dbrda`) via R's
`vegan` package under the shared R runtime lock, run seeded permutation tests
(`anova.cca` omnibus, sequential `by = "terms"`, marginal `by = "margin"`, and
optional `by = "axis"`), and optionally compute `vegan::varpart` variance
partitioning.

`counts` is `n_samples × n_features` (rows = samples, columns = ASVs/OTUs/taxa).
For `:unweighted_unifrac` or `:weighted_unifrac`, pass either a precomputed
`distance_matrix` (`n_samples × n_samples`) or the `tree` and `feature_ids` keywords so
`CladeCumulus.unifrac_matrix` computes the phylogenetic distances.

Metadata and sample IDs follow count-row order; feature IDs follow column order.
At least three samples and positive residual model degrees of freedom are
required. Aitchison input must be non-negative: with zeros, retained features
must occur in at least two samples for Bayesian replacement or one for CZM,
and retained counts must be integer-valued. `beta_transform` accepts `"none"`
or `"hellinger"` where applied; Aitchison and tree-derived UniFrac ignore it.

`blocks` restricts permutations only when its length matches the sample count
and at least one label repeats; otherwise permutations are unrestricted.
Terms constant within every block have their p-values withheld. `r_timeout`
limits lock acquisition in seconds, not model execution. Fitting resets and
advances the shared R random-number generator using `cfg.seed`.

Return inertia and R² statistics, eigenvalues, two-axis sample/feature/covariate
scores, permutation tests, cautions and provenance. `max_feature_scores` limits
the feature scores selected by vector length, while all scores are also returned.
Variance partitioning is `nothing` when disabled, otherwise a computed or
skipped result with a reason. Failures of optional marginal/axis tests or
centroid/species scoring yield empty collections; caught `vegan::varpart`
failures yield a skipped result.

Throw `ArgumentError` for invalid data or formulae, `VeganUnavailable` if vegan
cannot load, and `RBusyError` if the runtime lock times out. Zero replacement
can propagate `ZCompositionsUnavailable`; uncaught R fitting, omnibus/sequential
testing and conversion errors also propagate. Unknown beta transforms raise
`ErrorException`.
"""
function run_constrained_ordination(
    counts::AbstractMatrix{<:Real},
    metadata::DataFrame,
    cfg::OrdinationConfig;
    sample_ids::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    feature_ids::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    beta_transform::AbstractString = "none",
    distance_matrix::Union{Nothing,AbstractMatrix{<:Real}} = nothing,
    tree::Union{Nothing,PhyloNode,AbstractString} = nothing,
    blocks::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    test_axes::Bool = false,
    max_feature_scores::Integer = 25,
    r_timeout::Real = R_WAIT_SECONDS[],
)
    cfg.ordination_method === :none && throw(ArgumentError(
        "Constrained ordination method is ':none'; select 'rda', 'cca', 'cap', or 'dbrda'"))

    n_samples, n_features = size(counts)
    nrow(metadata) == n_samples || throw(ArgumentError(
        "metadata has $(nrow(metadata)) rows for $n_samples samples in counts"))

    s_ids = isnothing(sample_ids) ? ["sample_$i" for i in 1:n_samples] : String.(sample_ids)
    length(s_ids) == n_samples || throw(ArgumentError(
        "sample_ids has length $(length(s_ids)) for $n_samples samples"))
    length(unique(s_ids)) == n_samples || throw(ArgumentError(
        "sample_ids must be unique across all $n_samples samples"))

    f_ids = isnothing(feature_ids) ? ["feature_$j" for j in 1:n_features] : String.(feature_ids)
    length(f_ids) == n_features || throw(ArgumentError(
        "feature_ids has length $(length(f_ids)) for $n_features features"))

    parsed = parse_ordination_formula(cfg.ordination_formula, metadata)
    r_meta, factor_cols = _prepare_metadata_for_r(metadata, parsed.referenced_columns)

    blocked = !isnothing(blocks) && length(blocks) == n_samples && !allunique(blocks)
    untestable_set = if blocked
        Set([t for t in parsed.constrained_terms if _term_untestable_in_blocks(t, metadata, blocks)])
    else
        Set{String}()
    end

    cautions = String[]
    zero_replacement_info = nothing
    dropped_zero_features = 0

    use_dist = false
    dist_mat_r = zeros(Float64, 0, 0)
    ord_mat = Matrix{Float64}(counts)
    kept_feature_ids = copy(f_ids)

    for x in ord_mat
        isfinite(x) || throw(ArgumentError("Input community matrix contains non-finite values"))
    end

    if !isnothing(distance_matrix)
        cfg.ordination_method in (:cap, :dbrda) || throw(ArgumentError(
            "Precomputed distance_matrix is only supported for 'cap' and 'dbrda', not '$(cfg.ordination_method)'"))
        _validate_distance_matrix!(distance_matrix, n_samples)
        use_dist = true
        dist_mat_r = Matrix{Float64}(distance_matrix)
        if lowercase(strip(String(beta_transform))) != "none" && n_features > 0 && all(>=(0.0), ord_mat)
            ord_mat = transform_counts(ord_mat; method=String(beta_transform))
        end
    elseif cfg.ordination_distance in (:unweighted_unifrac, :weighted_unifrac)
        isnothing(tree) && throw(ArgumentError(
            "Phylogenetic distance '$(cfg.ordination_distance)' requires a phylogenetic `tree` or precomputed `distance_matrix`"))
        n_features >= 2 || throw(ArgumentError(
            "UniFrac ordination requires at least 2 features (got $n_features)"))
        all(>=(0.0), ord_mat) || throw(ArgumentError(
            "UniFrac ordination requires non-negative abundances"))
        for i in 1:n_samples
            sum(@view ord_mat[i, :]) > 0.0 || throw(ArgumentError(
                "Sample '$(s_ids[i])' has zero total abundance; empty samples have undefined UniFrac distances"))
        end
        metric_sym = cfg.ordination_distance === :unweighted_unifrac ? :unweighted : :weighted
        phylo_node = tree isa AbstractString ? parse_newick(tree) : tree
        dist_mat_r = unifrac_matrix(permutedims(ord_mat), kept_feature_ids, s_ids, phylo_node; metric=metric_sym)
        _validate_distance_matrix!(dist_mat_r, n_samples)
        use_dist = true
    elseif cfg.ordination_distance === :aitchison
        n_features >= 2 || throw(ArgumentError(
            "Aitchison (CLR) ordination requires at least 2 features (got $n_features)"))
        all(>=(0.0), ord_mat) || throw(ArgumentError(
            "Aitchison (CLR) ordination expects non-negative counts or proportions; pass distance='euclidean' if data are already CLR-transformed"))
        for i in 1:n_samples
            sum(@view ord_mat[i, :]) > 0.0 || throw(ArgumentError(
                "Sample '$(s_ids[i])' has zero total reads; CLR is undefined on empty samples"))
        end
        has_zeros = any(==(0.0), ord_mat)
        if has_zeros
            min_pres = cfg.replacement_method == "bayesian_multiplicative" ? 2 : 1
            keep_cols = [j for j in 1:n_features if count(>(0.0), @view ord_mat[:, j]) >= min_pres]
            dropped_zero_features = n_features - length(keep_cols)
            length(keep_cols) >= 2 || throw(ArgumentError(
                "Aitchison ($(cfg.replacement_method)) ordination requires at least 2 features present in >= $min_pres sample(s)"))
            ord_mat = ord_mat[:, keep_cols]
            kept_feature_ids = kept_feature_ids[keep_cols]
            for i in 1:n_samples
                sum(@view ord_mat[i, :]) > 0.0 || throw(ArgumentError(
                    "Sample '$(s_ids[i])' has zero reads across retained features after sparsity filtering"))
            end
            int_counts = round.(Int, ord_mat)
            all(isapprox.(ord_mat, int_counts; atol=1e-9)) || throw(ArgumentError(
                "Aitchison zero replacement expects raw integer counts before normalisation (got non-integer values with zeros)"))
            repl = replace_zeros(
                int_counts;
                method = cfg.replacement_method,
                frac = cfg.replacement_delta,
                samples = s_ids,
                taxa = kept_feature_ids,
            )
            ord_mat = clr_transform(repl.proportions)
            zero_replacement_info = Dict{String,Any}(
                "method" => cfg.replacement_method,
                "delta" => cfg.replacement_delta,
                "zeros_replaced" => Int(repl.zeros_replaced),
            )
            push!(cautions,
                "Zeros were imputed via $(cfg.replacement_method) (delta=$(cfg.replacement_delta), $(repl.zeros_replaced) cell(s)) before CLR; imputed zeros are biased adjustments, not observed abundances.")
        else
            # Close each positive row to a composition and compute exact CLR
            n_kept = size(ord_mat, 2)
            props = similar(ord_mat)
            for i in 1:n_samples
                rs = sum(@view ord_mat[i, :])
                for j in 1:n_kept
                    props[i, j] = ord_mat[i, j] / rs
                end
            end
            ord_mat = clr_transform(props)
            zero_replacement_info = Dict{String,Any}(
                "method" => cfg.replacement_method,
                "delta" => cfg.replacement_delta,
                "zeros_replaced" => 0,
            )
        end
    elseif cfg.ordination_method === :cca
        n_features >= 2 || throw(ArgumentError(
            "CCA requires at least 2 features (got $n_features)"))
        all(>=(0.0), ord_mat) || throw(ArgumentError(
            "CCA chi-square ordination requires non-negative abundances; negative entries (such as CLR values) are incompatible with CCA"))
        btrans = lowercase(strip(String(beta_transform)))
        if btrans != "none"
            ord_mat = transform_counts(ord_mat; method=btrans)
        end
        keep_cols = [j for j in 1:n_features if sum(@view ord_mat[:, j]) > 0.0]
        dropped_zero_features = n_features - length(keep_cols)
        length(keep_cols) >= 2 || throw(ArgumentError(
            "CCA requires at least 2 features with positive total abundance across samples"))
        ord_mat = ord_mat[:, keep_cols]
        kept_feature_ids = kept_feature_ids[keep_cols]
        for i in 1:n_samples
            sum(@view ord_mat[i, :]) > 0.0 || throw(ArgumentError(
                "Sample '$(s_ids[i])' has zero total abundance; CCA chi-square weights are undefined on empty samples"))
        end
    else
        # rda(euclidean) or cap/dbrda(bray, jaccard, euclidean)
        n_features >= 2 || throw(ArgumentError(
            "Constrained ordination requires at least 2 features (got $n_features)"))
        btrans = lowercase(strip(String(beta_transform)))
        if btrans != "none"
            all(>=(0.0), ord_mat) || throw(ArgumentError(
                "Beta transform '$btrans' requires non-negative counts"))
            ord_mat = transform_counts(ord_mat; method=btrans)
        elseif cfg.ordination_method === :rda && all(>=(0.0), ord_mat) && any(==(0.0), ord_mat)
            push!(cautions,
                "Linear Euclidean RDA on untransformed sparse counts is sensitive to library-size differences and shared zeros (Legendre & Gallagher 2001; Gloor et al. 2017); consider distance='aitchison' (CLR) or Hellinger beta normalisation.")
        end
        if cfg.ordination_distance in (:bray, :jaccard)
            all(>=(0.0), ord_mat) || throw(ArgumentError(
                "Dissimilarity '$(cfg.ordination_distance)' requires non-negative abundances"))
            for i in 1:n_samples
                sum(@view ord_mat[i, :]) > 0.0 || throw(ArgumentError(
                    "Sample '$(s_ids[i])' has zero total abundance; '$(cfg.ordination_distance)' is undefined on empty samples"))
            end
        end
    end

    can_varpart_r = cfg.variance_partitioning &&
                    (2 <= length(parsed.constrained_terms) <= 4) &&
                    isempty(parsed.condition_terms)

    r_out = with_r_lock(; timeout=Float64(r_timeout)) do
        RCall.rcopy(RCall.reval("requireNamespace('vegan', quietly = TRUE)")) || throw(VeganUnavailable())
        RCall.reval("suppressPackageStartupMessages(library(vegan))")

        RCall.globalEnv[:ord_method]      = string(cfg.ordination_method)
        RCall.globalEnv[:ord_distance]    = string(cfg.ordination_distance)
        RCall.globalEnv[:ord_use_dist]    = use_dist
        RCall.globalEnv[:ord_mat]         = ord_mat
        RCall.globalEnv[:ord_dist_mat]    = dist_mat_r
        RCall.globalEnv[:ord_sample_ids]  = s_ids
        RCall.globalEnv[:ord_feature_ids] = kept_feature_ids
        RCall.globalEnv[:ord_meta]        = r_meta
        RCall.globalEnv[:ord_factor_cols] = factor_cols
        RCall.globalEnv[:ord_formula_rhs] = parsed.canonical_rhs
        RCall.globalEnv[:ord_scaling]     = cfg.ordination_scaling
        RCall.globalEnv[:ord_nperm]       = cfg.permutations
        RCall.globalEnv[:ord_seed]        = cfg.seed
        RCall.globalEnv[:ord_blocks]      = blocked ? String.(blocks) : String[]
        RCall.globalEnv[:ord_test_margin] = length(parsed.constrained_terms) >= 2
        RCall.globalEnv[:ord_test_axes]   = test_axes
        RCall.globalEnv[:ord_do_varpart]  = can_varpart_r
        RCall.globalEnv[:ord_vp_terms]    = parsed.constrained_terms
        try
            RCall.reval(_ORD_R)
            (;
                vegan_version = String(RCall.rcopy(RCall.reval("ord_vegan_ver"))),
                tot_chi       = Float64(RCall.rcopy(RCall.reval("ord_tot_chi"))),
                cond_chi      = Float64(RCall.rcopy(RCall.reval("ord_cond_chi"))),
                cca_chi       = Float64(RCall.rcopy(RCall.reval("ord_cca_chi"))),
                ca_chi        = Float64(RCall.rcopy(RCall.reval("ord_ca_chi"))),
                imag_chi      = Float64(RCall.rcopy(RCall.reval("ord_imag_chi"))),
                cca_eig       = _as_f64_vec(RCall.rcopy(RCall.reval("ord_cca_eig"))),
                cca_names     = _as_str_vec(RCall.rcopy(RCall.reval("ord_cca_names"))),
                ca_eig        = _as_f64_vec(RCall.rcopy(RCall.reval("ord_ca_eig"))),
                ca_names      = _as_str_vec(RCall.rcopy(RCall.reval("ord_ca_names"))),
                r2            = _num_or_nothing(RCall.rcopy(RCall.reval("ord_r2"))),
                adj_r2        = _num_or_nothing(RCall.rcopy(RCall.reval("ord_adj_r2"))),
                site_scores   = Matrix{Float64}(RCall.rcopy(RCall.reval("ord_site_scores"))),
                axis_names    = _as_str_vec(RCall.rcopy(RCall.reval("ord_axis_names"))),
                bp_scores     = Matrix{Float64}(RCall.rcopy(RCall.reval("ord_bp_scores"))),
                bp_names      = _as_str_vec(RCall.rcopy(RCall.reval("ord_bp_names"))),
                cn_scores     = Matrix{Float64}(RCall.rcopy(RCall.reval("ord_cn_scores"))),
                cn_names      = _as_str_vec(RCall.rcopy(RCall.reval("ord_cn_names"))),
                sp_scores     = Matrix{Float64}(RCall.rcopy(RCall.reval("ord_sp_scores"))),
                sp_names      = _as_str_vec(RCall.rcopy(RCall.reval("ord_sp_names"))),
                aov_overall   = RCall.rcopy(RCall.reval("ord_aov_overall")),
                aov_terms     = RCall.rcopy(RCall.reval("ord_aov_terms")),
                aov_margin    = RCall.rcopy(RCall.reval("ord_aov_margin")),
                aov_axes      = RCall.rcopy(RCall.reval("ord_aov_axes")),
                vp_ok         = Bool(RCall.rcopy(RCall.reval("ord_vp_ok"))),
                vp_ind_labels = _as_str_vec(RCall.rcopy(RCall.reval("ord_vp_ind_labels"))),
                vp_ind_df     = _as_int_vec(RCall.rcopy(RCall.reval("ord_vp_ind_df"))),
                vp_ind_r2     = _as_any_vec(RCall.rcopy(RCall.reval("ord_vp_ind_r2"))),
                vp_ind_adj    = _as_any_vec(RCall.rcopy(RCall.reval("ord_vp_ind_adj"))),
                vp_ind_test   = _as_bool_vec(RCall.rcopy(RCall.reval("ord_vp_ind_testable"))),
                vp_gr_labels  = _as_str_vec(RCall.rcopy(RCall.reval("ord_vp_gross_labels"))),
                vp_gr_df      = _as_int_vec(RCall.rcopy(RCall.reval("ord_vp_gross_df"))),
                vp_gr_r2      = _as_any_vec(RCall.rcopy(RCall.reval("ord_vp_gross_r2"))),
                vp_gr_adj     = _as_any_vec(RCall.rcopy(RCall.reval("ord_vp_gross_adj"))),
                vp_err        = String(RCall.rcopy(RCall.reval("ord_vp_err"))),
            )
        finally
            RCall.reval(_ORD_CLEANUP_R)
        end
    end

    if abs(r_out.imag_chi) > 0.0 && r_out.tot_chi > 0.0 && (abs(r_out.imag_chi) / r_out.tot_chi) > 0.05
        pct = round(100.0 * abs(r_out.imag_chi) / r_out.tot_chi; digits=1)
        push!(cautions,
            "Non-Euclidean dissimilarity produced negative eigenvalues ($(pct)% of total inertia); biplot axes display the real Euclidean subspace.")
    end

    push!(cautions,
        "Constrained ordination axes maximise variance aligned with the supplied covariates; interpret biplots alongside permutation F/p-values and residual unconstrained inertia rather than reading clustering alone as confirmatory proof.")

    tot = r_out.tot_chi
    prop_of_tot(x::Float64) = tot > 0.0 ? (x / tot) : 0.0

    constrained_eigs = [
        (; axis = r_out.cca_names[i],
           eigenvalue = r_out.cca_eig[i],
           proportion_total = prop_of_tot(r_out.cca_eig[i]),
           proportion_constrained = r_out.cca_chi > 0.0 ? (r_out.cca_eig[i] / r_out.cca_chi) : 0.0)
        for i in eachindex(r_out.cca_eig)
    ]
    unconstrained_eigs = [
        (; axis = r_out.ca_names[i],
           eigenvalue = r_out.ca_eig[i],
           proportion_total = prop_of_tot(r_out.ca_eig[i]))
        for i in eachindex(r_out.ca_eig)
    ]

    eig_lookup = Dict{String,Float64}()
    for e in constrained_eigs
        eig_lookup[e.axis] = e.proportion_total
    end
    for e in unconstrained_eigs
        eig_lookup[e.axis] = e.proportion_total
    end

    axis_labels = [
        let ax = r_out.axis_names[k]
            if haskey(eig_lookup, ax)
                pct = round(100.0 * max(0.0, eig_lookup[ax]); digits=1)
                kind = any(e -> e.axis == ax, constrained_eigs) ? "constrained" : "unconstrained"
                "$ax ($pct%, $kind)"
            else
                ax
            end
        end
        for k in 1:2
    ]

    overall_parsed = _parse_aov_list(r_out.aov_overall, Set{String}())
    terms_parsed   = _parse_aov_list(r_out.aov_terms, untestable_set)
    margin_parsed  = _parse_aov_list(r_out.aov_margin, untestable_set)
    axes_parsed    = _parse_aov_list(r_out.aov_axes, Set{String}())

    overall_untestable = blocked && !isempty(parsed.constrained_terms) &&
                         all(t -> t in untestable_set, parsed.constrained_terms)
    overall_row = isempty(overall_parsed.rows) ? nothing : overall_parsed.rows[1]
    actual_nperm = overall_parsed.nperm
    min_p = 1.0 / (actual_nperm + 1)

    omnibus = (;
        df_model = isnothing(overall_row) ? parsed.df_constrained : overall_row.df,
        df_residual = overall_parsed.residual_df,
        variance_model = isnothing(overall_row) ? r_out.cca_chi : overall_row.variance,
        variance_residual = overall_parsed.residual_variance,
        f_statistic = isnothing(overall_row) ? nothing : overall_row.f_statistic,
        p_value = (isnothing(overall_row) || overall_untestable) ? nothing : overall_row.p_value,
        untestable_reason = overall_untestable ?
            "All constraining covariates are constant within every permutation block, so within-block permutations cannot test the model" :
            nothing,
        permutations = actual_nperm,
        min_p_value = min_p,
        text = overall_parsed.text,
    )

    site_rows = [
        (; sample = s_ids[i],
           axis1 = r_out.site_scores[i, 1],
           axis2 = r_out.site_scores[i, 2])
        for i in 1:n_samples
    ]

    biplot_arrows = [
        let x = r_out.bp_scores[i, 1], y = r_out.bp_scores[i, 2]
            (; label = r_out.bp_names[i],
               axis1 = x,
               axis2 = y,
               length = sqrt(x * x + y * y))
        end
        for i in eachindex(r_out.bp_names)
    ]

    centroids = [
        (; label = r_out.cn_names[i],
           axis1 = r_out.cn_scores[i, 1],
           axis2 = r_out.cn_scores[i, 2])
        for i in eachindex(r_out.cn_names)
    ]

    all_feature_rows = [
        let x = r_out.sp_scores[i, 1], y = r_out.sp_scores[i, 2]
            (; feature = r_out.sp_names[i],
               axis1 = x,
               axis2 = y,
               length = sqrt(x * x + y * y))
        end
        for i in eachindex(r_out.sp_names)
    ]
    sort!(all_feature_rows; by = r -> (-r.length, r.feature))
    top_features = all_feature_rows[1:min(Int(max_feature_scores), length(all_feature_rows))]

    varpart_result = if !cfg.variance_partitioning
        nothing
    elseif can_varpart_r && r_out.vp_ok
        ind_rows = [
            (; label = strip(r_out.vp_ind_labels[i]),
               df = r_out.vp_ind_df[i],
               r2 = _num_or_nothing(r_out.vp_ind_r2[i]),
               adj_r2 = _num_or_nothing(r_out.vp_ind_adj[i]),
               testable = r_out.vp_ind_test[i])
            for i in eachindex(r_out.vp_ind_labels)
        ]
        gr_rows = [
            (; label = strip(r_out.vp_gr_labels[i]),
               df = r_out.vp_gr_df[i],
               r2 = _num_or_nothing(r_out.vp_gr_r2[i]),
               adj_r2 = _num_or_nothing(r_out.vp_gr_adj[i]))
            for i in eachindex(r_out.vp_gr_labels)
        ]
        has_neg = any(r -> !isnothing(r.adj_r2) && r.adj_r2 < -1e-6, ind_rows)
        vp_note = has_neg ?
            "Adjusted-R2 subtraction produced small negative fraction(s); per Peres-Neto et al. (2006), negative fractions indicate predictors explaining less variance than random normal variates (or suppressor effects) and are reported unclamped so fractions sum to 1." :
            "Adjusted-R2 variance partitioning (vegan::varpart; Peres-Neto et al. 2006). Shared overlap fractions have 0 df and cannot be tested individually by permutation."
        (; status = "computed",
           covariates = copy(parsed.constrained_terms),
           conditioned_on = String[],
           individual_fractions = ind_rows,
           gross_fractions = gr_rows,
           has_negative_fraction = has_neg,
           note = vp_note)
    elseif !isempty(parsed.condition_terms) && length(parsed.constrained_terms) == 2
        # Partial 2-way decomposition conditioned on Condition(...)
        t1, t2 = parsed.constrained_terms[1], parsed.constrained_terms[2]
        cond_str = "Condition(" * join(parsed.condition_terms, " + ") * ")"
        cfg_sub1 = OrdinationConfig(;
            ordination_method = cfg.ordination_method,
            ordination_formula = "~ $t1 + $cond_str",
            ordination_distance = cfg.ordination_distance,
            ordination_scaling = cfg.ordination_scaling,
            permutations = cfg.permutations,
            variance_partitioning = false,
            replacement_method = cfg.replacement_method,
            replacement_delta = cfg.replacement_delta,
            seed = cfg.seed,
        )
        cfg_sub2 = OrdinationConfig(;
            ordination_method = cfg.ordination_method,
            ordination_formula = "~ $t2 + $cond_str",
            ordination_distance = cfg.ordination_distance,
            ordination_scaling = cfg.ordination_scaling,
            permutations = cfg.permutations,
            variance_partitioning = false,
            replacement_method = cfg.replacement_method,
            replacement_delta = cfg.replacement_delta,
            seed = cfg.seed,
        )
        sub1 = run_constrained_ordination(counts, metadata, cfg_sub1;
            sample_ids=s_ids, feature_ids=f_ids, beta_transform, distance_matrix, tree, blocks, r_timeout)
        sub2 = run_constrained_ordination(counts, metadata, cfg_sub2;
            sample_ids=s_ids, feature_ids=f_ids, beta_transform, distance_matrix, tree, blocks, r_timeout)
        if !isnothing(sub1.adj_r2) && !isnothing(sub2.adj_r2) && !isnothing(r_out.adj_r2)
            vp2 = pure_varpart_two_way(sub1.adj_r2, sub2.adj_r2, r_out.adj_r2)
            ind_rows = [
                (; label = "[a] = $t1 | $t2", df = _term_df(t1, metadata), r2 = nothing, adj_r2 = vp2.unique_x1, testable = true),
                (; label = "[b] = Shared ($t1 & $t2)", df = 0, r2 = nothing, adj_r2 = vp2.shared, testable = false),
                (; label = "[c] = $t2 | $t1", df = _term_df(t2, metadata), r2 = nothing, adj_r2 = vp2.unique_x2, testable = true),
                (; label = "[d] = Residuals incl. conditioned share", df = omnibus.df_residual, r2 = nothing, adj_r2 = vp2.residual, testable = false),
            ]
            has_neg = any(r -> !isnothing(r.adj_r2) && r.adj_r2 < -1e-6, ind_rows)
            (; status = "computed",
               covariates = copy(parsed.constrained_terms),
               conditioned_on = copy(parsed.condition_terms),
               individual_fractions = ind_rows,
               gross_fractions = [
                   (; label = "[a+b] = $t1", df = _term_df(t1, metadata), r2 = sub1.r2, adj_r2 = sub1.adj_r2),
                   (; label = "[b+c] = $t2", df = _term_df(t2, metadata), r2 = sub2.r2, adj_r2 = sub2.adj_r2),
                   (; label = "[a+b+c] = $t1 + $t2", df = omnibus.df_model, r2 = r_out.r2, adj_r2 = r_out.adj_r2),
               ],
               has_negative_fraction = has_neg,
               note = "Partial adjusted-R2 variance partitioning conditioned on $(join(parsed.condition_terms, ", ")).")
        else
            (; status = "skipped",
               reason = "Adjusted R2 could not be computed for partial sub-models",
               covariates = copy(parsed.constrained_terms),
               conditioned_on = copy(parsed.condition_terms),
               individual_fractions = NamedTuple[],
               gross_fractions = NamedTuple[],
               has_negative_fraction = false,
               note = nothing)
        end
    else
        why = if length(parsed.constrained_terms) < 2
            "Variance partitioning requires 2 to 4 constraining terms in the formula (got $(length(parsed.constrained_terms)): $(join(parsed.constrained_terms, ", ")))"
        elseif length(parsed.constrained_terms) > 4
            "vegan::varpart supports up to 4 constraining tables (got $(length(parsed.constrained_terms)))"
        elseif !isempty(r_out.vp_err)
            "vegan::varpart could not partition this model: $(r_out.vp_err)"
        else
            "Partial variance partitioning with Condition(...) currently supports 2 constraining terms (got $(length(parsed.constrained_terms)))"
        end
        (; status = "skipped",
           reason = why,
           covariates = copy(parsed.constrained_terms),
           conditioned_on = copy(parsed.condition_terms),
           individual_fractions = NamedTuple[],
           gross_fractions = NamedTuple[],
           has_negative_fraction = false,
           note = nothing)
    end

    provenance = Dict{String,Any}(
        "method" => string(cfg.ordination_method),
        "distance" => string(cfg.ordination_distance),
        "scaling" => cfg.ordination_scaling,
        "scaling_meaning" => cfg.ordination_scaling == 1 ? "distance" : "correlation",
        "formula" => "~ " * parsed.canonical_rhs,
        "constrained_terms" => copy(parsed.constrained_terms),
        "condition_terms" => copy(parsed.condition_terms),
        "permutations_requested" => cfg.permutations,
        "permutations_performed" => actual_nperm,
        "seed" => cfg.seed,
        "rng_kind" => "R Mersenne-Twister / Inversion / Rejection",
        "blocked" => blocked,
        "beta_normalisation" => lowercase(strip(String(beta_transform))),
        "n_samples" => n_samples,
        "n_features" => length(kept_feature_ids),
        "dropped_zero_features" => dropped_zero_features,
        "zero_replacement" => zero_replacement_info,
        "multiple_testing_policy" => "omnibus_and_term_permutation_unadjusted; per_taxon_tests_require_bh",
        "software" => Dict{String,Any}(
            "r_package" => "vegan",
            "vegan_version" => r_out.vegan_version,
        ),
    )

    (;
        method = string(cfg.ordination_method),
        distance = string(cfg.ordination_distance),
        scaling = cfg.ordination_scaling,
        formula = "~ " * parsed.canonical_rhs,
        constrained_terms = copy(parsed.constrained_terms),
        condition_terms = copy(parsed.condition_terms),
        n_samples = n_samples,
        n_features = length(kept_feature_ids),
        total_inertia = r_out.tot_chi,
        conditioned_inertia = r_out.cond_chi,
        constrained_inertia = r_out.cca_chi,
        unconstrained_inertia = r_out.ca_chi,
        imaginary_inertia = r_out.imag_chi,
        conditioned_proportion = prop_of_tot(r_out.cond_chi),
        constrained_proportion = prop_of_tot(r_out.cca_chi),
        unconstrained_proportion = prop_of_tot(r_out.ca_chi),
        r2 = r_out.r2,
        adj_r2 = r_out.adj_r2,
        axis_names = copy(r_out.axis_names),
        axis_labels = axis_labels,
        constrained_eigenvalues = constrained_eigs,
        unconstrained_eigenvalues = unconstrained_eigs,
        site_scores = r_out.site_scores,
        sites = site_rows,
        biplot_arrows = biplot_arrows,
        centroids = centroids,
        top_feature_scores = top_features,
        all_feature_scores = all_feature_rows,
        omnibus_test = omnibus,
        term_tests = terms_parsed.rows,
        marginal_tests = margin_parsed.rows,
        axis_tests = axes_parsed.rows,
        variance_partitioning = varpart_result,
        cautions = cautions,
        provenance = provenance,
    )
end

## Plotly Biplot Builder

const _BIPLOT_PALETTE = [
    "#2563eb", "#dc2626", "#16a34a", "#d97706", "#7c3aed",
    "#0891b2", "#db2777", "#65a30d", "#ea580c", "#4f46e5",
]

const _BIPLOT_SYMBOLS = [
    "circle", "square", "diamond", "triangle-up", "triangle-down",
    "pentagon", "hexagon", "star", "cross", "x",
]

"""Scale the longest arrow to `fill_frac` of the largest site radius; return 1 for empty arrows or zero radii."""
function _arrow_multiplier(site_scores::Matrix{Float64}, arrows::AbstractVector; fill_frac::Float64 = 0.78)::Float64
    isempty(arrows) && return 1.0
    max_site = 0.0
    for i in axes(site_scores, 1)
        r = hypot(site_scores[i, 1], site_scores[i, 2])
        r > max_site && (max_site = r)
    end
    max_arrow = 0.0
    for a in arrows
        r = hypot(Float64(a.axis1), Float64(a.axis2))
        r > max_arrow && (max_arrow = r)
    end
    (max_site <= 0.0 || max_arrow <= 0.0) && return 1.0
    fill_frac * (max_site / max_arrow)
end

"""
    ordination_biplot_chart(ord_result; colour_by=nothing, shape_by=nothing, show_centroids=true, show_features=false, max_features=8) -> Dict{String,Any}

Build an interactive, I-JSON-compliant Plotly biplot dictionary showing sample
points (coloured by `colour_by`, shaped by `shape_by`), covariate arrows scaled
to the sample radii, optional factor centroids, and optional top taxon vectors.
Use a result from `run_constrained_ordination`; grouping labels follow site
order and mismatched lengths raise `ArgumentError`. Feature overlays use up to
`max_features` entries from `top_feature_scores`. Return `data` and `layout`
without changing the result or rendering a chart.
"""
function ordination_biplot_chart(
    ord_result;
    colour_by::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    shape_by::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    show_centroids::Bool = true,
    show_features::Bool = false,
    max_features::Integer = 8,
)::Dict{String,Any}
    coords = ord_result.site_scores
    labels = [s.sample for s in ord_result.sites]
    n = size(coords, 1)

    cb = isnothing(colour_by) ? fill("Samples", n) : String.(colour_by)
    sb = isnothing(shape_by)  ? fill("all", n)     : String.(shape_by)
    length(cb) == n || throw(ArgumentError("colour_by length ($(length(cb))) != sample count ($n)"))
    length(sb) == n || throw(ArgumentError("shape_by length ($(length(sb))) != sample count ($n)"))

    cgroups = unique(cb)
    sgroups = unique(sb)

    traces = Dict{String,Any}[]
    for (ci, cg) in enumerate(cgroups)
        col_hex = _BIPLOT_PALETTE[mod1(ci, length(_BIPLOT_PALETTE))]
        for (si, sg) in enumerate(sgroups)
            idxs = [i for i in 1:n if cb[i] == cg && sb[i] == sg]
            isempty(idxs) && continue
            same_label = cg == sg
            trace_name = length(sgroups) <= 1 ? cg : (same_label ? cg : "$cg / $sg")
            sym = _BIPLOT_SYMBOLS[mod1(si, length(_BIPLOT_SYMBOLS))]
            push!(traces, Dict{String,Any}(
                "type" => "scatter",
                "mode" => "markers",
                "name" => trace_name,
                "legendgroup" => trace_name,
                "x" => Float64[coords[i, 1] for i in idxs],
                "y" => Float64[coords[i, 2] for i in idxs],
                "text" => String[labels[i] for i in idxs],
                "hovertemplate" => "Sample: %{text}<br>Group: " * trace_name *
                                   "<br>%{xaxis.title.text}: %{x:.4f}<br>%{yaxis.title.text}: %{y:.4f}<extra></extra>",
                "marker" => Dict{String,Any}(
                    "color" => col_hex,
                    "size" => 10,
                    "symbol" => sym,
                    "line" => Dict{String,Any}("color" => "#ffffff", "width" => 1),
                ),
            ))
        end
    end

    if show_centroids && !isempty(ord_result.centroids)
        push!(traces, Dict{String,Any}(
            "type" => "scatter",
            "mode" => "markers+text",
            "name" => "Factor centroids",
            "legendgroup" => "__centroids__",
            "x" => Float64[c.axis1 for c in ord_result.centroids],
            "y" => Float64[c.axis2 for c in ord_result.centroids],
            "text" => String[c.label for c in ord_result.centroids],
            "textposition" => "top center",
            "hovertemplate" => "Centroid: %{text}<br>(%{x:.4f}, %{y:.4f})<extra></extra>",
            "marker" => Dict{String,Any}(
                "color" => "#111827",
                "size" => 11,
                "symbol" => "diamond-open",
                "line" => Dict{String,Any}("color" => "#111827", "width" => 2),
            ),
        ))
    end

    annotations = Dict{String,Any}[]
    mult = _arrow_multiplier(coords, ord_result.biplot_arrows)
    for arr in ord_result.biplot_arrows
        ax = arr.axis1 * mult
        ay = arr.axis2 * mult
        # Arrow annotation from origin (0, 0) to scaled tip (ax, ay)
        push!(annotations, Dict{String,Any}(
            "x" => ax,
            "y" => ay,
            "ax" => 0.0,
            "ay" => 0.0,
            "xref" => "x",
            "yref" => "y",
            "axref" => "x",
            "ayref" => "y",
            "text" => "",
            "showarrow" => true,
            "arrowhead" => 2,
            "arrowsize" => 1.1,
            "arrowwidth" => 2.0,
            "arrowcolor" => "#991b1b",
        ))
        # Label slightly beyond tip
        push!(annotations, Dict{String,Any}(
            "x" => ax * 1.08,
            "y" => ay * 1.08,
            "xref" => "x",
            "yref" => "y",
            "text" => "<b>$(arr.label)</b>",
            "showarrow" => false,
            "font" => Dict{String,Any}("size" => 11, "color" => "#991b1b"),
        ))
    end

    if !isempty(ord_result.biplot_arrows)
        # Invisible hover markers on arrow tips so exact unscaled biplot cosines remain inspectable
        push!(traces, Dict{String,Any}(
            "type" => "scatter",
            "mode" => "markers",
            "name" => "Covariate vectors",
            "legendgroup" => "__covariates__",
            "x" => Float64[a.axis1 * mult for a in ord_result.biplot_arrows],
            "y" => Float64[a.axis2 * mult for a in ord_result.biplot_arrows],
            "text" => String[a.label for a in ord_result.biplot_arrows],
            "customdata" => Vector{Float64}[[a.axis1, a.axis2] for a in ord_result.biplot_arrows],
            "hovertemplate" => "Covariate: %{text}<br>Biplot score: (%{customdata[0]:.4f}, %{customdata[1]:.4f})<extra></extra>",
            "marker" => Dict{String,Any}("color" => "#991b1b", "size" => 6, "symbol" => "circle-open"),
        ))
    end

    if show_features && !isempty(ord_result.top_feature_scores)
        feats = ord_result.top_feature_scores[1:min(Int(max_features), length(ord_result.top_feature_scores))]
        f_mult = _arrow_multiplier(coords, feats; fill_frac=0.65)
        push!(traces, Dict{String,Any}(
            "type" => "scatter",
            "mode" => "markers+text",
            "name" => "Top feature loadings",
            "legendgroup" => "__features__",
            "x" => Float64[f.axis1 * f_mult for f in feats],
            "y" => Float64[f.axis2 * f_mult for f in feats],
            "text" => String[f.feature for f in feats],
            "textposition" => "bottom center",
            "customdata" => Vector{Float64}[[f.axis1, f.axis2] for f in feats],
            "hovertemplate" => "Feature: %{text}<br>Score: (%{customdata[0]:.4f}, %{customdata[1]:.4f})<extra></extra>",
            "marker" => Dict{String,Any}("color" => "#475569", "size" => 6, "symbol" => "triangle-up-open"),
            "textfont" => Dict{String,Any}("size" => 10, "color" => "#475569"),
        ))
    end

    r2_txt = isnothing(ord_result.r2) ? "n/a" : string(round(ord_result.r2; digits=3))
    adj_txt = isnothing(ord_result.adj_r2) ? "n/a" : string(round(ord_result.adj_r2; digits=3))
    p_txt = isnothing(ord_result.omnibus_test.p_value) ? "withheld" :
            string(round(ord_result.omnibus_test.p_value; digits=4))
    summary_badge = "$(uppercase(ord_result.method)) ($(ord_result.distance), scaling $(ord_result.scaling)) · R²=$r2_txt, adj. R²=$adj_txt, p=$p_txt"

    push!(annotations, Dict{String,Any}(
        "text" => summary_badge,
        "xref" => "paper",
        "yref" => "paper",
        "x" => 0.01,
        "y" => 0.99,
        "xanchor" => "left",
        "yanchor" => "top",
        "showarrow" => false,
        "font" => Dict{String,Any}("size" => 11, "color" => "#334155"),
    ))

    method_upper = ord_result.method == "dbrda" ? "dbRDA" : uppercase(ord_result.method)
    layout = Dict{String,Any}(
        "title" => Dict{String,Any}("text" => "$method_upper constrained ordination ($(ord_result.formula))"),
        "xaxis" => Dict{String,Any}("title" => ord_result.axis_labels[1], "zeroline" => true, "zerolinecolor" => "#cbd5e1"),
        "yaxis" => Dict{String,Any}("title" => ord_result.axis_labels[2], "zeroline" => true, "zerolinecolor" => "#cbd5e1"),
        "annotations" => annotations,
    )

    Dict{String,Any}("data" => traces, "layout" => layout)
end

end # module Ordination
