// SPDX-License-Identifier: AGPL-3.0-only
import { expect, test } from 'bun:test'
import { CONFIG_DESCRIPTIONS, CONFIG_TYPES } from './PipelineStages'

test('dispersion uses the enum editor with both supported models', () => {
  expect(CONFIG_TYPES['analysis.differential.dispersion']).toEqual({
    kind: 'enum', options: ['ml', 'glmGamPoi'],
  })
})

test('the method editor offers both multinomial models and the enums they add', () => {
  expect(CONFIG_TYPES['analysis.differential.method']).toEqual({
    kind: 'enum',
    options: ['nb_glm', 'clr_welch', 'multinomial', 'dirichlet_multinomial'],
  })
  expect(CONFIG_TYPES['analysis.differential.dm_overdispersion_method']).toEqual({
    kind: 'enum', options: ['mle', 'mom'],
  })
  // The penalty is a non-negative ridge term, and the optimiser budget is a
  // positive number of seconds.
  expect(CONFIG_TYPES['analysis.differential.mn_penalty']).toEqual({
    kind: 'float', min: 0, step: 0.05,
  })
  expect(CONFIG_TYPES['analysis.differential.max_seconds']).toEqual({
    kind: 'float', min: 1,
  })
  expect(CONFIG_TYPES['analysis.differential.max_iter']).toEqual({ kind: 'int' })
})

test('advanced zero handling exposes both methods, bounded delta and nullable alpha', () => {
  expect(CONFIG_TYPES['analysis.differential.replacement_method']).toEqual({
    kind: 'enum', options: ['bayesian_multiplicative', 'multiplicative_replacement'],
  })
  expect(CONFIG_TYPES['analysis.differential.replacement_delta']).toMatchObject({ kind: 'float', step: 0.05 })
  expect(CONFIG_TYPES['analysis.differential.bayesian_alpha']).toMatchObject({ kind: 'float', nullable: true })
  expect(CONFIG_DESCRIPTIONS['analysis.differential.replacement_method']).toContain('every replacement is biased')
  expect(CONFIG_DESCRIPTIONS['analysis.differential.bayesian_alpha']).toContain('no posterior draws')
})
