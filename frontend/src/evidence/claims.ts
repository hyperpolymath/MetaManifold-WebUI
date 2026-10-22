// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

// Claim rules for the epistemic editor.
//
// This module mirrors `src/core/evidence.jl`. The server is the authority; this
// copy exists so the editor can say *why* a Save is disabled before the request
// is made, and so the same sentence is used in both places. When a rule changes
// there, change it here too: `evidence.test.ts` pins the pair of behaviours.

import {
  CLAIM_STATUSES, EVIDENTIAL_WARRANTS, PROJECTION_TAGS, WARRANT_KINDS,
  type ClaimScope, type ClaimStatus, type ClaimWarrant, type EvidenceClaim,
  type EvidenceContext, type FibreRequest, type ProjectionTag, type WarrantKind,
} from './types'
import type { AnnotationSource } from '../api/types'

export const MAX_CLAIMS = 200
export const MAX_VALUES = 50
export const MAX_WARRANTS = 5
export const MAX_CAVEATS = 20
export const MAX_TEXT = 2000
export const MAX_LABEL = 200
export const MAX_ID = 64

const SAFE_NAME = /^[A-Za-z0-9._-]+$/
const RANK_NAME = /^[A-Za-z][A-Za-z0-9_]*$/

export const isSafeName = (s: string): boolean => SAFE_NAME.test(s) && !s.startsWith('.')

const isBlank = (s: unknown): boolean => typeof s !== 'string' || s.trim() === ''

/**
 * The identifier stem for a claim, mirroring `slugify` in the Julia module: runs
 * outside [a-z0-9] collapse to one hyphen, cut to 48 characters.
 */
export function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48)
}

/** A free identifier for `text`, suffixed `-2`, `-3`, … when taken. */
export function nextClaimId(existing: EvidenceClaim[], text: string): string {
  const taken = new Set(existing.map(c => c.id))
  const base = slugify(text) || 'claim'
  let candidate = base
  let n = 1
  while (taken.has(candidate)) {
    n += 1
    candidate = `${base}-${n}`
  }
  return candidate
}

/**
 * The projection the fibre and residual views open on: the merged table, the
 * first classifier the run carries and its first rank, with no values (the user
 * must name the fibre).
 */
export function defaultRequest(context: EvidenceContext): FibreRequest {
  const table = context.merged_table ?? context.tables[0]?.id ?? 'merged'
  const source = context.sources[0] ?? null
  const rankSet = source ? context.ranks.find(r => r.source === source) : context.ranks[0]
  const tag: ProjectionTag = rankSet && rankSet.names.length
    ? 'rank'
    : (context.category_sets.length ? 'category' : 'rank')
  const value = tag === 'rank'
    ? (rankSet?.names[0] ?? '')
    : (context.category_sets[0]?.name ?? '')
  return { table, tag, value, source, values: [] }
}

/** An empty claim scoped to nothing yet; the editor fills the scope in. */
export function newClaim(scope?: Partial<ClaimScope>): EvidenceClaim {
  return {
    id: '',
    text: '',
    status: 'draft',
    scope: {
      table: scope?.table ?? 'merged',
      tag: scope?.tag ?? 'rank',
      value: scope?.value ?? '',
      source: scope?.source ?? null,
      values: scope?.values ? [...scope.values] : [],
    },
    warrant: [],
    caveats: [],
  }
}

/** Warrants of a kind that can carry an empirical claim. */
export function evidentialWarrants(claim: EvidenceClaim): ClaimWarrant[] {
  return claim.warrant.filter(w => EVIDENTIAL_WARRANTS.includes(w.kind))
}

/** One line describing a scope, for a claim list. */
export function scopeSummary(scope: ClaimScope): string {
  const where = scope.tag === 'rank' ? scope.value : `set ${scope.value}`
  const labels = scope.values.length ? scope.values.join(', ') : '(no values)'
  const source = scope.source ? ` · ${scope.source}` : ''
  return `${where} ⊇ ${labels}${source} · ${scope.table}`
}

/** Colour used for a claim's status badge. */
export function statusTone(status: ClaimStatus): string {
  switch (status) {
    case 'supported': return '#2b8a3e'
    case 'contested': return '#b7791f'
    case 'refuted':   return '#c92a2a'
    default:          return '#6c757d'
  }
}

/**
 * Every reason the claim cannot be saved, in the order a reader would fix them.
 * Empty means valid. Mirrors `claim_errors` in `src/core/evidence.jl`.
 */
