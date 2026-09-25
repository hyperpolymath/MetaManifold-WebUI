// SPDX-License-Identifier: AGPL-3.0-only
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// AnalysisConfig — safe, explicit, versioned layer
// Frontend types mirroring Julia src/analysis/AnalysisConfig.jl (capital)
// JSON + Nickel + DEED schemes from hyperpolymath/standards
// Milestone 3: immutable struct exactly matching user's answers (NB GLM, CLR/ILR+Gaussian, logistic v1, BH mandatory, DANGER banner, Advanced Analysis heavy validation for pseudocount/epsilon/zero_policy/etc.)

export type AnalysisMethod = 'nb_glm' | 'clr_lm' | 'ilr_lm' | 'logistic'

export type ZeroPolicy = 'pseudocount' | 'multiplicative_replacement' | 'bayesian_multiplicative' | 'refuse'

export type NormalizationMethod = 'none' | 'rarefy' | 'relative' | 'size_factors' | 'clr' | 'ilr' | 'presence_absence' | 'TSS' | 'CSS' | 'RSS' | 'tss' | 'css' | 'rss'

export interface NormalizationConfig {
  method: NormalizationMethod
  pseudocount: number
  epsilon: number
  zero_policy: ZeroPolicy
  ilr_basis?: string | null
  multiplicative_replacement_delta?: number | null
  tss_css_rss_note?: string | null
  // CSS: quantile of each sample's count distribution whose cumulative sum is the
  // scaling factor. Only used by method='css'. Default 0.75 (Paulson et al. 2013).
  css_quantile?: number
  // RSS/TMM: reference sample every other sample's log-ratios are taken against.
  // Omitted means "chosen the way edgeR chooses it", and the choice is recorded.
  tmm_ref_column?: string | null
  // RSS/TMM: fraction trimmed from each log-ratio tail before the weighted mean (0.3).
  tmm_log_ratio_trim?: number
  // RSS/TMM: fraction trimmed from each mean-abundance tail (0.05).
  tmm_sum_trim?: number
}

export interface CorrectionConfig {
  method: string
  alpha: number
  allow_no_correction: boolean
  acknowledgment_token?: string | null
}

export interface AdvancedConfig {
  dispersion_method: 'parametric' | 'local' | 'mean' | 'pooled' | 'glmGamPoi'
  zero_handling: ZeroPolicy
  zero_policy: ZeroPolicy
  pseudocount: number
  epsilon: number
  min_prevalence: number
  min_abundance: number
  max_features?: number | null
  min_samples_per_group: number
  robust: boolean
  acknowledgment_token?: string | null
}

// Backwards compatibility alias — old tests and lowercase file use AdvancedOverrides
export type AdvancedOverrides = AdvancedConfig

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
  advanced: AdvancedConfig
  provenance: Record<string, unknown>
  hash: string
  dangerous: boolean
}

// Alias for backwards compatibility
export type AnalysisConfigStruct = AnalysisConfig

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

export const SCHEMA_VERSION = '1.0.0'

/** Report whether the current fields match a client-recognised risky configuration. */
export function isDangerous(config: AnalysisConfig): boolean {
  if (config.correction.allow_no_correction) return true
  if (config.advanced.zero_handling === 'refuse' || config.advanced.zero_policy === 'refuse') return true
  if (config.normalization.zero_policy === 'refuse') return true
  if (config.normalization.method === 'rarefy' && config.method === 'nb_glm') return true
  if (config.advanced.min_samples_per_group < 3) return true
  return false
}

