// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

// Plotly specs for the fibre visualiser and the residual explorer.
//
// The figures are built here rather than in the components so their content can
// be asserted in `evidence.test.ts`: a chart that silently drops samples, or
// plots a share on the wrong axis, is a scientific error, not a cosmetic one.

import type { FibreResult, ResidualResult } from './types'

export interface PlotSpec {
  data: Record<string, unknown>[]
  layout: Record<string, unknown>
}

/** Thousands-separated integer, e.g. 12 345. */
export function formatCount(n: number): string {
  return Number.isFinite(n) ? Math.round(n).toLocaleString('en-GB') : '0'
}

/** One decimal place, e.g. 12.3 %. */
export function formatPercent(fraction: number, digits = 1): string {
  const pct = (Number.isFinite(fraction) ? fraction : 0) * 100
  return `${pct.toFixed(digits)} %`
}

/** Signed, two-decimal number, for residuals and log-ratios. */
export function formatSigned(n: number, digits = 2): string {
  if (!Number.isFinite(n)) return '0'
  return `${n > 0 ? '+' : ''}${n.toFixed(digits)}`
}

const MAX_TITLE_LABEL = 60

function scopeLabel(values: string[], value: string): string {
  const labels = values.join(', ')
  const shown = labels.length > MAX_TITLE_LABEL ? `${labels.slice(0, MAX_TITLE_LABEL - 1)}…` : labels
  return `${value} ⊇ ${shown}`
}

function sampleName(s: string): string {
  return s.length > 24 ? `${s.slice(0, 23)}…` : s
}

/**
 * The fibre across samples: each bar is the fibre's share of that sample's
 * reads. The series is deliberately a share, not a raw count, because the
 * question a claim asks of a fibre is whether it is enriched, and raw counts
 * answer that question with library size instead of composition.
 */
export function fibreFigure(result: FibreResult): PlotSpec {
  const samples = result.fibre.samples
  return {
    data: [{
      type: 'bar',
      x: samples.map(s => s.sample),
      y: samples.map(s => s.percent),
      customdata: samples.map(s => [s.observed, s.total]),
      name: scopeLabel(result.values, result.value),
      marker: { color: '#1c7ed6' },
      hovertemplate: '<b>%{x}</b><br>share of sample reads: %{y:.2f} %' +
                     '<br>fibre reads: %{customdata[0]:,}<br>sample reads: %{customdata[1]:,}' +
                     '<extra></extra>',
    }],
    layout: {
      title: {
        text: `${scopeLabel(result.values, result.value)} — share of each sample’s reads`,
        font: { size: 15 },
      },
      xaxis: {
        title: { text: 'Sample' },
        tickangle: samples.length > 12 ? -45 : 0,
        tickvals: samples.map(s => s.sample),
        ticktext: samples.map(s => sampleName(s.sample)),
      },
      yaxis: { title: { text: '% of sample reads' }, rangemode: 'tozero' },
      bargap: 0.25,
      showlegend: false,
      margin: { l: 70, r: 30, t: 60, b: samples.length > 12 ? 130 : 80 },
    },
  }
}

/**
 * Residuals, worst first, with the ±2 band drawn as threshold lines. The band is
 * a reading aid, not a significance test: the chi-square statistic in the
 * summary is descriptive, and the figure makes the null it measures against
 * explicit in its subtitle.
 */
export function residualFigure(result: ResidualResult): PlotSpec {
  const rows = result.samples
  const nullText = result.null.kind === 'proportional'
    ? 'null: the fibre is distributed across samples as the library is'
    : `null: the fibre holds ${formatPercent(result.null.share ?? 0)} of every sample`

  return {
    data: [{
      type: 'bar',
      x: rows.map(r => r.sample),
      y: rows.map(r => r.residual),
      customdata: rows.map(r => [r.observed, r.expected, r.total]),
      name: 'Pearson residual',
      marker: { color: rows.map(r => (r.residual >= 0 ? '#2b8a3e' : '#c92a2a')) },
      hovertemplate: '<b>%{x}</b><br>residual: %{y:.2f}' +
                     '<br>observed: %{customdata[0]:,}<br>expected: %{customdata[1]:,.1f}' +
                     '<br>sample reads: %{customdata[2]:,}<extra></extra>',
    }],
    layout: {
      title: {
        text: `${scopeLabel(result.values, result.value)} — residuals by sample`,
        subtitle: { text: nullText, font: { size: 12 } },
        font: { size: 15 },
      },
      xaxis: {
        title: { text: 'Sample' },
        tickangle: rows.length > 12 ? -45 : 0,
        tickvals: rows.map(r => r.sample),
        ticktext: rows.map(r => sampleName(r.sample)),
      },
      yaxis: { title: { text: 'Pearson residual (observed − expected) / √expected' }, zeroline: true },
      shapes: [
        { type: 'line', xref: 'paper', x0: 0, x1: 1, y0: 0, y1: 0,
          line: { color: '#868e96', width: 1 } },
        { type: 'line', xref: 'paper', x0: 0, x1: 1, y0: 2, y1: 2,
          line: { color: '#868e96', width: 1, dash: 'dot' } },
        { type: 'line', xref: 'paper', x0: 0, x1: 1, y0: -2, y1: -2,
          line: { color: '#868e96', width: 1, dash: 'dot' } },
      ],
      annotations: [
        { xref: 'paper', yref: 'paper', x: 1, y: 1.02, xanchor: 'right', yanchor: 'bottom',
          text: 'dotted: |residual| = 2', showarrow: false,
          font: { size: 11, color: '#868e96' } },
      ],
      bargap: 0.25,
      showlegend: false,
      margin: { l: 70, r: 30, t: 80, b: rows.length > 12 ? 130 : 80 },
    },
  }
}
