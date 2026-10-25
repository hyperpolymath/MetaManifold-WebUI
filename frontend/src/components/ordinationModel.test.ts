// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

import { describe, expect, test } from 'bun:test'
import type { OrdinationResult } from '../api/types'
import {
  ORDINATION_CITATIONS,
  estimateOrdinationRuntime,
  formatOrdinationCsv,
  isDistanceCompatible,
  resolveCompatibleDistance,
  scalingDescription,
  validateOrdinationFormulaSyntax,
} from './ordinationModel'

describe('method and distance compatibility', () => {
  test('RDA requires linear Euclidean or Aitchison CLR geometry and rejects Bray-Curtis', () => {
    expect(isDistanceCompatible('rda', 'aitchison')).toBe(true)
    expect(isDistanceCompatible('rda', 'euclidean')).toBe(true)
    expect(isDistanceCompatible('rda', 'bray')).toBe(false)
    expect(isDistanceCompatible('rda', 'weighted_unifrac')).toBe(false)
    expect(resolveCompatibleDistance('rda', 'bray')).toBe('aitchison')
    expect(resolveCompatibleDistance('rda', 'euclidean')).toBe('euclidean')
  })

  test('CCA requires chi-square geometry', () => {
    expect(isDistanceCompatible('cca', 'chisq')).toBe(true)
    expect(isDistanceCompatible('cca', 'bray')).toBe(false)
    expect(resolveCompatibleDistance('cca', 'bray')).toBe('chisq')
  })

  test('CAP and dbRDA accept Bray-Curtis, Jaccard, Euclidean, Aitchison, and UniFrac', () => {
    for (const m of ['cap', 'dbrda'] as const) {
      expect(isDistanceCompatible(m, 'bray')).toBe(true)
      expect(isDistanceCompatible(m, 'jaccard')).toBe(true)
      expect(isDistanceCompatible(m, 'euclidean')).toBe(true)
      expect(isDistanceCompatible(m, 'aitchison')).toBe(true)
      expect(isDistanceCompatible(m, 'unweighted_unifrac')).toBe(true)
      expect(isDistanceCompatible(m, 'weighted_unifrac')).toBe(true)
      expect(isDistanceCompatible(m, 'chisq')).toBe(false)
    }
  })
})

describe('formula syntax validation', () => {
  test('accepts empty formula, main effects, interactions, and Condition(...) partial ordination', () => {
    expect(validateOrdinationFormulaSyntax('')).toEqual({
      valid: true, error: null, constrainedCount: 1, hasCondition: false,
    })
    expect(validateOrdinationFormulaSyntax('~ group + run')).toEqual({
      valid: true, error: null, constrainedCount: 2, hasCondition: false,
    })
    expect(validateOrdinationFormulaSyntax('~ group * depth + Condition(run + batch)')).toEqual({
      valid: true, error: null, constrainedCount: 3, hasCondition: true,
    })
  })

  test('rejects R code injection, Condition-only formulas, and overlapping Condition covariates', () => {
    expect(validateOrdinationFormulaSyntax('~ system(ls)').valid).toBe(false)
    expect(validateOrdinationFormulaSyntax('y ~ group').valid).toBe(false)
    expect(validateOrdinationFormulaSyntax('~ Condition(run)').valid).toBe(false)
    expect(validateOrdinationFormulaSyntax('~ group + Condition(group)').valid).toBe(false)
    expect(validateOrdinationFormulaSyntax('~ group +').valid).toBe(false)
  })
})

