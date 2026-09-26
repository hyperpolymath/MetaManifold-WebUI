// SPDX-License-Identifier: AGPL-3.0-only
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// AnalysisConfig — safe, explicit, versioned layer
// Frontend types mirroring Julia src/analysis/AnalysisConfig.jl (capital)
// JSON + Nickel + DEED schemes from hyperpolymath/standards
// Milestone 3: immutable struct exactly matching user's answers (NB GLM, CLR/ILR+Gaussian, logistic v1, BH mandatory, DANGER banner, Advanced Analysis heavy validation for pseudocount/epsilon/zero_policy/etc.)

export type AnalysisMethod = 'nb_glm' | 'clr_lm' | 'ilr_lm' | 'logistic'

export type ZeroPolicy = 'pseudocount' | 'multiplicative_replacement' | 'bayesian_multiplicative' | 'refuse'

export type NormalizationMethod = 'none' | 'rarefy' | 'relative' | 'size_factors' | 'clr' | 'ilr' | 'presence_absence' | 'TSS' | 'CSS' | 'RSS' | 'tss' | 'css' | 'rss'

// ILR bases (issue #20). Conditions, refusals and evidence:
// docs/statistics/method-conditions/ilr-bases.md. Mirrors AnalysisConfig.jl.
export const ILR_BASES = ['default', 'phylogenetic', 'sequential_binary_partition', 'balance_dendrogram'] as const
export type IlrBasis = typeof ILR_BASES[number]
export const ILR_PART_WEIGHTS = ['uniform', 'gm_counts', 'anorm', 'enorm', 'anorm_x_gm_counts', 'enorm_x_gm_counts'] as const
export type IlrPartWeights = typeof ILR_PART_WEIGHTS[number]
export const ILR_BALANCE_WEIGHTS = ['uniform', 'blw', 'blw_sqrt', 'mean_descendants'] as const
export type IlrBalanceWeights = typeof ILR_BALANCE_WEIGHTS[number]
export const ILR_DENDROGRAM_METHODS = ['ward', 'complete', 'average'] as const
export type IlrDendrogramMethod = typeof ILR_DENDROGRAM_METHODS[number]
/** More than this many distinct SBP matrices (history plus the current one) raises the DANGER banner. */
export const ILR_SBP_ATTEMPT_DANGER_THRESHOLD = 3

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
  // ILR basis inputs (issue #20). Optional so that configurations written before them
  // still type-check; absent means unset / 'uniform' / [] exactly as in the backend.
  ilr_phylo_tree_path?: string | null
  ilr_sbp_matrix_path?: string | null
  ilr_balance_dendrogram_method?: IlrDendrogramMethod | null
  ilr_part_weights?: IlrPartWeights
  ilr_balance_weights?: IlrBalanceWeights
  ilr_sbp_history?: string[]
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

