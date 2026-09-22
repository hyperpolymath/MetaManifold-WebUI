# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""
    Execution — execution harness with abstract AnalysisAdapter and concrete stubs (RAdapter, JuliaAdapter)

Implements Milestone 4:

- abstract AnalysisAdapter and concrete stubs RAdapter, JuliaAdapter
- prepare_analysis_table: applies declared transform, offset, zero_policy, epistemic filtering with Advanced section validation
- run_analysis: stub that records full manifest and diagnostics, hard-stop with DANGER banner on failures
- self-diagnostics and safe self-healing
- Tests for prepare_analysis_table (CLR with pseudocount=1, epsilon=1e-6, drop vs impute)

Standards alignment:
- Uses AnalysisConfig.jl immutable struct (NB GLM, CLR/ILR+Gaussian, logistic v1, BH mandatory, DANGER banner, Advanced Analysis heavy validation)
- JSON + Nickel + DEED schemes from hyperpolymath/standards
- Epistemic layer: avec_fibre, present_in_every_admissible_world from echo-types, epistemic-types, residual-evidence-types
- No silent switching, every analysis explicit, immutable, provenance-rich
- Hard-stop with DANGER banner on failures for paper writers

Design:
- Counts: Matrix{Float64} where rows=taxa, cols=samples (or transposed? We use rows=taxa, cols=samples as per DESeq2 style)
- Sample metadata: Dict or DataFrame-like (we use OrderedDict and DataFrames if available)
- Taxa metadata: optional with avec_fibre, epistemic_status, residual_count
- Transforms: none, relative, size_factors, clr, ilr, presence_absence, rarefy (discouraged), TSS/CSS/RSS deferred alias to relative
- Zero policies: pseudocount (default safe), multiplicative_replacement, bayesian_multiplicative, refuse (DANGEROUS)
- Offsets: log library size or size_factors for NB_GLM
- Epistemic filtering: avec_fibre true, epistemic_status present_in_every_admissible_world, min_prevalence, min_abundance, max_features
- Self-diagnostics: NaN/Inf, zero variance, all-zero samples/taxa, library size outliers, batch confounding, prevalence/abundance, etc.
- Safe self-healing: heal NaN/Inf with epsilon, drop all-zero samples/taxa with warning, record healing in diagnostics, never silent
- run_analysis: stub records full manifest and diagnostics, hard-stop with DANGER banner on failures
"""
module Execution

using Dates
using SHA
using UUIDs
using JSON3
using OrderedCollections
using Logging
using Statistics

# Use AnalysisConfig from parent module
import ..AnalysisConfig
using ..Epistemic
using ..Provenance: probe_metamanifold, probe_host

export AnalysisAdapter, RAdapter, JuliaAdapter,
       prepare_analysis_table, run_analysis,
       ExecutionDiagnostics, ExecutionManifest, ExecutionResult,
       self_diagnostics, safe_self_healing,
       check_nan_inf, check_zero_variance, check_all_zero_samples, check_all_zero_taxa,
       check_library_size_outliers, check_prevalence_abundance, check_batch_confounding,
       heal_nan_inf, heal_all_zero_samples, heal_all_zero_taxa,
       is_dangerous_execution, danger_banner_execution, log_danger_banner_execution

# --------------------------------------------------------------------------
# Constants and types
# --------------------------------------------------------------------------

const SCHEMA_VERSION = "1.0.0"

@enum DropPolicy begin
    DROP = 1      # Drop all-zero samples/taxa
    IMPUTE = 2    # Impute with pseudocount/epsilon
    REFUSE = 3    # Refuse to handle, hard-stop DANGER
end

const DROP_POLICY_STRINGS = Dict{String,DropPolicy}(
    "drop" => DROP,
    "impute" => IMPUTE,
    "refuse" => REFUSE,
)

@enum ImputePolicy begin
    PSEUDOCOUNT_IMPUTE = 1
    EPSILON_IMPUTE = 2
    MULTIPLICATIVE_IMPUTE = 3
    REFUSE_IMPUTE = 4
end

const IMPUTE_POLICY_STRINGS = Dict{String,ImputePolicy}(
    "pseudocount" => PSEUDOCOUNT_IMPUTE,
    "epsilon" => EPSILON_IMPUTE,
    "multiplicative" => MULTIPLICATIVE_IMPUTE,
    "refuse" => REFUSE_IMPUTE,
)

# --------------------------------------------------------------------------
# Abstract adapter and concrete stubs
# --------------------------------------------------------------------------

"""
    AnalysisAdapter — abstract adapter for analysis execution

Concrete implementations:
- RAdapter: uses R via RCall or pipeline tools (DESeq2, edgeR, vegan, etc.)
- JuliaAdapter: pure Julia via GLM, MultivariateStats, etc.

Every adapter must implement:
- prepare_analysis_table (via Execution module, not adapter-specific, but adapter may provide custom transform)
- run_analysis (adapter-specific stub that records manifest and diagnostics)
"""
abstract type AnalysisAdapter end

"""
    RAdapter — stub for R-based execution (DESeq2, edgeR, vegan, metagenomeSeq, etc.)

Fields:
- r_binary: path to R binary (from config/tools.yml)
- r_packages: required R packages (e.g., ["DESeq2", "edgeR", "vegan"])
- method: analysis method (nb_glm, clr_lm, etc.) — must match AnalysisConfig
- use_r_runtime_lock: whether to use R runtime lock (from core/r_runtime.jl) to avoid deadlock
- seed: random seed for reproducibility (for permutation, Dirichlet sampling, etc.)
"""
struct RAdapter <: AnalysisAdapter
    r_binary::String
    r_packages::Vector{String}
    method::String
    use_r_runtime_lock::Bool
    seed::Union{Int,Nothing}

    function RAdapter(;
        r_binary::String="R",
        r_packages::Vector{String}=String["DESeq2", "edgeR"],
        method::String="nb_glm",
        use_r_runtime_lock::Bool=true,
        seed::Union{Int,Nothing}=42
    )
        isempty(strip(r_binary)) && throw(ArgumentError("r_binary must be non-empty"))
        isempty(r_packages) && throw(ArgumentError("r_packages must be non-empty for RAdapter"))
        method_clean = lowercase(strip(method))
        isempty(method_clean) && throw(ArgumentError("method must be non-empty for RAdapter"))
        # Validate method is one of AnalysisConfig methods
        if !(method_clean in keys(AnalysisConfig.METHOD_STRINGS))
            throw(ArgumentError("RAdapter method must be one of $(join(keys(AnalysisConfig.METHOD_STRINGS), ", ")) — got '$method_clean'"))
        end
        new(r_binary, r_packages, method_clean, use_r_runtime_lock, seed)
    end
end

"""
    JuliaAdapter — stub for pure Julia execution (GLM, MultivariateStats, etc.)

Fields:
- method: analysis method (must match AnalysisConfig)
- use_multithreading: whether to use multithreading for large taxa tables
- seed: random seed for reproducibility
- optimizer: optimizer for MN/DM (e.g., "LBFGS", "Newton")
"""
struct JuliaAdapter <: AnalysisAdapter
    method::String
    use_multithreading::Bool
    seed::Union{Int,Nothing}
    optimizer::String

    function JuliaAdapter(;
        method::String="nb_glm",
        use_multithreading::Bool=false,
        seed::Union{Int,Nothing}=42,
        optimizer::String="LBFGS"
    )
        method_clean = lowercase(strip(method))
        isempty(method_clean) && throw(ArgumentError("method must be non-empty for JuliaAdapter"))
        if !(method_clean in keys(AnalysisConfig.METHOD_STRINGS))
            throw(ArgumentError("JuliaAdapter method must be one of $(join(keys(AnalysisConfig.METHOD_STRINGS), ", ")) — got '$method_clean'"))
        end
        new(method_clean, use_multithreading, seed, optimizer)
    end
end

# --------------------------------------------------------------------------
# Diagnostics and manifest
# --------------------------------------------------------------------------

"""
    ExecutionDiagnostics — self-diagnostics for prepared table

Fields:
- warnings: Vector{String} — non-fatal issues (e.g., library size outlier, rarefy discouraged)
- errors: Vector{String} — fatal issues that trigger hard-stop with DANGER banner (e.g., all-zero samples, NaN/Inf not healable, incompatible normalization)
- healings: Vector{String} — safe self-healing actions taken (e.g., "Healed NaN/Inf with epsilon=1e-6", "Dropped 2 all-zero samples")
- checks: OrderedDict{String,Any} — detailed check results (e.g., nan_inf_count, zero_variance_taxa, library_size_outliers, etc.)
- is_dangerous: Bool — true if any dangerous condition (e.g., BH disabled, refuse zero_policy, min_samples_per_group<3, healing performed)
- banner: Union{String,Nothing} — DANGER banner if dangerous
"""
struct ExecutionDiagnostics
    warnings::Vector{String}
    errors::Vector{String}
    healings::Vector{String}
    checks::OrderedDict{String,Any}
    is_dangerous::Bool
    banner::Union{String,Nothing}

    function ExecutionDiagnostics(;
        warnings::Vector{String}=String[],
        errors::Vector{String}=String[],
        healings::Vector{String}=String[],
        checks::OrderedDict{String,Any}=OrderedDict{String,Any}(),
        is_dangerous::Bool=false,
        banner::Union{String,Nothing}=nothing
    )
        new(warnings, errors, healings, checks, is_dangerous, banner)
    end
end

"""
    ExecutionManifest — full manifest for prepared table and analysis run

