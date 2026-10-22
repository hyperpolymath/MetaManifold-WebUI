// SPDX-License-Identifier: AGPL-3.0-only
import { expect, test } from 'bun:test'
import {
  addValue, claimCountByStatus, defaultRequest, draftClaim, evidentialWarrants,
  newClaim, nextClaimId, parseValues, scopeSummary, slugify, statusTone, validateClaim,
} from './claims'
import { fibreFigure, formatPercent, formatSigned, residualFigure } from './figures'
import type { EvidenceClaim, EvidenceContext, FibreResult, ResidualResult } from './types'

function validClaim(): EvidenceClaim {
  return {
    id: 'genus-lactobacillus',
    text: 'Lactobacillus holds more than half the caecal reads',
    status: 'draft',
    scope: {
      table: 'merged', tag: 'rank', value: 'Genus', source: 'VSEARCH',
      values: ['Lactobacillus'],
    },
    warrant: [],
    caveats: [],
  }
}

test('a well-formed draft has no errors', () => {
  expect(validateClaim(validClaim())).toEqual([])
})

test('a claim needs an id and text', () => {
  const noId = { ...validClaim(), id: '' }
  expect(validateClaim(noId)).toContain('a claim needs an id')
  const noText = { ...validClaim(), text: '   ' }
  expect(validateClaim(noText)).toContain('a claim needs text')
})

test('unsafe identifiers are refused', () => {
  expect(validateClaim({ ...validClaim(), id: '../etc/passwd' }))
    .toContain('claim id “../etc/passwd” must be letters, digits, dots, hyphens or underscores, not starting with a dot')
  expect(validateClaim({ ...validClaim(), id: 'x'.repeat(65) }))
    .toContain('claim id “' + 'x'.repeat(65) + '” is longer than 64 characters')
})

test('a scope must name at least one value and a real projection', () => {
  const empty = { ...validClaim() }
  empty.scope = { ...empty.scope, values: [] }
  expect(validateClaim(empty)[0]).toContain('at least one value')

  const badTag = { ...validClaim() }
  badTag.scope = { ...badTag.scope, tag: 'clade' as never }
  expect(validateClaim(badTag).some(e => e.includes('scope.tag'))).toBe(true)

  const badRank = { ...validClaim() }
  badRank.scope = { ...badRank.scope, value: 'Genus; DROP TABLE merged' }
  expect(validateClaim(badRank)).toContain('scope.value “Genus; DROP TABLE merged” is not a rank name')

  const badSet = { ...validClaim() }
  badSet.scope = { ...badSet.scope, tag: 'category', value: 'not a name' }
  expect(validateClaim(badSet)).toContain('scope.value “not a name” is not a category set name')

  const badSource = { ...validClaim() }
  badSource.scope = { ...badSource.scope, source: 'BLAST' as never }
  expect(validateClaim(badSource)).toContain('scope.source must be VSEARCH, DADA2 or empty')
})

test('too many values are refused, matching the server cap', () => {
  const many = { ...validClaim() }
  many.scope = { ...many.scope, values: Array.from({ length: 51 }, (_, i) => `taxon-${i}`) }
  expect(validateClaim(many)).toContain('scope.values holds 51 values; the limit is 50')
})

test('supported requires an evidential warrant, not a definition', () => {
  const supported = { ...validClaim(), status: 'supported' as const }
  expect(validateClaim(supported).some(e => e.includes("status 'supported' needs at least one warrant"))).toBe(true)

  const defined = {
    ...supported,
    warrant: [{ kind: 'definition' as const, text: 'A bloom is a high read share' }],
  }
  expect(validateClaim(defined).some(e => e.includes("status 'supported' needs at least one warrant"))).toBe(true)
  expect(evidentialWarrants(defined)).toEqual([])

  const measured = {
    ...supported,
    warrant: [{ kind: 'measurement' as const, text: '54 % of caecal reads', ref: 'fibre:Genus/Lactobacillus' }],
  }
  expect(validateClaim(measured)).toEqual([])
  expect(evidentialWarrants(measured)).toHaveLength(1)
})

test('warrant rows are validated individually', () => {
  const badKind = { ...validClaim(), warrant: [{ kind: 'vibes' as never, text: 'feelings' }] }
  expect(validateClaim(badKind).some(e => e.includes('warrant 1 kind'))).toBe(true)

  const noText = { ...validClaim(), warrant: [{ kind: 'citation' as const, text: '' }] }
  expect(validateClaim(noText)).toContain('warrant 1 needs text')

  const tooMany = {
    ...validClaim(),
    warrant: Array.from({ length: 6 }, () => ({ kind: 'citation' as const, text: 'x' })),
  }
  expect(validateClaim(tooMany)).toContain('a claim may carry at most 5 warrants')
})

