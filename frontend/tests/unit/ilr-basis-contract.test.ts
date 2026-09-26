// SPDX-License-Identifier: AGPL-3.0-only
// ILR basis inputs (issue #20) — the frontend copy of the contract table.
//
// The same table lives in four places: AnalysisConfig.jl (`_validate_ilr_inputs`,
// authoritative), the JSON schema's allOf rules, Nickel IlrBasisInputsContract and
// `ilrInputProblems` here. This file tests the frontend copy case by case and pins its
// enumerations to the JSON schema and the Julia constants, so a value added in one
// place and not the others fails the build instead of producing a form the backend
// refuses. See docs/statistics/method-conditions/ilr-bases.md.
import { describe, test, expect } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import type { AnalysisConfig, AdvancedConfig } from '../../src/types/analysis_config'
import {
  ILR_BALANCE_WEIGHTS,
  ILR_BASES,
  ILR_DENDROGRAM_METHODS,
  ILR_PART_WEIGHTS,
  ILR_SBP_ATTEMPT_DANGER_THRESHOLD,
  contextHelp,
  dangerBanner,
  ilrBasisOf,
  ilrInputProblems,
  ilrSbpAttempts,
  isDangerous,
  withIlrBasis,
  withoutIlrInputs,
} from '../../src/types/analysis_config'

const ROOT = resolve(import.meta.dir, '../../..')
const read = (p: string) => readFileSync(join(ROOT, p), 'utf8')

function base(basis: string | null = 'default', advanced: Partial<AdvancedConfig> = {}, method: 'ilr' | 'clr' = 'ilr'): AnalysisConfig {
  return {
    schema_version: '1.0.0',
    id: '00000000-0000-0000-0000-000000000000',
    created_at: '2026-09-26T00:00:00Z',
    created_by: 'test',
    method: method === 'ilr' ? 'ilr_lm' : 'clr_lm',
    formula: '~ group',
    metadata_columns: ['group'],
    normalization: { method, pseudocount: 0.5, epsilon: 1e-6, zero_policy: 'pseudocount', ilr_basis: method === 'ilr' ? basis : null },
    correction: { method: 'BH', alpha: 0.05, allow_no_correction: false, acknowledgment_token: null },
    advanced: {
      dispersion_method: 'parametric', zero_handling: 'pseudocount', zero_policy: 'pseudocount', pseudocount: 0.5,
      epsilon: 1e-6, min_prevalence: 0.1, min_abundance: 0, max_features: null, min_samples_per_group: 3, robust: false,
      acknowledgment_token: null, ...advanced,
    },
    provenance: {},
    hash: 'a'.repeat(64),
    dangerous: false,
  }
}
const H = (c: string) => c.repeat(64)
const fields = (cfg: AnalysisConfig) => ilrInputProblems(cfg).map(p => p.field)

