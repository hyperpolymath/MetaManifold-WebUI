// SPDX-License-Identifier: AGPL-3.0-only
import { expect, test } from 'bun:test'
import { CONFIG_DESCRIPTIONS, CONFIG_TYPES } from './PipelineStages'

test('dispersion uses the enum editor with both supported models', () => {
  expect(CONFIG_TYPES['analysis.differential.dispersion']).toEqual({
    kind: 'enum', options: ['ml', 'glmGamPoi'],
  })
})

test('differential model editor exposes every method the backend accepts', () => {
  // Every method the backend accepts, in one list: offering a method the server
  // refuses, or hiding one it accepts, are both failures here.
  expect(CONFIG_TYPES['analysis.differential.method']).toEqual({
    kind: 'enum',
    options: [
      'nb_glm', 'clr_welch', 'zinb', 'hurdle_nb',
      'ancom_bc', 'aldex2', 'songbird',
      'multinomial', 'dirichlet_multinomial',
    ],
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

test('compositional models expose their own settings and say what they mean', () => {
  expect(CONFIG_TYPES['analysis.differential.mn_reference_taxon']).toEqual({ kind: 'string', nullable: true })
  expect(CONFIG_TYPES['analysis.differential.mn_penalty']).toMatchObject({ kind: 'float', min: 0 })
  expect(CONFIG_TYPES['analysis.differential.dm_overdispersion_method']).toEqual({
    kind: 'enum', options: ['mle', 'mom'],
  })
  expect(CONFIG_TYPES['analysis.differential.mc_samples']).toEqual({ kind: 'int' })
  expect(CONFIG_DESCRIPTIONS['analysis.differential.mc_samples']).toContain('Dirichlet')
  // The penalty is the one setting a user is tempted to tune for significance,
  // so the description has to warn against it.
  expect(CONFIG_DESCRIPTIONS['analysis.differential.mn_penalty']).toContain('do not tune it for significance')
})
