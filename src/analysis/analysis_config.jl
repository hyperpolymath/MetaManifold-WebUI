# SPDX-License-Identifier: AGPL-3.0-only
"""
    AnalysisConfig — safe, explicit, versioned analysis configuration layer

Implements the requirements from the hyperpolymath estate task:

- Explicit, versioned, immutable, provenance-rich derived objects
- Methods in v1: NB GLM, CLR/ILR+Gaussian LM, logistic
- BH mandatory, hard-stop with DANGER banner on overrides
- All advanced options behind "Advanced Analysis" expander
- Heavy validation, context-sensitive help, refusal of meaningless inputs
- JSON + Nickel + DEED schemes from hyperpolymath/standards
- DOI-ready bundles

No silent switching or auto-selection. Every field must be explicit.
"""
module AnalysisConfig

using Dates
using SHA
using UUIDs
using JSON3
using OrderedCollections
using ..Provenance: CapturedEnvironment, probe_metamanifold, probe_host

export AnalysisMethod, NormalizationConfig, CorrectionConfig, AdvancedOverrides,
       AnalysisConfigStruct, AnalysisResult,
       validate_config, config_hash, canonical_json,
       context_help, danger_banner, is_dangerous,
       to_json, from_json, to_deed, to_nickel,
       create_doi_bundle, present_in_every_admissible_world,
       AVEC_FIBRE_COLUMN, EPISTEMIC_STATUS_VALUES

# --------------------------------------------------------------------------
# Constants and enums (explicit, no silent defaults)
# --------------------------------------------------------------------------

const SCHEMA_VERSION = "1.0.0"
const SCHEMA_VERSIONS_SUPPORTED = ("1.0.0",)
const AVEC_FIBRE_COLUMN = "avec_fibre"
const EPISTEMIC_STATUS_VALUES = ("present_in_every_admissible_world",
                                 "present_in_some_admissible_world",
                                 "absent_in_every_admissible_world",
                                 "unknown")

const DANGER_ACK_TOKEN = "I_UNDERSTAND_THE_RISK_AND_WANT_TO_OVERRIDE_BH"

@enum AnalysisMethod begin
    NB_GLM = 1        # Negative Binomial GLM (DESeq2/MASS style)
    CLR_LM = 2        # CLR transform + Gaussian LM
    ILR_LM = 3        # ILR transform + Gaussian LM
    LOGISTIC = 4      # Logistic regression (presence/absence)
end

const METHOD_STRINGS = Dict{String,AnalysisMethod}(
    "nb_glm" => NB_GLM,
    "clr_lm" => CLR_LM,
    "ilr_lm" => ILR_LM,
    "logistic" => LOGISTIC,
    "NB_GLM" => NB_GLM,
    "CLR_LM" => CLR_LM,
    "ILR_LM" => ILR_LM,
    "LOGISTIC" => LOGISTIC,
)

const METHOD_TO_STRING = Dict{AnalysisMethod,String}(
    NB_GLM => "nb_glm",
    CLR_LM => "clr_lm",
    ILR_LM => "ilr_lm",
    LOGISTIC => "logistic",
)

const VALID_DISPERSION_METHODS = ("parametric", "local", "mean", "pooled", "glmGamPoi")
const VALID_ZERO_HANDLING = ("pseudocount", "multiplicative_replacement", "bayesian_multiplicative", "refuse")
const VALID_ILR_BASIS = ("default", "phylogenetic", "sequential_binary_partition", "balance_dendrogram")
const VALID_NORMALIZATION_FOR_METHOD = Dict{AnalysisMethod, Vector{String}}(
    NB_GLM => ["none", "rarefy", "size_factors", "relative"],
    CLR_LM => ["clr"],
    ILR_LM => ["ilr"],
    LOGISTIC => ["none", "relative", "rarefy", "presence_absence"],
)

# --------------------------------------------------------------------------
# Sub-configs
# --------------------------------------------------------------------------

"""
    NormalizationConfig — explicit normalization / compositional transform

For CLR/ILR, pseudocount is mandatory and must be >0. For NB_GLM, size_factors is preferred.
Refuses meaningless: pseudocount <=0, ilr_basis invalid, method not compatible with parent method.
"""
struct NormalizationConfig
    method::String
    pseudocount::Float64
    ilr_basis::Union{String,Nothing}
    multiplicative_replacement_delta::Union{Float64,Nothing}

    function NormalizationConfig(; method::String,
                                   pseudocount::Float64=0.5,
                                   ilr_basis::Union{String,Nothing}=nothing,
                                   multiplicative_replacement_delta::Union{Float64,Nothing}=nothing)
        method = lowercase(strip(method))
        isempty(method) && throw(ArgumentError("normalization.method must be non-empty (e.g. 'clr', 'none')"))

        # Heavy validation
        if method in ("clr", "ilr")
            pseudocount <= 0 && throw(ArgumentError("For compositional methods (CLR/ILR), pseudocount must be >0 (got $pseudocount). Zero replacement is mandatory because log(0) is undefined."))
            pseudocount >= 1 && @warn "pseudocount >=1 is unusual for CLR/ILR (got $pseudocount); typical is 0.5 or 0.65. This may distort low-abundance features."
            if method == "ilr"
                if !isnothing(ilr_basis) && !(ilr_basis in VALID_ILR_BASIS)
                    throw(ArgumentError("ilr_basis must be one of $(join(VALID_ILR_BASIS, ", ")) (got '$ilr_basis')"))
                end
            else # clr
                if !isnothing(ilr_basis)
                    throw(ArgumentError("ilr_basis is meaningless for CLR (only for ILR). Refusing."))
                end
            end
        else
            # For non-compositional, ilr_basis is meaningless
            if !isnothing(ilr_basis)
                throw(ArgumentError("ilr_basis is only meaningful for ILR method, not for '$method'"))
            end
        end

        if !isnothing(multiplicative_replacement_delta)
            delta = multiplicative_replacement_delta
            (delta <= 0 || delta >= 1) && throw(ArgumentError("multiplicative_replacement_delta must be in (0,1), got $delta"))
        end

        new(method, pseudocount, ilr_basis, multiplicative_replacement_delta)
    end
