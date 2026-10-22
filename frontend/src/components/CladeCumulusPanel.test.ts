// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

import { describe, expect, test } from 'bun:test'
import type { CladeNodeData } from '../api/types'
import {
  EPISTEMIC_META,
  cloudSizeByResidual,
  collectAllCladeIds,
  flattenCladeTree,
  formatDistanceMatrixCsv,
  preflightCladeMove,
} from './cladeCumulusModel'

function makeNode(
  id: string,
  name: string,
  cumulative_count: number,
  residual_count: number,
  epistemic_status: CladeNodeData['epistemic_status'],
  children: CladeNodeData[] = [],
): CladeNodeData {
  return {
    id,
    name,
    rank: children.length ? 'clade' : 'tip',
    direct_count: children.length ? 0 : cumulative_count,
    cumulative_count,
    cumulative_frequency: cumulative_count / 100,
    residual_count,
    cloud_size: cloudSizeByResidual(residual_count),
    branch_length: 0.1,
    support: 0.95,
    subtree_pd: 0.25,
    dominant_taxon: null,
    taxon_purity: null,
    monophyletic: null,
    epistemic_status,
    colour: EPISTEMIC_META[epistemic_status].colour,
    children,
  }
}

describe('CladeCumulus frontend model invariants', () => {
  test('epistemic colours match canonical hex palette', () => {
    expect(EPISTEMIC_META.present_in_every.colour).toBe('#2e7d32')
    expect(EPISTEMIC_META.present_in_some.colour).toBe('#f9a825')
    expect(EPISTEMIC_META.absent.colour).toBe('#9e9e9e')
    expect(EPISTEMIC_META.sans_fibre.colour).toBe('#c62828')
  })

  test('cloudSizeByResidual implements log(1 + r) * 10 + 5 and rejects negatives', () => {
    expect(cloudSizeByResidual(0)).toBeCloseTo(5.0, 12)
    expect(cloudSizeByResidual(Math.E - 1)).toBeCloseTo(15.0, 12)
    expect(cloudSizeByResidual(99)).toBeGreaterThan(cloudSizeByResidual(10))
    expect(() => cloudSizeByResidual(-0.01)).toThrow(RangeError)
    expect(() => cloudSizeByResidual(Number.NaN)).toThrow(RangeError)
  })

  test('flattenCladeTree respects collapsed clade sets and preserves hierarchy depth', () => {
    const tipA1 = makeNode('asv_1', 'ASV_1', 40, 0, 'present_in_every')
    const tipA2 = makeNode('asv_2', 'ASV_2', 20, 5, 'present_in_some')
    const cladeA = makeNode('clade_a', 'Clade A', 60, 5, 'present_in_every', [tipA1, tipA2])
    const cladeB = makeNode('clade_b', 'Clade B', 40, 12, 'present_in_some', [
      makeNode('asv_3', 'ASV_3', 40, 12, 'present_in_some'),
    ])
    const root = makeNode('root', 'Root', 100, 17, 'present_in_every', [cladeA, cladeB])

    const allIds = collectAllCladeIds(root)
    expect(allIds.size).toBe(6)
    expect(flattenCladeTree(root, allIds).map(r => [r.depth, r.node.id])).toEqual([
      [0, 'root'],
      [1, 'clade_a'],
      [2, 'asv_1'],
      [2, 'asv_2'],
      [1, 'clade_b'],
      [2, 'asv_3'],
    ])

    // Collapsing clade_a hides its tips while keeping sibling clade_b visible
    const collapsed = new Set(['root', 'clade_b'])
    expect(flattenCladeTree(root, collapsed).map(r => r.node.id)).toEqual([
      'root',
      'clade_a',
      'clade_b',
      'asv_3',
    ])
  })

  test('preflightCladeMove blocks root moves, self drops, and descendant cycles', () => {
    const child = makeNode('tip_1', 'ASV_1', 30, 0, 'present_in_every')
    const subClade = makeNode('sub_1', 'Subclade', 30, 0, 'present_in_every', [child])
    const sibling = makeNode('clade_target', 'Target', 70, 0, 'present_in_every')
    const root = makeNode('root', 'Root', 100, 0, 'present_in_every', [subClade, sibling])

    expect(preflightCladeMove(root, 'root', 'clade_target').structurallyValid).toBe(false)
    expect(preflightCladeMove(root, 'sub_1', 'sub_1').structurallyValid).toBe(false)
    expect(preflightCladeMove(root, 'sub_1', 'tip_1').structurallyValid).toBe(false)
    expect(preflightCladeMove(root, 'sub_1', 'missing').structurallyValid).toBe(false)
    expect(preflightCladeMove(root, 'sub_1', 'clade_target')).toEqual({ structurallyValid: true })
  })

  test('formatDistanceMatrixCsv quotes commas and formats symmetric matrices cleanly', () => {
    const csv = formatDistanceMatrixCsv(
      ['S1,ctrl', 'S2'],
      [
        [0, 0.733333333333],
        [0.733333333333, 0],
      ],
    )
    const lines = csv.split('\n')
    expect(lines[0]).toBe('Sample,"S1,ctrl",S2')
    expect(lines[1]).toBe('"S1,ctrl",0.00000000,0.73333333')
    expect(lines[2]).toBe('S2,0.73333333,0.00000000')
  })
})
