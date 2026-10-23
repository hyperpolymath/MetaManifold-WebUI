// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

import type {
  ActiveOrdinationMethod,
  OrdinationDistance,
  OrdinationResult,
  OrdinationScaling,
} from '../api/types'

export interface OrdinationMethodInfo {
  id: ActiveOrdinationMethod
  label: string
  veganFn: string
  defaultDistance: OrdinationDistance
  compatibleDistances: readonly OrdinationDistance[]
  summary: string
  whenToUse: string
}

export const ORDINATION_METHODS_INFO: readonly OrdinationMethodInfo[] = [
  {
    id: 'dbrda',
    label: 'dbRDA (Distance-based RDA)',
    veganFn: 'vegan::dbrda',
    defaultDistance: 'bray',
    compatibleDistances: ['bray', 'jaccard', 'euclidean', 'aitchison', 'unweighted_unifrac', 'weighted_unifrac'],
    summary: 'Direct constrained decomposition of Gower-centred ecological or phylogenetic dissimilarities (Legendre & Anderson 1999; McArdle & Anderson 2001).',
    whenToUse: 'Recommended general-purpose constrained ordination for Bray-Curtis, Jaccard, or UniFrac dissimilarities without complex imaginary axes.',
  },
  {
    id: 'cap',
    label: 'CAP (Constrained Principal Coordinates)',
    veganFn: 'vegan::capscale',
    defaultDistance: 'bray',
    compatibleDistances: ['bray', 'jaccard', 'euclidean', 'aitchison', 'unweighted_unifrac', 'weighted_unifrac'],
    summary: 'Metric PCoA followed by linear RDA on real principal coordinates (Anderson & Willis 2003).',
    whenToUse: 'Use when classical PCoA coordinate scores and weighted-average taxon projections on arbitrary dissimilarities are desired.',
  },
  {
    id: 'rda',
    label: 'RDA (Redundancy Analysis)',
    veganFn: 'vegan::rda',
    defaultDistance: 'aitchison',
    compatibleDistances: ['aitchison', 'euclidean'],
    summary: 'Linear constrained ordination in Euclidean geometry (compositional CLR / Aitchison space or Hellinger-transformed Euclidean space).',
    whenToUse: 'Best for compositional log-ratio (Aitchison) analysis (Gloor et al. 2017) or Hellinger transformation-based RDA with direct taxon loading vectors.',
  },
  {
    id: 'cca',
    label: 'CCA (Canonical Correspondence Analysis)',
    veganFn: 'vegan::cca',
    defaultDistance: 'chisq',
    compatibleDistances: ['chisq'],
    summary: 'Unimodal constrained ordination weighted by chi-square distance on non-negative abundances.',
    whenToUse: 'Use across broad environmental gradients where taxa exhibit bell-shaped unimodal niche optima rather than monotonic linear responses.',
  },
] as const

export const ORDINATION_DISTANCE_LABELS: Record<OrdinationDistance, string> = {
  bray: 'Bray-Curtis dissimilarity',
  jaccard: 'Jaccard dissimilarity',
  euclidean: 'Euclidean (uses study beta transform)',
  aitchison: 'Aitchison (zero-replaced CLR)',
  chisq: 'Chi-square (intrinsic to CCA)',
  unweighted_unifrac: 'Unweighted UniFrac (phylogenetic)',
  weighted_unifrac: 'Weighted UniFrac (phylogenetic)',
}

export const ORDINATION_CITATIONS = [
  {
    authors: 'Legendre, P. & Anderson, M. J. (1999)',
    title: 'Distance-based redundancy analysis: testing multispecies responses in multifactorial ecological experiments. Ecological Monographs 69(1), 1–24.',
    doi: '10.1890/0012-9615(1999)069[0001:DBRATM]2.0.CO;2',
  },
  {
    authors: 'McArdle, B. H. & Anderson, M. J. (2001)',
    title: 'Fitting multivariate models to community data: a comment on distance-based redundancy analysis. Ecology 82(1), 290–297.',
    doi: '10.1890/0012-9658(2001)082[0290:FMMTCD]2.0.CO;2',
  },
  {
    authors: 'Anderson, M. J. & Willis, T. J. (2003)',
    title: 'Canonical analysis of principal coordinates: a useful method of constrained ordination for ecology. Ecology 84(2), 511–525.',
    doi: '10.1890/0012-9658(2003)084[0511:CAOPCA]2.0.CO;2',
  },
  {
    authors: 'Peres-Neto, P. R., Legendre, P., Dray, S. & Borcard, D. (2006)',
    title: 'Variation partitioning of species data matrices: estimation and comparison of fractions. Ecology 87(10), 2614–2625.',
    doi: '10.1890/0012-9658(2006)87[2614:VPOSDM]2.0.CO;2',
  },
  {
    authors: 'Gloor, G. B., Macklaim, J. M., Pawlowsky-Glahn, V. & Egozcue, J. J. (2017)',
    title: 'Microbiome datasets are compositional: and this is not optional. Frontiers in Microbiology 8, 2224.',
    doi: '10.3389/fmicb.2017.02224',
  },
  {
    authors: 'Oksanen, J. et al. (2025)',
    title: 'vegan: Community Ecology Package (CRAN).',
    doi: '10.32614/CRAN.package.vegan',
  },
] as const

