// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Fuzz-lite totality tests — boundary adapters must never throw on
// wire-shaped garbage.
//
// Category (standards/testing-and-benchmarking/TESTING-TAXONOMY.adoc):
//   Fuzz (lite). Doctrine from proven-tests-and-benches: adversarial input
//   at the boundary, one invariant — THE ADAPTER MUST NOT THROW. Scope is
//   honest: inputs are JSON-shaped values (what the wire can actually carry:
//   null, wrong-type scalars, hostile nesting, absurd strings). Cyclic
//   structures and live host objects are out of scope by construction.
import { describe, test, expect } from 'bun:test'
import { applyColourOverrides, applyChartCosmetics } from '../../src/api/figureColours'
import { errorMessage } from '../../src/api/errorMessage'
import { splitLines } from '../../src/utils/text'

// Hand-curated hostile corpus: every shape of wrong the backend could send.
const GARBAGE: unknown[] = [
  null, undefined, true, false, 0, -0, NaN, Infinity, -Infinity,
  '', ' ', '\n', '\0', 'x'.repeat(100_000),
  'null', '{"a":1}', '[1,2,3]', '\ud800\udfff', // unpaired surrogates
  [], [null], [[[[[]]]]], [0, 'name', {}],
  {}, { data: null }, { data: 'nope' }, { data: {} }, { data: [null, undefined, 7] },
  { data: [{ name: null }] }, { data: [{ name: 42 }] },
  { data: [{ name: 'A', marker: null }] }, { data: [{ name: 'A', marker: 7 }] },
  { data: [{ name: 'A', marker: [], line: 'x' }] },
  { layout: null }, { layout: 0 }, { layout: [] }, { layout: '' },
  Object.create(null) as object,
  Array(1_000).fill({ name: 'A' }), // wide
  JSON.parse('{"data":[{"name":"A","marker":{"color":{"color":{"color":1}}}}]}') as unknown, // deep
]

const MAPS: Record<string, string>[] = [
  {}, { A: '#fff' }, { '': '#000' }, { A: '' }, JSON.parse('{"A":"#123456"}') as Record<string, string>,
]

describe('fuzz: applyColourOverrides is total over wire-shaped garbage', () => {
  for (const [i, g] of GARBAGE.entries()) {
    for (const [j, m] of MAPS.entries()) {
      test(`garbage[${i}] x map[${j}] does not throw`, () => {
        expect(() => applyColourOverrides(g, m)).not.toThrow()
      })
    }
  }
})

describe('fuzz: applyChartCosmetics is total over wire-shaped garbage', () => {
  const COSMETICS = [
    {},
    { layout: null },
    { layout: {} },
    { layout: { a: 1 }, traces: undefined },
    { traces: {} },
    { traces: { A: { opacity: 0.5 } } },
    { layout: { font: { size: 12 } }, traces: { '': { x: null } } },
  ]
  for (const [i, g] of GARBAGE.entries()) {
    for (const [j, c] of COSMETICS.entries()) {
      test(`garbage[${i}] x cosmetics[${j}] does not throw`, () => {
        expect(() => applyChartCosmetics(g, c)).not.toThrow()
      })
    }
  }
})

describe('fuzz: errorMessage never throws and always returns a string', () => {
  const CAUGHT: unknown[] = [
    null, undefined, 0, NaN, '', 'boom', {}, [], { message: 42 },
    new Error('real'), new TypeError('typed'), new RangeError(''),
    Object.assign(new Error('enriched'), { code: 'E_HOSTILE' }),
  ]
  for (const [i, c] of CAUGHT.entries()) {
    test(`caught[${i}] yields a string`, () => {
      const s = errorMessage(c)
      expect(typeof s).toBe('string')
      // Contract: Error → .message, string → verbatim (even ''), else fallback.
      if (c instanceof Error) expect(s).toBe(c.message)
      else if (typeof c === 'string') expect(s).toBe(c)
      else expect(s).toBe('Unknown error')
    })
  }
})

describe('fuzz: splitLines holds its contract for hostile text', () => {
  const TEXTS = ['', '\n', '\n\n\n', '  \n  ', 'a\n\n b \n', '\0\n\0', 'x'.repeat(50_000), 'a\rb\r', '  spaced  \n\ttabbed\t']
  for (const [i, t] of TEXTS.entries()) {
    test(`text[${i}]: no throw, no blank lines, all trimmed`, () => {
      let out: string[] = []
      expect(() => { out = splitLines(t) }).not.toThrow()
      for (const line of out) {
        expect(line.length).toBeGreaterThan(0)
        expect(line).toBe(line.trim())
      }
    })
  }
})