describe('runtime estimation, scaling, citations, and CSV export', () => {
  test('estimates fast runtime on small studies and flags > 5 minute heavy runs', () => {
    const small = estimateOrdinationRuntime({
      method: 'dbrda',
      distance: 'bray',
      nSamples: 24,
      nFeatures: 120,
      permutations: 999,
      nTerms: 2,
      variancePartitioning: true,
    })
    expect(small.tier).toBe('fast')
    expect(small.warnFiveMinutes).toBe(false)

    const huge = estimateOrdinationRuntime({
      method: 'cap',
      distance: 'weighted_unifrac',
      nSamples: 2600,
      nFeatures: 4000,
      permutations: 9999,
      nTerms: 3,
      variancePartitioning: true,
    })
    expect(huge.warnFiveMinutes).toBe(true)
    expect(huge.tier).toBe('heavy')
  })

  test('scaling descriptions and primary literature citations are complete', () => {
    expect(scalingDescription(1)).toContain('Scaling 1')
    expect(scalingDescription(2)).toContain('Scaling 2')
    expect(ORDINATION_CITATIONS.map(c => c.doi)).toContain('10.3389/fmicb.2017.02224')
    expect(ORDINATION_CITATIONS.map(c => c.doi)).toContain('10.1890/0012-9658(2003)084[0511:CAOPCA]2.0.CO;2')
  })

  test('formats full provenance and result tables into CSV', () => {
    const mock: OrdinationResult = {
      method: 'dbrda',
      distance: 'bray',
      scaling: 2,
      formula: '~ group + Condition(run)',
      constrained_terms: ['group'],
      condition_terms: ['run'],
      available_covariates: ['group', 'run'],
      n_samples: 4,
      n_features: 12,
      total_inertia: 1.25,
      conditioned_inertia: 0.25,
      constrained_inertia: 0.55,
      unconstrained_inertia: 0.45,
      imaginary_inertia: 0,
      conditioned_proportion: 0.2,
      constrained_proportion: 0.44,
      unconstrained_proportion: 0.36,
      r2: 0.55,
      adj_r2: 0.41,
      axis_names: ['dbRDA1', 'MDS1'],
      axis_labels: ['dbRDA1 (44.0% total, 100.0% constrained)', 'MDS1 (36.0% total)'],
      constrained_eigenvalues: [{ axis: 'dbRDA1', eigenvalue: 0.55, proportion_total: 0.44, proportion_constrained: 1 }],
      unconstrained_eigenvalues: [{ axis: 'MDS1', eigenvalue: 0.45, proportion_total: 0.36 }],
      sites: [{ sample: 's1', axis1: -0.4, axis2: 0.1 }],
      biplot_arrows: [{ label: 'groupTreatment', axis1: 0.85, axis2: 0.0, length: 0.85 }],
      centroids: [{ label: 'group:Control', axis1: -0.5, axis2: 0.0 }],
      top_feature_scores: [],
      omnibus_test: {
        df_model: 1,
        df_residual: 1,
        variance_model: 0.55,
        variance_residual: 0.45,
        f_statistic: 4.12,
        p_value: 0.012,
        untestable_reason: null,
        permutations: 999,
        min_p_value: 0.001,
        text: 'Permutation test for dbrda',
      },
      term_tests: [{ term: 'group', df: 1, variance: 0.55, f_statistic: 4.12, p_value: 0.012, untestable_reason: null }],
      marginal_tests: [{ term: 'group', df: 1, variance: 0.55, f_statistic: 4.12, p_value: 0.012, untestable_reason: null }],
      axis_tests: [],
      variance_partitioning: {
        status: 'computed',
        covariates: ['group', 'depth'],
        conditioned_on: ['run'],
        individual_fractions: [{ label: '[a] = X1|X2', df: 1, r2: 0.32, adj_r2: 0.28, testable: true }],
        gross_fractions: [],
        has_negative_fraction: false,
        note: null,
      },
      cautions: ['Constrained ordination is exploratory/explanatory.'],
      runtime_estimate: { estimated_seconds: 0.12, tier: 'fast', warn_five_minutes: false },
      provenance: {
        method: 'dbrda',
        distance: 'bray',
        scaling: 2,
        scaling_meaning: 'correlation',
        formula: '~ group + Condition(run)',
        constrained_terms: ['group'],
        condition_terms: ['run'],
        permutations_requested: 999,
        permutations_performed: 999,
        seed: 20260409,
        rng_kind: 'Mersenne-Twister / Inversion / Rejection',
        blocked: false,
        beta_normalisation: 'hellinger',
        n_samples: 4,
        n_features: 12,
        dropped_zero_features: 0,
        zero_replacement: null,
        multiple_testing_policy: 'omnibus_and_term_permutation_tests_not_bh; per_taxon_tests_require_bh',
        software: { r_package: 'vegan', vegan_version: '2.7-3' },
      },
      biplot: { data: [], layout: {} },
    }
    const csv = formatOrdinationCsv(mock)
    expect(csv).toContain('# method=dbrda; distance=bray; scaling=2(correlation); formula=~ group + Condition(run)')
    expect(csv).toContain('site_score,s1,-0.4,0.1,,,')
    expect(csv).toContain('term_anova_sequential,group,1,0.55,4.12,0.012,')
    expect(csv).toContain('varpart_fraction,[a] = X1|X2,1,,0.32,0.28,testable')
  })
})
