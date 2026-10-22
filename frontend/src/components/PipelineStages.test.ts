// SPDX-License-Identifier: AGPL-3.0-only
import { expect, test } from 'bun:test'
import { CONFIG_TYPES } from './PipelineStages'

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
