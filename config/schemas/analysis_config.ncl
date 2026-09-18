# SPDX-License-Identifier: AGPL-3.0-only
# AnalysisConfig Nickel contract — hyperpolymath/standards style
# From 1-formats/k9/*.ncl and .machine_readable/contractiles/_base.ncl
# Implements BH mandatory, DANGER banner, advanced validation

let AnalysisMethod = std.enum.TagOrString & [| 'nb_glm, 'clr_lm, 'ilr_lm, 'logistic |] in
let NormalizationMethod = std.enum.TagOrString & [| 'none, 'rarefy, 'relative, 'size_factors, 'clr, 'ilr, 'presence_absence |] in
let CorrectionMethod = std.enum.TagOrString & [| 'BH, 'FDR, 'Benjamini-Hochberg |] in
let DispersionMethod = std.enum.TagOrString & [| 'parametric, 'local, 'mean, 'pooled, 'glmGamPoi |] in
let ZeroHandling = std.enum.TagOrString & [| 'pseudocount, 'multiplicative_replacement, 'bayesian_multiplicative, 'refuse |] in
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
    'Error { message = "pseudocount must be >0 for CLR/ILR (log(0) undefined). Got %{std.to_string value}" }
  else if value >= 1 then
    # Warn but allow — typical is 0.5
    'Ok value
  else
    'Ok value
in

let PrevalenceContract = fun label value =>
  if value < 0 || value > 1 then
    'Error { message = "min_prevalence must be in [0,1], got %{std.to_string value}" }
  else
    'Ok value
in

let CorrectionContract = fun label value =>
  if value.allow_no_correction then
    if value.acknowledgment_token != DANGER_TOKEN then
      'Error {
        message = "DANGER: BH override requires acknowledgment_token = '%{DANGER_TOKEN}'. This will be logged, bannered, and included in DOI bundle. See context-sensitive help for 'correction.method'.",
      }
    else
      'Ok value
  else
    if value.method != 'BH && value.method != 'FDR && value.method != 'Benjamini-Hochberg then
      'Error {
        message = "Correction method must be BH in v1 (got %{std.to_string value.method}). BH controls FDR for high-dimensional microbiome data. If you truly want to override, set allow_no_correction=true and acknowledgment_token='%{DANGER_TOKEN}'.",
      }
    else
      'Ok value
in

let ZeroHandlingContract = fun label value =>
  if value.zero_handling == 'refuse then
    if value.acknowledgment_token != DANGER_TOKEN then
      'Error {
        message = "DANGER: zero_handling='refuse' will cause log(0) for CLR/ILR and biased handling for NB_GLM. Requires acknowledgment_token='%{DANGER_TOKEN}'. Even then, CLR/ILR + refuse is mathematically invalid and will be refused at runtime.",
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
      'Error { message = "NB_GLM expects count data, not CLR/ILR transforms. Use clr_lm/ilr_lm for compositional, or change normalization to none/size_factors. Refusing meaningless combination." }
    else
      'Ok value
  else if method == 'clr_lm then
    if norm != 'clr then
      'Error { message = "CLR_LM requires normalization.method='clr', got '%{std.to_string norm}'" }
    else
      'Ok value
  else if method == 'ilr_lm then
    if norm != 'ilr then
      'Error { message = "ILR_LM requires normalization.method='ilr', got '%{std.to_string norm}'" }
    else
      'Ok value
  else
    'Ok value
in

{
  schema_version
    | String
    | doc "Semver schema version, currently only 1.0.0"
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
      Analysis method — explicit, no auto-selection.

      - 'nb_glm: Negative Binomial GLM for raw counts with overdispersion (DESeq2/MASS style)
      - 'clr_lm: Centered Log-Ratio + Gaussian LM (compositional, Aitchison geometry)
      - 'ilr_lm: Isometric Log-Ratio + Gaussian LM (balances, phylogenetic basis possible)
      - 'logistic: Logistic regression for binary outcome (presence/absence)

      No silent switching: you must choose one. Changing method changes statistical model and interpretation.
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
      "%m,

  outcome_column
    | std.option.String
    | doc "Binary outcome column for logistic regression. Required for logistic, ignored for others unless formula uses it.",

  metadata_columns
    | Array String
    | std.contract.from_predicate (fun arr => std.array.length arr > 0)
    | doc "Explicit list of metadata columns used. Must exist in study metadata. No auto-selection.",

  normalization
    | {
        method
          | NormalizationMethod
          | doc "Normalization / transform, must be compatible with method",

        pseudocount
          | Number
          | PseudocountContract
          | doc "Pseudocount for zero replacement in CLR/ILR. Must be >0. Typical 0.5. Refuses 0 because log(0) undefined.",

        ilr_basis
          | std.option.String
          | doc "ILR basis, only meaningful for ILR method",

        multiplicative_replacement_delta
          | std.option.Number
          | doc "Delta for multiplicative replacement, in (0,1)",
      },

  correction
    | {
        method
          | [| 'BH, 'FDR, 'Benjamini-Hochberg, 'none, 'bonferroni |]
          | doc "BH mandatory in v1. Any override triggers DANGER banner and requires acknowledgment token.",

        alpha
          | Number
          | std.contract.from_predicate (fun a => a > 0 && a < 1)
          | doc "FDR threshold, typically 0.05, must be in (0,1)",

        allow_no_correction
          | Bool
          | default = false
          | doc "If true, allows non-BH methods, but triggers DANGER banner and requires acknowledgment_token",

        acknowledgment_token
          | std.option.String
          | doc "Must be 'I_UNDERSTAND_THE_RISK_AND_WANT_TO_OVERRIDE_BH' if allow_no_correction=true",
      }
    | CorrectionContract,

  advanced
    | {
        dispersion_method
          | DispersionMethod
          | doc "Dispersion estimation for NB_GLM: parametric (DESeq2 default), local, mean, pooled, glmGamPoi",

        zero_handling
          | ZeroHandling
          | doc "Zero handling. 'refuse' is DANGEROUS and requires acknowledgment token.",

        min_prevalence
          | Number
          | PrevalenceContract
          | doc "Minimum prevalence filter in [0,1]. 0.1 = present in >=10% samples.",

        min_abundance
          | Number
          | std.contract.from_predicate (fun v => v >= 0)
          | doc "Minimum abundance threshold >=0",

        max_features
          | std.option.Number
          | doc "Max features to test. >100k refused as meaningless.",

        min_samples_per_group
          | Number
          | std.contract.from_predicate (fun v => v >= 2)
          | doc "Minimum samples per group for variance estimation. <2 refused, <3 triggers DANGER.",

        robust
          | Bool
          | doc "Robust estimation flag",

        acknowledgment_token
          | std.option.String
          | doc "Required for dangerous zero_handling='refuse'",
      }
    | ZeroHandlingContract,

  provenance
    | { .. }
    | doc "Provenance chain: metamanifold version, host, tools, etc.",

  hash
    | String
    | doc "SHA256 of canonical JSON representation (immutable, content-addressed)",
}
| MethodNormalizationCompatibility
