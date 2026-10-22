// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

// Types and vocabulary for Evidence Mode.
//
// A claim is a sentence a reader could disagree with, its scope fixes the part
// of the data it is about (its *fibre*), and its warrant says why it follows.
// The server is the authority on what a valid claim is; `claims.ts` mirrors the
// rules so the editor can explain a disabled Save before a request is made.

import type { AnnotationSource } from '../api/types'

export const CLAIM_STATUSES = ['draft', 'supported', 'contested', 'refuted'] as const
export type ClaimStatus = (typeof CLAIM_STATUSES)[number]

export const WARRANT_KINDS = ['definition', 'measurement', 'citation', 'inference'] as const
export type WarrantKind = (typeof WARRANT_KINDS)[number]

/** Warrants that can carry an empirical claim; a definition alone cannot. */
export const EVIDENTIAL_WARRANTS: readonly WarrantKind[] = ['measurement', 'citation', 'inference']

export const PROJECTION_TAGS = ['rank', 'category'] as const
export type ProjectionTag = (typeof PROJECTION_TAGS)[number]

export interface ClaimScope {
  table: string
  /** 'rank' names a taxonomy rank; 'category' names a composition set. */
  tag: ProjectionTag
  /** The rank name, or the category set name. */
  value: string
  source: AnnotationSource | null
  /** The labels that define the fibre. Never empty: a claim is never about everything. */
  values: string[]
}

export interface ClaimWarrant {
  kind: WarrantKind
  text: string
  /** Where the warrant comes from, e.g. a DOI, a figure file, a fibre reference. */
  ref?: string
}

export interface EvidenceClaim {
  id: string
  text: string
  status: ClaimStatus
  scope: ClaimScope
  warrant: ClaimWarrant[]
  caveats: string[]
  created?: string
  modified?: string
}

export interface ProvenanceSummary {
  present: boolean
  readable?: boolean
  file: string
  schema_version?: number
  generated?: string
  uniform?: boolean
  degraded?: boolean
  degraded_components?: string[]
  divergent?: string[]
  metamanifold?: { git_sha: string; git_dirty: boolean }
  runtimes?: { name: string; version: string }[]
  tools?: { name: string; version: string; sha256: string }[]
  databases?: { name: string; release: string }[]
  stages?: { name: string; status: string; finished: string }[]
}

export interface TableSummary {
  id: string
  rows: number
}

export interface RankSet {
  source: AnnotationSource
  names: string[]
  /** Column holding each rank, positionally aligned with `names`. */
  columns: string[]
}

export interface CategoryInfo {
  name: string
  colour?: string
}

export interface CategorySet {
  name: string
  label: string
  description: string
  categories: CategoryInfo[]
  unassigned_colour?: string
}

export interface EvidenceContext {
  study: string
  run: string
  group: string | null
  schema_version: number
  claim_statuses: ClaimStatus[]
  warrant_kinds: WarrantKind[]
  claims: EvidenceClaim[]
  updated: string | null
  /** Record path relative to the run directory, for display. */
  file: string
  provenance: ProvenanceSummary
  no_results: boolean
  tables: TableSummary[]
  sources: AnnotationSource[]
  ranks: RankSet[]
  merged_table?: string
  category_sets: CategorySet[]
}

export interface FibreSample {
  sample: string
  observed: number
  total: number
  /** The fibre's share of this sample's reads, in percent. */
  percent: number
}

export interface FibreMember {
  member: string
  reads: number
}

export interface FibreEcho {
  /** 'source': the other classifier at the same rank. 'rank': the parent rank. */
  kind: 'source' | 'rank'
  label: string
  projection: {
    tag: ProjectionTag
    value: string
    source: AnnotationSource | null
    values: string[]
  }
  fibre_rows: number
  fibre_reads: number
  agree_rows?: number
  agree_reads?: number
  missing_rows?: number
  missing_reads?: number
  conflict_rows?: number
  conflict_reads?: number
  echo_rows?: number
  echo_reads?: number
  inside_rows?: number
  inside_reads?: number
  agree_fraction: number
  contained_in_echo?: boolean
  verdict: string
  note?: string
}

export interface FibreTotals {
  rows: number
  reads: number
}

export interface Fibre {
  rows: number
  reads: number
  row_share: number
  read_share: number
  samples: FibreSample[]
}

export interface FibreRequest {
  table: string
  tag: ProjectionTag
  value: string
  values: string[]
  source?: AnnotationSource | null
}

export interface FibreResult {
  study: string
  run: string
  group: string | null
  table: string
  tag: ProjectionTag
  value: string
  values: string[]
  source: AnnotationSource | null
  label: string
  column: string
  totals: FibreTotals
  fibre: Fibre
  members: FibreMember[]
  member_count: number
  members_truncated: boolean
  echoes: FibreEcho[]
  notes: string[]
}

export type ResidualNull = 'proportional' | 'claim_share'

export interface ResidualRequest extends FibreRequest {
  null?: ResidualNull
  /** Required with null 'claim_share': the share of each sample's reads the fibre should hold. */
  share?: number | null
}

export interface ResidualSample {
  sample: string
  observed: number
  expected: number
  residual: number
  log2_ratio: number
  total: number
}

export interface ResidualSummary {
  chi2: number
  df: number
  n_samples: number
  n_usable: number
  n_excess: number
  n_deficit: number
  max_abs_residual: number
}

export interface ResidualResult {
  study: string
  run: string
  group: string | null
  table: string
  tag: ProjectionTag
  value: string
  values: string[]
  source: AnnotationSource | null
  null: { kind: ResidualNull; share: number | null; note: string }
  fibre: { rows: number; reads: number; read_share: number }
  grand: FibreTotals
  samples: ResidualSample[]
  summary: ResidualSummary
}