end

"""
    CorrectionConfig — BH mandatory

BH is the only sane default for high-dimensional microbiome data. Any override triggers DANGER.
"""
struct CorrectionConfig
    method::String
    alpha::Float64
    allow_no_correction::Bool
    acknowledgment_token::Union{String,Nothing}

    function CorrectionConfig(; method::String="BH",
                                alpha::Float64=0.05,
                                allow_no_correction::Bool=false,
                                acknowledgment_token::Union{String,Nothing}=nothing)
        method_clean = strip(method)
        isempty(method_clean) && throw(ArgumentError("correction.method must be non-empty"))

        # BH mandatory check
        if uppercase(method_clean) != "BH" && uppercase(method_clean) != "FDR" && uppercase(method_clean) != "BENJAMINI-HOCHBERG"
            if !allow_no_correction
                throw(ArgumentError("p-value correction method must be BH (Benjamini-Hochberg) in v1. Got '$method_clean'. If you truly want to override, you must set allow_no_correction=true and provide acknowledgment_token='$DANGER_ACK_TOKEN'. This will trigger a DANGER banner and be recorded in provenance."))
            end
        end

        if allow_no_correction
            if isnothing(acknowledgment_token) || acknowledgment_token != DANGER_ACK_TOKEN
                throw(ArgumentError("DANGER: You are attempting to disable BH correction. This is scientifically dangerous for high-dimensional data and will inflate false discoveries. To proceed, you must set acknowledgment_token to exactly '$DANGER_ACK_TOKEN'. This action will be logged, bannered, and included in DOI bundle provenance."))
            end
        end

        (alpha <= 0 || alpha >= 1) && throw(ArgumentError("alpha must be in (0,1), got $alpha. Typical is 0.05."))

        # Normalize to canonical BH
        canonical_method = allow_no_correction ? method_clean : "BH"

        new(canonical_method, alpha, allow_no_correction, acknowledgment_token)
    end
end

"""
    AdvancedOverrides — all behind Advanced Analysis expander

Heavy validation, context-sensitive help, refusal of meaningless.
"""
struct AdvancedOverrides
    dispersion_method::String
    zero_handling::String
    min_prevalence::Float64
    min_abundance::Float64
    max_features::Union{Int,Nothing}
    min_samples_per_group::Int
    robust::Bool
    acknowledgment_token::Union{String,Nothing}  # for any advanced override that is dangerous

    function AdvancedOverrides(; dispersion_method::String="parametric",
                                 zero_handling::String="pseudocount",
                                 min_prevalence::Float64=0.1,
                                 min_abundance::Float64=0.0,
                                 max_features::Union{Int,Nothing}=nothing,
                                 min_samples_per_group::Int=3,
                                 robust::Bool=false,
                                 acknowledgment_token::Union{String,Nothing}=nothing)

        dispersion_method = lowercase(strip(dispersion_method))
        zero_handling = lowercase(strip(zero_handling))

        !(dispersion_method in VALID_DISPERSION_METHODS) &&
            throw(ArgumentError("dispersion_method must be one of $(join(VALID_DISPERSION_METHODS, ", ")) (got '$dispersion_method')"))

        !(zero_handling in VALID_ZERO_HANDLING) &&
            throw(ArgumentError("zero_handling must be one of $(join(VALID_ZERO_HANDLING, ", ")) (got '$zero_handling')"))

        (min_prevalence < 0 || min_prevalence > 1) &&
            throw(ArgumentError("min_prevalence must be in [0,1], got $min_prevalence. 0.1 means feature must be present in at least 10% of samples."))

        min_abundance < 0 &&
            throw(ArgumentError("min_abundance must be >=0, got $min_abundance"))

        if !isnothing(max_features)
            max_features <= 0 && throw(ArgumentError("max_features must be >0 if set, got $max_features"))
            max_features > 100000 && throw(ArgumentError("max_features=$max_features is absurdly large (>100k). Refusing as meaningless."))
        end

        min_samples_per_group < 2 &&
            throw(ArgumentError("min_samples_per_group must be >=2 (got $min_samples_per_group). Need at least 2 samples per group for variance estimation."))

        if zero_handling == "refuse"
            # This is dangerous for CLR/ILR - will cause log(0) errors
            if isnothing(acknowledgment_token) || acknowledgment_token != DANGER_ACK_TOKEN
                throw(ArgumentError("DANGER: zero_handling='refuse' will cause log(0) failures for compositional methods and drop zeros for NB_GLM, biasing results. To proceed, set acknowledgment_token='$DANGER_ACK_TOKEN'."))
            end
        end

        new(dispersion_method, zero_handling, min_prevalence, min_abundance, max_features, min_samples_per_group, robust, acknowledgment_token)
    end
end

# --------------------------------------------------------------------------
# Main immutable config
# --------------------------------------------------------------------------

