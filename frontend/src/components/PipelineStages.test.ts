// SPDX-License-Identifier: AGPL-3.0-only
import { expect, test } from 'bun:test'
import { CONFIG_TYPES } from './PipelineStages'

test('dispersion uses the enum editor with both supported models', () => {
  expect(CONFIG_TYPES['analysis.differential.dispersion']).toEqual({
    kind: 'enum', options: ['ml', 'glmGamPoi'],
  })
})