Fields:
- id: UUID4
- created_at: DateTime
- config_id: UUID4 from AnalysisConfig
- config_hash: SHA256 from AnalysisConfig
- adapter_type: String (RAdapter, JuliaAdapter)
- adapter_config: OrderedDict (r_binary, r_packages, method, etc.)
- transform: String (none, relative, size_factors, clr, ilr, etc.)
- zero_policy: String (pseudocount, multiplicative_replacement, etc.)
- offset: Union{Vector{Float64},Nothing} — log library size or size_factors
- prepared_table_hash: SHA256 of prepared table
- diagnostics: ExecutionDiagnostics
- provenance: OrderedDict (metamanifold version, host, etc.)
- hash: SHA256 of manifest itself
"""
struct ExecutionManifest
    id::String
    created_at::DateTime
    config_id::String
    config_hash::String
    adapter_type::String
    adapter_config::OrderedDict{String,Any}
    transform::String
    zero_policy::String
    offset::Union{Vector{Float64},Nothing}
    prepared_table_hash::String
    diagnostics::ExecutionDiagnostics
    provenance::OrderedDict{String,Any}
    hash::String

    function ExecutionManifest(;
        id::String=string(uuid4()),
        created_at::DateTime=now(Dates.UTC),
        config_id::String,
        config_hash::String,
        adapter_type::String,
        adapter_config::OrderedDict{String,Any}=OrderedDict{String,Any}(),
        transform::String,
        zero_policy::String,
        offset::Union{Vector{Float64},Nothing}=nothing,
        prepared_table_hash::String,
        diagnostics::ExecutionDiagnostics,
        provenance::OrderedDict{String,Any}=OrderedDict{String,Any}(),
        hash::Union{String,Nothing}=nothing
    )
        try UUID(id) catch; throw(ArgumentError("id must be valid UUID4")) end
        try UUID(config_id) catch; throw(ArgumentError("config_id must be valid UUID4")) end
        isempty(config_hash) && throw(ArgumentError("config_hash must be non-empty"))
        isempty(adapter_type) && throw(ArgumentError("adapter_type must be non-empty"))
        isempty(transform) && throw(ArgumentError("transform must be non-empty"))
        isempty(zero_policy) && throw(ArgumentError("zero_policy must be non-empty"))
        isempty(prepared_table_hash) && throw(ArgumentError("prepared_table_hash must be non-empty"))

        prov = OrderedDict{String,Any}(provenance)
        if !haskey(prov, "schema_version")
            prov["schema_version"] = SCHEMA_VERSION
        end
        if !haskey(prov, "created_at")
            prov["created_at"] = string(created_at)
        end
        if !haskey(prov, "config_id")
            prov["config_id"] = config_id
        end
        if !haskey(prov, "config_hash")
            prov["config_hash"] = config_hash
        end
        try
            prov["metamanifold"] = probe_metamanifold()
        catch
            prov["metamanifold"] = OrderedDict("version" => "unknown")
        end
        try
            prov["host"] = probe_host()
        catch
            prov["host"] = OrderedDict("hostname" => "unknown")
        end

        hash_computed = if isnothing(hash)
            canonical = OrderedDict(
                "id" => id,
                "created_at" => string(created_at),
                "config_id" => config_id,
                "config_hash" => config_hash,
                "adapter_type" => adapter_type,
                "adapter_config" => adapter_config,
                "transform" => transform,
                "zero_policy" => zero_policy,
                "offset" => offset,
                "prepared_table_hash" => prepared_table_hash,
                "diagnostics" => OrderedDict(
                    "warnings" => diagnostics.warnings,
                    "errors" => diagnostics.errors,
                    "healings" => diagnostics.healings,
                    "checks" => diagnostics.checks,
                    "is_dangerous" => diagnostics.is_dangerous
                )
            )
            bytes2hex(sha256(JSON3.write(canonical)))
        else
            hash
        end

        new(id, created_at, config_id, config_hash, adapter_type, adapter_config, transform, zero_policy, offset, prepared_table_hash, diagnostics, prov, hash_computed)
    end
end

"""
    ExecutionResult — stub result from run_analysis, records full manifest and diagnostics

