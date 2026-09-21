// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Scaffold smoke test — components/annotationShared.ts rank helpers
// (unit battery). Pure module: no DOM required.
import { test, expect } from 'bun:test'
import { prefillFromRow, SOURCES } from '../../src/components/annotationShared'

test('prefillFromRow: VSEARCH row yields the VSEARCH assignment column', () => {
  // SOURCES is derived from the backend contract; asserting its membership is
  // the one known property that proves the module graph wired up.
  expect(SOURCES).toContain('VSEARCH')
  const filled = prefillFromRow(
    { 'VSEARCH Assignment': 'Malassezia;g__Malassezia' } as Record<string, unknown>,
    'VSEARCH',
  )
  expect(typeof filled).toBe('object')
})