describe('ILR basis inputs: the contract table', () => {
  test('the default basis with no inputs, and a configuration written before the fields existed, are accepted', () => {
    expect(ilrInputProblems(base())).toEqual([])
    expect(ilrInputProblems(base(null))).toEqual([])
    expect(ilrBasisOf(base(null))).toBe('default')
  })

  test('each non-default basis requires its own input', () => {
    expect(fields(base('phylogenetic'))).toEqual(['advanced.ilr_phylo_tree_path'])
    expect(fields(base('sequential_binary_partition'))).toEqual(['advanced.ilr_sbp_matrix_path'])
    expect(fields(base('balance_dendrogram'))).toEqual(['advanced.ilr_balance_dendrogram_method'])
    expect(ilrInputProblems(base('phylogenetic'))[0]!.message).toContain("requires advanced.ilr_phylo_tree_path")
  })

  test('each basis accepts its own input and its permitted options', () => {
    expect(ilrInputProblems(base('phylogenetic', { ilr_phylo_tree_path: 'data/tree.nwk', ilr_part_weights: 'gm_counts', ilr_balance_weights: 'blw_sqrt' }))).toEqual([])
    expect(ilrInputProblems(base('sequential_binary_partition', { ilr_sbp_matrix_path: 'sbp.csv', ilr_part_weights: 'anorm', ilr_sbp_history: [H('a'), H('b')] }))).toEqual([])
    expect(ilrInputProblems(base('balance_dendrogram', { ilr_balance_dendrogram_method: 'average', ilr_part_weights: 'enorm' }))).toEqual([])
  })

  test("another basis's input is refused as silently ignored", () => {
    const p = ilrInputProblems(base('phylogenetic', { ilr_phylo_tree_path: 't.nwk', ilr_sbp_matrix_path: 's.csv' }))
    expect(p.map(x => x.field)).toEqual(['advanced.ilr_sbp_matrix_path'])
    expect(p[0]!.message).toContain('silently ignored')
    expect(fields(base('default', { ilr_balance_dendrogram_method: 'ward' }))).toEqual(['advanced.ilr_balance_dendrogram_method'])
  })

  test('part weights need a non-default basis; balance weights need the phylogenetic basis; history needs the SBP basis', () => {
    expect(ilrInputProblems(base('default', { ilr_part_weights: 'anorm' }))[0]!.message).toContain('default Helmert basis is unweighted')
    expect(ilrInputProblems(base('balance_dendrogram', { ilr_balance_dendrogram_method: 'ward', ilr_balance_weights: 'blw' }))[0]!.message).toContain("only ilr_basis = 'phylogenetic'")
    expect(fields(base('balance_dendrogram', { ilr_balance_dendrogram_method: 'ward', ilr_sbp_history: [H('a')] }))).toEqual(['advanced.ilr_sbp_history'])
  })

  test('outside ILR every ILR input is refused', () => {
    const p = ilrInputProblems(base(null, { ilr_balance_dendrogram_method: 'ward', ilr_part_weights: 'anorm' }, 'clr'))
    expect(p.map(x => x.field)).toEqual(['advanced.ilr_balance_dendrogram_method', 'advanced.ilr_part_weights'])
    expect(p[0]!.message).toContain('only meaningful for the ILR transform')
    expect(ilrInputProblems(base(null, {}, 'clr'))).toEqual([])
  })

  test('paths: empty and injection-looking values are refused; digests must be SHA-256', () => {
    expect(ilrInputProblems(base('phylogenetic', { ilr_phylo_tree_path: '  ' }))[0]!.message).toContain('is empty')
    expect(ilrInputProblems(base('phylogenetic', { ilr_phylo_tree_path: 'a;rm.nwk' }))[0]!.message).toContain('not allowed in a path')
    expect(ilrInputProblems(base('phylogenetic', { ilr_phylo_tree_path: 'tree[1].nwk' }))[0]!.message).toContain('not allowed in a path')
    expect(ilrInputProblems(base('sequential_binary_partition', { ilr_sbp_matrix_path: 's.csv', ilr_sbp_history: ['abc'] }))[0]!.message).toContain('SHA-256')
    expect(ilrInputProblems(base('sequential_binary_partition', { ilr_sbp_matrix_path: 's.csv', ilr_sbp_history: [H('A')] }))).toEqual([])
  })

  test('every problem carries the field help', () => {
    for (const p of ilrInputProblems(base('phylogenetic', { ilr_sbp_matrix_path: 's.csv', ilr_balance_dendrogram_method: 'ward' }))) {
      expect(p.help).toBe(contextHelp(p.field))
      expect(p.help!.startsWith('No help available')).toBe(false)
    }
  })
})

describe('ILR basis inputs: switching', () => {
  test('switching basis clears the other bases\u2019 inputs and chooses nothing for the new one', () => {
    const phylo = base('phylogenetic', { ilr_phylo_tree_path: 't.nwk', ilr_part_weights: 'gm_counts', ilr_balance_weights: 'blw' })
    const dendro = withIlrBasis(phylo, 'balance_dendrogram')
    expect(dendro.normalization.ilr_basis).toBe('balance_dendrogram')
    expect(dendro.advanced.ilr_phylo_tree_path).toBeNull()
    expect(dendro.advanced.ilr_balance_weights).toBe('uniform')
    expect(dendro.advanced.ilr_part_weights).toBe('gm_counts')
    expect(dendro.advanced.ilr_balance_dendrogram_method).toBeNull()
    expect(fields(dendro)).toEqual(['advanced.ilr_balance_dendrogram_method'])
    const back = withIlrBasis(dendro, 'default')
    expect(ilrInputProblems(back)).toEqual([])
    expect(back.advanced.ilr_part_weights).toBe('uniform')
  })

  test('switching to the same basis keeps its inputs', () => {
    const sbp = base('sequential_binary_partition', { ilr_sbp_matrix_path: 's.csv', ilr_sbp_history: [H('a')] })
    const again = withIlrBasis(sbp, 'sequential_binary_partition')
    expect(again.advanced.ilr_sbp_matrix_path).toBe('s.csv')
    expect(again.advanced.ilr_sbp_history).toEqual([H('a')])
  })

  test('leaving ILR clears every input', () => {
    const cleared = withoutIlrInputs(base('phylogenetic', { ilr_phylo_tree_path: 't.nwk', ilr_balance_weights: 'blw' }).advanced)
    expect(ilrInputProblems({ ...base(null, {}, 'clr'), advanced: cleared })).toEqual([])
  })
})

