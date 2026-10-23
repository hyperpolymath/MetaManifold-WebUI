// SPDX-License-Identifier: AGPL-3.0-only
import { expect, test } from 'bun:test'
import { CONFIG_DESCRIPTIONS, CONFIG_TYPES } from './PipelineStages'

test('dispersion uses the enum editor with both supported models', () => {
  expect(CONFIG_TYPES['analysis.differential.dispersion']).toEqual({
    kind: 'enum', options: ['ml', 'glmGamPoi'],
  })
})

test('differential model editor exposes supported two-part NB methods', () => {
  expect(CONFIG_TYPES['analysis.differential.method']).toEqual({
    kind: 'enum', options: ['nb_glm', 'clr_welch', 'zinb', 'hurdle_nb'],
  })
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

test('differential method enum lists exactly the methods accepted by the backend', () => {
  expect(CONFIG_TYPES['analysis.differential.method']).toEqual({
    kind: 'enum',
    options: ['nb_glm', 'clr_welch', 'zinb', 'hurdle_nb'],
  })
})
