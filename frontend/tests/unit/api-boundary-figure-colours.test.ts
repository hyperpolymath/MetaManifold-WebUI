// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Type-boundary tests — api/figureColours.ts (adapter: cosmetics DTO → figure).
//
// Boundary under test: LayoutOverrides / TraceOverrides (src/types/api/cosmetics.ts,
// SOURCE src/server/routes/analysis.jl) are applied onto a PlotFigure-shaped
// unknown (src/types/plotly.ts). The adapter must (a) transform valid data
// into the declared cosmetic shapes, (b) pass malformed shapes through
// untouched (never crash, never fabricate), and (c) never mutate its input.
// These are the app-side parsers for the chart-cosmetics boundary; they are
// the only place cosmetics semantics live outside ChartCustomiser.
//
// DOM-free module: no REACT, no plotly — safe for the bun lane.
import { describe, test, expect } from 'bun:test'
import { applyColourOverrides, applyChartCosmetics } from '../../src/api/figureColours'

describe('applyColourOverrides — trace-name-keyed recolouring', () => {
  test('recolours only the matched trace, preserving co-traces', () => {
    // Arrange
    const figure = {
      data: [
        { name: 'Fungi', marker: { size: 9 }, line: { width: 2 } },
        { name: 'Metazoa', marker: {} },
      ],
      layout: { title: 'x' },
    }
    // Act
    const out = applyColourOverrides(figure, { Fungi: '#1b9e77' }) as {
      data: { name: string; marker?: Record<string, unknown>; line?: Record<string, unknown> }[]
      layout: unknown
    }
    // Assert: matched trace gains marker+line colour, keeps width; unmatched
    // trace is the original reference; layout untouched.
    expect(out.data[0]?.marker?.color).toBe('#1b9e77')
    expect(out.data[0]?.marker?.size).toBe(9)
    expect(out.data[0]?.line?.color).toBe('#1b9e77')
    expect(out.data[0]?.line?.width).toBe(2)
    expect(out.data[1]).toBe(figure.data[1])
    expect(out.layout).toBe(figure.layout)
  })

  test('a trace without a line does not gain one', () => {
    // Recolouring must not fabricate structure the renderer would draw.
    const figure = { data: [{ name: 'Fungi' }] }
    const out = applyColourOverrides(figure, { Fungi: '#c92a2a' }) as {
      data: Record<string, unknown>[]
    }
    expect(out.data[0]?.['marker']).toEqual({ color: '#c92a2a' })
    expect('line' in (out.data[0] ?? {})).toBe(false)
  })

  test('parameterised over representative wire value kinds from the boundary', () => {
    // Boundary rows arrive under any TableCell-ish name; recolouring only
    // keys on a present string name.
    for (const name of ['soil', 'Mock Community 1', 'Échantillon']) {
      const figure = { data: [{ name, marker: {} }] }
      const out = applyColourOverrides(figure, { [name]: '#000' }) as {
        data: { marker?: Record<string, unknown> }[]
      }
      expect(out.data[0]?.marker?.color).toBe('#000')
    }
  })

  test('malformed figures pass through by identity (rejection contract)', () => {
    // Arrange/Act/Assert: the three malformed families the boundary admits:
    // nullish, non-object, and object without a `data` array.
    expect(applyColourOverrides(null, { a: '#000' })).toBeNull()
    expect(applyColourOverrides(undefined, { a: '#000' })).toBeUndefined()
    expect(applyColourOverrides('raw', { a: '#000' })).toBe('raw')
    const noData = { layout: {} }
    expect(applyColourOverrides(noData, { a: '#000' })).toBe(noData)
    // data present but not an array also passes through.
    const badData = { data: 'not-an-array' }
    expect(applyColourOverrides(badData, { a: '#000' })).toBe(badData)
  })

  test('non-object elements inside data pass through unscathed', () => {
    const figure = { data: [null, 42, { name: 'Fungi', marker: {} }] }
    const out = applyColourOverrides(figure, { Fungi: '#111' }) as { data: unknown[] }
    expect(out.data[0]).toBeNull()
    expect(out.data[1]).toBe(42)
    expect((out.data[2] as { marker?: Record<string, unknown> })?.marker?.color).toBe('#111')
  })

  test('the input figure is never mutated (immutability contract)', () => {
    const trace = { name: 'Fungi', marker: { size: 3 }, line: { width: 1 } }
    const figure = { data: [trace], layout: { title: 'x' } }
    const markerBefore = trace.marker
    const lineBefore = trace.line
    const out = applyColourOverrides(figure, { Fungi: '#0f0' })
    expect(out).not.toBe(figure)
    expect(figure.data[0]).toBe(trace) // original array element untouched
    expect(trace.marker).toBe(markerBefore)
    expect(trace.line).toBe(lineBefore)
    expect(trace.marker.size).toBe(3)
  })

  test('an empty colour map leaves every trace reference untouched', () => {
    const figure = { data: [{ name: 'Fungi', marker: { color: '#aaa' } }] }
    const out = applyColourOverrides(figure, {}) as { data: unknown[] }
    expect(out.data[0]).toBe(figure.data[0])
  })
})