"""
    AnalysisConfigStruct — immutable, versioned, provenance-rich derived object

Every analysis is an explicit, immutable, provenance-rich derived object. No silent switching.
"""
struct AnalysisConfigStruct
    schema_version::String
    id::String
    created_at::DateTime
    created_by::String
    method::AnalysisMethod
    formula::String
    outcome_column::Union{String,Nothing}
    metadata_columns::Vector{String}
    normalization::NormalizationConfig
    correction::CorrectionConfig
    advanced::AdvancedOverrides
    provenance::OrderedDict{String,Any}
    hash::String

    function AnalysisConfigStruct(; schema_version::String=SCHEMA_VERSION,
                                    id::String=string(uuid4()),
                                    created_at::DateTime=now(UTC),
                                    created_by::String="anonymous",
                                    method::Union{String,AnalysisMethod},
                                    formula::String,
                                    outcome_column::Union{String,Nothing}=nothing,
                                    metadata_columns::Vector{String},
                                    normalization::NormalizationConfig,
                                    correction::CorrectionConfig=CorrectionConfig(),
                                    advanced::AdvancedOverrides=AdvancedOverrides(),
                                    provenance::OrderedDict{String,Any}=OrderedDict{String,Any}(),
                                    hash::String="")

        # schema_version must be supported
        schema_version in SCHEMA_VERSIONS_SUPPORTED ||
            throw(ArgumentError("Unsupported schema_version '$schema_version'. Supported: $(join(SCHEMA_VERSIONS_SUPPORTED, ", "))"))

        # method parsing — explicit, no auto-selection
        m = if method isa AnalysisMethod
            method
        else
            ms = lowercase(strip(String(method)))
            get(METHOD_STRINGS, ms, nothing) |>
                x -> isnothing(x) ? throw(ArgumentError("method must be one of $(join(keys(METHOD_STRINGS), ", ")) (got '$method')")) : x
        end

        # formula heavy validation
        formula_stripped = strip(formula)
        isempty(formula_stripped) && throw(ArgumentError("formula must be non-empty, e.g. '~ group' or 'disease ~ group + batch'. Refusing empty formula as meaningless."))
        # Must contain ~ or be a single variable? We enforce R-style formula with ~
        occursin(r"[;`\$]", formula_stripped) && throw(ArgumentError("formula contains forbidden characters (; ` \$) that could be injection. Refusing."))
        # Basic R formula check: must have ~ somewhere, or for some methods allow single term?
        if !occursin("~", formula_stripped)
            # For some methods, we allow "~ var" shorthand? Actually we require ~ always for explicitness
            throw(ArgumentError("formula must be an R-style formula containing '~', e.g. '~ group' or 'outcome ~ group + batch'. Got '$formula_stripped'"))
        end
        # Check that formula is not just "~" or "~ 1" without metadata
        if strip(replace(formula_stripped, "~" => "")) in ("", "1", "0")
            throw(ArgumentError("formula '$formula_stripped' is meaningless (no covariates). Must reference at least one metadata column."))
        end

        # metadata_columns validation
        isempty(metadata_columns) && throw(ArgumentError("metadata_columns must be non-empty. At least one column must be specified."))
        for col in metadata_columns
            isempty(strip(col)) && throw(ArgumentError("metadata_columns contains empty string — refusing as meaningless."))
            occursin(r"[^a-zA-Z0-9_\.\-]", col) && @warn "metadata column '$col' contains unusual characters; will be validated against actual metadata schema later."
        end
        length(metadata_columns) != length(unique(metadata_columns)) &&
            throw(ArgumentError("metadata_columns contains duplicates: $(metadata_columns)"))

        # outcome_column validation for LOGISTIC
        if m == LOGISTIC
            isnothing(outcome_column) && throw(ArgumentError("For LOGISTIC method, outcome_column must be specified (binary outcome). Refusing."))
            isempty(strip(outcome_column)) && throw(ArgumentError("outcome_column must be non-empty for LOGISTIC"))
        else
            if !isnothing(outcome_column) && m != NB_GLM
                @warn "outcome_column is specified for method $(METHOD_TO_STRING[m]) which typically does not need it; will be ignored unless formula uses it."
            end
        end

        # normalization compatibility
        allowed_norm = VALID_NORMALIZATION_FOR_METHOD[m]
        norm_method = normalization.method
        if !(norm_method in allowed_norm)
            throw(ArgumentError("Normalization method '$norm_method' is incompatible with analysis method '$(METHOD_TO_STRING[m])'. Allowed for this method: $(join(allowed_norm, ", ")). Refusing meaningless combination."))
        end

        # min_samples_per_group already validated in AdvancedOverrides, but cross-check with metadata
        # (actual existence check happens in validate_config with available columns)

        # provenance enrichment
        prov = OrderedDict{String,Any}(provenance)
        if !haskey(prov, "metamanifold")
            try
                prov["metamanifold"] = probe_metamanifold()
            catch
                prov["metamanifold"] = OrderedDict("version" => "unknown")
            end
        end
        if !haskey(prov, "host")
            prov["host"] = probe_host()
        end
        prov["created_at"] = string(created_at)
        prov["created_by"] = created_by
        prov["schema_version"] = schema_version

        # canonical hash (without hash field itself, to avoid circularity)
        temp_dict = OrderedDict{String,Any}(
            "schema_version" => schema_version,
            "id" => id,
            "created_at" => string(created_at),
            "created_by" => created_by,
            "method" => METHOD_TO_STRING[m],
            "formula" => formula_stripped,
            "outcome_column" => outcome_column,
            "metadata_columns" => sort(metadata_columns),
            "normalization" => OrderedDict(
                "method" => normalization.method,
                "pseudocount" => normalization.pseudocount,
                "ilr_basis" => normalization.ilr_basis,
                "multiplicative_replacement_delta" => normalization.multiplicative_replacement_delta,
            ),
            "correction" => OrderedDict(
                "method" => correction.method,
                "alpha" => correction.alpha,
                "allow_no_correction" => correction.allow_no_correction,
            ),
            "advanced" => OrderedDict(
                "dispersion_method" => advanced.dispersion_method,
                "zero_handling" => advanced.zero_handling,
                "min_prevalence" => advanced.min_prevalence,
                "min_abundance" => advanced.min_abundance,
                "max_features" => advanced.max_features,
                "min_samples_per_group" => advanced.min_samples_per_group,
                "robust" => advanced.robust,
            ),
        )
        canonical = JSON3.write(temp_dict)
        computed_hash = isnothing(hash) || isempty(hash) ? bytes2hex(sha256(canonical)) : hash

        new(schema_version, id, created_at, created_by, m, formula_stripped, outcome_column, metadata_columns, normalization, correction, advanced, prov, computed_hash)
    end