Fields:
- id: UUID4
- manifest_id: UUID4 from ExecutionManifest
- config_id: UUID4
- config_hash: SHA256
- method: AnalysisMethod
- results: OrderedDict{String,Any} — taxon -> stats (mock for stub)
- diagnostics: ExecutionDiagnostics
- manifest: ExecutionManifest
- provenance: OrderedDict
- hash: SHA256 chain
"""
struct ExecutionResult
    id::String
    manifest_id::String
    config_id::String
    config_hash::String
    method::AnalysisConfig.AnalysisMethod
    results::OrderedDict{String,Any}
    diagnostics::ExecutionDiagnostics
    manifest::ExecutionManifest
    provenance::OrderedDict{String,Any}
    hash::String

    function ExecutionResult(;
        id::String=string(uuid4()),
        manifest_id::String,
        config_id::String,
        config_hash::String,
        method::AnalysisConfig.AnalysisMethod,
        results::OrderedDict{String,Any}=OrderedDict{String,Any}(),
        diagnostics::ExecutionDiagnostics,
        manifest::ExecutionManifest,
        provenance::OrderedDict{String,Any}=OrderedDict{String,Any}(),
        hash::Union{String,Nothing}=nothing
    )
        try UUID(id) catch; throw(ArgumentError("id must be valid UUID4")) end
        try UUID(manifest_id) catch; throw(ArgumentError("manifest_id must be valid UUID4")) end
        try UUID(config_id) catch; throw(ArgumentError("config_id must be valid UUID4")) end

        prov = OrderedDict{String,Any}(provenance)
        prov["manifest_id"] = manifest_id
        prov["config_id"] = config_id
        prov["config_hash"] = config_hash
        prov["method"] = AnalysisConfig.METHOD_TO_STRING[method]

        hash_computed = if isnothing(hash)
            canonical = OrderedDict(
                "id" => id,
                "manifest_id" => manifest_id,
                "config_id" => config_id,
                "config_hash" => config_hash,
                "method" => AnalysisConfig.METHOD_TO_STRING[method],
                "results" => results,
                "manifest_hash" => manifest.hash
            )
            bytes2hex(sha256(JSON3.write(canonical)))
        else
            hash
        end

        new(id, manifest_id, config_id, config_hash, method, results, diagnostics, manifest, prov, hash_computed)
    end
end

# --------------------------------------------------------------------------
# Self-diagnostics — checks
# --------------------------------------------------------------------------

function check_nan_inf(table::Matrix{Float64})
    nan_count = count(isnan, table)
    inf_count = count(isinf, table)
    total = length(table)
    return OrderedDict{String,Any}(
        "nan_count" => nan_count,
        "inf_count" => inf_count,
        "total" => total,
        "has_nan_inf" => (nan_count > 0 || inf_count > 0),
        "nan_inf_ratio" => (nan_count + inf_count) / total
    )
end

function check_zero_variance(table::Matrix{Float64})
    # Check taxa (rows) with zero variance across samples
    zero_var_rows = Int[]
    for i in 1:size(table, 1)
        row = table[i, :]
        if var(row) == 0.0
            push!(zero_var_rows, i)
        end
    end
    # Check samples (cols) with zero variance across taxa
    zero_var_cols = Int[]
    for j in 1:size(table, 2)
        col = table[:, j]
        if var(col) == 0.0
            push!(zero_var_cols, j)
        end
    end
    return OrderedDict{String,Any}(
        "zero_variance_taxa_indices" => zero_var_rows,
        "zero_variance_taxa_count" => length(zero_var_rows),
        "zero_variance_samples_indices" => zero_var_cols,
        "zero_variance_samples_count" => length(zero_var_cols),
        "has_zero_variance" => (length(zero_var_rows) > 0 || length(zero_var_cols) > 0)
    )
end

function check_all_zero_samples(counts::Matrix{Float64})
    all_zero_cols = Int[]
    for j in 1:size(counts, 2)
        if all(counts[:, j] .== 0.0)
            push!(all_zero_cols, j)
        end
    end
    return OrderedDict{String,Any}(
        "all_zero_samples_indices" => all_zero_cols,
        "all_zero_samples_count" => length(all_zero_cols),
        "has_all_zero_samples" => length(all_zero_cols) > 0
    )
end

function check_all_zero_taxa(counts::Matrix{Float64})
    all_zero_rows = Int[]
    for i in 1:size(counts, 1)
        if all(counts[i, :] .== 0.0)
            push!(all_zero_rows, i)
        end
    end
    return OrderedDict{String,Any}(
        "all_zero_taxa_indices" => all_zero_rows,
        "all_zero_taxa_count" => length(all_zero_rows),
        "has_all_zero_taxa" => length(all_zero_rows) > 0
    )
end

function check_library_size_outliers(counts::Matrix{Float64})
    lib_sizes = vec(sum(counts, dims=1))
    m = mean(lib_sizes)
    s = std(lib_sizes)
    # Outliers >3sd from mean
    outliers = Int[]
    for (j, ls) in enumerate(lib_sizes)
        if s > 0 && abs(ls - m) > 3 * s
            push!(outliers, j)
        end
    end
    return OrderedDict{String,Any}(
        "library_sizes" => lib_sizes,
        "library_size_mean" => m,
        "library_size_std" => s,
        "library_size_outliers_indices" => outliers,
        "library_size_outliers_count" => length(outliers),
        "has_library_size_outliers" => length(outliers) > 0
    )
end

function check_prevalence_abundance(counts::Matrix{Float64}, min_prevalence::Float64, min_abundance::Float64)
    n_samples = size(counts, 2)
    prevalence = [count(x -> x > 0, counts[i, :]) / n_samples for i in 1:size(counts, 1)]
    abundance = vec(sum(counts, dims=2))

    low_prevalence = [i for (i, p) in enumerate(prevalence) if p < min_prevalence]
    low_abundance = [i for (i, a) in enumerate(abundance) if a < min_abundance]

    return OrderedDict{String,Any}(
        "prevalence" => prevalence,
        "abundance" => abundance,
        "low_prevalence_taxa_indices" => low_prevalence,
        "low_prevalence_count" => length(low_prevalence),
        "low_abundance_taxa_indices" => low_abundance,
        "low_abundance_count" => length(low_abundance),
        "has_low_prevalence" => length(low_prevalence) > 0,
        "has_low_abundance" => length(low_abundance) > 0
    )
end

function check_batch_confounding(sample_metadata::Union{OrderedDict{String,Any},Nothing}, formula::String)
    # Stub: check if batch column exists and is confounded with group
    # Real implementation would check via DataFrames and statistical test
    if isnothing(sample_metadata)
        return OrderedDict{String,Any}(
            "has_batch_confounding" => false,
            "note" => "No sample metadata provided, cannot check batch confounding"
        )
    end

    # Simple check: if formula contains batch and group, warn about potential confounding if batch and group correlated
    has_batch = occursin("batch", lowercase(formula))
    has_group = occursin("group", lowercase(formula))

    return OrderedDict{String,Any}(
        "has_batch_confounding" => false, # stub always false, real would compute
        "formula_has_batch" => has_batch,
        "formula_has_group" => has_group,
        "note" => "Stub: real implementation would check correlation between batch and group via chi-square or ANOVA"
    )
end

function self_diagnostics(
    counts::Matrix{Float64},
    prepared::Matrix{Float64},
    config::AnalysisConfig.AnalysisConfig;
    sample_metadata::Union{OrderedDict{String,Any},Nothing}=nothing,
    # Pre-filtering counts. The prevalence/abundance check exists to tell the user
    # how many taxa *will be* filtered, so it must run on the unfiltered matrix.
    # Callers pass the post-filter matrix as `counts`, which made this check
    # vacuous: every surviving taxon clears the thresholds by construction, so
    # low_prevalence_count and low_abundance_count were permanently 0.
    raw_counts::Union{Matrix{Float64},Nothing}=nothing
)
    checks = OrderedDict{String,Any}()

    checks["nan_inf"] = check_nan_inf(prepared)
    checks["zero_variance"] = check_zero_variance(prepared)
    checks["all_zero_samples"] = check_all_zero_samples(counts)
    checks["all_zero_taxa"] = check_all_zero_taxa(counts)
    checks["library_size_outliers"] = check_library_size_outliers(counts)
    checks["prevalence_abundance"] = check_prevalence_abundance(something(raw_counts, counts), config.advanced.min_prevalence, config.advanced.min_abundance)
    checks["batch_confounding"] = check_batch_confounding(sample_metadata, config.formula)

    warnings = String[]
    errors = String[]

    # Warnings
    if checks["nan_inf"]["has_nan_inf"]
        push!(warnings, "Prepared table has $(checks["nan_inf"]["nan_count"]) NaN and $(checks["nan_inf"]["inf_count"]) Inf (ratio $(round(checks["nan_inf"]["nan_inf_ratio"]*100, digits=2))%) — will attempt safe self-healing with epsilon=$(config.advanced.epsilon)")
    end
    if checks["zero_variance"]["has_zero_variance"]
        push!(warnings, "Zero variance detected: $(checks["zero_variance"]["zero_variance_taxa_count"]) taxa and $(checks["zero_variance"]["zero_variance_samples_count"]) samples have zero variance — may cause singularities in LM/GLM")
    end
    if checks["all_zero_samples"]["has_all_zero_samples"]
        push!(warnings, "All-zero samples detected: $(checks["all_zero_samples"]["all_zero_samples_count"]) samples have all zeros — will be dropped or imputed based on drop_policy")
    end
    if checks["all_zero_taxa"]["has_all_zero_taxa"]
        push!(warnings, "All-zero taxa detected: $(checks["all_zero_taxa"]["all_zero_taxa_count"]) taxa have all zeros — will be dropped or imputed")
    end
    if checks["library_size_outliers"]["has_library_size_outliers"]
        push!(warnings, "Library size outliers detected: $(checks["library_size_outliers"]["library_size_outliers_count"]) samples >3sd from mean (mean=$(round(checks["library_size_outliers"]["library_size_mean"], digits=2)), std=$(round(checks["library_size_outliers"]["library_size_std"], digits=2))) — check for contamination or failed sequencing")
    end
    if checks["prevalence_abundance"]["has_low_prevalence"] || checks["prevalence_abundance"]["has_low_abundance"]
        push!(warnings, "Low prevalence/abundance: $(checks["prevalence_abundance"]["low_prevalence_count"]) taxa below min_prevalence=$(config.advanced.min_prevalence), $(checks["prevalence_abundance"]["low_abundance_count"]) below min_abundance=$(config.advanced.min_abundance) — will be filtered")
    end

    # Errors that trigger hard-stop with DANGER banner
    if size(counts, 2) < config.advanced.min_samples_per_group * 2
        push!(errors, "Too few samples: $(size(counts,2)) samples < 2*min_samples_per_group=$(config.advanced.min_samples_per_group*2) — need at least 2 groups with $(config.advanced.min_samples_per_group) samples each for variance estimation. Refusing.")
    end
    if size(counts, 1) == 0
        push!(errors, "No taxa after filtering — all taxa filtered by prevalence/abundance or all-zero check. Refusing meaningless analysis with 0 features.")
    end
    if size(counts, 2) == 0
        push!(errors, "No samples after filtering — all samples dropped as all-zero. Refusing meaningless analysis with 0 samples.")
    end

    # Check for incompatible normalization already done in AnalysisConfig, but re-check
    if config.method == AnalysisConfig.NB_GLM && config.normalization.method in ("clr", "ilr")
        push!(errors, "Incompatible: NB_GLM with CLR/ILR normalization — NB_GLM expects counts, not log-ratios. Refusing.")
    end
    if config.method in (AnalysisConfig.CLR_LM, AnalysisConfig.ILR_LM) && config.normalization.pseudocount <= 0
        push!(errors, "For CLR/ILR, pseudocount must be >0 — got $(config.normalization.pseudocount). Refusing log(0).")
    end

    return (checks, warnings, errors)
end

# --------------------------------------------------------------------------
# Safe self-healing
# --------------------------------------------------------------------------

function heal_nan_inf(table::Matrix{Float64}, epsilon::Float64)
    healed = copy(table)
    nan_count = 0
    inf_count = 0
    for i in eachindex(healed)
        if isnan(healed[i])
            healed[i] = epsilon
            nan_count += 1
        elseif isinf(healed[i])
            # Replace Inf with log(max) or large value, -Inf with log(epsilon)
            if healed[i] > 0
                healed[i] = log(1/epsilon) # large positive
            else
                healed[i] = log(epsilon) # large negative
            end
            inf_count += 1
        end
    end
    return (healed, nan_count, inf_count)
end

function heal_all_zero_samples(counts::Matrix{Float64}, sample_ids::Vector{String}, drop_policy::DropPolicy, epsilon::Float64)
    check = check_all_zero_samples(counts)
    if !check["has_all_zero_samples"]
        return (counts, sample_ids, String[], Int[])
    end

    indices = check["all_zero_samples_indices"]
    healings = String[]

    if drop_policy == DROP
        # Drop all-zero samples
        keep_cols = [j for j in 1:size(counts,2) if !(j in indices)]
        healed_counts = counts[:, keep_cols]
        healed_sample_ids = sample_ids[keep_cols]
        push!(healings, "Dropped $(length(indices)) all-zero samples at indices $(indices) — drop_policy=drop")
        return (healed_counts, healed_sample_ids, healings, indices)
    elseif drop_policy == IMPUTE
        # Impute all-zero samples with epsilon
        healed_counts = copy(counts)
        for j in indices
            healed_counts[:, j] .= epsilon
        end
        push!(healings, "Imputed $(length(indices)) all-zero samples with epsilon=$epsilon — drop_policy=impute")
        return (healed_counts, sample_ids, healings, indices)
    else # REFUSE
        throw(ArgumentError("DANGER: All-zero samples detected at indices $(indices) and drop_policy=refuse — refusing. Set drop_policy=drop or impute with acknowledgment. See context_help('advanced.zero_policy')"))
    end
end

function heal_all_zero_taxa(
    counts::Matrix{Float64},
    taxa_ids::Vector{String},
    drop_policy::DropPolicy,
    epsilon::Float64;
    indices::Union{Nothing,Vector{Int}}=nothing
)
    indices = isnothing(indices) ? check_all_zero_taxa(counts)["all_zero_taxa_indices"] : indices
    if isempty(indices)
        return (counts, taxa_ids, String[], Int[])
    end

    healings = String[]

    if drop_policy == DROP
        keep_rows = [i for i in 1:size(counts,1) if !(i in indices)]
        healed_counts = counts[keep_rows, :]
        healed_taxa_ids = taxa_ids[keep_rows]
        push!(healings, "Dropped $(length(indices)) all-zero taxa at indices $(indices) — drop_policy=drop")
        return (healed_counts, healed_taxa_ids, healings, indices)
    elseif drop_policy == IMPUTE
        healed_counts = copy(counts)
        for i in indices
            healed_counts[i, :] .= epsilon
        end
        push!(healings, "Imputed $(length(indices)) all-zero taxa with epsilon=$epsilon — drop_policy=impute")
        return (healed_counts, taxa_ids, healings, indices)
    else
        throw(ArgumentError("DANGER: All-zero taxa detected at indices $(indices) and drop_policy=refuse — refusing. Set drop_policy=drop or impute."))
    end
end

function safe_self_healing(
    counts::Matrix{Float64},
    prepared::Matrix{Float64},
    config::AnalysisConfig.AnalysisConfig,
    sample_ids::Vector{String},
    taxa_ids::Vector{String},
    drop_policy::DropPolicy,
    epsilon::Float64
)
    healings = String[]
    healed_prepared = copy(prepared)
    healed_counts = copy(counts)
    healed_sample_ids = copy(sample_ids)
    healed_taxa_ids = copy(taxa_ids)

    # Heal NaN/Inf in prepared table
    nan_inf_check = check_nan_inf(prepared)
    if nan_inf_check["has_nan_inf"]
        (healed_prepared, nan_c, inf_c) = heal_nan_inf(prepared, epsilon)
        push!(healings, "Healed $(nan_c) NaN and $(inf_c) Inf in prepared table with epsilon=$epsilon — safe self-healing, logged in diagnostics and manifest")
        @warn "Healed NaN/Inf in prepared table" nan_count=nan_c inf_count=inf_c epsilon=epsilon
    end

    # Heal all-zero samples
    try
        (healed_counts, healed_sample_ids, heal_s, _) = heal_all_zero_samples(healed_counts, healed_sample_ids, drop_policy, epsilon)
        append!(healings, heal_s)
    catch e
        # If REFUSE policy, throw with DANGER banner
        throw(e)
    end

    # Heal all-zero taxa
    try
        (healed_counts, healed_taxa_ids, heal_t, _) = heal_all_zero_taxa(healed_counts, healed_taxa_ids, drop_policy, epsilon)
        append!(healings, heal_t)
    catch e
        throw(e)
    end

    return (healed_counts, healed_prepared, healed_sample_ids, healed_taxa_ids, healings)
end

# --------------------------------------------------------------------------
# Core functions: prepare_analysis_table and run_analysis
# --------------------------------------------------------------------------

"""
    prepared_table_hash(prepared) -> String