export function validateClaim(claim: EvidenceClaim): string[] {
  const errors: string[] = []

  const id = claim.id ?? ''
  if (!id) errors.push('a claim needs an id')
  else if (!isSafeName(id)) {
    errors.push(`claim id “${id}” must be letters, digits, dots, hyphens or underscores, not starting with a dot`)
  } else if (id.length > MAX_ID) errors.push(`claim id “${id}” is longer than ${MAX_ID} characters`)

  if (isBlank(claim.text)) errors.push('a claim needs text')
  else if (claim.text.trim().length > MAX_TEXT) errors.push(`claim text is longer than ${MAX_TEXT} characters`)

  if (!CLAIM_STATUSES.includes(claim.status)) {
    errors.push(`status “${claim.status}” must be one of ${CLAIM_STATUSES.join(', ')}`)
  }

  const scope = claim.scope
  if (!scope) {
    errors.push('a claim needs a scope naming the projection it is about')
  } else {
    if (!isSafeName(scope.table)) {
      errors.push(`scope.table “${scope.table}” must be letters, digits, dots, hyphens or underscores`)
    }
    if (!PROJECTION_TAGS.includes(scope.tag)) {
      errors.push(`scope.tag “${scope.tag}” must be one of ${PROJECTION_TAGS.join(', ')}`)
    }
    if (!scope.value) {
      errors.push("scope.value must name a rank (tag 'rank') or a category set (tag 'category')")
    } else if (scope.tag === 'rank' && !RANK_NAME.test(scope.value)) {
      errors.push(`scope.value “${scope.value}” is not a rank name`)
    } else if (scope.tag === 'category' && !isSafeName(scope.value)) {
      errors.push(`scope.value “${scope.value}” is not a category set name`)
    }
    if (scope.source != null && scope.source !== 'VSEARCH' && scope.source !== 'DADA2') {
      errors.push('scope.source must be VSEARCH, DADA2 or empty')
    }
    if (!scope.values.length) {
      errors.push('scope.values must list at least one value: the fibre a claim is about is never everything')
    } else if (scope.values.length > MAX_VALUES) {
      errors.push(`scope.values holds ${scope.values.length} values; the limit is ${MAX_VALUES}`)
    } else if (scope.values.some(v => isBlank(v))) {
      errors.push('scope.values contains an empty value')
    } else if (scope.values.some(v => v.length > MAX_LABEL)) {
      errors.push(`scope.values entry is longer than ${MAX_LABEL} characters`)
    }
  }

  if (claim.warrant.length > MAX_WARRANTS) {
    errors.push(`a claim may carry at most ${MAX_WARRANTS} warrants`)
  }
  claim.warrant.forEach((w, i) => {
    const n = i + 1
    if (!WARRANT_KINDS.includes(w.kind)) {
      errors.push(`warrant ${n} kind “${w.kind}” must be one of ${WARRANT_KINDS.join(', ')}`)
    }
    if (isBlank(w.text)) errors.push(`warrant ${n} needs text`)
    else if (w.text.trim().length > MAX_TEXT) {
      errors.push(`warrant ${n} text is longer than ${MAX_TEXT} characters`)
    }
  })

  // The anti-cherry-pick rule: the record may not say a claim is supported
  // without saying what supports it.
  if (claim.status === 'supported' && evidentialWarrants(claim).length === 0) {
    errors.push(
      "status 'supported' needs at least one warrant of kind measurement, citation, inference " +
      '- a definition alone supports nothing',
    )
  }

  if (claim.caveats.length > MAX_CAVEATS) {
    errors.push(`a claim may carry at most ${MAX_CAVEATS} caveats`)
  } else if (claim.caveats.some(c => isBlank(c))) {
    errors.push('caveats contains an empty entry')
  } else if (claim.caveats.some(c => c.length > MAX_TEXT)) {
    errors.push(`a caveat is longer than ${MAX_TEXT} characters`)
  }

  return errors
}

/** A claim with the fields the editor renders, tolerant of a partial record. */
export function draftClaim(claim: EvidenceClaim): EvidenceClaim {
  return {
    ...claim,
    scope: {
      table: claim.scope?.table ?? 'merged',
      tag: (claim.scope?.tag ?? 'rank') as ProjectionTag,
      value: claim.scope?.value ?? '',
      source: claim.scope?.source ?? null,
      values: claim.scope?.values ? [...claim.scope.values] : [],
    },
    warrant: claim.warrant ? claim.warrant.map(w => ({ ...w })) : [],
    caveats: claim.caveats ? [...claim.caveats] : [],
  }
}

/** Split a comma- or newline-separated input into unique, trimmed values. */
export function parseValues(raw: string): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const part of raw.split(/[,\n]/)) {
    const v = part.trim()
    if (!v || seen.has(v)) continue
    seen.add(v)
    out.push(v)
  }
  return out
}

/** Add one value to a scope's fibre, ignoring blanks and duplicates. */
export function addValue(values: string[], value: string): string[] {
  const v = value.trim()
  if (!v || values.includes(v)) return values
  return [...values, v]
}

/** A warrant row with the kind the editor starts new rows at. */
export const emptyWarrant = (kind: WarrantKind = 'measurement'): ClaimWarrant => ({ kind, text: '', ref: '' })

/** `(; source)` options for a projection, from the context's present classifiers. */
export function sourceOptions(sources: AnnotationSource[]): (AnnotationSource | null)[] {
  return [null, ...sources]
}

/** How many claims sit in each status, for the record header. */
export const claimCountByStatus = (claims: EvidenceClaim[]) => {
  const counts: Record<ClaimStatus, number> = { draft: 0, supported: 0, contested: 0, refuted: 0 }
  for (const c of claims) counts[c.status] = (counts[c.status] ?? 0) + 1
  return counts
}
