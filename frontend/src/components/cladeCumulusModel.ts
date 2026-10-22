// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

import type { CladeNodeData, EpistemicStatus } from '../api/types'

export const EPISTEMIC_META: Record<
  EpistemicStatus,
  { colour: string; badge: string; symbol: string; summary: string }
> = {
  present_in_every: {
    colour: '#2e7d32',
    badge: 'Every admissible world',
    symbol: '●',
    summary: 'Warranted across all admissible support / placement worlds; eligible target for clade reassignment.',
  },
  present_in_some: {
    colour: '#f9a825',
    badge: 'Some admissible worlds',
    symbol: '◆',
    summary: 'Supported in permissive worlds only; sensitive to bootstrap or placement weight threshold.',
  },
  absent: {
    colour: '#9e9e9e',
    badge: 'Absent in every world',
    symbol: '□',
    summary: 'Zero active reads or below every admissible world threshold.',
  },
  sans_fibre: {
    colour: '#c62828',
    badge: 'Unanchored (sans fibre)',
    symbol: '✕',
    summary: 'Unplaced or unanchored in the current reference / placement fibre.',
  },
}

export interface FlatCladeRow {
  depth: number
  node: CladeNodeData
  parentId: string | null
}

/** Exact client mirror of `Epistemic.cloud_size_by_residual(r) = log(1 + r) * 10 + 5`. */
export function cloudSizeByResidual(residualCount: number): number {
  if (!Number.isFinite(residualCount) || residualCount < 0) {
    throw new RangeError(`residualCount must be finite and non-negative, got ${residualCount}`)
  }
  return Math.log(1 + residualCount) * 10 + 5
}

export function flattenCladeTree(
  root: CladeNodeData,
  expandedIds?: ReadonlySet<string>,
  depth = 0,
  parentId: string | null = null,
  out: FlatCladeRow[] = [],
): FlatCladeRow[] {
  out.push({ depth, node: root, parentId })
  if (!expandedIds || expandedIds.has(root.id)) {
    for (const ch of root.children) {
      flattenCladeTree(ch, expandedIds, depth + 1, root.id, out)
    }
  }
  return out
}

export function collectAllCladeIds(root: CladeNodeData, out = new Set<string>()): Set<string> {
  out.add(root.id)
  for (const ch of root.children) {
    collectAllCladeIds(ch, out)
  }
  return out
}

export function findCladeNode(root: CladeNodeData, id: string): CladeNodeData | null {
  if (root.id === id) return root
  for (const ch of root.children) {
    const found = findCladeNode(ch, id)
    if (found) return found
  }
  return null
}

export function isCladeDescendant(candidateId: string, ancestor: CladeNodeData): boolean {
  for (const ch of ancestor.children) {
    if (ch.id === candidateId || isCladeDescendant(candidateId, ch)) {
      return true
    }
  }
  return false
}

/** Immediate client preflight matching server & Agda `validateMove` invariants. */
export function preflightCladeMove(
  root: CladeNodeData,
  sourceId: string,
  targetId: string,
): { structurallyValid: boolean; reason?: string } {
  if (!sourceId || !targetId) {
    return { structurallyValid: false, reason: 'Select both a source clade and a target clade.' }
  }
  if (sourceId === root.id) {
    return { structurallyValid: false, reason: 'The root clade cannot be detached.' }
  }
  if (sourceId === targetId) {
    return { structurallyValid: false, reason: 'Cannot drop a clade onto itself.' }
  }
  const src = findCladeNode(root, sourceId)
  const dst = findCladeNode(root, targetId)
  if (!src || !dst) {
    return { structurallyValid: false, reason: 'Source or target clade does not exist in this tree.' }
  }
  if (isCladeDescendant(targetId, src)) {
    return { structurallyValid: false, reason: 'Cannot move a clade beneath its own descendant (cycle forbidden).' }
  }
  return { structurallyValid: true }
}

function csvCell(val: string | number): string {
  const s = String(val)
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
}

export function formatDistanceMatrixCsv(samples: string[], matrix: number[][]): string {
  const header = ['Sample', ...samples].map(csvCell).join(',')
  const lines = samples.map((s, r) => {
    const rowVals = (matrix[r] ?? []).map(v => Number(v).toFixed(8))
    return [csvCell(s), ...rowVals].join(',')
  })
  return [header, ...lines].join('\n')
}