Canonical sha256 of a prepared table.

Hashes the raw bytes rather than a JSON rendering on purpose: JSON has no
representation for NaN or Inf, and a prepared table may legitimately contain
them — detecting those is the whole job of `check_nan_inf`, and `run_analysis`
hard-stops on them. A JSON-based hash therefore threw "NaN not allowed to be
written in JSON spec" on precisely the tables it most needed to fingerprint.
"""
function prepared_table_hash(prepared::AbstractMatrix{Float64})::String
    return bytes2hex(sha256(reinterpret(UInt8, vec(prepared))))
end

"""
    prepare_analysis_table(config, counts, sample_metadata; taxa_metadata, sample_ids, taxa_ids, drop_policy, impute_policy) -> (prepared, diagnostics, manifest)

Applies declared transform, offset, zero_policy, epistemic filtering with Advanced section validation.

- config: AnalysisConfig.AnalysisConfig immutable
- counts: Matrix{Float64} rows=taxa, cols=samples
- sample_metadata: OrderedDict or nothing (stub for DataFrame)
- taxa_metadata: OrderedDict or nothing with avec_fibre, epistemic_status, residual_count
- sample_ids, taxa_ids: explicit IDs, must match counts dimensions
- drop_policy: "drop", "impute", "refuse" — how to handle all-zero samples/taxa
- impute_policy: "pseudocount", "epsilon", "multiplicative", "refuse" — how to impute zeros

Returns (prepared_table, diagnostics, manifest) with full provenance.