test('caveats are validated', () => {
  expect(validateClaim({ ...validClaim(), caveats: [''] })).toContain('caveats contains an empty entry')
  expect(validateClaim({ ...validClaim(), caveats: ['One site only'] })).toEqual([])
})

test('claim identifiers are slugged and made unique', () => {
  expect(slugify('Lactobacillus is enriched!')).toBe('lactobacillus-is-enriched')
  expect(slugify('  %%  ')).toBe('')
  expect(slugify('a'.repeat(200))).toHaveLength(48)

  const existing = [validClaim()]
  expect(nextClaimId(existing, 'Genus Lactobacillus')).toBe('genus-lactobacillus-2')
  expect(nextClaimId([], 'Genus Lactobacillus')).toBe('genus-lactobacillus')
  expect(nextClaimId([], '%%')).toBe('claim')
})

test('scope summaries name the projection, the fibre and the table', () => {
  expect(scopeSummary(validClaim().scope)).toBe('Genus ⊇ Lactobacillus · VSEARCH · merged')
  const set = { ...validClaim().scope, tag: 'category' as const, value: 'trophic', source: null }
  expect(scopeSummary(set)).toBe('set trophic ⊇ Lactobacillus · merged')
  expect(scopeSummary({ ...set, values: [] })).toContain('(no values)')
})

test('statuses carry distinct tones', () => {
  const tones = new Set(['draft', 'supported', 'contested', 'refuted'].map(s => statusTone(s as never)))
  expect(tones.size).toBe(4)
})

test('a draft claim starts empty but well-shaped', () => {
  const claim = newClaim({ table: 'merged_otu', tag: 'category', value: 'trophic', values: ['copiotroph'] })
  expect(claim.scope.table).toBe('merged_otu')
  expect(claim.scope.values).toEqual(['copiotroph'])
  expect(claim.status).toBe('draft')
  expect(claim.warrant).toEqual([])
  // A new claim has no id yet, which is the editor's only required pre-save fix.
  expect(validateClaim(claim)).toContain('a claim needs an id')
})

test('draftClaim tolerates a partial record without sharing arrays', () => {
  const partial = { id: 'x', text: 'y', status: 'draft' } as unknown as EvidenceClaim
  const draft = draftClaim(partial)
  expect(draft.scope.table).toBe('merged')
  expect(draft.scope.values).toEqual([])
  expect(draft.warrant).toEqual([])
  expect(draftClaim(validClaim()).scope.values).not.toBe(validClaim().scope.values)
})

test('values are split, trimmed and deduplicated', () => {
  expect(parseValues('a, b\nc , a ,,')).toEqual(['a', 'b', 'c'])
  expect(parseValues('')).toEqual([])
  expect(addValue(['a'], ' a ')).toEqual(['a'])
  expect(addValue(['a'], 'b')).toEqual(['a', 'b'])
  expect(addValue([], '  ')).toEqual([])
})

test('claim counts cover every status', () => {
  const counts = claimCountByStatus([
    validClaim(),
    { ...validClaim(), status: 'supported' },
    { ...validClaim(), status: 'supported' },
  ])
  expect(counts).toEqual({ draft: 1, supported: 2, contested: 0, refuted: 0 })
})

function fibreResult(): FibreResult {
  return {
    study: 's', run: 'r', group: null,
    table: 'merged', tag: 'rank', value: 'Genus', values: ['Lactobacillus'],
    source: 'VSEARCH', label: 'Genus', column: 'Genus',
    totals: { rows: 1000, reads: 100000 },
    fibre: {
      rows: 120, reads: 20000, row_share: 0.12, read_share: 0.2,
      samples: [
        { sample: 'a', observed: 100, total: 1000, percent: 10 },
        { sample: 'b', observed: 300, total: 1000, percent: 30 },
      ],
    },
    members: [{ member: 'ASV1', reads: 300 }],
    member_count: 1,
    members_truncated: false,
    echoes: [],
    notes: [],
  }
}

test('the fibre figure plots one share bar per sample', () => {
  const spec = fibreFigure(fibreResult())
  expect(spec.data).toHaveLength(1)
  const trace = spec.data[0]
  expect(trace.type).toBe('bar')
  expect(trace.x).toEqual(['a', 'b'])
  expect(trace.y).toEqual([10, 30])
  expect((trace.customdata as number[][])[1]).toEqual([300, 1000])
  const layout = spec.layout as { title: { text: string }, yaxis: { title: { text: string } } }
  expect(layout.title.text).toContain('Genus ⊇ Lactobacillus')
  expect(layout.yaxis.title.text).toContain('% of sample reads')
})

