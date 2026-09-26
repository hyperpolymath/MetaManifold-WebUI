# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# AnalysisConfig Nickel contract — hyperpolymath/standards style Milestone 3
# From 1-formats/k9/*.ncl and .machine_readable/contractiles/_base.ncl
# Implements BH mandatory, DANGER banner, advanced validation for pseudocount/epsilon/zero_policy/etc.
# tss/css/rss are exact offsets since 2026-09-25 (issue #16), see docs/statistics/method-conditions/scaling-and-offsets.md

let AnalysisMethod = std.enum.TagOrString & [| 'nb_glm, 'clr_lm, 'ilr_lm, 'logistic |] in
let NormalizationMethod = std.enum.TagOrString & [| 'none, 'rarefy, 'relative, 'size_factors, 'clr, 'ilr, 'presence_absence, 'TSS, 'CSS, 'RSS, 'tss, 'css, 'rss |] in
let CorrectionMethod = std.enum.TagOrString & [| 'BH, 'FDR, 'Benjamini-Hochberg |] in
let DispersionMethod = std.enum.TagOrString & [| 'parametric, 'local, 'mean, 'pooled, 'glmGamPoi |] in
let ZeroHandling = std.enum.TagOrString & [| 'pseudocount, 'multiplicative_replacement, 'bayesian_multiplicative, 'refuse |] in
let ZeroPolicy = ZeroHandling in
let IlrBasis = std.enum.TagOrString & [| 'default, 'phylogenetic, 'sequential_binary_partition, 'balance_dendrogram |] in
# ILR basis inputs (issue #20; docs/statistics/method-conditions/ilr-bases.md).
let IlrPartWeights = std.enum.TagOrString & [| 'uniform, 'gm_counts, 'anorm, 'enorm, 'anorm_x_gm_counts, 'enorm_x_gm_counts |] in
let IlrBalanceWeights = std.enum.TagOrString & [| 'uniform, 'blw, 'blw_sqrt, 'mean_descendants |] in
let IlrDendrogramMethod = std.enum.TagOrString & [| 'ward, 'complete, 'average |] in
let Sha256Hex = std.contract.from_predicate (fun v => std.is_string v && std.string.is_match "^[0-9a-f]{64}$" v) in

let DANGER_TOKEN = "I_UNDERSTAND_THE_RISK_AND_WANT_TO_OVERRIDE_BH" in

let ValidFormula = fun label value =>
  if std.string.contains ";" value then
    'Error { message = "Formula contains forbidden ';' (injection prevention)" }
  else if std.string.contains "`" value then
    'Error { message = "Formula contains forbidden backtick" }
  else if std.string.contains "$" value then
    'Error { message = "Formula contains forbidden '$'" }
  else if !(std.string.contains "~" value) then
    'Error { message = "Formula must contain '~' (R-style), e.g. '~ group'" }
  else if std.string.length (std.string.trim value) < 2 then
    'Error { message = "Formula must be non-empty and reference at least one metadata column" }
  else
    'Ok value
in

let PseudocountContract = fun label value =>
  if value <= 0 then
    'Error { message = "pseudocount must be >0 for CLR/ILR (log(0) undefined). Got %{std.to_string value}. See context_help('normalization.pseudocount')" }
  else if value >= 1 then
    # Warn but allow — typical is 0.5
    'Ok value
  else
    'Ok value
in

let CssQuantileContract = fun label value =>
  if value <= 0 || value >= 1 then
    'Error { message = "css_quantile must be in (0,1), got %{std.to_string value}. It is the per-sample quantile of the count distribution whose cumulative sum becomes the CSS scaling factor. See context_help('normalization.css_quantile')" }
  else
    'Ok value
in

let TmmTrimContract = fun label value =>
  if value < 0 || value >= 0.5 then
    'Error { message = "a TMM trim must be in [0,0.5), got %{std.to_string value}. See context_help('normalization.tmm_log_ratio_trim')" }
  else
    'Ok value
in

let EpsilonContract = fun label value =>
  if value <= 0 || value >= 1 then
    'Error { message = "epsilon must be in (0,1) for numerical stability, got %{std.to_string value}. Typical 1e-6. See context_help('advanced.epsilon')" }
  else if value > 0.001 then
    # Warn but allow — large epsilon may affect transforms
    'Ok value
  else if value < 0.000000000001 then
    # Warn but allow — extremely small may underflow
    'Ok value
  else
    'Ok value
in

let PrevalenceContract = fun label value =>
  if value < 0 || value > 1 then
    'Error { message = "min_prevalence must be in [0,1], got %{std.to_string value}. See context_help('advanced.min_prevalence')" }
  else
    'Ok value
in

let CorrectionContract = fun label value =>
  if value.allow_no_correction then
    if value.acknowledgment_token != DANGER_TOKEN then
      'Error {
        message = "DANGER: BH override requires acknowledgment_token = '%{DANGER_TOKEN}'. This will be logged, bannered, and included in DOI bundle. See context-sensitive help for 'correction.method'. Scary DANGER banner for paper writers.",
      }
    else
      'Ok value
  else
    if value.method != 'BH && value.method != 'FDR && value.method != 'Benjamini-Hochberg then
      'Error {
        message = "Correction method must be BH in v1 (got %{std.to_string value.method}). BH controls FDR for high-dimensional microbiome data. If you truly want to override, set allow_no_correction=true and acknowledgment_token='%{DANGER_TOKEN}'. See context_help('correction.method')",
      }
    else
      'Ok value
in

let MultiplicativeDeltaContract = fun label value =>
  if value == null then
    'Ok value
  else
    if value <= 0 || value >= 1 then
      'Error {
        message = "multiplicative_delta must be in (0,1) exclusive, got %{std.to_string value}. The operator refuses anything else: delta drives the fraction of the sample total placed in replaced values (Martín-Fernández et al. 2003). Values below 0.01 or at or above 0.9 warn in the runtime validation. See context_help('advanced.multiplicative_delta').",
      }
    else
      'Ok value
in

let BayesianAlphaContract = fun label value =>
  if value == null then
    'Ok value
  else
    if value <= 0 then
      'Error {
        message = "bayesian_alpha must be > 0, got %{std.to_string value}. It is the Dirichlet prior concentration of bayesian_multiplicative; zero or negative leaves the prior improper (Martín-Fernández et al. 2015). See context_help('advanced.bayesian_alpha').",
      }
    else
      'Ok value
