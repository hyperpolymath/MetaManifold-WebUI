// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Type-boundary tests — components/annotationShared.ts taxonomy rank helpers.
//
// Boundary under test: TaxonomyRank (src/types/domain/index.ts) derives from
// the canonical RANK_ORDER value found here; RANK_COL maps every
// (rank × AnnotationSource) pair onto the column names the backend actually
// serves (SOURCE src/server/routes/annotations.jl). These helpers decide
// which table columns drive the annotation form, so the invariants tested
// here are the ones the whole annotation UI depends on: (1) the mapping is
// total over ranks × sources, (2) finest-rank walking honours the canonical
// order, (3) form prefill maps only real wire columns.
//
// DOM-free module: pure functions over wire rows.
import { describe, test, expect } from 'bun:test'
import {
  findFinestRank, prefillFromRow, RANK_ORDER, RANK_COL, SOURCES,
  FUNCDB_FIELDS, CONTAM_STYLE,
} from '../../src/components/annotationShared'
import type { AnnotationSource } from '../../src/api/types'

describe('rank vocabulary invariants (the values TaxonomyRank derives from)', () => {
  test('RANK_ORDER is exactly the seven canonical ranks, finest to coarsest', () => {
    // This list is the value-level twin of the domain type union; a silent
    // edit here must fail a behavioural test, not just a type test.
    expect(RANK_ORDER).toEqual([
      'species', 'genus', 'family', 'order', 'class', 'division', 'supergroup',
    ])
  })

  test('RANK_COL is total: every rank has a column name per declared source', () => {
    for (const rank of RANK_ORDER) {
      for (const source of SOURCES) {
        expect(typeof RANK_COL[rank]?.[source]).toBe('string')
        expect(RANK_COL[rank]?.[source].length).toBeGreaterThan(0)
      }
    }
  })

  test('DADA2 columns are the VSEARCH names with the _dada2 suffix', () => {
    // Enumerated contract from the annotations pipeline; the prefill logic
    // selects by source using exactly this mapping.
    expect(RANK_COL['species']).toEqual({ VSEARCH: 'Species', DADA2: 'Species_dada2' })
    expect(RANK_COL['supergroup']).toEqual({ VSEARCH: 'Supergroup', DADA2: 'Supergroup_dada2' })
  })

  test('contamination style map is total over the ContamStatus union', () => {
    for (const status of ['unassigned', 'yes', 'no'] as const) {
      expect(CONTAM_STYLE[status]).toBeDefined()
    }
  })
})

describe('findFinestRank — canonical-order rank walking', () => {
  const vsearchRow: Record<string, unknown> = {
    Species: '', Genus: 'Malassezia', Family: 'Malasseziaceae',
  }

  test('returns the finest populated rank for the given source', () => {
    // Species is empty; genus holds the value → 'genus'.
    expect(findFinestRank(vsearchRow, 'VSEARCH')).toBe('genus')
  })

  test('parameterised: empty, whitespace, and null values are all unpopulated', () => {
    for (const blank of ['', '   ', null, undefined]) {
      const row: Record<string, unknown> = { Species: blank, Genus: 'X' }
      expect(findFinestRank(row, 'VSEARCH')).toBe('genus')
    }
  })

  test('selects per source: DADA2 walks its own column set', () => {
    // Arrange: the same logical row under both sources' column families.
    const row: Record<string, unknown> = {
      Species_dada2: 'Sporidiobolus', Genus_dada2: '', // DADA2 fine rank present
      Species: '', Genus: '',                          // VSEARCH fine ranks empty
      Family: 'Sporidiobolaceae',                      // VSEARCH family present
    }
    expect(findFinestRank(row, 'DADA2')).toBe('species')
    expect(findFinestRank(row, 'VSEARCH')).toBe('family')
  })

  test('startRank resumes the walk from a coarser position', () => {
    const row: Record<string, unknown> = { Species: 'sp', Order: 'o' }
    expect(findFinestRank(row, 'VSEARCH', 'order')).toBe('order')
    expect(findFinestRank(row, 'VSEARCH', 'species')).toBe('species')
  })

  test('an unrecognised startRank and an unpopulated row behave safely', () => {
    // Unknown start → walk from the finest rank (documented fallback).
    expect(findFinestRank(vsearchRow, 'VSEARCH', 'not-a-rank')).toBe('genus')
    // Fully empty row → null, never a fabricated rank.
    expect(findFinestRank({ Species: '' }, 'VSEARCH')).toBeNull()
  })

  test('non-string cell values still rank-populate via String() coercion', () => {
    // DuckDB can serve numeric-looking cells; the helper treats any non-null
    // non-blank value as populated.
    expect(findFinestRank({ Species: 0 }, 'VSEARCH')).toBe('species')
  })
})