test('a long scope label is truncated in the figure title', () => {
  const result = fibreResult()
  result.values = ['a'.repeat(50), 'b'.repeat(50)]
  const layout = fibreFigure(result).layout as { title: { text: string } }
  expect(layout.title.text.length).toBeLessThan(160)
  expect(layout.title.text).toContain('…')
})

function residualResult(): ResidualResult {
  return {
    study: 's', run: 'r', group: null,
    table: 'merged', tag: 'rank', value: 'Genus', values: ['Lactobacillus'], source: 'VSEARCH',
    null: {
      kind: 'proportional', share: null,
      note: 'Expected reads distribute the fibre across samples as the whole library is distributed.',
    },
    fibre: { rows: 10, reads: 100, read_share: 0.2 },
    grand: { rows: 100, reads: 500 },
    samples: [
      { sample: 'd', observed: 70, expected: 20, residual: 11.18, log2_ratio: 1.79, total: 100 },
      { sample: 'a', observed: 10, expected: 20, residual: -2.24, log2_ratio: -0.94, total: 100 },
    ],
    summary: { chi2: 25, df: 3, n_samples: 4, n_usable: 4, n_excess: 1, n_deficit: 1, max_abs_residual: 11.18 },
  }
}

test('the residual figure keeps the worst residual first and colours by sign', () => {
  const spec = residualFigure(residualResult())
  const trace = spec.data[0]
  expect(trace.x).toEqual(['d', 'a'])
  expect(trace.y).toEqual([11.18, -2.24])
  expect(trace.marker).toEqual({ color: ['#2b8a3e', '#c92a2a'] })
  const shapes = (spec.layout as { shapes: { y0: number, y1: number }[] }).shapes
  expect(shapes).toHaveLength(3)
  expect(shapes.map(s => s.y0)).toEqual([0, 2, -2])
})

test('the residual figure states the null it measures against', () => {
  const proportional = residualFigure(residualResult()).layout as { title: { subtitle: { text: string } } }
  expect(proportional.title.subtitle.text).toContain('as the library is')

  const shared = residualResult()
  shared.null = { kind: 'claim_share', share: 0.5, note: '' }
  const claimShare = residualFigure(shared).layout as { title: { subtitle: { text: string } } }
  expect(claimShare.title.subtitle.text).toContain('50.0 %')
})

test('number formatting is stable', () => {
  expect(formatPercent(0.2)).toBe('20.0 %')
  expect(formatPercent(0)).toBe('0.0 %')
  expect(formatSigned(2.345)).toBe('+2.35')
  expect(formatSigned(-2.345)).toBe('-2.35')
  expect(formatSigned(0)).toBe('0.00')
})

function context(): EvidenceContext {
  return {
    study: 's', run: 'r', group: null, schema_version: 1,
    claim_statuses: ['draft', 'supported', 'contested', 'refuted'],
    warrant_kinds: ['definition', 'measurement', 'citation', 'inference'],
    claims: [], updated: null, file: 'evidence/claims.yml',
    provenance: { present: false, file: 'attestation.yml' },
    no_results: false,
    tables: [{ id: 'merged', rows: 10 }, { id: 'merged_otu', rows: 8 }],
    sources: ['VSEARCH', 'DADA2'],
    ranks: [
      { source: 'VSEARCH', names: ['Family', 'Genus'], columns: ['Family', 'Genus'] },
      { source: 'DADA2', names: ['Genus'], columns: ['Genus_dada2'] },
    ],
    merged_table: 'merged',
    category_sets: [],
  }
}

test('the default projection is the first classifier and its first rank, with no fibre', () => {
  const request = defaultRequest(context())
  expect(request.table).toBe('merged')
  expect(request.source).toBe('VSEARCH')
  expect(request.value).toBe('Family')
  expect(request.tag).toBe('rank')
  // Values start empty: the fibre must be named, never assumed.
  expect(request.values).toEqual([])
})

test('a context with no ranks opens on a category set', () => {
  const ctx = context()
  ctx.ranks = []
  ctx.sources = []
  ctx.category_sets = [{
    name: 'trophic', label: 'Trophic', description: '',
    categories: [{ name: 'copiotroph' }],
  }]
  const request = defaultRequest(ctx)
  expect(request.tag).toBe('category')
  expect(request.value).toBe('trophic')
  expect(request.source).toBeNull()
})

test('a context with neither ranks nor sets still yields a computable shape', () => {
  const ctx = context()
  ctx.ranks = []
  ctx.sources = []
  ctx.category_sets = []
  const request = defaultRequest(ctx)
  expect(request.tag).toBe('rank')
  expect(request.value).toBe('')
  expect(request.values).toEqual([])
})