const RESERVED_R_WORDS = new Set([
  'if', 'else', 'repeat', 'while', 'function', 'for', 'in', 'next', 'break',
  'TRUE', 'FALSE', 'NULL', 'Inf', 'NaN', 'NA', 'NA_integer_', 'NA_real_',
  'NA_complex_', 'NA_character_', '.', '...', 'Condition',
])

/** Return method metadata, falling back to dbRDA for an unrecognised runtime value. */
export function getMethodInfo(method: ActiveOrdinationMethod): OrdinationMethodInfo {
  const found = ORDINATION_METHODS_INFO.find(m => m.id === method)
  return found ?? ORDINATION_METHODS_INFO[0]
}

/** Check the method's allowed geometries; an unrecognised method uses the dbRDA list. */
export function isDistanceCompatible(
  method: ActiveOrdinationMethod,
  distance: OrdinationDistance,
): boolean {
  return getMethodInfo(method).compatibleDistances.includes(distance)
}

/** Keep the current distance when compatible; otherwise use the method's default. */
export function resolveCompatibleDistance(
  method: ActiveOrdinationMethod,
  current: OrdinationDistance,
): OrdinationDistance {
  const info = getMethodInfo(method)
  return info.compatibleDistances.includes(current) ? current : info.defaultDistance
}

/** Return interpretation guidance for distance scaling (1) or correlation scaling (2). */
export function scalingDescription(scaling: OrdinationScaling): string {
  return scaling === 1
    ? 'Scaling 1 (distance biplot): distances between sample points approximate their ecological/Euclidean distances; project sample points onto covariate arrows at right angles.'
    : 'Scaling 2 (correlation biplot): cosines of angles between covariate arrows (and feature vectors) approximate correlations; distances between sample points are not approximate dissimilarities.'
}

/** Split additive terms outside parentheses, returning an error for empty terms or unbalanced parentheses. */
function splitTopLevelPlus(rhs: string): string[] | { error: string } {
  const parts: string[] = []
  let depth = 0
  let start = 0
  for (let i = 0; i < rhs.length; i++) {
    const ch = rhs[i]
    if (ch === '(') depth++
    else if (ch === ')') {
      depth--
      if (depth < 0) return { error: "Unbalanced ')' in formula" }
    } else if (ch === '+' && depth === 0) {
      const seg = rhs.slice(start, i).trim()
      if (!seg) return { error: "Empty '+' term in formula" }
      parts.push(seg)
      start = i + 1
    }
  }
  if (depth !== 0) return { error: "Unbalanced '(' in formula" }
  const tail = rhs.slice(start).trim()
  if (!tail) return { error: "Trailing '+' in formula" }
  parts.push(tail)
  return parts
}

/** Return a trimmed ASCII covariate identifier, or null for invalid or reserved names. */
function validIdent(s: string): string | null {
  const t = s.trim()
  if (!/^[A-Za-z][A-Za-z0-9_.]*$/.test(t)) return null
  if (RESERVED_R_WORDS.has(t) || /^\.\.[0-9]+$/.test(t)) return null
  return t
}

/**
 * Client-side preflight validation matching `Ordination.validate_formula_syntax`
 * on the backend. Empty/null formula is valid (uses study default covariates).
 * Only two-way interactions are supported; `a*b` counts as `a`, `b` and `a:b`.
 * On success, return the number of distinct expanded constraints and whether
 * conditioning is present; invalid syntax returns an error message. Empty input
 * uses a count of 1 for runtime estimation. This checks syntax only; metadata
 * and model degrees of freedom are checked by the server.
 */