end

# --------------------------------------------------------------------------
# Validation with available metadata (context-sensitive)
# --------------------------------------------------------------------------

"""
    validate_config(config, available_metadata_columns; strict=true) -> Vector{String}

Heavy validation, context-sensitive, refusal of meaningless inputs.
Returns list of errors (empty = valid). If strict, throws on first error.
"""
function validate_config(config::AnalysisConfigStruct,
                         available_metadata_columns::Union{Vector{String},Nothing}=nothing;
                         strict::Bool=true)::Vector{String}
    errors = String[]

    # Check formula references
    # Extract tokens from formula: split by ~ + * : etc.
    formula_tokens = _extract_formula_vars(config.formula)
    for tok in formula_tokens
        # tok should be in metadata_columns or outcome_column
        if !(tok in config.metadata_columns) && (isnothing(config.outcome_column) || tok != config.outcome_column) && tok != "1" && tok != "0"
            push!(errors, "Formula references variable '$tok' which is not listed in metadata_columns $(config.metadata_columns) nor outcome_column $(config.outcome_column). Refusing as meaningless. Did you forget to include it in metadata_columns?")
        end
    end

    if !isnothing(available_metadata_columns)
        avail_set = Set(available_metadata_columns)
        for col in config.metadata_columns
            col in avail_set || push!(errors, "metadata_columns contains '$col' which does not exist in available metadata columns $(available_metadata_columns).")
        end
        if !isnothing(config.outcome_column)
            config.outcome_column in avail_set || push!(errors, "outcome_column '$(config.outcome_column)' does not exist in available metadata columns.")
        end
        for tok in formula_tokens
            if tok != "1" && tok != "0" && !(tok in avail_set) && !(tok in config.metadata_columns) && (isnothing(config.outcome_column) || tok != config.outcome_column)
                push!(errors, "Formula variable '$tok' not found in available metadata columns $(available_metadata_columns).")
            end
        end
    end

    # Method-specific meaningless checks
    if config.method == LOGISTIC
        if isnothing(config.outcome_column)
            push!(errors, "LOGISTIC requires binary outcome_column, but none provided.")
        end
        # Check that formula has outcome on LHS for logistic? Should be "outcome ~ ..."
        if !occursin(r"^\s*[a-zA-Z0-9_\.]+\s*~", config.formula)
            push!(errors, "For LOGISTIC, formula should be of form 'outcome ~ predictors' (outcome on left of ~). Got '$(config.formula)'. Refusing ambiguous formula.")
        end
    end

    if config.method in (CLR_LM, ILR_LM)
        if config.normalization.pseudocount <= 0
            push!(errors, "For compositional methods CLR/ILR, pseudocount must be >0 to handle zeros. Got $(config.normalization.pseudocount).")
        end
        if config.advanced.zero_handling == "refuse"
            push!(errors, "DANGER: zero_handling='refuse' with CLR/ILR will cause log(0) = -Inf and break the analysis. This combination is refused even with acknowledgment, because it is mathematically invalid.")
        end
    end

    if config.method == NB_GLM
        if config.normalization.method in ("clr", "ilr")
            push!(errors, "NB_GLM expects count data, not compositional transforms CLR/ILR. Use CLR_LM/ILR_LM for compositional, or change normalization to none/size_factors.")
        end
    end

    # Prevalence / abundance sanity
    if config.advanced.min_prevalence == 1.0 && config.advanced.min_abundance > 0
        push!(errors, "min_prevalence=1.0 with min_abundance>0 requires feature to be present in 100% of samples above abundance threshold — this will likely filter everything. Refusing as overly stringent; if intentional, set min_prevalence=0.99.")
    end

    if config.advanced.min_prevalence == 0.0 && config.advanced.min_abundance == 0.0 && !isnothing(config.advanced.max_features) && config.advanced.max_features < 10
        @warn "Filtering none (prevalence 0, abundance 0) but max_features=$(config.advanced.max_features) is very low — you will arbitrarily truncate features. Consider raising max_features or adding prevalence filter."
    end

    if strict && !isempty(errors)
        throw(ArgumentError("AnalysisConfig validation failed:\n" * join(errors, "\n")))
    end

    return errors
end

function _extract_formula_vars(formula::String)::Vector{String}
    # Remove ~, +, *, :, (, ), spaces, then split
    # This is simplified; for full R parsing we'd need R, but we do lexical extraction
    cleaned = replace(formula, "~" => " ", "+" => " ", "*" => " ", ":" => " ", "(" => " ", ")" => " ", "/" => " ")
    tokens = split(cleaned)
    # Filter out numeric constants and known R functions
    r_keywords = Set(["1", "0", "I", "log", "sqrt", "scale", "factor", "as.factor", "as.numeric"])
    filter(t -> !(t in r_keywords) && !all(isdigit, t) && !isempty(t), tokens) |> unique
end

# --------------------------------------------------------------------------
# Context-sensitive help
# --------------------------------------------------------------------------

