// SPDX-License-Identifier: MPL-2.0
import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { parseNewick, indexTree, parseJplace, buildDisplay, foldOps } from './model'
import { layoutTree, DEFAULT_SETTINGS } from './layout'
import { evidenceMarkers, type EvidenceResponse, type QueryEvidence } from './evidence'

const query = (ordinal: number, verdict: QueryEvidence['verdict'], value: number | null): QueryEvidence => ({
  key: `digest:${ordinal}`, ordinal, verdict, value, aliases: [{ name: `q${ordinal}`, multiplicity: 1 }],
  reason: '', best: [0], candidates: [],
})
const response = (queries: QueryEvidence[]): EvidenceResponse => ({
  state: 'ready', role: 'raw', result: { version: 1, checker: 'raw-best-lwr-v1', predicate: 'raw_best_lwr_gte',
    threshold: 0.95, tolerance: 1e-6, source_sha256: 'digest', assurance: 'computed; regression-tested', queries },
})
const rawTree = '((A:1{0},B:1{1}):1{2},C:1{3},D:1{4}){5};'
const source = parseJplace(JSON.stringify({ tree: rawTree, fields: ['edge_num', 'like_weight_ratio'],
  placements: [{ n: ['q0'], p: [[0, 0.6], [1, 0.4]] }, { n: ['q1'], p: [[1, 1]] }] }))
const ix = indexTree(source)
function layout(ops = foldOps([])) {
  return layoutTree(buildDisplay(ix, ops, new Map()), ix, source.pqueries, DEFAULT_SETTINGS)
}

describe('evidence identity vectors', () => {
  test('viewer IDs match the shared Julia known-answer fixture', () => {
    const vectors = JSON.parse(readFileSync(new URL('../../../test/fixtures/evidence/split-vectors.json', import.meta.url), 'utf8'))
    for (const v of vectors) {
      const index = indexTree(parseNewick(v.tree))
      expect(Object.fromEntries([...index.edgeByNum].map(([n, edge]) => [n, `split:${index.split[edge]}`])))
        .toEqual(Object.fromEntries(v.edges.map((e: { edge: number; split: string }) => [e.edge, e.split])))
    }
  })
})

describe('evidence presentation', () => {
  test('raw 0.6/0.4 remains fails on an accumulated LWR=1 marker', () => {
    const ev = response([query(0, 'fails', 0.6)])
    ev.role = 'accumulated'
    ev.mapping = [{ raw_ordinal: 0, target: { ordinal: 1, edge_num: 1, split: '' }, reason: '' }]
    const markers = evidenceMarkers(ev, layout())
    expect(markers).toHaveLength(1)
    expect(markers[0].counts).toEqual({ holds: 0, fails: 1, undecided: 0 })
    expect(ev.result!.queries[0].value).toBe(0.6)
  })
  test('unmapped queries have no invented location', () => {
    const ev = response([query(0, 'fails', 0.6)])
    ev.role = 'accumulated'; ev.mapping = [{ raw_ordinal: 0, target: null, reason: 'Absent' }]
    expect(evidenceMarkers(ev, layout())).toEqual([])
    expect(ev.result!.queries).toHaveLength(1)
  })
  test('invalid raw candidates have no display fallback marker', () => {
    expect(evidenceMarkers(response([query(0, 'undecided', null)]), layout())).toEqual([])
  })
  test('stale evidence never becomes a marker', () => {
    const ev = response([query(0, 'holds', 1)])
    ev.state = 'stale'
    expect(evidenceMarkers(ev, layout())).toEqual([])
  })
  test('collapse groups query counts without changing verdicts', () => {
    const ev = response([query(0, 'fails', 0.6), query(1, 'holds', 1)])
    const node = buildDisplay(ix, foldOps([]), new Map()).nodes.find(n => n.tips === 2)!
    const markers = evidenceMarkers(ev, layout(foldOps([{ op: 'collapse', clade: node.clade }])))
    expect(markers).toHaveLength(1)
    expect(markers[0].counts).toEqual({ holds: 1, fails: 1, undecided: 0 })
  })
  test('reroot preserves the query result set', () => {
    const ev = response([query(0, 'fails', 0.6), query(1, 'holds', 1)])
    const keys = (markers: ReturnType<typeof evidenceMarkers>) => [...new Set(markers.flatMap(m => m.queries.map(q => q.key)))].sort()
    expect(keys(evidenceMarkers(ev, layout(foldOps([{ op: 'reroot', split: ix.split[ix.edgeByNum.get(0)!], at: 0.5 }])))))
      .toEqual(keys(evidenceMarkers(ev, layout())))
  })
})
