// Scaffold smoke test — api/figureColours.ts colour override merge (unit battery).
import { test, expect } from 'bun:test'
import { applyColourOverrides } from '../../src/api/figureColours'

test('applyColourOverrides: named trace receives its mapped colour', () => {
  const figure = {
    data: [
      { name: 'Fungi', marker: {} },
      { name: 'Metazoa', marker: {} },
    ],
  }
  const out = applyColourOverrides(figure, { Fungi: '#1b9e77' }) as {
    data: { name: string; marker?: Record<string, unknown> }[]
  }
  expect(out.data[0]?.marker?.color).toBe('#1b9e77')
})