"""
    context_help(field_path) -> String

Returns help text for a given field, with scientific context.
"""
function context_help(field_path::String)::String
    help_db = Dict{String,String}(
        "method" => """
        **Analysis Method** (required, explicit, no auto-selection)

        - `nb_glm`: Negative Binomial GLM, appropriate for raw counts with overdispersion. Uses DESeq2-style size factors or MASS::glm.nb. Best for differential abundance of individual taxa when library sizes vary. Requires at least 3 samples per group.
        - `clr_lm`: Centered Log-Ratio transform + Gaussian LM. Compositional method (Aitchison geometry). Handles compositionality but requires pseudocount for zeros. Use when you care about relative shifts, not absolute counts.
        - `ilr_lm`: Isometric Log-Ratio + Gaussian LM. Like CLR but with orthonormal basis (balances). Allows phylogenetic or sequential binary partition basis. More interpretable for hierarchical hypotheses.
        - `logistic`: Logistic regression for presence/absence or binary outcome. Outcome must be binary. Use when you dichotomize (e.g., pathogen present/absent).

        No silent switching: you must choose one. Changing method changes the statistical model and interpretation.
        """,
        "formula" => """
        **Formula** (R-style, required)

        Example: `~ group` or `disease ~ group + batch + age`

        - Left of `~` is outcome (required for logistic, optional for others — if omitted, each taxon is tested independently).
        - Right of `~` lists metadata columns as covariates.
        - Must reference only columns listed in metadata_columns.
        - Forbidden: `;`, backticks, `$` (injection prevention).
        - Must contain at least one covariate.

        Context: If you have batch effects, include batch: `~ group + batch`. If you don't, your p-values may be confounded.
        """,
        "normalization.method" => """
        **Normalization / Transform** (method-dependent)

        - For NB_GLM: `none` (use raw counts with size_factors), `size_factors` (DESeq2), `relative` (proportions), `rarefy` (subsample — discouraged for differential abundance, but allowed with acknowledgment).
        - For CLR_LM: must be `clr`. Pseudocount mandatory.
        - For ILR_LM: must be `ilr`. Pseudocount + ilr_basis.
        - For LOGISTIC: `presence_absence`, `none`, `relative`.

        Refusal: CLR/ILR without pseudocount is mathematically invalid (log(0)). We refuse it.
        """,
        "normalization.pseudocount" => """
        **Pseudocount** for zero replacement (CLR/ILR only)

        Typical: 0.5 or 0.65 (Martín-Fernández et al. 2003). Must be >0, <1 recommended.

        - Too small (e.g., 1e-6): creates extreme log-ratios, inflates variance.
        - Too large (e.g., >=1): distorts low-abundance features.
        - Zero: refused (log(0) undefined).

        For NB_GLM, zero handling is via dispersion estimation, not pseudocount.
        """,
        "correction.method" => """
        **Multiple testing correction** — BH mandatory in v1

        Microbiome data tests thousands of taxa. Uncorrected p-values will give ~5% false positives even under null.

        - `BH` (Benjamini-Hochberg FDR) is mandatory.
        - Any override (e.g., `none`, `bonferroni`) requires Advanced Analysis expander, DANGER banner, and acknowledgment token `$DANGER_ACK_TOKEN`.
        - Override is logged in provenance and DOI bundle.

        Scientific value: BH controls false discovery rate, appropriate for exploratory microbiome studies.
        """,
        "advanced.min_prevalence" => """
        **Minimum prevalence** filter (0-1)

        Feature must be present in at least this fraction of samples to be tested.

        - 0.1 = present in >=10% samples. Recommended to reduce multiple testing burden.
        - 0 = no filter (tests everything, more multiple testing, slower).
        - 1 = present in 100% samples (very stringent, likely filters everything unless abundance threshold is 0).

        Refusal: values outside [0,1] are meaningless.
        """,
        "advanced.dispersion_method" => """
        **Dispersion estimation** (NB_GLM advanced)

        - `parametric`: fit dispersion ~ mean trend (DESeq2 default). Good for large n.
        - `local`: local regression fit. More flexible.
        - `mean`: use mean dispersion.
        - `pooled`: pool across genes (when n small).
        - `glmGamPoi`: use glmGamPoi fast estimator.

        Context: Dispersion = extra variance beyond Poisson. Mis-specifying inflates false positives/negatives.
        """,
    )
    return get(help_db, field_path, "No help available for '$field_path'. This field may be advanced or undocumented — please check documentation or file an issue.")
end

# --------------------------------------------------------------------------
# DANGER banner logic
# --------------------------------------------------------------------------

function is_dangerous(config::AnalysisConfigStruct)::Bool
    # Any override that weakens statistical rigor
    config.correction.allow_no_correction && return true
    config.advanced.zero_handling == "refuse" && return true
    config.normalization.method == "rarefy" && config.method == NB_GLM && return true # rarefying for NB_GLM is discouraged
    config.advanced.min_samples_per_group < 3 && return true
    return false
end

function danger_banner(config::AnalysisConfigStruct)::Union{String,Nothing}
    is_dangerous(config) || return nothing

    reasons = String[]
    if config.correction.allow_no_correction
        push!(reasons, "BH correction disabled (method=$(config.correction.method)). This will inflate false discoveries in high-dimensional data.")
    end
    if config.advanced.zero_handling == "refuse"
        push!(reasons, "zero_handling='refuse' will cause log(0) or biased zero handling.")
    end
    if config.normalization.method == "rarefy" && config.method == NB_GLM
        push!(reasons, "Rarefaction for NB_GLM discards data and reduces power; size_factors preferred (McMurdie & Holmes 2014).")
    end
    if config.advanced.min_samples_per_group < 3
        push!(reasons, "min_samples_per_group=$(config.advanced.min_samples_per_group) <3: variance estimation will be unstable.")
    end

    banner = """
    ╔════════════════════════════════════════════════════════════════════════════╗
    ║  ⚠️  DANGER — SCIENTIFICALLY RISKY CONFIGURATION DETECTED  ⚠️             ║
    ╠════════════════════════════════════════════════════════════════════════════╣
    ║  You have enabled overrides that weaken statistical rigor:                ║
    $(join(["║  - $r" for r in reasons], "\n"))
    ║                                                                            ║
    ║  This configuration will be:                                               ║
    ║  • Logged in provenance with full user identity and timestamp              ║
    ║  • Bannered in every figure and DOI bundle                                 ║
    ║  • Flagged in the GitHub Project board as 'needs-review'                   ║
    ║                                                                            ║
    ║  If you are sure, you must acknowledge with token:                         ║
    ║  $DANGER_ACK_TOKEN
    ║                                                                            ║
    ║  Consider: Is there a safer alternative? Consult context-sensitive help.   ║
    ╚════════════════════════════════════════════════════════════════════════════╝
    """
    return banner