describe('ILR basis inputs: SBP p-hacking guard', () => {
  const sbp = (history: string[]) => base('sequential_binary_partition', { ilr_sbp_matrix_path: 's.csv', ilr_sbp_history: history })

  test('distinct digests are counted (case- and duplicate-insensitive)', () => {
    expect(ilrSbpAttempts(sbp([H('a'), H('a'), H('A'), H('b')]).advanced)).toBe(2)
  })

  test(`more than ${ILR_SBP_ATTEMPT_DANGER_THRESHOLD} recorded SBPs raise the DANGER banner; ${ILR_SBP_ATTEMPT_DANGER_THRESHOLD} do not`, () => {
    expect(isDangerous(sbp([H('a'), H('b'), H('c')]))).toBe(false)
    const four = sbp([H('a'), H('b'), H('c'), H('d')])
    expect(isDangerous(four)).toBe(true)
    expect(dangerBanner(four)).toContain('SBP p-hacking guard')
    expect(dangerBanner(four)).toContain('4 distinct SBP')
  })

  test('the guard is about the SBP basis only', () => {
    // (history outside the SBP basis is refused by the contract, and never makes the banner)
    expect(isDangerous(base('phylogenetic', { ilr_phylo_tree_path: 't', ilr_sbp_history: [H('a'), H('b'), H('c'), H('d')] }))).toBe(false)
  })
})

describe('ILR basis inputs: help and cross-copy coupling', () => {
  test('every ILR field has help with its citation', () => {
    const cites: Record<string, string> = {
      'normalization.ilr_basis': 'Silverman',
      'advanced.ilr_phylo_tree_path': 'Silverman',
      'advanced.ilr_sbp_matrix_path': 'Egozcue',
      'advanced.ilr_balance_dendrogram_method': 'Pawlowsky-Glahn',
      'advanced.ilr_part_weights': 'Silverman',
      'advanced.ilr_balance_weights': 'philr',
      'advanced.ilr_sbp_history': 'forking-paths',
    }
    for (const [field, cite] of Object.entries(cites)) expect(contextHelp(field)).toContain(cite)
    expect(contextHelp('normalization.ilr_basis')).toContain('Egozcue & Pawlowsky-Glahn 2005')
    expect(contextHelp('normalization.ilr_basis')).toContain('2015')
  })

  test('enumerations agree with the JSON schema', () => {
    const schema = JSON.parse(read('config/schemas/analysis_config.schema.json'))
    const adv = schema.properties.advanced.properties
    expect(schema.properties.normalization.properties.ilr_basis.enum.filter((v: unknown) => v !== null)).toEqual([...ILR_BASES])
    expect(adv.ilr_part_weights.enum).toEqual([...ILR_PART_WEIGHTS])
    expect(adv.ilr_balance_weights.enum).toEqual([...ILR_BALANCE_WEIGHTS])
    expect(adv.ilr_balance_dendrogram_method.enum.filter((v: unknown) => v !== null)).toEqual([...ILR_DENDROGRAM_METHODS])
  })

  test('enumerations and the DANGER threshold agree with AnalysisConfig.jl', () => {
    const jl = read('src/analysis/AnalysisConfig.jl')
    const tuple = (name: string) => {
      const m = jl.match(new RegExp(`^const ${name} = \\(([^)]*)\\)`, 'm'))
      expect(m).not.toBeNull()
      return [...m![1]!.matchAll(/"([^"]+)"/g)].map(x => x[1])
    }
    expect(tuple('VALID_ILR_BASIS')).toEqual([...ILR_BASES])
    expect(tuple('VALID_ILR_PART_WEIGHTS')).toEqual([...ILR_PART_WEIGHTS])
    expect(tuple('VALID_ILR_BALANCE_WEIGHTS')).toEqual([...ILR_BALANCE_WEIGHTS])
    expect(tuple('VALID_ILR_DENDROGRAM_METHODS')).toEqual([...ILR_DENDROGRAM_METHODS])
    expect(jl).toMatch(new RegExp(`^const ILR_SBP_ATTEMPT_DANGER_THRESHOLD = ${ILR_SBP_ATTEMPT_DANGER_THRESHOLD}$`, 'm'))
  })

  test('the component module loads and exports a callable component', async () => {
    const mod = (await import('../../src/components/IlrBasisInputs')) as Record<string, unknown>
    expect(typeof mod['IlrBasisInputs']).toBe('function')
  })
})