describe('applyChartCosmetics — layout and trace override deep-merge', () => {
  test('layout overrides merge deeply, preserving sibling keys', () => {
    // Arrange: cosmetics as they arrive from the backend (SOURCE analysis.jl).
    const figure = {
      data: [],
      layout: { title: { text: 'old' }, margin: { l: 60, r: 30 } },
    }
    const cosmetics = { layout: { title: { font: { size: 20 } }, margin: { r: 45 } } }
    // Act
    const out = applyChartCosmetics(figure, cosmetics) as {
      layout: { title: Record<string, unknown>; margin: Record<string, unknown> }
    }
    // Assert: deep overrides land; untouched layout keys survive the merge.
    expect((out.layout.title['font'] as Record<string, unknown>)?.['size']).toBe(20)
    expect(out.layout.title['text']).toBe('old')
    expect(out.layout.margin['l']).toBe(60)
    expect(out.layout.margin['r']).toBe(45)
  })

  test('array-valued overrides replace rather than merge elementwise', () => {
    // deepMerge semantics: arrays are replaced outright (merging tick arrays
    // elementwise would corrupt plotly axis config).
    const figure = { data: [], layout: { xaxis: { tickvals: [1, 2, 3] } } }
    const out = applyChartCosmetics(figure, { layout: { xaxis: { tickvals: [9] } } }) as {
      layout: { xaxis: { tickvals: unknown[] } }
    }
    expect(out.layout.xaxis.tickvals).toEqual([9])
  })

  test('trace overrides apply per trace name; unknown names are dropped', () => {
    const figure = {
      data: [
        { name: 'Fungi', marker: { size: 4 } },
        { name: 'Metazoa', hoverinfo: 'x' },
      ],
      layout: {},
    }
    const out = applyChartCosmetics(figure, {
      traces: { Fungi: { marker: { color: '#1b9e77' } }, Phantom: { opacity: 0.1 } },
    }) as { data: Record<string, unknown>[] }
    expect((out.data[0]?.['marker'] as Record<string, unknown>)?.['color']).toBe('#1b9e77')
    expect((out.data[0]?.['marker'] as Record<string, unknown>)?.['size']).toBe(4)
    expect(out.data[1]).toBe(figure.data[1]) // Phantom must not fabricate a trace
  })

  test('cosmetics do not mutate either input', () => {
    const figure = { data: [{ name: 'A', marker: {} }], layout: { showlegend: true } }
    const cosmetics = { layout: { showlegend: false }, traces: { A: { mode: 'lines' } } }
    const tracesBefore = cosmetics.traces.A
    const out = applyChartCosmetics(figure, cosmetics)
    expect(out).not.toBe(figure)
    expect(figure.layout.showlegend).toBe(true) // source figure intact
    expect((figure.data[0] as Record<string, unknown>)?.['mode']).toBeUndefined()
    expect(cosmetics.traces.A).toBe(tracesBefore)
  })

  test('empty or absent cosmetics still yield a clean clone', () => {
    // Arrange/Act/Assert: cosmetics = {} is the steady state when the study
    // has no persisted overrides; the figure survives with cloned containers.
    const figure = { data: [{ name: 'A' }], layout: { autosize: true } }
    const out = applyChartCosmetics(figure, {}) as { data: unknown[]; layout: Record<string, unknown> }
    expect(out.data[0]).toBe(figure.data[0])
    expect(out.layout).toEqual({ autosize: true })
    expect(out.layout).not.toBe(figure.layout)
  })

  test('malformed figures pass through by identity', () => {
    expect(applyChartCosmetics(null, { layout: { x: 1 } })).toBeNull()
    expect(applyChartCosmetics(17, {})).toBe(17)
    const dataless = { layout: {} }
    expect(applyChartCosmetics(dataless, {})).not.toBe(dataless) // layout cloned even when data absent
    expect((applyChartCosmetics(dataless, {}) as Record<string, unknown>)?.['layout']).toEqual({})
  })
})