/** Return a provenance-rich warning banner for a dangerous configuration, otherwise null. */
export function dangerBanner(config: AnalysisConfig): string | null {
  if (!isDangerous(config)) return null
  const reasons: string[] = []
  if (config.correction.allow_no_correction) {
    reasons.push(`BH correction disabled (method=${config.correction.method}) — will inflate false discoveries (e.g., 1500 taxa → ~75 false positives under null at alpha=0.05)`)
  }
  if (config.advanced.zero_handling === 'refuse' || config.advanced.zero_policy === 'refuse') {
    reasons.push(`zero_handling='refuse' — will cause log(0) for CLR/ILR and biased handling for NB_GLM — mathematically invalid for CLR/ILR even with token`)
  }
  if (config.advanced.min_samples_per_group < 3) {
    reasons.push(`min_samples_per_group=${config.advanced.min_samples_per_group} <3 — statistical power very low, results unreliable`)
  }
  if (config.normalization.method === 'rarefy' && config.method === 'nb_glm') {
    reasons.push(`rarefy + NB_GLM — rarefy discards data and NB_GLM already handles library size via size_factors — combining is questionable`)
  }
  return `
╔════════════════════════════════════════════════════════════════════════════╗
║  ⚠️  DANGER — SCIENTIFICALLY RISKY CONFIGURATION DETECTED  ⚠️             ║
║  This configuration overrides safe defaults and may produce             ║
║  misleading or irreproducible results. Review carefully before          ║
║  publishing. This banner will be logged, included in provenance,       ║
║  and in DOI bundle.                                                    ║
╠════════════════════════════════════════════════════════════════════════════╣
║  Reasons:                                                              ║
${reasons.map(r => `║  - ${r}`).join('\n')}
║                                                                        ║
║  Acknowledgment token: ${config.correction.acknowledgment_token ?? config.advanced.acknowledgment_token ?? 'none'} ║
║  Config ID: ${config.id}                                                ║
║  Hash: ${config.hash}                                                   ║
║  Method: ${config.method}                             ║
║  Formula: ${config.formula}                                             ║
║                                                                        ║
║  If you are writing a paper, you MUST disclose these overrides in      ║
║  Methods and discuss limitations. Uncorrected p-values in high-dim     ║
║  data are NOT publishable without strong justification.                ║
╚════════════════════════════════════════════════════════════════════════════╝
`
}