in

let ZeroHandlingContract = fun label value =>
  if value.zero_handling == 'refuse || value.zero_policy == 'refuse then
    if value.acknowledgment_token != DANGER_TOKEN then
      'Error {
        message = "DANGER: zero_handling='refuse' will cause log(0) for CLR/ILR and biased handling for NB_GLM. Requires acknowledgment_token='%{DANGER_TOKEN}'. Even then, CLR/ILR + refuse is mathematically invalid and will be refused at runtime. See context_help('advanced.zero_handling')",
      }
    else
      'Ok value
  else
    'Ok value
in

let MethodNormalizationCompatibility = fun label value =>
  let method = value.method in
  let norm = value.normalization.method in
  if method == 'nb_glm then
    if norm == 'clr || norm == 'ilr then
      'Error { message = "NB_GLM expects count data, not CLR/ILR transforms. Use clr_lm/ilr_lm for compositional, or change normalization to none/size_factors/relative/tss/css/rss. Refusing meaningless combination. See context_help('normalization.method')" }
    else
      'Ok value
  else if method == 'clr_lm then
    if norm != 'clr then
      'Error { message = "CLR_LM requires normalization.method='clr', got '%{std.to_string norm}'. See context_help('normalization.method')" }
    else
      'Ok value
  else if method == 'ilr_lm then
    if norm != 'ilr then
      'Error { message = "ILR_LM requires normalization.method='ilr', got '%{std.to_string norm}'. See context_help('normalization.method')" }
    else
      'Ok value
  else
    'Ok value
in

