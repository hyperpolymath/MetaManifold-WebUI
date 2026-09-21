// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Property/generative tests — api/figureColours.ts chart-transform laws.
//
// Category (standards/testing-and-benchmarking/TESTING-TAXONOMY.adoc):
//   Property (generative), seeded — ported from the proven-tests-and-benches
//   doctrine ("generate cases, prove laws, pin the seed"). No new dependency:
//   fast-check et al. would be idle weight here; a 20-line seeded generator
//   with recorded seeds gives the same failure reproducibility.
//
// Boundary under test: applyColourOverrides / applyChartCosmetics are the
// transforms every persisted chart cosmetic and colour preset flows through
// before Plotly renders. The laws that must hold for ANY generated input:
//   1. Totality        — never throws on wire-shaped data.
//   2. Immutability    — the incoming figure is never mutated.
//   3. Selectivity     — only traces named in the map change; every other
//                        trace is the identical object.
//   4. Application     — a named trace's marker.color becomes the override.
//   5. Idempotence     — applying the same map twice adds nothing.
// Deterministic seeds: if a case ever fails, the printed seed reproduces it.
import { describe, test, expect } from 'bun:test'
import { applyColourOverrides, applyChartCosmetics } from '../../src/api/figureColours'

// mulberry32 — small, deterministic PRNG; the seed IS the test corpus.
function rng(seed: number): () => number {
  let a = seed >>> 0
  return () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

type J = null | boolean | number | string | J[] | { [k: string]: J }

function genJson(r: () => number, depth: number): J {
  const pick = r()
  if (depth <= 0 || pick < 0.35) {
    if (pick < 0.08) return null
    if (pick < 0.14) return r() < 0.5
    if (pick < 0.26) return Math.floor(r() * 2000) - 1000
    return ['alpha', 'beta', '', 'OTU-1', String(Math.floor(r() * 50))][Math.floor(r() * 5)]
  }
  if (pick < 0.65) return Array.from({ length: Math.floor(r() * 4) }, () => genJson(r, depth - 1))
  const o: Record<string, J> = {}
  for (let i = 0, n = Math.floor(r() * 4); i < n; i++) o['k' + i] = genJson(r, depth - 1)
  return o
}

function genFigure(r: () => number, names: string[]): Record<string, unknown> {
  const data = Array.from({ length: Math.floor(r() * 5) }, () => {
    const t: Record<string, unknown> = {
      name: names[Math.floor(r() * names.length)],
      x: genJson(r, 1),
      y: genJson(r, 1),
    }
    if (r() < 0.7) t.marker = { color: '#111111', size: Math.floor(r() * 10) }
    if (r() < 0.5) t.line = { color: '#222222' }
    return t
  })
  return { data, layout: { title: genJson(r, 1), margin: { l: 10 } } }
}

const NAMES = ['Bacteria', 'Archaea', 'unmapped', 'k0', '']
const SEEDS = [1, 42, 1337, 2026, 900913]

// Structural equality over plain (JSON-shaped) data.
const eq = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b)
const snap = (v: unknown): string => JSON.stringify(v)

describe('property: applyColourOverrides laws over generated figures', () => {
  for (const seed of SEEDS) {
    test(`seed ${seed}: totality, immutability, selectivity, application, idempotence`, () => {
      const r = rng(seed)
      for (let round = 0; round < 40; round++) {
        const figure = genFigure(r, NAMES)
        const map: Record<string, string> = {}
        for (const n of NAMES) if (r() < 0.5) map[n] = '#' + Math.floor(r() * 0xffffff).toString(16).padStart(6, '0')

        const before = snap(figure)
        let out: unknown = undefined
        expect(() => { out = applyColourOverrides(figure, map) }).not.toThrow()
        expect(snap(figure)).toBe(before) // immutability

        const inTraces = (figure as { data: Record<string, unknown>[] }).data
        const outTraces = (out as { data: Record<string, unknown>[] }).data
        expect(outTraces.length).toBe(inTraces.length)
        outTraces.forEach((ot, i) => {
          const it = inTraces[i]
          const colour = map[it.name as string]
          if (!colour) {
            expect(ot).toBe(it) // selectivity: untouched identity
          } else {
            expect((ot.marker as Record<string, unknown>).color).toBe(colour) // application
            expect(JSON.stringify({ ...it, marker: undefined, line: undefined }))
              .toBe(JSON.stringify({ ...ot, marker: undefined, line: undefined }))
          }
        })

        // idempotence
        const twice = applyColourOverrides(out, map)
        expect(eq(twice, out)).toBe(true)
      }
    })
  }
})

describe('property: applyChartCosmetics laws (layout merge + trace cosmetics)', () => {
  for (const seed of SEEDS) {
    test(`seed ${seed}: totality, immutability, idempotence, layout monotonicity`, () => {
      const r = rng(seed)
      for (let round = 0; round < 40; round++) {
        const figure = genFigure(r, NAMES)
        const cosmetics = {
          layout: { font: { size: 8 + Math.floor(r() * 8) } } as Record<string, unknown>,
          traces: { Bacteria: { opacity: r() } } as Record<string, Record<string, unknown>>,
        }

        const before = snap(figure)
        let out: unknown = undefined
        expect(() => { out = applyChartCosmetics(figure, cosmetics) }).not.toThrow()
        expect(snap(figure)).toBe(before) // immutability

        // layout monotonicity: cosmetics keys land on top, prior keys survive
        const layout = (out as { layout: Record<string, unknown> }).layout
        expect((layout.font as Record<string, unknown>).size).toBe(cosmetics.layout.font.size)
        expect(layout.margin).toEqual({ l: 10 })

        // idempotence
        const twice = applyChartCosmetics(out, cosmetics)
        expect(eq(twice, out)).toBe(true)
      }
    })
  }
})

describe('property: generated garbage and the documented pass-through guards', () => {
  test('applyColourOverrides returns non-figure input by identity', () => {
    // Contract: anything that is not an object carrying an array `data`
    // passes through untouched — the SAME reference.
    for (const seed of SEEDS) {
      const r = rng(seed)
      for (let round = 0; round < 30; round++) {
        const v = genJson(r, 3)
        if (v && typeof v === 'object' && !Array.isArray(v) && 'data' in v) continue // figure-shaped: other laws cover it
        expect(applyColourOverrides(v, { x: '#fff' })).toBe(v)
      }
    }
  })

  test('applyChartCosmetics returns only null / non-objects by identity', () => {
    // Contract: the pass-through guard is `figure == null || typeof !==
    // 'object'`; any real object is legitimately rebuilt (layout merged).
    const r = rng(7)
    for (let round = 0; round < 30; round++) {
      const v = genJson(r, 0) // scalars and null only
      expect(applyChartCosmetics(v, { layout: { a: 1 } })).toBe(v)
    }
  })
})