/** Return help for a recognised analysis field path, or a path-specific fallback. */
export function contextHelp(fieldPath: string): string {
  const helpDb: Record<string, string> = {
    method: `Analysis Method (required, explicit, no auto-selection) — v1: NB GLM, CLR/ILR+Gaussian, logistic

- nb_glm: Negative Binomial GLM for raw counts with overdispersion. Uses DESeq2-style size_factors. Best for counts, handles library size via size_factors, dispersion via parametric/local/mean/pooled/glmGamPoi. See Love et al. 2014.
- clr_lm: Centered Log-Ratio + Gaussian LM (compositional, Aitchison geometry). Requires pseudocount >0 because log(0) undefined. Handles compositional data (relative abundances). See Gloor et al. 2017.
- ilr_lm: Isometric Log-Ratio + Gaussian LM (balances, phylogenetic basis possible). Requires pseudocount >0 and ilr_basis. Basis options: default, phylogenetic, sequential_binary_partition, balance_dendrogram. See Egozcue et al. 2003.
- logistic: Logistic regression for binary outcome (presence/absence). Requires outcome_column. Normalization presence_absence or relative.

No silent switching. Every analysis explicit. See JSON schema and Nickel contract MethodNormalizationCompatibility.
`,
    formula: `R-style formula, e.g. '~ group' or 'disease ~ group + batch'

- Left of ~ is outcome (required for logistic, must match outcome_column)
- Right of ~ lists metadata columns, e.g. group + batch
- Must reference only columns in metadata_columns — no auto-selection
- Forbidden: ; \` $ (injection prevention, see ValidFormula contract in Nickel)
- Must contain ~ and at least one column after ~
- Example: "~ group" tests effect of group, "~ group + batch" controls for batch
- For logistic: "disease ~ group" with outcome_column="disease"

Refuses meaningless inputs: empty, "~", "group" without ~, forbidden chars.
See JSON schema pattern ^[^;\`$]+$ and Nickel ValidFormula.
`,
    'normalization.method': `Normalization / Transform (method-dependent) — must be compatible with method

- For NB_GLM: none, size_factors (median-of-ratios), relative, rarefy (discouraged), tss, css, rss
- For CLR_LM: must be clr — Centered Log-Ratio, requires pseudocount >0
- For ILR_LM: must be ilr — Isometric Log-Ratio, requires pseudocount >0 and ilr_basis
- For LOGISTIC: presence_absence, none, relative, rarefy, tss

How the count-model choices differ (each is an offset, not a transform; counts stay counts):

- tss (total sum scaling): offset = log(library size). The McMurdie & Holmes (2014) answer to rarefaction: model depth, do not divide by it.
- css (cumulative sum scaling, Paulson et al. 2013): offset = log of the sum of counts at or below each sample's own quantile, set by css_quantile (default 0.75). Robust to a few dominant taxa. Refused when that sum is zero for any sample.
- rss (TMM, Robinson & Oshlack 2010): offset = log of a trimmed weighted mean of log-ratios against a reference sample; set by tmm_log_ratio_trim (0.3), tmm_sum_trim (0.05) and tmm_ref_column. Assumes most features are not differentially abundant.
- size_factors: median-of-ratios (DESeq2/RLE), in the offset form.
- relative: proportions. A transform, not an offset: it discards the count nature of the data.
- none: no scaling; for a count model the offset is the plain log library size.

None of these removes the compositional constraint. They correct for sequencing depth; a log fold change from a model with these offsets is still relative to the sampled community. css and rss are refused for a response with no counts to offset.

Refuses meaningless: NB_GLM + clr/ilr (counts vs compositional), CLR_LM + none, css/rss on a non-count response, etc. See Nickel MethodNormalizationCompatibility contract.
See docs/statistics/method-conditions/scaling-and-offsets.md, JSON schema enum and DEED (normalization :method).
`,
    'normalization.css_quantile': `CSS quantile (normalization.method = css only)

- The per-sample quantile of the count distribution whose cumulative sum becomes the scaling factor. Paulson et al. (2013) use 0.5-0.75; the default here is 0.75.
- Must be in (0,1). Below 0.5 the cumulative sum covers less than half of a sample's counts and is dominated by how many features are zero — a warning is issued.
- Refused at run time when that cumulative sum is zero for any sample (log(0) is not a small number). Raise the quantile or exclude the sample.
- metagenomeSeq's data-driven choice of this quantile (cumNormStatFast) is deliberately not implemented: a parameter chosen from the data is a decision the run has to record.

Recorded in the config hash and in the manifest provenance.
`,
    'normalization.tmm_ref_column': `TMM reference sample (normalization.method = rss only)

- Names the sample every other sample's log-ratios are taken against.
- Omitted (the default): the reference is chosen the way edgeR chooses it — the sample whose upper-quartile-scaled counts are closest to the mean of those values. Which sample was chosen is recorded in the provenance.
- The name is not checked until the run has the sample list; an unknown name is refused there, by name, rather than silently falling back to the data-driven choice.

Recorded in the config hash.
`,
    'normalization.tmm_log_ratio_trim': `TMM log-ratio trimming (normalization.method = rss only)

- Fraction trimmed from each tail of the log-ratios before the weighted mean: 0.3 by default, as in edgeR.
- Must be in [0,0.5). Zero means no trimming, which removes the robustness TMM is used for; both values are recorded, so an untrimmed run is visible rather than assumed.

Recorded in the config hash.
`,
    'normalization.tmm_sum_trim': `TMM abundance trimming (normalization.method = rss only)

- Fraction trimmed from each tail of the mean abundances before the weighted mean: 0.05 by default, as in edgeR.
- Must be in [0,0.5). Zero means no trimming of the abundance tails.

Recorded in the config hash.
`,
    'normalization.pseudocount': `Pseudocount for zero replacement (CLR/ILR mandatory, NB_GLM optional but warned)

- Must be >0 because log(0) undefined — refuses 0 or negative
- Typical: 0.5 (common), 0.65 (Martín-Fernández et al.), 1.0 (conservative but distorts)
- Too small (<0.1) creates extreme log-ratios for zeros, too large (>=1) distorts low-abundance features — warnings issued
- For NB_GLM size_factors: ignored, warning issued if not default 0.5
- Advanced: custom pseudocount behind Advanced Analysis expander, hidden unless Evidence Mode, heavy validation, warnings

See JSON schema exclusiveMinimum 0 and Nickel PseudocountContract.
See context_help('advanced.pseudocount') for advanced warnings.
`,
    'normalization.epsilon': `Epsilon for numerical stability (advanced, behind Advanced Analysis)

- Must be in (0,1), typical 1e-6
- Used for zero handling and log transforms numerical stability
- Too large >1e-3 may affect zero handling and log transforms — warning
- Too small <1e-12 may cause underflow — warning
- Heavy validation, refusal if not in (0,1)

See context_help('advanced.epsilon') and Nickel contract.
`,
    'normalization.zero_policy': `Zero handling policy (advanced)

- pseudocount: add pseudocount to zeros (default, safe)
- multiplicative_replacement: replace zeros via multiplicative replacement (Martín-Fernández et al.), requires multiplicative_replacement_delta in (0,1)
- bayesian_multiplicative: Bayesian multiplicative replacement
- refuse: refuse to handle zeros — DANGEROUS, requires DANGER token, mathematically invalid for CLR/ILR (log(0) undefined), will be refused at runtime even with token

See context_help('advanced.zero_policy') and Nickel ZeroHandlingContract.
`,
    'correction.method': `Multiple testing correction — BH mandatory in v1, hard-stop DANGER banner on overrides

Microbiome data tests thousands of taxa. Uncorrected p-values give ~5% false positives under null (e.g., 1500 taxa → 75 false positives).

- BH mandatory in v1 — any override triggers DANGER banner and requires acknowledgment token
- Allowed: BH, FDR, Benjamini-Hochberg (all normalized to BH)
- Override: set allow_no_correction=true and acknowledgment_token='I_UNDERSTAND_THE_RISK_AND_WANT_TO_OVERRIDE_BH' — will be logged, bannered, included in DOI bundle provenance, scary DANGER banner for paper writers

See JSON schema and Nickel CorrectionContract, and danger_banner().

Scientific value: Prevents p-hacking and false discoveries. See Benjamini & Hochberg 1995.
`,
    'advanced.pseudocount': `Custom pseudocount (advanced, behind Advanced Analysis, hidden unless Evidence Mode)

- Must be >0, typical 0.5
- <0.1 very small → extreme log-ratios for zeros — warning
- >=1 unusual → distorts low-abundance — warning
- Heavy validation, refusal if <=0
- Warnings for paper writers: "pseudocount <0.1 very small will create extreme log-ratios" etc.

See normalization.pseudocount and Nickel PseudocountContract.
`,
    'advanced.epsilon': `Epsilon for numerical stability (advanced, behind Advanced Analysis)

- Must be in (0,1), typical 1e-6
- >1e-3 large may affect transforms — warning
- <1e-12 extremely small may cause underflow — warning
- Heavy validation refusal if not in (0,1)

See normalization.epsilon.
`,
    'advanced.zero_policy': `Zero policy (advanced, same as zero_handling but enum)

See advanced.zero_handling — pseudocount, multiplicative_replacement, bayesian_multiplicative, refuse.

Refuse is DANGEROUS and requires token, but still refused at runtime for CLR/ILR because log(0) undefined.

See Nickel ZeroHandlingContract.
`,
    'advanced.min_prevalence': `Minimum prevalence filter [0,1] (advanced)

- Feature must be present in at least this fraction of samples
- 0.1 = present in >=10% samples — recommended to reduce multiple testing burden
- 0 = no filter, 1 = present in 100% samples
- Heavy validation [0,1]

See JSON schema and Nickel PrevalenceContract.
`,
    'advanced.dispersion_method': `Dispersion estimation (NB_GLM advanced, behind Advanced Analysis)

- parametric: fit dispersion ~ mean trend (DESeq2 default, recommended)
- local: local regression fit (when parametric fails)
- mean: use mean dispersion (when n small)
- pooled: pool across genes (when n very small)
- glmGamPoi: fast estimator from glmGamPoi package (deferred, fast)

Heavy validation, only meaningful for NB_GLM, warning if used for other methods.

See Love et al. 2014 and context_help('method').
`,
  }
  return helpDb[fieldPath] ?? `No help available for '${fieldPath}'. See JSON schema and Nickel contracts. Field path examples: method, formula, metadata_columns, normalization.method, correction.method, advanced.pseudocount, advanced.epsilon, advanced.zero_policy.`
}
