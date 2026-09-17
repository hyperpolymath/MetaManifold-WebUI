// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Scaffold smoke test — component/view/hook module graph (unit battery).
//
// Constraint honesty: bun test runs without a DOM, and neither
// proven-tests-and-benches nor rsr-template-repo defines a React DOM-harness
// pattern, so these scaffolds do NOT render. Each test imports the module
// (catches import-graph/type errors — the stated purpose) and asserts the
// one property every React component must have: at least one callable
// export. Full render coverage is a later prompt (see the accompanying
// plotly-chain.todo.test.ts and docs/testing/infrastructure.md).
import { test, expect } from 'bun:test'

const components = [
  ['DataTable', () => import('../../src/components/DataTable')],
  ['ErrorBoundary', () => import('../../src/components/ErrorBoundary')],
  ['Skeleton', () => import('../../src/components/Skeleton')],
] as const

const views = [
  ['StudiesView', () => import('../../src/views/StudiesView')],
  ['NotFoundView', () => import('../../src/views/NotFoundView')],
] as const

for (const [name, load] of [...components, ...views]) {
  test(`${name}: module loads and exports a callable component`, async () => {
    const mod = (await load()) as Record<string, unknown>
    // Function components are functions; class components (ErrorBoundary) are
    // classes — both are typeof 'function'. Modules export several values;
    // the known property is: at least one export is callable.
    const callables = Object.values(mod).filter((v) => typeof v === 'function')
    expect(callables.length).toBeGreaterThan(0)
  })
}

const hooks = [
  ['useAnalysis', () => import('../../src/hooks/useAnalysis')],
  ['useApi', () => import('../../src/hooks/useApi')],
  ['useJobEvents', () => import('../../src/hooks/useJobEvents')],
  ['useSSE', () => import('../../src/hooks/useSSE')],
] as const

for (const [name, load] of hooks) {
  test(`${name}: module loads and exports a callable hook`, async () => {
    const mod = (await load()) as Record<string, unknown>
    const callables = Object.values(mod).filter((v) => typeof v === 'function')
    expect(callables.length).toBeGreaterThan(0)
  })
}