const ILR_PATH_FORBIDDEN = /["\n\r\0[\]{}`;$]/

function ilrSet(value: string | null | undefined): boolean {
  return value !== undefined && value !== null && value.trim() !== ''
}

/** The ILR basis in force: the normalization's, or 'default' when unset. */
export function ilrBasisOf(config: AnalysisConfig): IlrBasis {
  const b = config.normalization.ilr_basis
  return (ILR_BASES as readonly string[]).includes(b ?? '') ? (b as IlrBasis) : 'default'
}

/** Distinct SBP matrices recorded as tried (the run adds the current file's digest). */
export function ilrSbpAttempts(advanced: AdvancedConfig): number {
  return new Set((advanced.ilr_sbp_history ?? []).map(h => h.trim().toLowerCase())).size
}

/**
 * The ILR basis-input contract — the same table as `_validate_ilr_inputs` in
 * AnalysisConfig.jl, the JSON schema's allOf rules and Nickel IlrBasisInputsContract:
 * each non-default basis requires its own input and forbids the others'. File
 * existence is checked by the run, not here.
 */
export function ilrInputProblems(config: AnalysisConfig): ValidationError[] {
  const a = config.advanced
  const problems: ValidationError[] = []
  const push = (field: string, message: string) => problems.push({ field, message, help: contextHelp(field) })
  for (const [field, value] of [['advanced.ilr_phylo_tree_path', a.ilr_phylo_tree_path], ['advanced.ilr_sbp_matrix_path', a.ilr_sbp_matrix_path]] as const) {
    if (value !== undefined && value !== null && value.trim() === '') push(field, `${field} is empty — give the path of the file, or leave the field unset.`)
    else if (ilrSet(value) && ILR_PATH_FORBIDDEN.test(value as string)) push(field, `${field} contains a character that is not allowed in a path here (quote, newline, NUL, brackets, backtick, ';' or '$').`)
  }
  const partW = a.ilr_part_weights ?? 'uniform'
  const balW = a.ilr_balance_weights ?? 'uniform'
  const history = a.ilr_sbp_history ?? []
  for (const h of history) {
    if (!/^[0-9a-f]{64}$/.test(h.trim().toLowerCase())) push('advanced.ilr_sbp_history', `advanced.ilr_sbp_history entries must be SHA-256 hex digests (64 hex characters) — got '${h}'.`)
  }
  if (config.normalization.method !== 'ilr') {
    const fields: Array<[string, boolean]> = [
      ['advanced.ilr_phylo_tree_path', ilrSet(a.ilr_phylo_tree_path)],
      ['advanced.ilr_sbp_matrix_path', ilrSet(a.ilr_sbp_matrix_path)],
      ['advanced.ilr_balance_dendrogram_method', ilrSet(a.ilr_balance_dendrogram_method)],
      ['advanced.ilr_part_weights', partW !== 'uniform'],
      ['advanced.ilr_balance_weights', balW !== 'uniform'],
      ['advanced.ilr_sbp_history', history.length > 0],
    ]
    for (const [field, set] of fields) {
      if (set) push(field, `${field} only meaningful for the ILR transform (normalization.method = '${config.normalization.method}').`)
    }
    return problems
  }
  const basis = ilrBasisOf(config)
  const pairs: Array<[string, IlrBasis, boolean]> = [
    ['advanced.ilr_phylo_tree_path', 'phylogenetic', ilrSet(a.ilr_phylo_tree_path)],
    ['advanced.ilr_sbp_matrix_path', 'sequential_binary_partition', ilrSet(a.ilr_sbp_matrix_path)],
    ['advanced.ilr_balance_dendrogram_method', 'balance_dendrogram', ilrSet(a.ilr_balance_dendrogram_method)],
  ]
  for (const [field, wanted, set] of pairs) {
    if (basis === wanted && !set) push(field, `normalization.ilr_basis = '${wanted}' requires ${field}.`)
    if (basis !== wanted && set) push(field, `${field} is only used by ilr_basis = '${wanted}', but ilr_basis is '${basis}'. Refusing an input that would be silently ignored.`)
  }
  if (basis === 'default' && partW !== 'uniform') push('advanced.ilr_part_weights', `advanced.ilr_part_weights = '${partW}' needs a phylogenetic, sequential_binary_partition or balance_dendrogram basis: the default Helmert basis is unweighted.`)
  if (basis !== 'phylogenetic' && balW !== 'uniform') push('advanced.ilr_balance_weights', `advanced.ilr_balance_weights = '${balW}' needs branch lengths, which only ilr_basis = 'phylogenetic' has.`)
  if (basis !== 'sequential_binary_partition' && history.length > 0) push('advanced.ilr_sbp_history', `advanced.ilr_sbp_history is only used by ilr_basis = 'sequential_binary_partition'.`)
  return problems
}

/**
 * Switch the ILR basis explicitly. Inputs that belong to other bases are cleared (they
 * would otherwise be refused as silently ignored); the new basis's required input is
 * left unset for the user to supply — nothing is chosen for them.
 */
export function withIlrBasis(config: AnalysisConfig, basis: IlrBasis): AnalysisConfig {
  const a = config.advanced
  return {
    ...config,
    normalization: { ...config.normalization, ilr_basis: basis },
    advanced: {
      ...a,
      ilr_phylo_tree_path: basis === 'phylogenetic' ? (a.ilr_phylo_tree_path ?? null) : null,
      ilr_sbp_matrix_path: basis === 'sequential_binary_partition' ? (a.ilr_sbp_matrix_path ?? null) : null,
      ilr_balance_dendrogram_method: basis === 'balance_dendrogram' ? (a.ilr_balance_dendrogram_method ?? null) : null,
      ilr_part_weights: basis === 'default' ? 'uniform' : (a.ilr_part_weights ?? 'uniform'),
      ilr_balance_weights: basis === 'phylogenetic' ? (a.ilr_balance_weights ?? 'uniform') : 'uniform',
      ilr_sbp_history: basis === 'sequential_binary_partition' ? (a.ilr_sbp_history ?? []) : [],
    },
  }
}

/** Clear every ILR basis input (used when the normalization stops being ILR). */
export function withoutIlrInputs(advanced: AdvancedConfig): AdvancedConfig {
  return {
    ...advanced,
    ilr_phylo_tree_path: null,
    ilr_sbp_matrix_path: null,
    ilr_balance_dendrogram_method: null,
    ilr_part_weights: 'uniform',
    ilr_balance_weights: 'uniform',
    ilr_sbp_history: [],
  }
}

function sbpGuardTripped(config: AnalysisConfig): boolean {
  return config.normalization.method === 'ilr' && ilrBasisOf(config) === 'sequential_binary_partition' &&
    ilrSbpAttempts(config.advanced) > ILR_SBP_ATTEMPT_DANGER_THRESHOLD
}

/** Report whether the current fields match a client-recognised risky configuration. */
export function isDangerous(config: AnalysisConfig): boolean {
  if (config.correction.allow_no_correction) return true
  if (config.advanced.zero_handling === 'refuse' || config.advanced.zero_policy === 'refuse') return true
  if (config.normalization.zero_policy === 'refuse') return true
  if (config.normalization.method === 'rarefy' && config.method === 'nb_glm') return true
  if (config.advanced.min_samples_per_group < 3) return true
  if (sbpGuardTripped(config)) return true
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
  if (sbpGuardTripped(config)) {
    reasons.push(`SBP p-hacking guard — ${ilrSbpAttempts(config.advanced)} distinct SBP matrices recorded as tried (more than ${ILR_SBP_ATTEMPT_DANGER_THRESHOLD}); choosing a partition after seeing results is a forking-paths problem BH cannot correct. Report every SBP tried.`)
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
    'normalization.ilr_basis': `ILR basis (only for ILR, meaningless otherwise). Every basis gives D-1 orthonormal balances; one test per balance, Benjamini-Hochberg across balances is mandatory.

- default: Helmert sequential binary partition (balance i = taxa 1..i against taxon i+1). Unchanged; the new engine reproduces it exactly (Agda: comb-is-helmert).
- phylogenetic: PhILR (Silverman et al. 2017, eLife 6:e21887). Needs advanced.ilr_phylo_tree_path, a ROOTED, strictly BIFURCATING Newick tree whose tips are the taxon ids. Unrooted trees and polytomies are refused, never resolved; tips that are not retained taxa are pruned.
- sequential_binary_partition: a user-defined SBP (Egozcue & Pawlowsky-Glahn 2005, Math. Geol. 37:795-828). Needs advanced.ilr_sbp_matrix_path (CSV: taxa rows, balance columns, entries 1/-1/0). More than 3 distinct SBPs tried raises the DANGER banner.
- balance_dendrogram: clusters parts on the variation matrix Var(log(x_i/x_j)) and uses the dendrogram as the SBP (Pawlowsky-Glahn, Egozcue & Tolosana-Delgado 2015, Modeling and Analysis of Compositional Data, Wiley). Needs advanced.ilr_balance_dendrogram_method. Data-derived basis: recorded as such.

See docs/statistics/method-conditions/ilr-bases.md, the JSON schema and Nickel IlrBasisInputsContract.
`,
    'advanced.ilr_phylo_tree_path': `Newick tree for ilr_basis = 'phylogenetic' (required then, refused otherwise).

- Tip labels must equal taxon ids exactly (no case folding or underscore/space rewriting; quote labels with spaces).
- Must be rooted: a basal trifurcation is how FastTree, IQ-TREE and RAxML write UNROOTED trees — root it in a phylogenetics tool first.
- Must be strictly bifurcating: polytomies are refused, never resolved at random.
- Extra tips are pruned; retained taxa missing from the tree are refused.
- The file's SHA-256 is recorded in the provenance. Relative paths resolve against the working directory of the run.

Silverman et al. (2017) eLife 6:e21887.
`,
    'advanced.ilr_sbp_matrix_path': `SBP CSV for ilr_basis = 'sequential_binary_partition' (required then, refused otherwise).

- First column: taxon ids (exactly the retained taxa). Other columns: one per balance, header = balance id, entries 1 (numerator), -1 (denominator), 0 (not involved).
- D taxa need exactly D-1 columns; the first partition involves every taxon and each later one splits a group made by an earlier one (Egozcue & Pawlowsky-Glahn 2005).
- Each failure names the column and the taxa. The file's SHA-256 is recorded; add it to advanced.ilr_sbp_history if you try another SBP.
`,
    'advanced.ilr_balance_dendrogram_method': `Clustering for ilr_basis = 'balance_dendrogram' (required then, refused otherwise): ward (R's ward.D2), complete or average, applied to the variation matrix with R's hclust algorithm — as robCompositions::clustCoDa_qmode with the classical variation. Needs at least 2 samples.

The basis is chosen from the data it is then used to test; this is recorded. Pawlowsky-Glahn, Egozcue & Tolosana-Delgado (2015).
`,
    'advanced.ilr_part_weights': `Part weights for a non-default ILR basis (philr's part.weights): uniform (default), gm_counts, anorm, enorm, anorm_x_gm_counts, enorm_x_gm_counts.

Non-uniform weights give the weighted ILR of Silverman et al. (2017) — orthonormal in the weighted Aitchison geometry — computed from the zero-handled table itself (recorded). Refused for the default basis.
`,
    'advanced.ilr_balance_weights': `Balance weights for ilr_basis = 'phylogenetic' only (philr's ilr.weights): uniform (default), blw, blw_sqrt, mean_descendants. They need branch lengths.

A balance weight multiplies a balance by a constant: effect sizes change, per-balance test statistics do not, and the coordinates stop being isometric (recorded). Zero-length tip edges are replaced by the smallest non-zero edge, as in philr.
`,
    'advanced.ilr_sbp_history': `SHA-256 digests of SBP files tried earlier in this project (ilr_basis = 'sequential_binary_partition' only).

The run counts distinct SBPs including the current one; more than 3 raises the DANGER banner. Trying partitions until one 'works' is a forking-paths problem BH cannot correct. The count is disclosed, not refused: pre-register the SBP.
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
