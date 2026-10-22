// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).
import type { CumulativeCladeNode } from '../api/types'

export interface PositionedClade extends CumulativeCladeNode {
  x: number
  y: number
  depth: number
  children: string[]
  collapsed: boolean
}

export interface CladeLink {
  from: string
  to: string
  path: string
  frequency: number
}

export interface CumulativeLayout {
  nodes: PositionedClade[]
  byId: Map<string, PositionedClade>
  links: CladeLink[]
  width: number
  height: number
  rows: number
}

/**
 * Rectangular layout of the visible part of a cumulative tree. Descendants of a
 * collapsed clade occupy no rows. Parent ids must form one connected, acyclic
 * hierarchy; malformed server data is rejected rather than partially drawn.
 */
export function layoutCumulativeTree(
  source: CumulativeCladeNode[],
  collapsed: ReadonlySet<string> = new Set(),
  options: { rowHeight?: number; levelWidth?: number; margin?: number } = {},
): CumulativeLayout {
  const rowHeight = options.rowHeight ?? 26
  const levelWidth = options.levelWidth ?? 180
  const margin = options.margin ?? 28
  if (![rowHeight, levelWidth, margin].every(v => Number.isFinite(v) && v > 0)) {
    throw new Error('Tree layout dimensions must be positive')
  }

  const bySourceId = new Map<string, CumulativeCladeNode>()
  const children = new Map<string, string[]>()
  const roots: string[] = []
  for (const node of source) {
    if (bySourceId.has(node.id)) throw new Error(`Duplicate clade id: ${node.id}`)
    bySourceId.set(node.id, node)
    children.set(node.id, [])
  }
  for (const node of source) {
    if (node.parent_id === null) {
      roots.push(node.id)
    } else {
      const siblings = children.get(node.parent_id)
      if (!siblings) throw new Error(`Clade ${node.id} has a missing parent`)
      siblings.push(node.id)
    }
  }
  if (roots.length !== 1) throw new Error(`Expected one root, found ${roots.length}`)
  const reachable = new Set<string>()
  const markReachable = (id: string) => {
    if (reachable.has(id)) return
    reachable.add(id)
    for (const child of children.get(id) ?? []) markReachable(child)
  }
  markReachable(roots[0])
  if (reachable.size !== source.length) throw new Error('The clade hierarchy is not connected')

  const byId = new Map<string, PositionedClade>()
  const links: CladeLink[] = []
  const visited = new Set<string>()
  const active = new Set<string>()
  let row = 0
  let maxDepth = 0

  const visit = (id: string, depth: number): PositionedClade => {
    if (active.has(id)) throw new Error(`Cycle at clade ${id}`)
    if (visited.has(id)) throw new Error(`Clade ${id} occurs more than once`)
    const node = bySourceId.get(id)
    if (!node) throw new Error(`Unknown clade ${id}`)
    active.add(id)
    const kids = children.get(id) ?? []
    const isCollapsed = collapsed.has(id) && kids.length > 0
    const positioned: PositionedClade = {
      ...node,
      children: kids,
      collapsed: isCollapsed,
      depth,
      x: margin + depth * levelWidth,
      y: 0,
    }
    maxDepth = Math.max(maxDepth, depth)

    if (kids.length === 0 || isCollapsed) {
      positioned.y = margin + row * rowHeight
      row += 1
    } else {
      const positionedChildren = kids.map(child => visit(child, depth + 1))
      positioned.y = (positionedChildren[0].y + positionedChildren[positionedChildren.length - 1].y) / 2
      for (const child of positionedChildren) {
        links.push({
          from: id,
          to: child.id,
          path: `M ${positioned.x} ${positioned.y} V ${child.y} H ${child.x}`,
          frequency: Math.max(0, Math.min(1, child.cumulative_frequency)),
        })
      }
    }
    active.delete(id)
    visited.add(id)
    byId.set(id, positioned)
    return positioned
  }

  visit(roots[0], 0)

  // Return visible nodes in source order so SVG keyboard navigation is predictable.
  const nodes = source.filter(node => byId.has(node.id)).map(node => byId.get(node.id)!)
  return {
    nodes,
    byId,
    links,
    rows: row,
    width: margin * 2 + maxDepth * levelWidth + 300,
    height: Math.max(margin * 2, margin * 2 + (row - 1) * rowHeight),
  }
}

export const cumulativeRadius = (frequency: number) =>
  3 + 9 * Math.sqrt(Math.max(0, Math.min(1, frequency)))

export const cumulativeStroke = (frequency: number) =>
  1 + 5 * Math.sqrt(Math.max(0, Math.min(1, frequency)))