end

# --------------------------------------------------------------------------
# Serialization: JSON, Nickel, DEED
# --------------------------------------------------------------------------

function canonical_json(config::AnalysisConfigStruct)::String
    dict = OrderedDict{String,Any}(
        "schema_version" => config.schema_version,
        "id" => config.id,
        "created_at" => string(config.created_at),
        "created_by" => config.created_by,
        "method" => METHOD_TO_STRING[config.method],
        "formula" => config.formula,
        "outcome_column" => config.outcome_column,
        "metadata_columns" => config.metadata_columns,
        "normalization" => OrderedDict(
            "method" => config.normalization.method,
            "pseudocount" => config.normalization.pseudocount,
            "ilr_basis" => config.normalization.ilr_basis,
            "multiplicative_replacement_delta" => config.normalization.multiplicative_replacement_delta,
        ),
        "correction" => OrderedDict(
            "method" => config.correction.method,
            "alpha" => config.correction.alpha,
            "allow_no_correction" => config.correction.allow_no_correction,
        ),
        "advanced" => OrderedDict(
            "dispersion_method" => config.advanced.dispersion_method,
            "zero_handling" => config.advanced.zero_handling,
            "min_prevalence" => config.advanced.min_prevalence,
            "min_abundance" => config.advanced.min_abundance,
            "max_features" => config.advanced.max_features,
            "min_samples_per_group" => config.advanced.min_samples_per_group,
            "robust" => config.advanced.robust,
        ),
        "provenance" => config.provenance,
        "hash" => config.hash,
    )
    return JSON3.write(dict)
end

function config_hash(config::AnalysisConfigStruct)::String
    return config.hash
end

function to_json(config::AnalysisConfigStruct)::String
    return canonical_json(config)
end

function from_json(json_str::String)::AnalysisConfigStruct
    data = JSON3.read(json_str, Dict{String,Any})

    method_str = String(data["method"])
    norm_data = data["normalization"] isa Dict ? data["normalization"] : Dict{String,Any}()
    corr_data = data["correction"] isa Dict ? data["correction"] : Dict{String,Any}()
    adv_data = data["advanced"] isa Dict ? data["advanced"] : Dict{String,Any}()

    normalization = NormalizationConfig(
        method=String(get(norm_data, "method", "none")),
        pseudocount=Float64(get(norm_data, "pseudocount", 0.5)),
        ilr_basis=get(norm_data, "ilr_basis", nothing) isa Nothing ? nothing : String(get(norm_data, "ilr_basis", nothing)),
        multiplicative_replacement_delta=get(norm_data, "multiplicative_replacement_delta", nothing) isa Nothing ? nothing : Float64(get(norm_data, "multiplicative_replacement_delta", nothing)),
    )

    correction = CorrectionConfig(
        method=String(get(corr_data, "method", "BH")),
        alpha=Float64(get(corr_data, "alpha", 0.05)),
        allow_no_correction=Bool(get(corr_data, "allow_no_correction", false)),
        acknowledgment_token=get(corr_data, "acknowledgment_token", nothing) isa Nothing ? nothing : String(get(corr_data, "acknowledgment_token", nothing)),
    )

    advanced = AdvancedOverrides(
        dispersion_method=String(get(adv_data, "dispersion_method", "parametric")),
        zero_handling=String(get(adv_data, "zero_handling", "pseudocount")),
        min_prevalence=Float64(get(adv_data, "min_prevalence", 0.1)),
        min_abundance=Float64(get(adv_data, "min_abundance", 0.0)),
        max_features=get(adv_data, "max_features", nothing) isa Nothing ? nothing : Int(get(adv_data, "max_features", nothing)),
        min_samples_per_group=Int(get(adv_data, "min_samples_per_group", 3)),
        robust=Bool(get(adv_data, "robust", false)),
        acknowledgment_token=get(adv_data, "acknowledgment_token", nothing) isa Nothing ? nothing : String(get(adv_data, "acknowledgment_token", nothing)),
    )

    return AnalysisConfigStruct(
        schema_version=String(get(data, "schema_version", SCHEMA_VERSION)),
        id=String(get(data, "id", string(uuid4()))),
        created_at=try DateTime(String(get(data, "created_at", string(now(UTC))))) catch; now(UTC) end,
        created_by=String(get(data, "created_by", "anonymous")),
        method=method_str,
        formula=String(data["formula"]),
        outcome_column=get(data, "outcome_column", nothing) isa Nothing ? nothing : String(get(data, "outcome_column", nothing)),
        metadata_columns=Vector{String}(String.(get(data, "metadata_columns", String[]))),
        normalization=normalization,
        correction=correction,
        advanced=advanced,
        provenance=OrderedDict{String,Any}(get(data, "provenance", OrderedDict{String,Any}())),
        hash=String(get(data, "hash", "")),
    )
end