# Each non-default ILR basis requires its own input and forbids the others' (the Julia
# constructor enforces the same table, `_validate_ilr_inputs`). Whether the tree or SBP
# file exists is checked when the run reads it: a configuration may be written on one
# machine and run on another.
let IlrBasisInputsContract = fun label value =>
  let norm = value.normalization in
  let adv = value.advanced in
  let basis =
    if std.record.has_field "ilr_basis" norm && norm.ilr_basis != null then norm.ilr_basis else 'default
  in
  let present = fun field => std.record.has_field field adv && adv."%{field}" != null in
  let non_default = fun field default_value => present field && adv."%{field}" != default_value in
  let pairing = fun field wanted wanted_name =>
    if basis == wanted && !(present field) then
      "normalization.ilr_basis = '%{wanted_name}' requires advanced.%{field}"
    else if basis != wanted && present field then
      "advanced.%{field} is only used by ilr_basis = '%{wanted_name}' (refusing an input that would be silently ignored)"
    else
      ""
  in
  let problems =
    if norm.method != 'ilr then
      std.array.filter (fun m => m != "") [
        if present "ilr_phylo_tree_path" || present "ilr_sbp_matrix_path" || present "ilr_balance_dendrogram_method"
           || non_default "ilr_part_weights" 'uniform || non_default "ilr_balance_weights" 'uniform
        then "advanced.ilr_* inputs are only meaningful for normalization.method = 'ilr'" else "",
      ]
    else
      std.array.filter (fun m => m != "") [
        pairing "ilr_phylo_tree_path" 'phylogenetic "phylogenetic",
        pairing "ilr_sbp_matrix_path" 'sequential_binary_partition "sequential_binary_partition",
        pairing "ilr_balance_dendrogram_method" 'balance_dendrogram "balance_dendrogram",
        if basis == 'default && non_default "ilr_part_weights" 'uniform
        then "advanced.ilr_part_weights needs a non-default ilr_basis (the Helmert default is unweighted)" else "",
        if basis != 'phylogenetic && non_default "ilr_balance_weights" 'uniform
        then "advanced.ilr_balance_weights needs branch lengths, so ilr_basis = 'phylogenetic'" else "",
        if basis != 'sequential_binary_partition && present "ilr_sbp_history" && std.array.length adv.ilr_sbp_history > 0
        then "advanced.ilr_sbp_history is only used by ilr_basis = 'sequential_binary_partition'" else "",
      ]
  in
  if std.array.length problems > 0 then
    'Error { message = "%{std.string.join "; " problems}. See docs/statistics/method-conditions/ilr-bases.md" }
  else
    'Ok value
in

let EpsilonWarning = fun label value =>
  if value.epsilon > 0.001 then
    std.contract.blame_with_message "epsilon >1e-3 large may affect zero handling and log transforms — warning" label
  else if value.epsilon < 0.000000000001 then
    std.contract.blame_with_message "epsilon <1e-12 extremely small may cause underflow — warning" label
  else
    'Ok value
in