describe('prefillFromRow — wire row → annotation form mapping', () => {
  test('VSEARCH source maps the plain column family; DADA2 the suffixed family', () => {
    // One logical concept: the source switch selects the correct columns.
    const row: Record<string, unknown> = {
      Domain: 'Eukaryota', Genus: 'Malassezia',        // VSEARCH family
      Domain_dada2: 'DADA', Genus_dada2: 'G_dada',     // DADA2 family
    }
    const v = prefillFromRow(row, 'VSEARCH')
    expect(v['Domain']).toBe('Eukaryota')
    expect(v['Genus']).toBe('Malassezia')
    const d = prefillFromRow(row, 'DADA2')
    expect(d['Domain']).toBe('DADA')
    expect(d['Genus']).toBe('G_dada')
  })

  test('absent and null wire values are omitted, never empty-string keys', () => {
    const row: Record<string, unknown> = { Genus: null, Family: 'F' }
    const out = prefillFromRow(row, 'VSEARCH')
    expect(out['Genus']).toBeUndefined()
    // Family's destination is the lowercase FUNCDB form key 'family'
    // (FUNCDB_FIELDS), matching how the form addresses it.
    expect(out['family']).toBe('F')
  })

  test('functional payload columns map to their form keys verbatim', () => {
    // The FUNCDB value-map is the user-visible contract of the form.
    const row: Record<string, unknown> = {
      function: 'pathogenic', detailed_function: 'keratitis',
      assoc_organism: 'Homo sapiens', human_pathogen: 'yes', reference: 'doi:10.1/x',
    }
    const out = prefillFromRow(row, 'VSEARCH')
    expect(out['Function']).toBe('pathogenic')
    expect(out['Detailed_function']).toBe('keratitis')
    expect(out['Associated_organism']).toBe('Homo sapiens')
    expect(out['Potential_human_pathogen']).toBe('yes')
    expect(out['Reference']).toBe('doi:10.1/x')
  })

  test("match_rank 'unmatched' suppresses the assignment level", () => {
    expect(prefillFromRow({ match_rank: 'unmatched' }, 'VSEARCH')['Assignment_level']).toBeUndefined()
    expect(prefillFromRow({ match_rank: 'species' }, 'VSEARCH')['Assignment_level']).toBe('species')
  })

  test('non-string cells coerce to strings (TableCell boundary)', () => {
    const out = prefillFromRow({ Genus: 12345 }, 'VSEARCH')
    expect(out['Genus']).toBe('12345')
  })

  test('FUNCDB form keys stay aligned with the prefill destinations', () => {
    // Every FUNCDB field label is a destination the prefill can produce; a
    // renamed form field without a matching prefill would silently lose data.
    const keys = FUNCDB_FIELDS.map((f) => f.key)
    const prefillDestinations = [
      'Domain', 'supergroup', 'division', 'class', 'order', 'family', 'Genus', 'Species',
      'Assignment_level', 'Function', 'Detailed_function', 'Associated_organism',
      'Associated_material', 'Environment', 'Potential_human_pathogen', 'Comment', 'Reference',
    ]
    for (const dest of prefillDestinations) {
      expect(keys).toContain(dest)
    }
  })
})

describe('SOURCES — the AnnotationSource contract', () => {
  test('exactly the two backend sources, in stable order', () => {
    expect(SOURCES).toEqual(['VSEARCH', 'DADA2'])
    // Parameterised sanity for future sources: every declared source must
    // typecheck against the API union (compile-time) — the runtime twin is
    // that findFinestRank/prefill accept it.
    for (const source of SOURCES as AnnotationSource[]) {
      expect(() => findFinestRank({}, source)).not.toThrow()
    }
  })
})