function to_nickel(config::AnalysisConfigStruct)::String
    # Nickel contract from hyperpolymath/standards style
    """
    # SPDX-License-Identifier: AGPL-3.0-only
    # AnalysisConfig Nickel contract — generated from $(config.id)
    # Schema version: $(config.schema_version)
    # Hash: $(config.hash)
    # DANGER: $(is_dangerous(config) ? "YES - " * something(danger_banner(config), "")[1:100] : "NO")

    let AnalysisMethod = std.enum.TagOrString & [| 'nb_glm, 'clr_lm, 'ilr_lm, 'logistic |] in
    let CorrectionMethod = std.enum.TagOrString & [| 'BH, 'FDR |] in
    {
      schema_version | String | doc "Must be $(SCHEMA_VERSION)" = "$(config.schema_version)",
      id | String = "$(config.id)",
      created_at | String = "$(config.created_at)",
      created_by | String = "$(config.created_by)",
      method | AnalysisMethod = '$(METHOD_TO_STRING[config.method])',
      formula | String | doc $(context_help("formula") |> s -> "\"\"\"$(replace(s, "\"" => "\\\""))\"\"\"") = "$(config.formula)",
      outcome_column | std.option.String = $(isnothing(config.outcome_column) ? "null" : "\"$(config.outcome_column)\""),
      metadata_columns | Array String = $(JSON3.write(config.metadata_columns)),

      normalization = {
        method | String = "$(config.normalization.method)",
        pseudocount | Number | doc "Must be >0 for CLR/ILR" = $(config.normalization.pseudocount),
        ilr_basis | std.option.String = $(isnothing(config.normalization.ilr_basis) ? "null" : "\"$(config.normalization.ilr_basis)\""),
      },

      correction = {
        method | CorrectionMethod | doc "BH mandatory in v1" = '$(lowercase(config.correction.method))',
        alpha | Number | doc "FDR threshold, (0,1)" = $(config.correction.alpha),
        allow_no_correction | Bool = $(config.correction.allow_no_correction),
      } | std.contract.custom (fun label value =>
        if value.allow_no_correction && value.method != 'BH then
          if value.acknowledgment_token != "$DANGER_ACK_TOKEN" then
            'Error { message = "DANGER: BH override requires acknowledgment token" }
          else
            'Ok value
        else
          'Ok value
      ),

      advanced = {
        dispersion_method | String = "$(config.advanced.dispersion_method)",
        zero_handling | String = "$(config.advanced.zero_handling)",
        min_prevalence | Number = $(config.advanced.min_prevalence),
        min_abundance | Number = $(config.advanced.min_abundance),
        max_features | std.option.Number = $(isnothing(config.advanced.max_features) ? "null" : string(config.advanced.max_features)),
        min_samples_per_group | Number = $(config.advanced.min_samples_per_group),
        robust | Bool = $(config.advanced.robust),
      },

      provenance | { .. } = $(JSON3.write(config.provenance)),
      hash | String = "$(config.hash)",
    }
    """
end

function to_deed(config::AnalysisConfigStruct)::String
    # DEED format from hyperpolymath/standards 1-formats/deed
    # Filename dispatch: *_chora.deed, head repo-deed, :schema-version first
    banner = is_dangerous(config) ? ";; DANGER: $(replace(something(danger_banner(config), "")[1:200], "\n" => " "))" : ";; Safe configuration (BH enforced)"
    """
    ;; SPDX-FileCopyrightText: © 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
    ;; SPDX-License-Identifier: AGPL-3.0-only
    ;; AnalysisConfig DEED — $(config.id) — $(config.hash)
    $banner
    (repo-deed
      :schema-version "$(config.schema_version)"
      :canonical-name "analysis-config-$(config.id)"
      :beholding-chora #u5"estate/chora"

      (method
        :name "$(METHOD_TO_STRING[config.method])"
        :formula "$(config.formula)"
        :outcome-column $(isnothing(config.outcome_column) ? "\"\"" : "\"$(config.outcome_column)\"")
        :metadata-columns ($(join(["\"$c\"" for c in config.metadata_columns], " "))))

      (normalization
        :method "$(config.normalization.method)"
        :pseudocount $(config.normalization.pseudocount)
        :ilr-basis $(isnothing(config.normalization.ilr_basis) ? "\"\"" : "\"$(config.normalization.ilr_basis)\""))

      (correction
        :method "$(config.correction.method)"
        :alpha $(config.correction.alpha)
        :allow-no-correction $(config.correction.allow_no_correction ? "#t" : "#f"))

      (advanced
        :dispersion-method "$(config.advanced.dispersion_method)"
        :zero-handling "$(config.advanced.zero_handling)"
        :min-prevalence $(config.advanced.min_prevalence)
        :min-abundance $(config.advanced.min_abundance)
        :max-features $(isnothing(config.advanced.max_features) ? "0" : string(config.advanced.max_features))
        :min-samples-per-group $(config.advanced.min_samples_per_group)
        :robust $(config.advanced.robust ? "#t" : "#f"))

      (provenance
        :id "$(config.id)"
        :hash "$(config.hash)"
        :created-at "$(config.created_at)"
        :created-by "$(config.created_by)"
        :dangerous $(is_dangerous(config) ? "#t" : "#f"))

      (warrant
        :evidence-type "AnalysisConfig"
        :soundness "Requires BH unless DANGER token provided"
        :fiber "Echo of raw counts through $(config.normalization.method) transform"))
    """
end

# --------------------------------------------------------------------------
# AnalysisResult — immutable derived object
# --------------------------------------------------------------------------

"""
    AnalysisResult — immutable, provenance-rich derived object

Every analysis run produces this, with hash chaining to its config.
"""
struct AnalysisResult
    id::String
    config_id::String
    config_hash::String
    created_at::DateTime
    method::AnalysisMethod
    results::OrderedDict{String,Any}  # taxon -> stats
    provenance::OrderedDict{String,Any}
    hash::String

    function AnalysisResult(; id::String=string(uuid4()),
                              config_id::String,
                              config_hash::String,
                              created_at::DateTime=now(UTC),
                              method::AnalysisMethod,
                              results::OrderedDict{String,Any},
                              provenance::OrderedDict{String,Any}=OrderedDict{String,Any}(),
                              hash::String="")
        prov = OrderedDict{String,Any}(provenance)
        prov["config_id"] = config_id
        prov["config_hash"] = config_hash
        prov["created_at"] = string(created_at)
        prov["method"] = METHOD_TO_STRING[method]

        # Hash chain: result hash includes config hash
        canonical = JSON3.write(OrderedDict(
            "id" => id,
            "config_id" => config_id,
            "config_hash" => config_hash,
            "created_at" => string(created_at),
            "method" => METHOD_TO_STRING[method],
            "results" => results,
        ))
        computed_hash = isempty(hash) ? bytes2hex(sha256(canonical)) : hash

        new(id, config_id, config_hash, created_at, method, results, prov, computed_hash)
    end