export function validateOrdinationFormulaSyntax(formula: string | null | undefined): {
  valid: boolean
  error: string | null
  constrainedCount: number
  hasCondition: boolean
} {
  if (formula == null || formula.trim() === '') {
    return { valid: true, error: null, constrainedCount: 1, hasCondition: false }
  }
  if (!/^[A-Za-z0-9_.+*:()~ \t]+$/.test(formula)) {
    return {
      valid: false,
      error: "Formula may contain only covariate identifiers, '+', ':', '*', and Condition(...)",
      constrainedCount: 0,
      hasCondition: false,
    }
  }
  let rhs = formula.trim()
  if (rhs.includes('~')) {
    const pieces = rhs.split('~')
    if (pieces.length !== 2) {
      return { valid: false, error: "Formula may contain at most one '~'", constrainedCount: 0, hasCondition: false }
    }
    if (pieces[0].trim() !== '') {
      return { valid: false, error: "Formula must be right-hand-side only (start with '~')", constrainedCount: 0, hasCondition: false }
    }
    rhs = pieces[1].trim()
    if (!rhs) {
      return { valid: false, error: 'Formula right-hand side cannot be empty', constrainedCount: 0, hasCondition: false }
    }
  }

  const splitRes = splitTopLevelPlus(rhs)
  if (!Array.isArray(splitRes)) {
    return { valid: false, error: splitRes.error, constrainedCount: 0, hasCondition: false }
  }

  const constrained: string[] = []
  const conditioned = new Set<string>()
  for (const term of splitRes) {
    const condMatch = /^Condition\s*\((.*)\)$/.exec(term)
    if (condMatch) {
      const inner = condMatch[1].trim()
      if (!inner || inner.includes('(') || inner.includes(')')) {
        return { valid: false, error: 'Invalid Condition(...) clause', constrainedCount: 0, hasCondition: false }
      }
      for (const sub of inner.split('+')) {
        const id = validIdent(sub)
        if (!id) return { valid: false, error: `Invalid covariate '${sub.trim()}' in Condition(...)`, constrainedCount: 0, hasCondition: false }
        conditioned.add(id)
      }
    } else if (term.includes('(') || term.includes(')')) {
      return { valid: false, error: `Only Condition(...) calls are allowed in formulas; rejected '${term}'`, constrainedCount: 0, hasCondition: false }
    } else if (term.includes('*') || term.includes(':')) {
      const op = term.includes('*') ? '*' : ':'
      const other = op === '*' ? ':' : '*'
      if (term.includes(other)) {
        return { valid: false, error: `Do not mix '*' and ':' in '${term}'`, constrainedCount: 0, hasCondition: false }
      }
      const pair = term.split(op)
      if (pair.length !== 2) {
        return { valid: false, error: `Only two-way interactions are supported; rejected '${term}'`, constrainedCount: 0, hasCondition: false }
      }
      const a = validIdent(pair[0])
      const b = validIdent(pair[1])
      if (!a || !b || a === b) {
        return { valid: false, error: `Invalid interaction term '${term}'`, constrainedCount: 0, hasCondition: false }
      }
      if (op === '*') {
        if (!constrained.includes(a)) constrained.push(a)
        if (!constrained.includes(b)) constrained.push(b)
      }
      const inter = `${a}:${b}`
      if (!constrained.includes(inter)) constrained.push(inter)
    } else {
      const id = validIdent(term)
      if (!id) {
        return { valid: false, error: `Invalid covariate identifier '${term}'`, constrainedCount: 0, hasCondition: false }
      }
      if (!constrained.includes(id)) constrained.push(id)
    }
  }

  if (constrained.length === 0) {
    return {
      valid: false,
      error: 'Include at least one constraining covariate outside Condition(...)',
      constrainedCount: 0,
      hasCondition: conditioned.size > 0,
    }
  }

  for (const t of constrained) {
    for (const part of t.split(':')) {
      if (conditioned.has(part)) {
        return {
          valid: false,
          error: `Covariate '${part}' cannot appear both as a constraining term and inside Condition(...)`,
          constrainedCount: 0,
          hasCondition: true,
        }
      }
    }
  }

  return {
    valid: true,
    error: null,
    constrainedCount: constrained.length,
    hasCondition: conditioned.size > 0,
  }
}

/**
 * Estimate wall-clock seconds for UI guidance, with a display label and cost tier.
 * Missing feature/term counts use 250/1; counts are truncated and clamped to at
 * least 3 samples, 10 features, 99 permutations and 1 term. Tiers change at 5 and
 * 60 seconds; the five-minute warning is set only above 300 seconds. This is a
 * heuristic, not a measured duration or a validation of the request.
 */
