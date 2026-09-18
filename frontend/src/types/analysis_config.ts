// SPDX-License-Identifier: AGPL-3.0-only
// AnalysisConfig — safe, explicit, versioned layer
// Frontend types mirroring Julia src/analysis/analysis_config.jl
// JSON + Nickel + DEED schemes from hyperpolymath/standards

export type AnalysisMethod = 'nb_glm' | 'clr_lm' | 'ilr_lm' | 'logistic'

export interface NormalizationConfig {
  method: 'none' | 'rarefy' | 'relative' | 'size_factors' | 'clr' | 'ilr' | 'presence_absence'
  pseudocount: number
  ilr_basis?: string | null
  multiplicative_replacement_delta?: number | null
}

export interface CorrectionConfig {
  method: string
  alpha: number
  allow_no_correction: boolean
  acknowledgment_token?: string | null
}

export interface AdvancedOverrides {
  dispersion_method: 'parametric' | 'local' | 'mean' | 'pooled' | 'glmGamPoi'
  zero_handling: 'pseudocount' | 'multiplicative_replacement' | 'bayesian_multiplicative' | 'refuse'
  min_prevalence: number
  min_abundance: number
  max_features?: number | null
  min_samples_per_group: number
  robust: boolean
  acknowledgment_token?: string | null
}

export interface AnalysisConfig {
  schema_version: string
  id: string
  created_at: string
  created_by: string
  method: AnalysisMethod
  formula: string
  outcome_column?: string | null
  metadata_columns: string[]
  normalization: NormalizationConfig
  correction: CorrectionConfig
  advanced: AdvancedOverrides
  provenance: Record<string, unknown>
  hash: string
}

export interface AnalysisResult {
  id: string
  config_id: string
  config_hash: string
  created_at: string
  method: AnalysisMethod
  results: Record<string, unknown>
  provenance: Record<string, unknown>
  hash: string
}

export interface ValidationError {
  field: string
  message: string
  help?: string
}

export const DANGER_ACK_TOKEN = 'I_UNDERSTAND_THE_RISK_AND_WANT_TO_OVERRIDE_BH'

export function isDangerous(config: AnalysisConfig): boolean {
  if (config.correction.allow_no_correction) return true
  if (config.advanced.zero_handling === 'refuse') return true
  if (config.normalization.method === 'rarefy' && config.method === 'nb_glm') return true
  if (config.advanced.min_samples_per_group < 3) return true
  return false
}

export function contextHelp(fieldPath: string): string {
  const helpDb: Record<string, string> = {
    method: `Analysis Method (required, explicit, no auto-selection)
- nb_glm: Negative Binomial GLM for raw counts with overdispersion. Uses DESeq2-style size factors.
- clr_lm: Centered Log-Ratio + Gaussian LM (compositional, Aitchison geometry). Requires pseudocount.
- ilr_lm: Isometric Log-Ratio + Gaussian LM (balances, phylogenetic basis possible)
- logistic: Logistic regression for binary outcome (presence/absence)`,
    formula: `R-style formula, e.g. '~ group' or 'disease ~ group + batch'
- Left of ~ is outcome (required for logistic)
- Right of ~ lists metadata columns
- Must reference only columns in metadata_columns
- Forbidden: ; \` $ (injection prevention)`,
    'normalization.method': `Normalization / Transform (method-dependent)
- For NB_GLM: none, size_factors, relative, rarefy (discouraged)
- For CLR_LM: must be clr
- For ILR_LM: must be ilr
- For LOGISTIC: presence_absence, none, relative`,
    'normalization.pseudocount': `Pseudocount for zero replacement (CLR/ILR only)
Typical: 0.5. Must be >0 because log(0) undefined.
Too small creates extreme log-ratios, too large distorts low-abundance features.`,
    'correction.method': `Multiple testing correction — BH mandatory in v1
Microbiome data tests thousands of taxa. Uncorrected p-values give ~5% false positives under null.
BH (Benjamini-Hochberg FDR) is mandatory. Override requires DANGER banner and acknowledgment token.`,
    'advanced.min_prevalence': `Minimum prevalence filter [0,1]
Feature must be present in at least this fraction of samples.
0.1 = present in >=10% samples. Recommended to reduce multiple testing burden.`,
    'advanced.dispersion_method': `Dispersion estimation (NB_GLM advanced)
- parametric: fit dispersion ~ mean trend (DESeq2 default)
- local: local regression fit
- mean: use mean dispersion
- pooled: pool across genes (when n small)
- glmGamPoi: fast estimator`,
  }
  return helpDb[fieldPath] ?? `No help available for '${fieldPath}'.`
}
