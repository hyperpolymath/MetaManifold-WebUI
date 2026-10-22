// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import { describe, expect, test } from 'bun:test'
import type { CumulativeCladeNode } from '../api/types'
import { cumulativeRadius, cumulativeStroke, layoutCumulativeTree } from './cumulativeLayout'

const node = (id: string, parent_id: string | null, frequency: number): CumulativeCladeNode => ({
  id, parent_id, label: id, branch_length: 1, is_tip: id > 'n2', tip_count: 1,
  cumulative_count: frequency * 12, cumulative_frequency: frequency,
})

// root(n1) -> AB(n2) -> A(n3), B(n4); root -> CD(n5) -> C(n6), D(n7)
const tree = [
  node('n1', null, 1), node('n2', 'n1', 0.75), node('n3', 'n2', 0.5),
  node('n4', 'n2', 0.25), node('n5', 'n1', 0.25), node('n6', 'n5', 0.125),
  node('n7', 'n5', 0.125),
]

describe('layoutCumulativeTree', () => {
  test('lays out every tip row and cumulative branch', () => {
    const layout = layoutCumulativeTree(tree)
    expect(layout.rows).toBe(4)
    expect(layout.nodes).toHaveLength(7)
    expect(layout.links).toHaveLength(6)
    expect(layout.byId.get('n3')?.y).toBe(28)
    expect(layout.byId.get('n4')?.y).toBe(54)
    expect(layout.byId.get('n2')?.y).toBe(41)
    expect(layout.byId.get('n1')?.y).toBe(67)
    expect(layout.byId.get('n1')?.x).toBe(28)
    expect(layout.byId.get('n3')?.x).toBe(388)
  })

  test('collapsed descendants occupy no rows or SVG links', () => {
    const layout = layoutCumulativeTree(tree, new Set(['n2']))
    expect(layout.rows).toBe(3)
    expect(layout.nodes.map(n => n.id)).toEqual(['n1', 'n2', 'n5', 'n6', 'n7'])
    expect(layout.links).toHaveLength(4)
    expect(layout.byId.get('n2')?.collapsed).toBe(true)
    expect(layout.byId.has('n3')).toBe(false)

    const rootOnly = layoutCumulativeTree(tree, new Set(['n1']))
    expect(rootOnly.rows).toBe(1)
    expect(rootOnly.nodes.map(n => n.id)).toEqual(['n1'])
    expect(rootOnly.links).toEqual([])
  })

  test('rejects malformed hierarchies', () => {
    expect(() => layoutCumulativeTree([...tree, node('n1', null, 1)])).toThrow('Duplicate')
    expect(() => layoutCumulativeTree(tree.filter(n => n.id !== 'n2'))).toThrow('missing parent')
    const disconnected = [...tree, node('n8', 'n9', 0), node('n9', 'n8', 0)]
    expect(() => layoutCumulativeTree(disconnected)).toThrow('not connected')
    expect(() => layoutCumulativeTree([])).toThrow('one root')
  })

  test('visual magnitudes are bounded', () => {
    expect(cumulativeRadius(0)).toBe(3)
    expect(cumulativeRadius(1)).toBe(12)
    expect(cumulativeRadius(100)).toBe(12)
    expect(cumulativeStroke(0.25)).toBe(3.5)
  })
})