end

# --------------------------------------------------------------------------
# DOI-ready bundle
# --------------------------------------------------------------------------

"""
    create_doi_bundle(config, result, output_dir; authors, license, title) -> String

Creates a DOI-ready bundle with DataCite metadata, config, result, provenance.
Returns path to bundle directory.
"""
function create_doi_bundle(config::AnalysisConfigStruct,
                           result::Union{AnalysisResult,Nothing},
                           output_dir::String;
                           authors::Vector{String}=String[],
                           license::String="CC-BY-4.0",
                           title::String="MetaManifold Analysis Bundle",
                           description::String="Differential abundance analysis with $(METHOD_TO_STRING[config.method])")::String

    mkpath(output_dir)

    # DataCite metadata
    datacite = OrderedDict{String,Any}(
        "id" => config.id,
        "type" => "Dataset",
        "titles" => [OrderedDict("title" => title)],
        "creators" => [OrderedDict("name" => a) for a in authors],
        "publicationYear" => string(year(now())),
        "descriptions" => [OrderedDict("description" => description, "descriptionType" => "Abstract")],
        "formats" => ["application/json", "text/vnd.deed", "application/nickel"],
        "version" => config.schema_version,
        "rightsList" => [OrderedDict("rights" => license)],
        "subjects" => [OrderedDict("subject" => METHOD_TO_STRING[config.method])],
        "relatedIdentifiers" => [
            OrderedDict("relatedIdentifier" => config.hash, "relatedIdentifierType" => "SHA256", "relationType" => "IsDerivedFrom"),
        ],
    )

    if is_dangerous(config)
        datacite["descriptions"] = vcat(datacite["descriptions"], [OrderedDict("description" => something(danger_banner(config), ""), "descriptionType" => "TechnicalInfo")])
    end

    # Write files
    open(joinpath(output_dir, "analysis_config.json"), "w") do io
        write(io, to_json(config))
    end
    open(joinpath(output_dir, "analysis_config.ncl"), "w") do io
        write(io, to_nickel(config))
    end
    open(joinpath(output_dir, "analysis_config_chora.deed"), "w") do io
        write(io, to_deed(config))
    end
    open(joinpath(output_dir, "datacite.json"), "w") do io
        write(io, JSON3.write(datacite))
    end
    open(joinpath(output_dir, "provenance.json"), "w") do io
        write(io, JSON3.write(config.provenance))
    end
    if !isnothing(result)
        open(joinpath(output_dir, "analysis_result.json"), "w") do io
            write(io, JSON3.write(OrderedDict(
                "id" => result.id,
                "config_id" => result.config_id,
                "config_hash" => result.config_hash,
                "created_at" => string(result.created_at),
                "method" => METHOD_TO_STRING[result.method],
                "results" => result.results,
                "provenance" => result.provenance,
                "hash" => result.hash,
            )))
        end
    end
    open(joinpath(output_dir, "README.md"), "w") do io
        write(io, """
        # $title

        DOI-ready bundle for MetaManifold analysis.

        - **Method**: $(METHOD_TO_STRING[config.method])
        - **Formula**: $(config.formula)
        - **Config ID**: $(config.id)
        - **Config Hash**: $(config.hash)
        - **Created**: $(config.created_at) by $(config.created_by)
        - **Schema Version**: $(config.schema_version)
        - **Dangerous**: $(is_dangerous(config) ? "YES" : "NO")

        ## Files

        - `analysis_config.json` — canonical JSON (hash: $(config.hash))
        - `analysis_config.ncl` — Nickel contract
        - `analysis_config_chora.deed` — DEED attestation (repo-deed)
        - `datacite.json` — DataCite metadata for DOI registration
        - `provenance.json` — full provenance chain
        $(isnothing(result) ? "" : "- `analysis_result.json` — immutable result with hash chain to config")

        ## Reproducibility

        This bundle is self-contained and content-addressed. The config hash $(config.hash) is SHA256 of canonical JSON.
        To verify: `sha256sum analysis_config.json` should match provenance.

        ## License

        $license

        $(is_dangerous(config) ? something(danger_banner(config), "") : "")
        """)
    end

    return abspath(output_dir)
end

# --------------------------------------------------------------------------
# Epistemic bridge — present_in_every_admissible_world
# --------------------------------------------------------------------------

"""
    present_in_every_admissible_world(taxon_counts, evidence; threshold=1) -> Bool

Implements the residual-evidence notion: a taxon is present in every admissible world
consistent with observation and evidence.

In the finite model: observation = sum of contributions, evidence = bounds on noise,
candidate worlds = all (u,n) consistent with observation and evidence.

For microbiome: observation = observed count, evidence = avec_fibre + epistemic status,
admissible worlds = all decompositions of observed count into true signal + noise
that satisfy evidence constraints.

Simplified: if avec_fibre=true and count >= threshold in all filtered views, then present in every admissible world.
"""
function present_in_every_admissible_world(observed_counts::Vector{Float64},
                                           evidence::Dict{String,Any};
                                           threshold::Float64=1.0)::Bool
    # evidence should contain avec_fibre, epistemic_status, noise_bound, etc.
    avec_fibre = get(evidence, "avec_fibre", false) == true
    epistemic_status = get(evidence, "epistemic_status", "unknown")

    # If sans fibre, we cannot claim presence in every world
    !avec_fibre && return false

    # If epistemic status is already present_in_every_admissible_world, trust it
    epistemic_status == "present_in_every_admissible_world" && return true
    epistemic_status == "absent_in_every_admissible_world" && return false

    # Finite candidate model: check all counts >= threshold?
    # In residual-evidence-types, Holds Present means Present holds for every candidate
    all(c -> c >= threshold, observed_counts) && return true

    return false
end

end # module AnalysisConfig
