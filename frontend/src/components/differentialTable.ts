// SPDX-License-Identifier: AGPL-3.0-only
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
import type { DifferentialResult, DifferentialRow } from '../api/types'

const COLUMNS = [
  'taxon', 'status', 'log2_fold_change', 'estimate', 'standard_error', 'statistic',
  'pvalue', 'padj', 'dispersion_theta', 'zero_process_log_odds', 'prevalence', 'note',
] as const

/** Quote one CSV field when it holds a comma, quote or line break (RFC 4180). */
export function csvField(value: string | number | null): string {
  if (value === null) return ''
  const s = String(value)
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
}

/**
 * The full results table as CSV, every taxon including failed and filtered
 * ones. Numbers keep full precision; a missing statistic is an empty field,
 * never 0 or 1. Leading `#` lines record the comparison and method (read.csv
 * skips them with `comment.char = "#"`).
 */
export function differentialCsv(result: DifferentialResult): string {
  const { reference, contrast } = result.groups
  const header = [
    `# Differential abundance: ${contrast} vs ${reference} (reference), rank ${result.rank}, table ${result.table}`,
    `# ${result.method}`,
    `# ${configLine(result)}`,
  ].map(l => l.replace(/[\r\n]+/g, ' '))
  const rows = result.rows.map(r => COLUMNS.map(c => csvField(r[c] ?? null)).join(','))
  return [...header, COLUMNS.join(','), ...rows].join('\r\n') + '\r\n'
}

/** Format a statistic for display: three significant figures, or a dash when absent. */
export function formatStat(value: number | null): string {
  if (value === null) return '–'
  if (value === 0) return '0'
  const a = Math.abs(value)
  return a < 1e-3 || a >= 1e4 ? value.toExponential(2) : value.toPrecision(3)
}

/**
 * The settings line of the CSV: the method and the parameters it used. Each
 * method names only its own parameters and states whether its effect is a
 * bias-corrected fold change or a relative log-ratio.
 */
export function configLine(result: DifferentialResult): string {
  const c = result.config

  if (c.method === 'multinomial' || c.method === 'dirichlet_multinomial') {
    const settings = [`method ${c.method}`]
    if (c.method === 'dirichlet_multinomial' && c.dm_overdispersion_method)
      settings.push(`overdispersion ${c.dm_overdispersion_method}`)
    if (c.mn_reference_taxon) settings.push(`reference ${c.mn_reference_taxon}`)
    if (c.mn_penalty !== undefined) settings.push(`penalty ${c.mn_penalty}`)
    settings.push(`min_prevalence ${c.min_prevalence}`)
    return `${settings.join(', ')}; estimates are log2 fold changes against the reference taxon`
  }

  if (c.method === 'clr_welch') {
    const replacement = c.replacement_method ?? 'bayesian_multiplicative'
    const settings = [
      `method clr_welch`,
      `replacement_method ${replacement}`,
      `replacement_delta ${c.replacement_delta}`,
    ]
    // CZM has no Bayesian concentration parameter; do not claim one was used.
    if (replacement === 'bayesian_multiplicative') {
      const alpha = c.bayesian_alpha === null || c.bayesian_alpha === undefined
        ? 'estimated' : String(c.bayesian_alpha)
      settings.push(`bayesian_alpha ${alpha}`)
    }
    settings.push(`min_prevalence ${c.min_prevalence}`)
    return `${settings.join(', ')}; estimate is a CLR difference, not a fold change`
  }

  if (c.method === 'ancom_bc')
    return `method ancom_bc, min_prevalence ${c.min_prevalence}; effect is bias-corrected log2 fold change (Lin & Peddada 2020)`

  if (c.method === 'aldex2')
    return `method aldex2, mc_samples ${c.mc_samples}, seed ${c.seed}, min_prevalence ${c.min_prevalence}; estimate is an ALDEx2 standardized CLR effect size, not a fold change`

  if (c.method === 'songbird')
    return `method songbird, min_prevalence ${c.min_prevalence}; estimate is a CLR-centred multinomial differential, not an absolute fold change`

  const settings = [`method ${c.method}`]
  if (c.offset !== undefined) settings.push(`offset ${c.offset}`)
  if (c.method === 'nb_glm' && c.dispersion !== undefined) settings.push(`dispersion ${c.dispersion}`)
  settings.push(`min_prevalence ${c.min_prevalence}`)
  return settings.join(', ')
}

/** The effect size of one row, from the field the result names in `effect`. */
export function effectValue(result: DifferentialResult, row: DifferentialRow): number | null {
  return row[result.effect.key]
}