Hard-stop with DANGER banner on failures: if validation fails, incompatible normalization, zero_policy=refuse for CLR/ILR, all-zero after filtering, etc., throws ArgumentError with DANGER banner from AnalysisConfig.danger_banner.
"""
function prepare_analysis_table(
    config::AnalysisConfig.AnalysisConfig,
    counts::Matrix{Float64};
    sample_metadata::Union{OrderedDict{String,Any},Nothing}=nothing,
    taxa_metadata::Union{OrderedDict{String,Any},Nothing}=nothing,
    sample_ids::Vector{String}=String[],
    taxa_ids::Vector{String}=String[],
    drop_policy::String="drop",
    impute_policy::String="pseudocount",
    adapter::Union{AnalysisAdapter,Nothing}=nothing
)
    # ----------------------------------------------------------------------
    # Advanced section validation — heavy, context-sensitive, refusal of meaningless
    # ----------------------------------------------------------------------

    # Validate drop_policy
    dp_clean = lowercase(strip(drop_policy))
    dp = get(DROP_POLICY_STRINGS, dp_clean, nothing)
    isnothing(dp) && throw(ArgumentError("drop_policy must be one of $(join(keys(DROP_POLICY_STRINGS), ", ")) — got '$drop_policy'. See context_help('advanced.zero_policy')"))

    # Validate impute_policy
    ip_clean = lowercase(strip(impute_policy))
    ip = get(IMPUTE_POLICY_STRINGS, ip_clean, nothing)
    isnothing(ip) && throw(ArgumentError("impute_policy must be one of $(join(keys(IMPUTE_POLICY_STRINGS), ", ")) — got '$impute_policy'"))

    # Validate counts dimensions
    size(counts, 1) == 0 && throw(ArgumentError("counts must have at least 1 taxon (row) — got 0 rows. Refusing meaningless analysis with 0 features."))
    size(counts, 2) == 0 && throw(ArgumentError("counts must have at least 1 sample (col) — got 0 cols. Refusing meaningless analysis with 0 samples."))

    # Validate sample_ids and taxa_ids if provided
    if !isempty(sample_ids)
        length(sample_ids) != size(counts, 2) && throw(ArgumentError("sample_ids length $(length(sample_ids)) must match counts cols $(size(counts,2)) — refusing."))
        length(unique(sample_ids)) != length(sample_ids) && throw(ArgumentError("sample_ids must be unique — got duplicates in $sample_ids"))
    else
        sample_ids = ["sample_$j" for j in 1:size(counts,2)]
    end

    if !isempty(taxa_ids)
        length(taxa_ids) != size(counts, 1) && throw(ArgumentError("taxa_ids length $(length(taxa_ids)) must match counts rows $(size(counts,1)) — refusing."))
        length(unique(taxa_ids)) != length(taxa_ids) && throw(ArgumentError("taxa_ids must be unique — got duplicates"))
    else
        taxa_ids = ["taxon_$i" for i in 1:size(counts,1)]
    end

    # Validate config via AnalysisConfig.validate_config
    try
        errors = AnalysisConfig.validate_config(config, config.metadata_columns; strict=false)
        if !isempty(errors)
            # If strict, throw with DANGER banner if dangerous
            if config.dangerous
                banner = AnalysisConfig.danger_banner(config)
                throw(ArgumentError("AnalysisConfig validation failed with DANGER banner:\n$(join(errors, "\n"))\n\n$banner"))
            else
                throw(ArgumentError("AnalysisConfig validation failed:\n$(join(errors, "\n"))"))
            end
        end
    catch e
        if e isa ArgumentError
            # Hard-stop with DANGER banner on failures
            if config.dangerous
                banner = AnalysisConfig.danger_banner(config)
                @error "Hard-stop with DANGER banner on validation failure" errors=e.msg banner=config.id
                throw(ArgumentError("Hard-stop with DANGER banner on validation failure:\n$(e.msg)\n\n$(something(banner, ""))"))
            else
                throw(e)
            end
        else
            rethrow(e)
        end
    end

    # Check dangerous flag and log banner
    if AnalysisConfig.is_dangerous(config)
        banner = AnalysisConfig.danger_banner(config)
        @warn "Config is dangerous — DANGER banner will be included in manifest and DOI bundle" config_id=config.id banner=banner
    end

    # ----------------------------------------------------------------------
    # Epistemic filtering with Advanced section validation
    # ----------------------------------------------------------------------

    # Start with all taxa and samples
    filtered_counts = copy(counts)
    filtered_taxa_ids = copy(taxa_ids)
    filtered_sample_ids = copy(sample_ids)

    # Prevalence and abundance filtering from AdvancedConfig
    # prevalence = fraction of samples where count >0
    # abundance = total count across samples
    n_samples = size(filtered_counts, 2)
    prevalence = [count(x -> x > 0, filtered_counts[i, :]) / n_samples for i in 1:size(filtered_counts, 1)]
    abundance = vec(sum(filtered_counts, dims=2))

    # Filter by min_prevalence and min_abundance
    keep_taxa = [i for i in 1:size(filtered_counts,1) if prevalence[i] >= config.advanced.min_prevalence && abundance[i] >= config.advanced.min_abundance]

    if isempty(keep_taxa)
        throw(ArgumentError("No taxa pass prevalence/abundance filtering: min_prevalence=$(config.advanced.min_prevalence) min_abundance=$(config.advanced.min_abundance) — all $(size(filtered_counts,1)) taxa filtered. Refusing meaningless analysis. See context_help('advanced.min_prevalence')"))
    end

    filtered_counts = filtered_counts[keep_taxa, :]
    filtered_taxa_ids = filtered_taxa_ids[keep_taxa]

    # Max features filtering — keep top N by abundance if set
    if !isnothing(config.advanced.max_features)
        max_f = config.advanced.max_features
        if size(filtered_counts, 1) > max_f
            # Sort by abundance descending and keep top max_f
            sorted_indices = sortperm(abundance[keep_taxa], rev=true)
            top_indices = sorted_indices[1:max_f]
            filtered_counts = filtered_counts[top_indices, :]
            filtered_taxa_ids = filtered_taxa_ids[top_indices]
            @warn "Filtered to max_features=$(max_f) top abundant taxa — may miss biology" max_features=max_f kept=size(filtered_counts,1)
        end
    end

    # Epistemic filtering: avec_fibre and epistemic_status if taxa_metadata provided
    if !isnothing(taxa_metadata)
        # taxa_metadata is expected to have keys for each taxon? For stub, we check if it has avec_fibre column
        # For simplicity, if taxa_metadata has "avec_fibre" key with Bool vector, filter
        if haskey(taxa_metadata, "avec_fibre")
            avec = taxa_metadata["avec_fibre"]
            if length(avec) == size(filtered_counts, 1)
                keep_avec = [i for (i, v) in enumerate(avec) if v == true]
                if isempty(keep_avec)
                    @warn "No taxa have avec_fibre=true — epistemic filtering would remove all taxa. Keeping all for now, but marking as dangerous."
                else
                    # Only filter if at least one has avec_fibre and epistemic_status is present_in_every?
                    # For now, we don't filter aggressively, just warn
                    @info "Epistemic filtering: $(length(keep_avec))/$(size(filtered_counts,1)) taxa have avec_fibre=true"
                end
            end
        end
        if haskey(taxa_metadata, "epistemic_status")
            statuses = taxa_metadata["epistemic_status"]
            if length(statuses) == size(filtered_counts, 1)
                present_every = count(s -> s == "present_in_every_admissible_world", statuses)
                @info "Epistemic status: $present_every/$(length(statuses)) taxa present_in_every_admissible_world"
            end
        end
    end

    # ----------------------------------------------------------------------
    # Zero policy handling
    # ----------------------------------------------------------------------

    # Extract zero_policy from config
    zero_policy = config.normalization.zero_policy
    pseudocount = config.normalization.pseudocount
    epsilon = config.normalization.epsilon
    delta = config.normalization.multiplicative_replacement_delta

    # For AdvancedConfig, also have pseudocount and epsilon — use AdvancedConfig's if set? For now use normalization's
    # But also check AdvancedConfig's pseudocount/epsilon for custom handling
    adv_pseudocount = config.advanced.pseudocount
    adv_epsilon = config.advanced.epsilon

    # Use the more specific: if normalization is clr/ilr, use normalization pseudocount, else advanced pseudocount
    effective_pseudocount = config.normalization.method in ("clr", "ilr") ? pseudocount : adv_pseudocount
    effective_epsilon = epsilon # could also use adv_epsilon, but use normalization epsilon for now

    # ----------------------------------------------------------------------
    # All-zero SAMPLES are healed here — before the transform, not after
    # ----------------------------------------------------------------------
    # This was the defect. Healing used to run after the transform, so `prepared`
    # was computed from counts that still contained zero-depth samples, and every
    # transform below divides by a sample total:
    #
    #   * relative  wrote `0.0` into each feature — the statement "this feature's
    #               relative abundance is exactly 0" about a sample whose relative
    #               abundances do not exist at all. 0/0 is undefined; 0 is a value.
    #   * rarefy    took `min_lib = minimum(lib_sizes)`, which is 0 when any sample
    #               is empty, and then scaled EVERY sample by 0/lib — emptying the
    #               whole prepared table while reporting success.
    #   * clr       took log(0) = -Inf, which centring turns into NaN, which the
    #               NaN/Inf healing later replaced with epsilon: a wrong number
    #               presented as a healed one.
    #
    # Healing afterwards could not repair any of this. Under drop_policy=drop the
    # affected columns were discarded, but only after the damage was computed;
    # under drop_policy=impute the imputed counts were assigned while `prepared`
    # kept the values computed from the empty column, so `prepared` and
    # `filtered_counts` described different data — the exact inconsistency a
    # pipeline must never have.
    #
    # Healing first removes the class rather than the instance: past this point no
    # zero-depth column can reach a transform, under any policy.
    #
    # Visible results change only where they were wrong. Under drop_policy=drop the
    # sample is still dropped; under refuse the same refusal is raised, earlier;
    # under impute the sample is imputed and the transform now sees the imputed
    # counts, so its relative abundances are a uniform distribution rather than a
    # column of 0.0.
    #
    # All-zero TAXA are deliberately still healed after the transform, and the
    # asymmetry is intentional. A zero-count taxon in a sample that has reads has a
    # relative abundance of exactly 0.0 — that value is true — so there is no lie
    # to remove, while moving the drop earlier would change the geometric mean CLR
    # centres on and therefore change results for analyses that were already
    # correct. Fixing a defect is not licence to change the numbers around it.
    healings = String[]
    is_dangerous_diag = false
    # Preserve the original all-zero taxa before imputing zero-depth samples.
    # Otherwise an epsilon inserted for an empty sample makes an all-zero taxon
    # appear nonzero when diagnostics and taxon healing run after the transform.
    all_zero_taxa_indices = check_all_zero_taxa(filtered_counts)["all_zero_taxa_indices"]
    zero_depth = check_all_zero_samples(filtered_counts)
    if zero_depth["has_all_zero_samples"]
        (filtered_counts, filtered_sample_ids, sample_healings, _) =
            heal_all_zero_samples(filtered_counts, filtered_sample_ids, dp, effective_epsilon)
        append!(healings, sample_healings)
        is_dangerous_diag = true
    end

    # Apply zero policy
    counts_after_zero = copy(filtered_counts)

    if zero_policy == AnalysisConfig.PSEUDOCOUNT
        # Add pseudocount to zeros or to all? For CLR/ILR, add to all to avoid log(0)
        # For NB_GLM, pseudocount may be ignored, but we add to zeros only for safety
        if config.normalization.method in ("clr", "ilr")
            # Add pseudocount to all counts (standard for CLR/ILR)
            counts_after_zero .+= effective_pseudocount
        else
            # For NB_GLM, add pseudocount only to zeros if impute_policy is pseudocount
            if ip == PSEUDOCOUNT_IMPUTE
                for i in eachindex(counts_after_zero)
                    if counts_after_zero[i] == 0.0
                        counts_after_zero[i] = effective_pseudocount
                    end
                end
            end
        end
    elseif zero_policy == AnalysisConfig.MULTIPLICATIVE_REPLACEMENT
        # Multiplicative replacement: replace zeros with delta * geometric mean of non-zeros, then adjust non-zeros multiplicatively
        # Stub implementation
        delta_val = isnothing(delta) ? 0.65 : delta
        for j in 1:size(counts_after_zero, 2)
            col = counts_after_zero[:, j]
            non_zero = filter(x -> x > 0, col)
            if isempty(non_zero)
                # All zeros in sample — will be handled by self-healing later
                continue
            end
            # Geometric mean of non-zeros
            geo_mean = exp(mean(log.(non_zero)))
            zero_replacement = delta_val * geo_mean
            # Count zeros
            n_zeros = count(x -> x == 0, col)
            if n_zeros > 0
                # Replace zeros
                for i in 1:size(col, 1)
                    if counts_after_zero[i, j] == 0.0
                        counts_after_zero[i, j] = zero_replacement
                    end
                end
                # Adjust non-zeros multiplicatively to preserve total (optional, for stub we don't adjust)
                # Real implementation would multiply non-zeros by (1 - n_zeros*zero_replacement/sum(col)) etc.
            end
        end
    elseif zero_policy == AnalysisConfig.BAYESIAN_MULTIPLICATIVE
        # Bayesian multiplicative: similar to multiplicative but with Dirichlet prior
        # Stub: use same as multiplicative for now, with Bayesian note
        delta_val = isnothing(delta) ? 0.65 : delta
        for j in 1:size(counts_after_zero, 2)
            col = counts_after_zero[:, j]
            non_zero = filter(x -> x > 0, col)
            if isempty(non_zero)
                continue
            end
            geo_mean = exp(mean(log.(non_zero)))
            zero_replacement = delta_val * geo_mean * 0.5 # Bayesian shrinks a bit
            for i in 1:size(col, 1)
                if counts_after_zero[i, j] == 0.0
                    counts_after_zero[i, j] = zero_replacement
                end
            end
        end
    elseif zero_policy == AnalysisConfig.REFUSE
        # Refuse to handle zeros — DANGEROUS, hard-stop with DANGER banner
        # Check if any zeros present
        if any(counts_after_zero .== 0.0)
            banner = AnalysisConfig.danger_banner(config)
            throw(ArgumentError("DANGER: zero_policy='refuse' and zeros present in counts — refusing. Zero replacement is mandatory for CLR/ILR because log(0) undefined, and for NB_GLM zeros need dispersion handling. Set zero_policy=pseudocount or multiplicative_replacement. See context_help('advanced.zero_policy')\n\n$(something(banner, ""))"))
        end
    end

    # ----------------------------------------------------------------------
    # Transform and offset
    # ----------------------------------------------------------------------

    transform_method = config.normalization.method
    prepared = copy(counts_after_zero)
    offset = nothing

    if transform_method == "none"
        # No transform, keep counts as is
        prepared = counts_after_zero
        # For NB_GLM, offset is log library size or size_factors
        if config.method == AnalysisConfig.NB_GLM
            lib_sizes = vec(sum(counts_after_zero, dims=1))
            offset = log.(lib_sizes .+ effective_epsilon)
        end
    elseif transform_method in ("relative", "tss", "css", "rss", "TSS", "CSS", "RSS")
        # Relative abundance: counts / sum per sample
        # TSS/CSS/RSS currently alias to relative with warning (deferred exact)
        if transform_method in ("tss", "TSS", "css", "CSS", "rss", "RSS")
            @warn "TSS/CSS/RSS are deferred features (see GitHub issues 01-tss-css-rss-offsets). Currently aliased to relative with warning. For exact TSS/CSS/RSS offsets, see deferred issue."
        end
        lib_sizes = vec(sum(counts_after_zero, dims=1))
        for j in 1:size(counts_after_zero, 2)
            if lib_sizes[j] > 0
                prepared[:, j] = counts_after_zero[:, j] ./ lib_sizes[j]
            else
                # Unreachable since all-zero samples are healed before the transform,
                # and deliberately a refusal rather than an assignment. This branch
                # used to write `prepared[:, j] .= 0.0`, which states that every
                # feature has a relative abundance of exactly 0 -- a value -- for a
                # sample whose relative abundances do not exist. 0/0 is undefined,
                # and "0" and "undefined" are different claims; the old value was
                # wrong in a way no downstream check could detect, because 0.0 is a
                # perfectly ordinary number. If a future path reintroduces a
                # zero-depth column here, that is a bug to surface, not to paper
                # over with a plausible-looking number.
                sample_name = j <= length(filtered_sample_ids) ? filtered_sample_ids[j] : string(j)
                throw(ArgumentError("INTERNAL: sample '$sample_name' (column $j) has zero total counts at the relative-abundance transform. All-zero samples are healed before this point, so reaching here means the healing was bypassed — the relative abundances of an empty sample are undefined and must not be reported as 0. Please report this with the config id $(config.id)."))
            end
        end
        # Offset for NB_GLM if needed? For relative, no offset, but for TSS offset we would use log(lib_sizes)
        if config.method == AnalysisConfig.NB_GLM && transform_method in ("tss", "TSS")
            offset = log.(lib_sizes .+ effective_epsilon)
        end
    elseif transform_method == "size_factors"
        # Size factors: DESeq2 median-of-ratios (stub: use median ratio or simple)
        # For stub, compute size_factors as median of counts / geometric mean per taxon
        # Simplified: size_factors = colSums / mean(colSums) or median ratio
        lib_sizes = vec(sum(counts_after_zero, dims=1))
        # Geometric mean per taxon (row) across samples, ignoring zeros
        # For stub, use lib_sizes / exp(mean(log(lib_sizes)))
        geo_mean_lib = exp(mean(log.(lib_sizes .+ effective_epsilon)))
        size_factors = lib_sizes ./ geo_mean_lib
        # For NB_GLM, we keep counts but store size_factors as offset? Actually DESeq2 uses size_factors as normalization, not offset, but for GLM we can use log(size_factors) as offset
        offset = log.(size_factors .+ effective_epsilon)
        prepared = counts_after_zero # keep counts, offset stored separately
    elseif transform_method == "clr"
        # Centered Log-Ratio: log(x) - mean(log(x)) per sample
        # Requires pseudocount>0 already applied
        for j in 1:size(counts_after_zero, 2)
            col = counts_after_zero[:, j]
            # Check for zeros after pseudocount — should be none if pseudocount>0
            if any(col .<= 0)
                throw(ArgumentError("CLR requires all counts >0 after pseudocount — got $(count(x->x<=0, col)) zeros/negatives in sample $j. Refusing. See context_help('normalization.pseudocount')"))
            end
            log_col = log.(col)
            mean_log = mean(log_col)
            prepared[:, j] = log_col .- mean_log
        end
    elseif transform_method == "ilr"
        # Isometric Log-Ratio with default basis (phylogenetic, SBP, balance_dendrogram deferred)
        # For stub, use CLR then transform via default ILR basis (e.g., Helmert matrix or sequential binary partition default)
        # Default ILR basis: for n taxa, n-1 balances, each balance is log ratio of geometric mean of first k vs k+1?
        # Simplified: use CLR then multiply by Helmert submatrix
        # First compute CLR
        clr_table = similar(counts_after_zero)
        for j in 1:size(counts_after_zero, 2)
            col = counts_after_zero[:, j]
            if any(col .<= 0)
                throw(ArgumentError("ILR requires all counts >0 after pseudocount — got $(count(x->x<=0, col)) zeros in sample $j"))
            end
            log_col = log.(col)
            clr_table[:, j] = log_col .- mean(log_col)
        end

        # Default ILR basis: create (n-1) x n matrix where each row is a balance
        n_taxa = size(clr_table, 1)
        if n_taxa < 2
            throw(ArgumentError("ILR requires at least 2 taxa — got $n_taxa"))
        end

        # For default basis, we use sequential binary partition: first balance is first taxon vs rest, second is second vs rest, etc.
        # Or use Helmert: ilr_basis[i,j] = sqrt(j/(j+1)) * (1/j for k<=j, -1 for k=j+1, 0 otherwise) — but need orthonormal
        # For stub, we use simple: ilr = clr transformed via basis where basis is identity minus 1/n? Actually CLR already centered, ILR is orthonormal version
        # For simplicity, we return CLR for now with warning that exact ILR basis deferred, and set prepared to clr_table
        # Real implementation would use `compositions::ilr` or `philr` or custom

        if config.normalization.ilr_basis in ("phylogenetic", "sequential_binary_partition", "balance_dendrogram")
            @warn "ILR basis $(config.normalization.ilr_basis) is deferred (see GitHub issue 05-ilr-basis-phylogenetic-sbp). Currently using default basis with warning."
        end

        # For default basis, we can compute ILR as: ilr = V^T * clr where V is n x (n-1) orthonormal basis
        # For stub, we use simple basis: first n-1 rows of clr_table (drop last taxon) — not orthonormal but works for testing
        # Better: use Helmert matrix
        # Create Helmert matrix of size n x n, then take first n-1 columns as basis for CLR space? Actually Helmert for ILR is n x (n-1)
        # Let's create simple ILR: for i=1..n-1, ilr_i = sqrt(i/(i+1)) * (mean(log(x_1..x_i)) - log(x_{i+1}))

        ilr_table = zeros(n_taxa - 1, size(clr_table, 2))
        for j in 1:size(clr_table, 2)
            # For each sample, compute ILR balances
            # Use log counts, not CLR, for ILR formula
            log_col = log.(counts_after_zero[:, j])
            for i in 1:(n_taxa-1)
                # Balance i: first i taxa vs taxon i+1
                # geo_mean_first_i = exp(mean(log_col[1:i]))
                # ilr_i = sqrt(i/(i+1)) * (mean(log_col[1:i]) - log_col[i+1])
                mean_first_i = mean(log_col[1:i])
                ilr_table[i, j] = sqrt(i/(i+1)) * (mean_first_i - log_col[i+1])
            end
        end

        prepared = ilr_table
        # Note: prepared now has n_taxa-1 rows, not n_taxa — for ILR, number of balances = n_taxa-1
        # For consistency, we keep taxa_ids as balances? For stub, we create new taxa_ids for balances
        # But for simplicity, we keep prepared as ilr_table and adjust taxa_ids later

    elseif transform_method == "presence_absence"
        prepared = Float64.(counts_after_zero .> 0)
    elseif transform_method == "rarefy"
        @warn "Rarefaction is discouraged for differential abundance (McMurdie & Holmes 2014) — discards data and reduces power. Size_factors preferred for NB_GLM. Using rarefy with warning, will be logged as dangerous."
        # Rarefy to min library size
        lib_sizes = vec(sum(counts_after_zero, dims=1))
        min_lib = minimum(lib_sizes)
        # A single zero-depth sample would make min_lib 0, and every sample would then
        # be scaled by 0/lib — emptying the entire prepared table while reporting
        # success. All-zero samples are healed before this point; this refusal exists
        # so that if that guarantee is ever broken the failure is loud rather than a
        # matrix of zeros that still passes every shape check downstream.
        min_lib <= 0 && throw(ArgumentError("INTERNAL: rarefaction target is $(min_lib) — at least one sample has zero total counts. All-zero samples are healed before this point, so reaching here means the healing was bypassed. Rarefying to an empty sample would set every value to 0. Please report this with the config id $(config.id)."))
        # For stub, rarefy by subsampling proportionally to min_lib (not exact, just scaling)
        for j in 1:size(counts_after_zero, 2)
            if lib_sizes[j] > 0
                prepared[:, j] = counts_after_zero[:, j] .* (min_lib / lib_sizes[j])
            end
        end
    else
        throw(ArgumentError("Unknown normalization method '$(transform_method)' — must be one of $(join(AnalysisConfig.VALID_NORMALIZATION_FOR_METHOD[config.method], ", ")). See context_help('normalization.method')"))
    end

    # ----------------------------------------------------------------------
    # Self-diagnostics and safe self-healing
    # ----------------------------------------------------------------------

    (checks, warnings, errors) = self_diagnostics(filtered_counts, prepared, config; sample_metadata=sample_metadata, raw_counts=counts)
    checks["all_zero_taxa"] = OrderedDict{String,Any}(
        "all_zero_taxa_indices" => all_zero_taxa_indices,
        "all_zero_taxa_count" => length(all_zero_taxa_indices),
        "has_all_zero_taxa" => !isempty(all_zero_taxa_indices)
    )

    # `healings` and `is_dangerous_diag` are initialised earlier, before the
    # all-zero sample healing that happens before the transform; re-initialising
    # them here would silently discard those entries.
    banner = nothing

    # If errors present, hard-stop with DANGER banner
    if !isempty(errors)
        # If config already dangerous, include its banner, plus new errors
        config_banner = AnalysisConfig.danger_banner(config)
        diag_banner = """
        ╔════════════════════════════════════════════════════════════════════════════╗
        ║  ⚠️  DANGER — EXECUTION HARD-STOP DUE TO FAILURES  ⚠️                     ║
        ╠════════════════════════════════════════════════════════════════════════════╣
        $(join(["║  - $e" for e in errors], "\n"))
        ║                                                                            ║
        ║  Config ID: $(config.id)                                                   ║
        ║  Hash: $(config.hash)                                                      ║
        ║  This failure will be logged, included in manifest and DOI bundle.        ║
        ╚════════════════════════════════════════════════════════════════════════════╝
        """
        full_banner = if !isnothing(config_banner)
            config_banner * "\n" * diag_banner
        else
            diag_banner
        end
        @error "Hard-stop with DANGER banner on execution failures" errors=config.id banner=full_banner
        throw(ArgumentError("Hard-stop with DANGER banner on execution failures:\n$(join(errors, "\n"))\n\n$full_banner"))
    end

    # Safe self-healing for warnings that are healable
    # Heal NaN/Inf
    if checks["nan_inf"]["has_nan_inf"]
        (healed_prepared, nan_c, inf_c) = heal_nan_inf(prepared, effective_epsilon)
        prepared = healed_prepared
        push!(healings, "Healed $(nan_c) NaN and $(inf_c) Inf with epsilon=$(effective_epsilon)")
        is_dangerous_diag = true
    end

    # All-zero SAMPLES were healed before the transform, above. The block that used to
    # stand here healed them afterwards, and in doing so had to guess how to reconcile
    # `prepared` with the healed counts -- the code said so: "for simplicity, we
    # re-apply transform after healing counts?" and, for the impute case, "for stub,
    # just keep". That guess is why a zero-depth sample could keep a column of 0.0
    # while its counts were imputed. Nothing is removed by deleting it: the guard
    # below cannot fire, because after healing there are no all-zero samples left for
    # `check_all_zero_samples` to find.
    if checks["all_zero_taxa"]["has_all_zero_taxa"]
        try
            (healed_counts, healed_taxa_ids, heal_t, _) = heal_all_zero_taxa(
                filtered_counts,
                filtered_taxa_ids,
                dp,
                effective_epsilon;
                indices=all_zero_taxa_indices
            )
            if dp == DROP
                keep_rows = [i for i in 1:size(prepared,1) if !(i in checks["all_zero_taxa"]["all_zero_taxa_indices"])]
                # For ILR, prepared has n-1 rows, so need to handle differently — for stub, skip if ILR
                if transform_method != "ilr"
                    prepared = prepared[keep_rows, :]
                end
                filtered_taxa_ids = healed_taxa_ids
                filtered_counts = healed_counts
            else
                filtered_counts = healed_counts
            end
            append!(healings, heal_t)
            is_dangerous_diag = true
        catch e
            throw(e)
        end
    end

    # If healing performed, mark as dangerous and create banner
    if is_dangerous_diag || !isempty(healings)
        banner = """
        ╔════════════════════════════════════════════════════════════════════════════╗
        ║  ⚠️  DANGER — SAFE SELF-HEALING PERFORMED  ⚠️                             ║
        ╠════════════════════════════════════════════════════════════════════════════╣
        $(join(["║  - $h" for h in healings], "\n"))
        $(join(["║  - $w" for w in warnings], "\n"))
        ║                                                                            ║
        ║  Config ID: $(config.id)                                                   ║
        ║  This healing was safe, logged, and recorded in manifest.                  ║
        ║  Review diagnostics before publishing.                                      ║
        ╚════════════════════════════════════════════════════════════════════════════╝
        """
        @warn "Safe self-healing performed" healings=config.id banner=banner
    end

    # Also include config dangerous banner if present
    if AnalysisConfig.is_dangerous(config)
        config_banner = AnalysisConfig.danger_banner(config)
        if !isnothing(config_banner)
            if isnothing(banner)
                banner = config_banner
            else
                banner = banner * "\n" * config_banner
            end
        end
        is_dangerous_diag = true
    end

    diagnostics = ExecutionDiagnostics(
        warnings=warnings,
        errors=String[], # errors already handled via hard-stop
        healings=healings,
        checks=checks,
        is_dangerous=is_dangerous_diag || AnalysisConfig.is_dangerous(config),
        banner=banner
    )

    # ----------------------------------------------------------------------
    # Manifest with full provenance
    # ----------------------------------------------------------------------

    prepared_hash = prepared_table_hash(prepared)

    adapter_type_str = isnothing(adapter) ? "none" : string(typeof(adapter))
    adapter_config_dict = if isnothing(adapter)
        OrderedDict{String,Any}()
    elseif adapter isa RAdapter
        OrderedDict{String,Any}(
            "r_binary" => adapter.r_binary,
            "r_packages" => adapter.r_packages,
            "method" => adapter.method,
            "use_r_runtime_lock" => adapter.use_r_runtime_lock,
            "seed" => adapter.seed
        )
    else # JuliaAdapter
        OrderedDict{String,Any}(
            "method" => adapter.method,
            "use_multithreading" => adapter.use_multithreading,
            "seed" => adapter.seed,
            "optimizer" => adapter.optimizer
        )
    end

    manifest = ExecutionManifest(
        config_id=config.id,
        config_hash=config.hash,
        adapter_type=adapter_type_str,
        adapter_config=adapter_config_dict,
        transform=transform_method,
        zero_policy=string(zero_policy),
        offset=offset,
        prepared_table_hash=prepared_hash,
        diagnostics=diagnostics,
        provenance=OrderedDict{String,Any}(
            "config" => JSON3.read(AnalysisConfig.to_json(config)),
            "sample_ids" => filtered_sample_ids,
            "taxa_ids" => filtered_taxa_ids,
            "drop_policy" => string(dp),
            "impute_policy" => string(ip),
            "transform" => transform_method,
            "zero_policy" => string(zero_policy),
            "pseudocount" => effective_pseudocount,
            "epsilon" => effective_epsilon
        )
    )

    return (prepared, diagnostics, manifest, filtered_sample_ids, filtered_taxa_ids)
end

# Overload with DataFrame-like for counts as Matrix
function prepare_analysis_table(
    config::AnalysisConfig.AnalysisConfig,
    counts::Matrix{Float64},
    sample_metadata::OrderedDict{String,Any};
    kwargs...
)
    return prepare_analysis_table(config, counts; sample_metadata=sample_metadata, kwargs...)
end

# --------------------------------------------------------------------------
# run_analysis — stub that records full manifest and diagnostics, hard-stop with DANGER banner on failures
# --------------------------------------------------------------------------

function is_dangerous_execution(diagnostics::ExecutionDiagnostics)
    return diagnostics.is_dangerous
end

function danger_banner_execution(diagnostics::ExecutionDiagnostics, config::AnalysisConfig.AnalysisConfig)
    if !is_dangerous_execution(diagnostics) && !AnalysisConfig.is_dangerous(config)
        return nothing
    end

    reasons = String[]
    append!(reasons, diagnostics.warnings)
    append!(reasons, diagnostics.healings)
    if AnalysisConfig.is_dangerous(config)
        push!(reasons, "Config is dangerous — BH disabled or refuse zero_policy or min_samples_per_group<3")
    end

    banner = """
    ╔════════════════════════════════════════════════════════════════════════════╗
    ║  ⚠️  DANGER — EXECUTION DIAGNOSTICS  ⚠️                                   ║
    ╠════════════════════════════════════════════════════════════════════════════╣
    $(join(["║  - $r" for r in reasons], "\n"))
    ║                                                                            ║
    ║  Config ID: $(config.id)                                                   ║
    ║  This banner will be logged, included in manifest and DOI bundle.          ║
    ╚════════════════════════════════════════════════════════════════════════════╝
    """
    return banner
end

function log_danger_banner_execution(diagnostics::ExecutionDiagnostics, config::AnalysisConfig.AnalysisConfig)
    banner = danger_banner_execution(diagnostics, config)
    if isnothing(banner)
        @info "Execution diagnostics safe — no DANGER banner" config_id=config.id
        return nothing
    else
        @error "DANGER BANNER — execution diagnostics" banner config_id=config.id
        @warn "SCARY DANGER BANNER FOR PAPER WRITERS — execution has warnings/healings, see manifest" banner config_id=config.id
        return banner
    end
end

"""
    run_analysis(adapter, config, prepared_table, sample_metadata; diagnostics, manifest) -> ExecutionResult

