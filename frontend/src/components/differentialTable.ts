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
  const caveat = result.diagnostics.calibration_caveat
  const header = [
    `# Differential abundance: ${contrast} vs ${reference} (reference), rank ${result.rank}, table ${result.table}`,
    `# ${result.method}`,
    `# ${configLine(result)}`,
    // The caveat travels with the numbers it qualifies: a downloaded table
    // must not look better-calibrated than the result it came from.
    ...(caveat ? [`# Calibration caveat (${caveat.severity}): ${caveat.message}`] : []),
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
  if (c.method === 'nb_glm')
    // Older saved results may not record the dispersion; name it only
    // when the result carries it, never guess one for the record.
    return `method nb_glm, offset ${c.offset}${c.dispersion ? `, dispersion ${c.dispersion}` : ''}, min_prevalence ${c.min_prevalence}`
  if (c.method !== 'clr_welch')
    return `method ${c.method}, offset ${c.offset}, min_prevalence ${c.min_prevalence}`
  const replacement = c.replacement_method ?? 'bayesian_multiplicative'
  const alpha = c.bayesian_alpha === null || c.bayesian_alpha === undefined
    ? 'estimated' : String(c.bayesian_alpha)
  return `method clr_welch, replacement_method ${replacement}, replacement_delta ${c.replacement_delta}, ` +
    `bayesian_alpha ${alpha}, min_prevalence ${c.min_prevalence}; estimate is a CLR difference, not a fold change`
}

/** The effect size of one row, from the field the result names in `effect`. */
export function effectValue(result: DifferentialResult, row: DifferentialRow): number | null {
  return row[result.effect.key]
}
