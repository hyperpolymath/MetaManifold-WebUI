// SPDX-License-Identifier: MPL-2.0
import type { TreeLayout } from './layout'

export type Verdict = 'holds' | 'fails' | 'undecided'
export interface QueryEvidence {
  key: string
  ordinal: number
  aliases: { name: string; multiplicity: number }[]
  verdict: Verdict
  reason: string
  value: number | null
  best: number[]
  candidates: { ordinal: number; edge_num: number; split: string; lwr: number }[]
}
export interface PlacementMapping {
  raw_ordinal: number
  target: { ordinal: number; edge_num: number; split: string } | null
  reason: string
}
export interface EvidenceResponse {
  state: 'missing' | 'not_applicable' | 'invalid' | 'stale' | 'ready'
  message?: string
  role?: 'raw' | 'accumulated'
  raw_file?: string
  source_sha256?: string
  result?: {
    version: number; checker: string; predicate: string; threshold: number; tolerance: number
    source_sha256: string; assurance: string; queries: QueryEvidence[]
  }
  mapping?: PlacementMapping[] | null
  mapping_reason?: string | null
  provenance?: Record<string, unknown>
}
export interface EvidenceMarker {
  node: number; x: number; y: number
  counts: Record<Verdict, number>
  queries: QueryEvidence[]
}

/** Query verdicts remain independent of layout, filtering and collapsed clades. */
export function evidenceMarkers(evidence: EvidenceResponse | null, layout: TreeLayout): EvidenceMarker[] {
  if (evidence?.state !== 'ready' || !evidence.result) return []
  const groups = new Map<number, EvidenceMarker>()
  const mappings = new Map(evidence.mapping?.map(m => [m.raw_ordinal, m]))
  const places = new Map<number, TreeLayout['placements']>()
  for (const p of layout.placements) {
    const list = places.get(p.query) ?? []
    list.push(p); places.set(p.query, list)
  }
  const seen = new Map<number, Set<string>>()
  for (const q of evidence.result.queries) {
    const mapping = mappings.get(q.ordinal)
    const ordinal = evidence.role === 'accumulated' ? mapping?.target?.ordinal : q.ordinal
    if (ordinal === undefined || ordinal === null) continue
    // Invalid raw candidates have no justified location; retain them in the details.
    const locations = (places.get(ordinal) ?? []).filter(p =>
      (evidence.role === 'accumulated' || (q.value !== null && p.lwr === q.value)))
    for (const p of locations) {
      let group = groups.get(p.node.id)
      if (!group) {
        group = { node: p.node.id, x: p.x, y: p.y, counts: { holds: 0, fails: 0, undecided: 0 }, queries: [] }
        groups.set(p.node.id, group)
        seen.set(p.node.id, new Set())
      }
      if (!seen.get(p.node.id)!.has(q.key)) {
        seen.get(p.node.id)!.add(q.key)
        group.queries.push(q)
        group.counts[q.verdict]++
      }
    }
  }
  return [...groups.values()]
}
