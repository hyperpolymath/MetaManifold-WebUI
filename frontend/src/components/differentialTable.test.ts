// SPDX-License-Identifier: AGPL-3.0-only
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
import { describe, expect, test } from 'bun:test'
import type { DifferentialResult } from '../api/types'
import { configLine, csvField, differentialCsv, effectValue, formatStat } from './differentialTable'

const result: DifferentialResult = {
  status: 'partial',
  method: 'NB GLM',
  rank: 'Genus',
  table: 'merged',
  groups: { reference: 'run_A', contrast: 'run_B' },
  n_samples: { run_A: 2, run_B: 2 },
  effect: { key: 'log2_fold_change', label: 'log2 fold change' },
  size_factors: [],
  config: { method: 'nb_glm', offset: 'tss', min_prevalence: 0 },
  diagnostics: { n_taxa: 2, n_tested: 1, n_failed: 1, n_boundary: 0, n_filtered: 0 },
  rows: [
    { taxon: 'Bacteroides', status: 'ok', note: '', estimate: 1.3862943611198906,
      log2_fold_change: 2, standard_error: 0.25, statistic: 5.545, pvalue: 2.9e-8, padj: 5.8e-8,
      dispersion_theta: 12.5, prevalence: 1 },
    { taxon: 'Odd, "quoted"', status: 'failed', note: 'the counts are constant across samples: there is nothing to estimate',
      estimate: null, log2_fold_change: null, standard_error: null, statistic: null, pvalue: null, padj: null,
      dispersion_theta: null, prevalence: 0.5 },
  ],
  figure: {},
}

describe('differential CSV', () => {
  test('quotes only fields that need it', () => {
    expect(csvField('plain')).toBe('plain')
    expect(csvField('a,b')).toBe('"a,b"')
    expect(csvField('say "hi"')).toBe('"say ""hi"""')
    expect(csvField(null)).toBe('')
    expect(csvField(0)).toBe('0')
  })

  test('keeps every taxon, full precision, and leaves missing statistics empty', () => {
    const lines = differentialCsv(result).trimEnd().split('\r\n')
    expect(lines[0]).toContain('run_B vs run_A (reference)')
    expect(lines[3]).toBe('taxon,status,log2_fold_change,estimate,standard_error,statistic,pvalue,padj,dispersion_theta,zero_process_log_odds,prevalence,note')
    expect(lines[4]).toBe('Bacteroides,ok,2,1.3862943611198906,0.25,5.545,2.9e-8,5.8e-8,12.5,,1,')
    expect(lines[5].startsWith('"Odd, ""quoted""",failed,,,,,,,,,0.5,')).toBe(true)
    expect(lines).toHaveLength(6)
  })
})

describe('formatStat', () => {
  test('shows a dash for an absent value, never zero', () => {
    expect(formatStat(null)).toBe('–')
    expect(formatStat(0)).toBe('0')
    expect(formatStat(0.04321)).toBe('0.0432')
    expect(formatStat(2.9e-8)).toBe('2.90e-8')
  })
})

describe('multinomial results', () => {
  const mn: DifferentialResult = {
    ...result,
    method: 'Multinomial logistic regression',
    effect: { key: 'log2_fold_change', label: 'log2 fold change vs Bacteroides' },
    size_factors: [],
    config: {
      method: 'multinomial', min_prevalence: 0.1, mn_reference_taxon: 'Bacteroides',
      mn_penalty: 0.5, tolerance: 1e-8, max_iter: 500, max_seconds: 300,
    },
    diagnostics: {
      n_taxa: 2, n_tested: 1, n_failed: 0, n_boundary: 0, n_filtered: 0,
      model: {
        reference_taxon: 'Bacteroides', penalty: 0.5, n_parameters: 2, iterations: 6,
        converged: true, log_likelihood: -31.2, runtime_seconds: 0.02, n_taxa_fitted: 2,
      },
    },
    rows: [
      { ...result.rows[0], taxon: 'Bacteroides', status: 'reference', estimate: 0,
        log2_fold_change: 0, standard_error: null, statistic: null, pvalue: null, padj: null,
        dispersion_theta: null,
        note: 'reference taxon: the denominator of every log ratio; its coefficient is fixed at zero, so it carries no test' },
      { ...result.rows[1], taxon: 'Prevotella', status: 'ok', estimate: 1.1,
        log2_fold_change: 1.6, standard_error: 0.2, statistic: 5.5, pvalue: 4e-8, padj: 4e-8, prevalence: 1 },
    ],
  }

  test('the settings line names the reference taxon and the penalty', () => {
    expect(configLine(mn)).toBe(
      'method multinomial, reference Bacteroides, penalty 0.5, min_prevalence 0.1; ' +
      'estimates are log2 fold changes against the reference taxon')
  })

  test('dirichlet_multinomial adds the overdispersion method to the line', () => {
    const dm: DifferentialResult = {
      ...mn,
      config: { ...mn.config, method: 'dirichlet_multinomial', dm_overdispersion_method: 'mom' },
    }
    expect(configLine(dm)).toBe(
      'method dirichlet_multinomial, overdispersion mom, reference Bacteroides, penalty 0.5, ' +
      'min_prevalence 0.1; estimates are log2 fold changes against the reference taxon')
  })

  test('the reference taxon is exported with an empty statistic set, never a substitute', () => {
    const lines = differentialCsv(mn).trimEnd().split('\r\n')
    expect(lines[4].startsWith('Bacteroides,reference,0,0,,,,,,1,')).toBe(true)
    expect(effectValue(mn, mn.rows[1])).toBe(1.6)
  })
})