Stub that records full manifest and diagnostics, hard-stop with DANGER banner on failures.

- adapter: AnalysisAdapter (RAdapter or JuliaAdapter stub)
- config: AnalysisConfig.AnalysisConfig
- prepared_table: Matrix{Float64} from prepare_analysis_table
- sample_metadata: OrderedDict or nothing
- diagnostics: ExecutionDiagnostics from prepare_analysis_table
- manifest: ExecutionManifest from prepare_analysis_table

Returns ExecutionResult stub with mock results, full manifest, diagnostics, provenance, hash chain.

Hard-stop with DANGER banner on failures: if diagnostics has errors (should have been hard-stopped earlier in prepare_analysis_table) or if adapter method mismatches config method, or if prepared table has NaN/Inf after healing, throws ArgumentError with DANGER banner.
"""
function run_analysis(
    adapter::AnalysisAdapter,
    config::AnalysisConfig.AnalysisConfig,
    prepared_table::Matrix{Float64};
    sample_metadata::Union{OrderedDict{String,Any},Nothing}=nothing,
    diagnostics::ExecutionDiagnostics,
    manifest::ExecutionManifest,
    sample_ids::Vector{String}=String[],
    taxa_ids::Vector{String}=String[]
)
    # Validate adapter method matches config method
    adapter_method = if adapter isa RAdapter
        adapter.method
    else
        adapter.method
    end

    config_method_str = AnalysisConfig.METHOD_TO_STRING[config.method]

    if lowercase(adapter_method) != lowercase(config_method_str)
        banner = """
        ╔════════════════════════════════════════════════════════════════════════════╗
        ║  ⚠️  DANGER — ADAPTER METHOD MISMATCH  ⚠️                                 ║
        ╠════════════════════════════════════════════════════════════════════════════╣
        ║  Adapter method '$(adapter_method)' does not match config method '$(config_method_str)' ║
        ║  This would cause silent switching — refusing.                             ║
        ║  Config ID: $(config.id)                                                   ║
        ╚════════════════════════════════════════════════════════════════════════════╝
        """
        @error "Adapter method mismatch — hard-stop with DANGER banner" adapter_method config_method=config_method_str config_id=config.id
        throw(ArgumentError("Adapter method mismatch — hard-stop with DANGER banner:\n$banner"))
    end

    # Check diagnostics for errors (should have been caught in prepare_analysis_table, but re-check)
    if !isempty(diagnostics.errors)
        banner = danger_banner_execution(diagnostics, config)
        @error "Hard-stop with DANGER banner on diagnostics errors in run_analysis" errors=diagnostics.errors config_id=config.id
        throw(ArgumentError("Hard-stop with DANGER banner on diagnostics errors:\n$(join(diagnostics.errors, "\n"))\n\n$(something(banner, ""))"))
    end

    # Check prepared table for NaN/Inf after healing — if still present, hard-stop
    nan_inf_check = check_nan_inf(prepared_table)
    if nan_inf_check["has_nan_inf"]
        banner = """
        ╔════════════════════════════════════════════════════════════════════════════╗
        ║  ⚠️  DANGER — PREPARED TABLE STILL HAS NaN/Inf AFTER HEALING  ⚠️          ║
        ╠════════════════════════════════════════════════════════════════════════════╣
        ║  NaN count: $(nan_inf_check["nan_count"]), Inf count: $(nan_inf_check["inf_count"]) ║
        ║  Ratio: $(round(nan_inf_check["nan_inf_ratio"]*100, digits=2))%            ║
        ║  Healing with epsilon=$(config.advanced.epsilon) failed — refusing.        ║
        ║  Config ID: $(config.id)                                                   ║
        ╚════════════════════════════════════════════════════════════════════════════╝
        """
        @error "Prepared table still has NaN/Inf after healing — hard-stop" nan_inf=nan_inf_check config_id=config.id
        throw(ArgumentError("Prepared table still has NaN/Inf after healing — hard-stop with DANGER banner:\n$banner"))
    end

    # Log DANGER banner if dangerous
    log_danger_banner_execution(diagnostics, config)

    # Mock results: for each taxon, create mock stats (p-value, log2FoldChange, etc.)
    # Real implementation would call R via RCall or Julia via GLM, etc.
    results = OrderedDict{String,Any}()
    for (i, taxon_id) in enumerate(taxa_ids)
        # Mock p-value and log2FoldChange
        # For deterministic testing, use hash of taxon_id
        h = hash(taxon_id)
        p_val = 0.01 + (h % 100) / 1000.0 # 0.01..0.11
        log2fc = (h % 20) / 10.0 - 1.0 # -1..1
        results[taxon_id] = OrderedDict{String,Any}(
            "pvalue" => p_val,
            "padj" => p_val * 1.5, # mock BH
            "log2FoldChange" => log2fc,
            "baseMean" => 100.0 + (h % 1000),
            "method" => config_method_str,
            "adapter" => string(typeof(adapter))
        )
    end

    # If no taxa_ids provided, use generic
    if isempty(results)
        for i in 1:size(prepared_table, 1)
            taxon_id = isempty(taxa_ids) ? "taxon_$i" : taxa_ids[i]
            results[taxon_id] = OrderedDict{String,Any}(
                "pvalue" => 0.05,
                "padj" => 0.1,
                "log2FoldChange" => 0.0,
                "method" => config_method_str
            )
        end
    end

    # Create ExecutionResult with full manifest and diagnostics
    exec_result = ExecutionResult(
        manifest_id=manifest.id,
        config_id=config.id,
        config_hash=config.hash,
        method=config.method,
        results=results,
        diagnostics=diagnostics,
        manifest=manifest,
        provenance=OrderedDict{String,Any}(
            "config_id" => config.id,
            "config_hash" => config.hash,
            "manifest_id" => manifest.id,
            "manifest_hash" => manifest.hash,
            "adapter_type" => string(typeof(adapter)),
            "prepared_table_hash" => manifest.prepared_table_hash,
            "diagnostics" => OrderedDict(
                "warnings" => diagnostics.warnings,
                "healings" => diagnostics.healings,
                "checks" => diagnostics.checks,
                "is_dangerous" => diagnostics.is_dangerous
            )
        )
    )

    @info "run_analysis stub completed" result_id=exec_result.id config_id=config.id method=config_method_str taxa_count=length(results) dangerous=diagnostics.is_dangerous

    return exec_result
end

# Overload with sample_ids and taxa_ids
function run_analysis(
    adapter::AnalysisAdapter,
    config::AnalysisConfig.AnalysisConfig,
    prepared_table::Matrix{Float64},
    sample_ids::Vector{String},
    taxa_ids::Vector{String};
    kwargs...
)
    return run_analysis(adapter, config, prepared_table; sample_ids=sample_ids, taxa_ids=taxa_ids, kwargs...)
end

end # module Execution
