// SPDX-License-Identifier: MPL-2.0
import { describe, test, expect } from 'bun:test'
import Ajv2020 from 'ajv/dist/2020.js'
import addFormats from 'ajv-formats'
import { validateCitation } from './citation-validation.js'
import { readFileSync, readdirSync } from 'node:fs'
import { resolve, join } from 'node:path'

const schema = JSON.parse(readFileSync(resolve(import.meta.dir, '../../config/schemas/doi_publication.schema.json'), 'utf8'))
const ajv = new Ajv2020({ allErrors: true, strict: false })
addFormats(ajv)
ajv.addSchema(schema)
const validate = ajv.getSchema(schema.$id)
const fragment = key => ajv.compile({ $ref: `${schema.$id}#/$defs/${key}` })
const metadata = {
  title: 'Explicit publication', description: 'Configuration only, not analysis results.',
  creators: [{ name: 'Example, Ada', orcid: '0000-0002-1825-0097' }], license: 'CC-BY-4.0',
}

export function statusFixture() {
  return {
    schema_version: '1.0.0', id: 'a'.repeat(64), state: 'ready', environment: 'sandbox',
    binding: { config_id: '12345678-1234-4234-8234-123456789012', config_hash: 'b'.repeat(64), config_file_sha256: 'c'.repeat(64),
      dangerous: false, result_id: null, result_hash: null, result_file_sha256: null, kind: 'configuration' },
    metadata: { ...metadata, version: '1.0.0', publication_date: '2026-01-01', github_release_url: null, github_project_url: null },
    deposition_id: '101', reserved_doi: '10.5072/zenodo.101', doi: null, record_url: null,
    bundle_sha256: 'd'.repeat(64), bundle_md5: 'e'.repeat(32), bundle_size: 100,
    created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-01T00:00:00Z', published_at: null, last_error: null,
    confirmation_phrase: 'PUBLISH sandbox 101', citation: null, doi_url: null, draft_url: 'https://sandbox.zenodo.org/deposit/101', test_record: true,
  }
}

describe('versioned publication contracts', () => {
  test('JSON Schema is valid draft 2020-12 and accepts a non-citable reserved DOI', () => {
    expect(ajv.validateSchema(schema)).toBe(true)
    expect(validate(statusFixture())).toBe(true)
  })
  test('cannot claim publication merely from a reserved DOI, or confuse environments', () => {
    expect(validate({ ...statusFixture(), state: 'published' })).toBe(false)
    expect(validate({ ...statusFixture(), environment: 'production' })).toBe(false)
    expect(validate({ ...statusFixture(), doi: '10.5072/zenodo.101' })).toBe(false)
    expect(validate({ ...statusFixture(), token: 'must-not-appear' })).toBe(false)
    const fake = statusFixture(); fake.binding.result_id = '12345678-1234-4234-8234-123456789013'
    expect(validate(fake)).toBe(false)
  })
  test('prepare and publish requests require separate, explicit consent', () => {
    const prepare = fragment('prepare_request'), publish = fragment('publish_request')
    const request = { config_id: statusFixture().binding.config_id, result_id: null, metadata, acknowledge_upload: true }
    expect(prepare(request)).toBe(true)
    expect(prepare({ ...request, result_id: undefined })).toBe(false)
    expect(prepare({ ...request, acknowledge_upload: false })).toBe(false)
    expect(prepare({ ...request, token: 'forbidden' })).toBe(false)
    expect(publish({ confirmation: 'PUBLISH sandbox 101', bundle_sha256: 'd'.repeat(64), acknowledge_public: true })).toBe(true)
    expect(publish({ confirmation: 'yes', bundle_sha256: 'd'.repeat(64), acknowledge_public: true })).toBe(false)
  })
  test('metadata excludes unreviewed access modes, API origins and invalid identifiers', () => {
    const check = fragment('metadata')
    expect(check(metadata)).toBe(true)
    for (const extra of [{ creators: [] }, { license: 'default' }, { publication_date: '2026-02-30' },
      { github_release_url: 'https://evil.example/releases/tag/v1' }, { access_right: 'closed' },
      { doi: '10.5281/zenodo.1' }, { token: 'secret' }, { base_url: 'http://localhost' }]) {
      expect(check({ ...metadata, ...extra })).toBe(false)
    }
  })
  test('reserved JSON, Nickel and DEED vocabularies carry the same attestation fields', () => {
    const contract = readFileSync(resolve(import.meta.dir, '../../config/schemas/doi_publication.ncl'), 'utf8')
    const deed = readFileSync(resolve(import.meta.dir, '../../config/templates/doi_publication_chora.deed'), 'utf8')
    for (const name of Object.keys(schema.$defs.attestation.properties)) {
      expect(contract).toContain(name)
      expect(deed).toContain(`:${name.replaceAll('_', '-')}`)
    }
    expect(deed.indexOf(':schema-version "1.0.0"')).toBeLessThan(deed.indexOf(':canonical-name'))
  })
})

// CI supplies actual outputs from the Julia lifecycle suite. This branch MUST
// fail if a requested artifact directory is absent/empty; it is not a skip gate.
if (process.env.DOI_CONTRACT_ARTIFACTS) {
  test('actual Julia-emitted statuses, receipts and attestations match the schema', () => {
    const dir = process.env.DOI_CONTRACT_ARTIFACTS
    const files = readdirSync(dir).filter(f => f.endsWith('.json'))
    expect(files.length).toBeGreaterThanOrEqual(6)
    for (const name of files) {
      const check = name.startsWith('attestation-') ? fragment('attestation') : validate
      const data = JSON.parse(readFileSync(join(dir, name), 'utf8'))
      const ok = check(data)
      if (!ok) throw new Error(`${name}: ${ajv.errorsText(check.errors)}`)
      expect(ok).toBe(true)
      if (name.startsWith('attestation-')) {
        const stem = join(dir, name.slice(0, -5))
        expect(validateCitation(readFileSync(`${stem}.cff`, 'utf8')).doi).toBe(data.doi)
        // Data roundtrips, not a substitute for evaluating the Nickel contract.
        const ncl = Object.fromEntries([...readFileSync(`${stem}.ncl`, 'utf8').matchAll(/^  ([a-z0-9_]+) = (.*),$/gm)].map(([, k, v]) => [k, JSON.parse(v)]))
        expect(ncl).toEqual(data)
        const deed = Object.fromEntries([...readFileSync(`${stem}.deed`, 'utf8').matchAll(/^ +:([a-z0-9-]+) (.+)$/gm)].map(([, k, v]) => [k.replaceAll('-', '_'), v === '#f' ? false : v === '#t' ? true : JSON.parse(v)]))
        for (const [key, value] of Object.entries(data)) expect(deed[key]).toEqual(value === null ? '' : value)
        expect(deed.canonical_name).toBe(`doi-publication-${data.publication_id}`)
      }
    }
  })
}
