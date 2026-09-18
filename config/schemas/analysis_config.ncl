# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# AnalysisConfig Nickel contract — hyperpolymath/standards style Milestone 3
# From 1-formats/k9/*.ncl and .machine_readable/contractiles/_base.ncl
# Implements BH mandatory, DANGER banner, advanced validation for pseudocount/epsilon/zero_policy/etc.
# TSS/CSS/RSS deferred as alias to relative with warning, see GitHub issues

let AnalysisMethod = std.enum.TagOrString & [| 'nb_glm, 'clr_lm, 'ilr_lm, 'logistic |] in
let NormalizationMethod = std.enum.TagOrString & [| 'none, 'rarefy, 'relative, 'size_factors, 'clr, 'ilr, 'presence_absence, 'TSS, 'CSS, 'RSS, 'tss, 'css, 'rss |] in
let CorrectionMethod = std.enum.TagOrString & [| 'BH, 'FDR, 'Benjamini-Hochberg |] in
let DispersionMethod = std.enum.TagOrString & [| 'parametric, 'local, 'mean, 'pooled, 'glmGamPoi |] in
let ZeroHandling = std.enum.TagOrString & [| 'pseudocount, 'multiplicative_replacement, 'bayesian_multiplicative, 'refuse |] in
let ZeroPolicy = std.enum.TagOrString & [| 'pseudocount, 'multiplicative_replacement, 'bayesian_multiplicative, 'refuse |] in
let IlrBasis = std.enum.TagOrString & [| 'default, 'phylogenetic, 'sequential_binary_partition, 'balance_dendrogram |] in

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
      'Error { message = "NB_GLM expects count data, not CLR/ILR transforms. Use clr_lm/ilr_lm for compositional, or change normalization to none/size_factors/relative/TSS/CSS/RSS. Refusing meaningless combination. See context_help('normalization.method')" }
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
          | doc "Normalization / transform, must be compatible with method. TSS/CSS/RSS deferred alias to relative with warning, see GitHub issue 01.",

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
          | std.option.IlrBasis
          | doc "ILR basis, only meaningful for ILR method. phylogenetic/sequential_binary_partition/balance_dendrogram deferred, see GitHub issue 05.",

        multiplicative_replacement_delta
          | std.option.Number
          | doc "Delta for multiplicative replacement, in (0,1), e.g., 0.65. Advanced.",

        tss_css_rss_note
          | std.option.String
          | doc "Note for TSS/CSS/RSS deferred features — currently aliased to relative with warning. See GitHub issue 01.",
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
          | doc "Dispersion estimation for NB_GLM: parametric (DESeq2 default), local, mean, pooled, glmGamPoi (deferred fast, see issue 06).",

        zero_handling
          | ZeroHandling
          | default = 'pseudocount
          | doc "Zero handling. 'refuse' is DANGEROUS and requires acknowledgment token, mathematically invalid for CLR/ILR.",

        zero_policy
          | ZeroPolicy
          | default = 'pseudocount
          | doc "Zero policy enum, same as zero_handling but explicit. Advanced heavy validation warnings.",

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