export function estimateOrdinationRuntime(opts: {
  method: ActiveOrdinationMethod
  distance: OrdinationDistance
  nSamples: number
  nFeatures?: number
  permutations: number
  nTerms?: number
  variancePartitioning?: boolean
}): {
  estimatedSeconds: number
  tier: 'fast' | 'moderate' | 'heavy'
  warnFiveMinutes: boolean
  label: string
} {
  const n = Math.max(3, Math.trunc(opts.nSamples))
  const p = Math.max(10, Math.trunc(opts.nFeatures ?? 250))
  const b = Math.max(99, Math.trunc(opts.permutations))
  const k = Math.max(1, Math.trunc(opts.nTerms ?? 1))

  const baseS = 0.06
  const prepS = (opts.distance === 'unweighted_unifrac' || opts.distance === 'weighted_unifrac')
    ? 4.5e-7 * n * n * p
    : opts.distance === 'aitchison'
      ? 2.5e-7 * n * p
      : 1.2e-7 * n * n * p
  const isDistModel = opts.method === 'cap' || opts.method === 'dbrda'
  const decompS = isDistModel ? 2.2e-9 * n * n * n : 1.5e-9 * n * p * Math.min(n, p)
  const passes = k >= 2 ? 3 : 2
  const permUnit = isDistModel ? 2.8e-8 * n * n : 1.8e-8 * n * Math.min(p, 250)
  const permS = passes * b * permUnit
  const vpS = opts.variancePartitioning && k >= 2
    ? 0.35 * (decompS + (opts.method === 'cca' ? b * permUnit : 0.02))
    : 0

  const est = Math.round((baseS + prepS + decompS + permS + vpS) * 100) / 100
  const tier = est >= 60 ? 'heavy' : est >= 5 ? 'moderate' : 'fast'
  const label = est < 1 ? '< 1 s' : est < 60 ? `~${est.toFixed(1)} s` : `~${(est / 60).toFixed(1)} min`
  return {
    estimatedSeconds: est,
    tier,
    warnFiveMinutes: est > 300,
    label,
  }
}

/** Escape commas, quotes and line breaks for one CSV cell; null/undefined become empty cells. */
function csvCell(val: string | number | boolean | null | undefined): string {
  if (val === null || val === undefined) return ''
  const s = String(val)
  if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`
  return s
}

/**
 * Format a constrained ordination result into a self-documenting CSV carrying
 * provenance headers, sample site scores, covariate biplot vectors, permutation
 * ANOVA results, and optional variance partitioning fractions.
 */
export function formatOrdinationCsv(res: OrdinationResult): string {
  const lines: string[] = []
  const prov = res.provenance
  lines.push(
    `# MetaManifold constrained ordination (${prov.software.r_package} ${prov.software.vegan_version})`,
  )
  const zr = prov.zero_replacement
    ? `; zero_replacement=${prov.zero_replacement.method}(delta=${prov.zero_replacement.delta},replaced=${prov.zero_replacement.zeros_replaced})`
    : ''
  lines.push(
    `# method=${res.method}; distance=${res.distance}; scaling=${res.scaling}(${prov.scaling_meaning}); formula=${res.formula}; permutations=${prov.permutations_performed}; seed=${prov.seed}; beta_normalisation=${prov.beta_normalisation}${zr}`,
  )
  lines.push(
    `# total_inertia=${res.total_inertia}; constrained_inertia=${res.constrained_inertia}; r2=${res.r2 ?? ''}; adj_r2=${res.adj_r2 ?? ''}; omnibus_F=${res.omnibus_test.f_statistic ?? ''}; omnibus_p=${res.omnibus_test.p_value ?? ''}`,
  )
  for (const c of res.cautions) {
    lines.push(`# caution: ${c}`)
  }
  lines.push('section,name,axis1_or_df,axis2_or_variance,f_or_r2,p_or_adj_r2,note')
  for (const s of res.sites) {
    lines.push(['site_score', s.sample, s.axis1, s.axis2, '', '', ''].map(csvCell).join(','))
  }
  for (const b of res.biplot_arrows) {
    lines.push(['covariate_arrow', b.label, b.axis1, b.axis2, b.length, '', ''].map(csvCell).join(','))
  }
  for (const c of res.centroids) {
    lines.push(['centroid', c.label, c.axis1, c.axis2, '', '', ''].map(csvCell).join(','))
  }
  lines.push([
    'omnibus_anova',
    'Model',
    res.omnibus_test.df_model,
    res.omnibus_test.variance_model,
    res.omnibus_test.f_statistic,
    res.omnibus_test.p_value,
    res.omnibus_test.untestable_reason ?? `residual_df=${res.omnibus_test.df_residual};permutations=${res.omnibus_test.permutations}`,
  ].map(csvCell).join(','))
  for (const t of res.term_tests) {
    lines.push([
      'term_anova_sequential',
      t.term,
      t.df,
      t.variance,
      t.f_statistic,
      t.p_value,
      t.untestable_reason ?? '',
    ].map(csvCell).join(','))
  }
  for (const t of res.marginal_tests) {
    lines.push([
      'term_anova_marginal',
      t.term,
      t.df,
      t.variance,
      t.f_statistic,
      t.p_value,
      t.untestable_reason ?? '',
    ].map(csvCell).join(','))
  }
  if (res.variance_partitioning?.status === 'computed') {
    for (const f of res.variance_partitioning.individual_fractions) {
      lines.push([
        'varpart_fraction',
        f.label,
        f.df,
        '',
        f.r2,
        f.adj_r2,
        f.testable ? 'testable' : 'untestable_shared_or_residual',
      ].map(csvCell).join(','))
    }
  }
  return lines.join('\n') + '\n'
}
