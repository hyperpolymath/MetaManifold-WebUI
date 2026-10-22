// SPDX-License-Identifier: AGPL-3.0-only
import { expect, test } from 'bun:test'
import { CONFIG_TYPES } from './PipelineStages'

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
