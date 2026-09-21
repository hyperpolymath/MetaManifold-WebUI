// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Coupling / drift test — the TS API client must never call a route the
// Julia backend does not serve.
//
// Category (standards/testing-and-benchmarking/TESTING-TAXONOMY.adoc):
//   Coupling / drift. Boundary under test: src/api/client.ts (frontend) vs
//   src/server/routes/*.jl (backend @get/@post/... declarations). A route
//   renamed on one side only is a classic silent-drift breakage; this test
//   makes it a build-time failure instead of a production 404.
//
// Scope (honest): path presence only. Method-matching per endpoint needs a
// real parser on both sides and is recorded as a tightening opportunity, not
// faked here.
import { describe, test, expect } from 'bun:test'
import { readdirSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const ROOT = resolve(import.meta.dir, '../../..')
const CLIENT = join(ROOT, 'frontend/src/api/client.ts')
const ROUTES_DIR = join(ROOT, 'src/server/routes')

// Normalise a path template to a canonical shape where every dynamic
// segment becomes '{}' — TS `${encodeURIComponent(k)}` and Julia `{k}`
// both mean "one path segment here".
function normalise(path: string): string {
  return path
    .replace(/\$\{[^}]*\}/g, '{}')
    .replace(/\{[^}]*\}/g, '{}')
    .replace(/\/+$/, '')
}

function tsEndpoints(): string[] {
  const src = readFileSync(CLIENT, 'utf8')
  const out = new Set<string>()
  // Whole backtick templates, then: strip trailing query-string builders
  // (`${qs}`, `${gq(group)}` …) — those are query params, not path — and
  // normalise the remaining ${param} segments to '{}'.
  for (const m of src.matchAll(/`([^`]*)`/g)) {
    let p = m[1]
    if (!p.includes('/api/v1/')) continue
    p = p.slice(p.indexOf('/api/v1/'))
    // Only genuine query builders are stripped at end-of-path — ${gq(...)}
    // calls and ${qs} vars. ${encodeURIComponent(name)} et al. at end are
    // PATH segments and must survive as '{}'.
    p = p.replace(/\$\{gq\([^}]*\)\}$/, '')
    p = p.replace(/\$\{qs\}$/, '')
    p = p.split('?')[0]
    if (p.endsWith('/')) p = p.slice(0, -1)
    out.add(normalise(p))
  }
  return [...out].sort()
}

function juliaRoutes(): Set<string> {
  const out = new Set<string>()
  const re = /@(?:get|post|put|delete|patch)\s+"([^"]+)"/g
  for (const f of readdirSync(ROUTES_DIR)) {
    if (!f.endsWith('.jl')) continue
    const src = readFileSync(join(ROUTES_DIR, f), 'utf8')
    for (const m of src.matchAll(re)) out.add(normalise(m[1]))
  }
  return out
}

describe('coupling/drift: every TS client endpoint exists in the Julia routes', () => {
  test('client endpoint set ⊆ served route set', () => {
    const endpoints = tsEndpoints()
    const routes = juliaRoutes()
    expect(endpoints.length).toBeGreaterThan(20) // guard: extraction must not silently collapse
    expect(routes.size).toBeGreaterThan(20)
    const orphans = endpoints.filter(e => !routes.has(e))
    expect(orphans).toEqual([])
  })

  test('backend route set is not allowed to shrink without the client noticing', () => {
    // Reverse direction, pinned as a live snapshot: if a route is removed
    // from the backend while the client still calls it, the forward test
    // fires; this assertion pins the SERVED surface size as a coarse drift
    // alarm (route removals without the forward failure still force an edit
    // here, which review will catch).
    const routes = juliaRoutes()
    expect(routes.size).toBeGreaterThanOrEqual(50)
  })
})