{
  schema_version
    | String
    | doc "Semver schema version, currently only 1.0.0, from DEED :schema-version first"
    | std.contract.from_predicate (fun v => v == "1.0.0")
    = "1.0.0",

  id
    | String
    | doc "UUIDv4, immutable identifier, part of provenance chain",

  created_at
    | String
    | doc "ISO8601 UTC timestamp",

  created_by
    | String
    | doc "User or system that created this config",

  method
    | AnalysisMethod
    | doc m%"
      Analysis method — explicit, no auto-selection — v1: NB GLM, CLR/ILR+Gaussian, logistic

      - 'nb_glm: Negative Binomial GLM for raw counts with overdispersion (DESeq2/MASS style), size_factors preferred, dispersion parametric/local/mean/pooled/glmGamPoi
      - 'clr_lm: Centered Log-Ratio + Gaussian LM (compositional, Aitchison geometry), requires pseudocount >0, epsilon for stability, zero_policy
      - 'ilr_lm: Isometric Log-Ratio + Gaussian LM (balances, phylogenetic basis possible), requires pseudocount >0 and ilr_basis
      - 'logistic: Logistic regression for binary outcome (presence/absence)

      No silent switching: you must choose one. Changing method changes statistical model and interpretation.
      Deferred: multinomial, dirichlet_multinomial, occupancy, zinb, rda, cca, cap, etc. See GitHub issues.
      "%m,

  formula
    | String
    | ValidFormula
    | doc m%"
      R-style formula, e.g. '~ group' or 'disease ~ group + batch'

      - Left of ~ is outcome (required for logistic)
      - Right of ~ lists metadata columns
      - Must reference only columns in metadata_columns
      - Forbidden: ; ` $ (injection prevention)
      - Must contain at least one covariate

      Context: If you have batch effects, include batch: '~ group + batch'. Otherwise p-values may be confounded.
      Refuses meaningless: empty, "~", "group" without ~, forbidden chars.
      "%m,

  outcome_column
    | std.option.String
    | doc "Binary outcome column for logistic regression. Required for logistic, ignored for others unless formula uses it.",

  metadata_columns
    | Array String
    | std.contract.from_predicate (fun arr => std.array.length arr > 0)
    | doc "Explicit list of metadata columns used. Must exist in study metadata. No auto-selection. Pattern ^[a-zA-Z0-9_.\\-]+$",

  normalization
    | {
        method
          | NormalizationMethod
          | doc "Normalization / transform, must be compatible with method. tss/css/rss are exact offsets (issue #16), not aliases to relative; see docs/statistics/method-conditions/scaling-and-offsets.md.",

        pseudocount
          | Number
          | PseudocountContract
          | doc "Pseudocount for zero replacement in CLR/ILR. Must be >0. Typical 0.5. Refuses 0 because log(0) undefined. Heavy validation warnings for <0.1 or >=1.",

        epsilon
          | Number
          | EpsilonContract
          | default = 0.000001
          | doc "Epsilon for numerical stability, (0,1), typical 1e-6. Advanced behind Advanced Analysis expander, heavy validation, warnings for >1e-3 or <1e-12.",

        zero_policy
          | ZeroPolicy
          | default = 'pseudocount
          | doc "Zero handling policy: pseudocount (default safe), multiplicative_replacement, bayesian_multiplicative, refuse (DANGEROUS requires DANGER token, mathematically invalid for CLR/ILR).",

        ilr_basis
          | IlrBasis
          | optional
          | doc "ILR basis, only meaningful for ILR method: default (Helmert), phylogenetic (PhILR, needs advanced.ilr_phylo_tree_path), sequential_binary_partition (needs advanced.ilr_sbp_matrix_path), balance_dendrogram (needs advanced.ilr_balance_dendrogram_method). Issue #20; see docs/statistics/method-conditions/ilr-bases.md.",

        multiplicative_replacement_delta
          | std.option.Number
          | doc "Delta for multiplicative replacement, in (0,1), e.g., 0.65. Advanced. Martin-Fernandez et al. 2003; the operator refuses anything outside (0,1), warns below 0.01, and warns at or above 0.9.",

        bayesian_multiplicative_alpha
          | std.option.Number
          | doc "Prior concentration (alpha) of bayesian_multiplicative, > 0. Omitted means the reference GBM estimate 1/gmean(t); supplied means a hand-set prior, recorded as a deviation. Martin-Fernandez et al. 2015, as implemented in zCompositions::cmultRepl(method='GBM').",

        tss_css_rss_note
          | std.option.String
          | doc "Free-form note recorded with the configuration. Historical name: TSS/CSS/RSS are not deferred any more (issue #16), and this field is kept so existing documents keep parsing.",

        css_quantile
          | Number
          | CssQuantileContract
          | default = 0.75
          | doc "CSS: per-sample quantile whose cumulative sum is the scaling factor. Used only by method='css'. Paulson et al. 2013 use 0.5-0.75. See docs/statistics/method-conditions/scaling-and-offsets.md.",

        tmm_ref_column
          | std.option.String
          | doc "RSS/TMM: reference sample, or omitted to choose it the way edgeR chooses it (recorded either way). Used only by method='rss'.",

        tmm_log_ratio_trim
          | Number
          | TmmTrimContract
          | default = 0.3
          | doc "RSS/TMM: fraction trimmed from each log-ratio tail before the weighted mean; edgeR default 0.3.",

        tmm_sum_trim
          | Number
          | TmmTrimContract
          | default = 0.05
          | doc "RSS/TMM: fraction trimmed from each mean-abundance tail; edgeR default 0.05.",
      },

  correction
    | {
        method
          | [| 'BH, 'FDR, 'Benjamini-Hochberg, 'none, 'bonferroni |]
          | doc "BH mandatory in v1. Any override triggers DANGER banner and requires acknowledgment token. See CorrectionContract.",

        alpha
          | Number
          | std.contract.from_predicate (fun a => a > 0 && a < 1)
          | doc "FDR threshold, typically 0.05, must be in (0,1)",

        allow_no_correction
          | Bool
          | default = false
          | doc "If true, allows non-BH methods, but triggers DANGER banner and requires acknowledgment_token = I_UNDERSTAND_THE_RISK_AND_WANT_TO_OVERRIDE_BH",

        acknowledgment_token
          | std.option.String
          | doc "Must be 'I_UNDERSTAND_THE_RISK_AND_WANT_TO_OVERRIDE_BH' if allow_no_correction=true — scary DANGER banner for paper writers",
      }
    | CorrectionContract,

  advanced
    | {
        dispersion_method
          | DispersionMethod
          | default = 'parametric
          | doc "Dispersion estimation for NB_GLM: parametric (DESeq2 default), local, mean, pooled, or glmGamPoi, the pure-Julia port of the reference pipeline (Cox-Reid adjusted MLE, local-median trend, quasi-likelihood conversion, inverse-chisquare prior). The reference's spline abundance trend is not ported and is refused by name. See docs/statistics/method-conditions/dispersion-glmGamPoi.md.",

        zero_handling
          | ZeroHandling
          | default = 'pseudocount
          | doc "Zero handling. 'refuse' is DANGEROUS and requires acknowledgment token, mathematically invalid for CLR/ILR.",

        zero_policy
          | ZeroPolicy
          | default = 'pseudocount
          | doc "Zero policy enum, same as zero_handling but explicit. Advanced heavy validation warnings.",

        zero_replacement_method
          | std.option ZeroPolicy
          | doc "Explicit replacement method; must equal zero_policy when both are set. null means the policy name is the method. See src/analysis/zero_replacement.jl.",

        multiplicative_delta
          | std.option.Number
          | MultiplicativeDeltaContract
          | doc "delta of multiplicative replacement, exactly the (0,1) the operator accepts (0.65 is the reference's frac). Below 0.01 or at or above 0.9 warns. Martin-Fernandez et al. 2003; see docs/statistics/zero-handling.md.",

        bayesian_alpha
          | std.option.Number
          | BayesianAlphaContract
          | doc "alpha of bayesian_multiplicative, > 0. Supplying it is a hand-set prior and is recorded as a deviation from the reference's GBM estimate. Martin-Fernandez et al. 2015.",

        glmgampoi_abundance_trend
          | std.option.Bool
          | doc "glmGamPoi's natural-spline abundance trend for the variance prior. The spline is NOT ported: true is refused, null is refused at or above 100 features, false runs the reference's own non-trended prior and records the deviation.",

        pseudocount
          | Number
          | PseudocountContract
          | default = 0.5
          | doc "Custom pseudocount advanced, >0, typical 0.5, warnings for <0.1 or >=1, heavy validation.",

        epsilon
          | Number
          | EpsilonContract
          | default = 0.000001
          | doc "Epsilon for numerical stability, (0,1), typical 1e-6, warnings for >1e-3 or <1e-12, heavy validation.",

        min_prevalence
          | Number
          | PrevalenceContract
          | default = 0.1
          | doc "Minimum prevalence filter in [0,1]. 0.1 = present in >=10% samples.",

        min_abundance
          | Number
          | std.contract.from_predicate (fun v => v >= 0)
          | default = 0
          | doc "Minimum abundance threshold >=0",

        max_features
          | std.option.Number
          | doc "Max features to test. >100k refused as meaningless, <10 warning.",

        min_samples_per_group
          | Number
          | std.contract.from_predicate (fun v => v >= 2)
          | default = 3
          | doc "Minimum samples per group for variance estimation. <2 refused, <3 triggers DANGER banner, warning power low.",

        robust
          | Bool
          | default = false
          | doc "Robust estimation flag",

        acknowledgment_token
          | std.option.String
          | doc "Required for dangerous zero_handling='refuse' or min_samples_per_group<3",

        ilr_phylo_tree_path
          | std.option.String
          | optional
          | doc "Rooted, strictly bifurcating Newick tree for ilr_basis = phylogenetic (required then, refused otherwise). Tips = taxon ids exactly. SHA-256 recorded in provenance.",

        ilr_sbp_matrix_path
          | std.option.String
          | optional
          | doc "SBP CSV (taxa rows, balance columns, entries 1/-1/0) for ilr_basis = sequential_binary_partition (required then, refused otherwise). Validated per Egozcue & Pawlowsky-Glahn (2005). SHA-256 recorded.",

        ilr_balance_dendrogram_method
          | IlrDendrogramMethod
          | optional
          | doc "ward (R ward.D2), complete or average, for ilr_basis = balance_dendrogram (required then, refused otherwise).",

        ilr_part_weights
          | IlrPartWeights
          | default = 'uniform
          | doc "philr part.weights for a non-default basis: uniform, gm_counts, anorm, enorm, anorm_x_gm_counts, enorm_x_gm_counts.",

        ilr_balance_weights
          | IlrBalanceWeights
          | default = 'uniform
          | doc "philr ilr.weights, phylogenetic basis only: uniform, blw, blw_sqrt, mean_descendants. Non-uniform weights are not isometric (recorded).",

        ilr_sbp_history
          | Array Sha256Hex
          | default = []
          | doc "SHA-256 of SBP files tried earlier in the project. More than 3 distinct SBPs (including the current one) raises the DANGER banner.",
      }
    | ZeroHandlingContract,

  provenance
    | { .. }
    | doc "Provenance chain: metamanifold version, host, tools, etc. Enriched automatically. Includes dangerous flag, hash, created_at, created_by.",

  hash
    | String
    | doc "SHA256 of canonical JSON representation (immutable, content-addressed)",

  dangerous
    | Bool
    | doc "Computed is_dangerous — true if BH disabled, zero_handling refuse, min_samples_per_group<3, rarefy+NB_GLM. Triggers DANGER banner.",
}
| MethodNormalizationCompatibility
| IlrBasisInputsContract