describe('clr_welch results', () => {
  const clr: DifferentialResult = {
    ...result,
    method: 'CLR Welch',
    effect: { key: 'estimate', label: 'CLR difference' },
    config: { method: 'clr_welch', min_prevalence: 0, replacement_delta: 0.65 },
    rows: [{ ...result.rows[0], estimate: -0.75, log2_fold_change: null, dispersion_theta: null }],
  }

  test('the effect comes from the field the result names, not log2_fold_change', () => {
    expect(effectValue(clr, clr.rows[0])).toBe(-0.75)
    expect(effectValue(result, result.rows[0])).toBe(2)
  })

  test('the settings line records replacement provenance and says the estimate is not a fold change', () => {
    expect(configLine(clr)).toBe('method clr_welch, replacement_method bayesian_multiplicative, replacement_delta 0.65, bayesian_alpha estimated, min_prevalence 0; estimate is a CLR difference, not a fold change')
    expect(configLine(result)).toBe('method nb_glm, offset tss, min_prevalence 0')
    expect(differentialCsv(clr).split('\r\n')[2]).toBe(`# ${configLine(clr)}`)
    const custom: DifferentialResult = {
      ...clr,
      config: { method: 'clr_welch', min_prevalence: 0.1,
        replacement_method: 'multiplicative_replacement', replacement_delta: 0.4, bayesian_alpha: null },
    }
    expect(configLine(custom)).toContain('replacement_method multiplicative_replacement')
    expect(configLine(custom)).toContain('replacement_delta 0.4')
    expect(configLine(custom)).not.toContain('bayesian_alpha')
    const alpha: DifferentialResult = {
      ...clr,
      config: { method: 'clr_welch', min_prevalence: 0,
        replacement_method: 'bayesian_multiplicative', replacement_delta: 0.65, bayesian_alpha: 2.5 },
    }
    expect(configLine(alpha)).toContain('bayesian_alpha 2.5')
  })
})

describe('advanced compositional methods (ancom_bc, aldex2, songbird)', () => {
  test('ancom_bc reports bias-corrected log2 fold change and clean CSV config line', () => {
    const bc: DifferentialResult = {
      ...result,
      method: 'ANCOM-BC',
      effect: { key: 'log2_fold_change', label: 'Bias-corrected log2 FC' },
      config: { method: 'ancom_bc', min_prevalence: 0.1 },
      rows: [{ ...result.rows[0], estimate: 1.3862943611198906, log2_fold_change: 2, dispersion_theta: null }],
    }
    expect(effectValue(bc, bc.rows[0])).toBe(2)
    expect(configLine(bc)).toBe('method ancom_bc, min_prevalence 0.1; effect is bias-corrected log2 fold change (Lin & Peddada 2020)')
  })

  test('aldex2 records mc_samples and seed in CSV metadata and leaves absent SE empty', () => {
    const ax: DifferentialResult = {
      ...result,
      method: 'ALDEx2',
      effect: { key: 'estimate', label: 'ALDEx2 effect size' },
      config: { method: 'aldex2', min_prevalence: 0.05, mc_samples: 128, seed: 123 },
      rows: [{ ...result.rows[0], estimate: 1.85, log2_fold_change: null, standard_error: null, dispersion_theta: null }],
    }
    expect(effectValue(ax, ax.rows[0])).toBe(1.85)
    expect(configLine(ax)).toBe('method aldex2, mc_samples 128, seed 123, min_prevalence 0.05; estimate is an ALDEx2 standardized CLR effect size, not a fold change')
    const csvRows = differentialCsv(ax).trimEnd().split('\r\n')
    expect(csvRows[4]).toBe('Bacteroides,ok,,1.85,,5.545,2.9e-8,5.8e-8,,1,')
  })

  test('songbird reports CLR-centred multinomial differential metadata', () => {
    const sb: DifferentialResult = {
      ...result,
      method: 'Songbird',
      effect: { key: 'estimate', label: 'Differential (CLR log-ratio)' },
      config: { method: 'songbird', min_prevalence: 0.2 },
      rows: [{ ...result.rows[0], estimate: -0.92, log2_fold_change: null, dispersion_theta: null }],
    }
    expect(effectValue(sb, sb.rows[0])).toBe(-0.92)
    expect(configLine(sb)).toBe('method songbird, min_prevalence 0.2; estimate is a CLR-centred multinomial differential, not an absolute fold change')
  })
})
